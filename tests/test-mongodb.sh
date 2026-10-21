#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — MongoDB Backup, Restore Drill & Production Restore
# ==============================================================================
# Runs end to end against mongo:7 with authentication, when a Docker daemon is
# reachable and the image can be pulled. In CI it runs in the PG_VERSION=16
# job only.
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
MANIFEST_PY="${ATLAS_ROOT}/scripts/lib/dump_manifest.py"

PASSED=0
FAILED=0
pass() { printf "  \033[32m✓ PASS\033[0m: %s\n" "$1"; PASSED=$((PASSED + 1)); }
fail() { printf "  \033[31m✗ FAIL\033[0m: %s\n" "$1"; FAILED=$((FAILED + 1)); }
skip() { printf "  \033[33m⚠ SKIP\033[0m: %s\n" "$1"; }

T="atlasmongo$$"
APP="${T}-notes"
WORK="$(mktemp -d)"
IMAGE="${ATLAS_TEST_MONGO_IMAGE:-mongo:7}"
# Quotes, a backslash, a dollar sign and a space: must survive every layer.
PASSWORD='s3c"re\t'"'"'$pw d'
cleanup() {
  docker rm -f "${T}_db" > /dev/null 2>&1 || true
  rm -rf "${WORK}" "/var/backups/${APP}" 2> /dev/null || true
}
trap cleanup EXIT

printf "\n\033[1m=== MongoDB Backup & Restore Tests ===\033[0m\n"

if [ -n "${PG_VERSION:-}" ] && [ "${PG_VERSION}" != "16" ]; then
  skip "End-to-end MongoDB tests run in the PG_VERSION=16 job only"
  exit 0
fi
if ! docker info > /dev/null 2>&1; then
  skip "Docker daemon not reachable; MongoDB tests skipped"
  exit 0
fi
if ! { [ -w /var/backups ] || mkdir -p /var/backups 2> /dev/null; }; then
  skip "/var/backups not writable; MongoDB tests skipped"
  exit 0
fi
if ! docker image inspect "${IMAGE}" > /dev/null 2>&1 && ! docker pull -q "${IMAGE}" > /dev/null 2>&1; then
  skip "Could not pull ${IMAGE}"
  exit 0
fi

mongo_eval() { # mongo_eval <js>  (authenticated, inside the production container)
  docker exec "${T}_db" sh -c 'exec mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$1"' _ "$1"
}

docker run -d --name "${T}_db" -e MONGO_INITDB_ROOT_USERNAME=root -e "MONGO_INITDB_ROOT_PASSWORD=${PASSWORD}" "${IMAGE}" > /dev/null
for _ in $(seq 60); do
  mongo_eval 'db.runCommand({ping: 1}).ok' 2> /dev/null | grep -q 1 && break
  sleep 1
done
mongo_eval '
  const n = db.getSiblingDB("notes");
  n.pages.insertMany([...Array(5000).keys()].map(i => ({ i, body: "line\nwith \u0000 nul and \"quotes\"", tags: ["a", "b"] })));
  n.authors.insertMany([{ name: "Ada" }, { name: "Grace" }, { name: "Linus" }]);
  n.createCollection("drafts");
  n.createView("recent", "pages", [{ $match: { i: { $gt: 4990 } } }]);
  db.getSiblingDB("billing").invoices.insertMany([{ total: 10 }, { total: 20 }]);
' > /dev/null

cat > "${WORK}/apps.yml" << EOF
apps:
  ${APP}:
    database:
      type: mongodb
      container: ${T}_db
EOF
run() { ATLAS_LOCK_DIR="${WORK}" "$@" --config="${WORK}/apps.yml"; }

# 1. Backup with authentication and exact counts read from the archive
if run "${ATLAS_ROOT}/scripts/backup.sh" --app="${APP}" --skip-files > "${WORK}/backup.log" 2>&1; then
  ARCHIVE="$(find "/var/backups/${APP}" -name "${APP}-*.sql.gz" | sort | tail -n 1)"
  if python3 -I - "${ARCHIVE}.manifest.json" << 'PY'
import json, sys
m = json.load(open(sys.argv[1]))
got = {(t["schema"], t["table"]): t["rows"] for t in m["tables"]}
assert m["engine"] == "mongodb", m["engine"]
assert got == {("notes", "pages"): 5000, ("notes", "authors"): 3, ("notes", "drafts"): 0, ("billing", "invoices"): 2}, got
PY
  then
    pass "Backs up every database with auth and records exact document counts (view and admin excluded, empty collection kept)"
  else
    fail "MongoDB manifest: $(cat "${ARCHIVE}.manifest.json")"
  fi
else
  fail "MongoDB backup: $(grep ERROR "${WORK}/backup.log" | tail -n 2)"
  ARCHIVE=""
fi

# 2. No credentials left behind or exposed
if ! docker exec "${T}_db" sh -c 'grep -rls "password:" /tmp 2>/dev/null' | grep -q . \
  && ! grep -qF "${PASSWORD}" "${WORK}/backup.log"; then
  pass "Password with quotes, backslash and \$ works, is not left in the container, and is never logged"
else
  fail "Credential handling"
fi

if [ -n "${ARCHIVE}" ]; then
  # 3. A cut-off archive is rejected
  (set +o pipefail; gzip -dc "${ARCHIVE}" 2> /dev/null | head -c 40000 | gzip > "${WORK}/cut.sql.gz")
  if ! python3 -I "${MANIFEST_PY}" manifest "${WORK}/cut.sql.gz" > /dev/null 2> "${WORK}/cut.err" && grep -q "truncated" "${WORK}/cut.err"; then
    pass "A truncated archive is detected and rejected"
  else
    fail "Truncated archive accepted"
  fi

  # 4. Restore drill
  if run "${ATLAS_ROOT}/scripts/restore.sh" --app="${APP}" --target=test > "${WORK}/drill.log" 2>&1 \
    && grep -q "4 collections, 5,005 documents" "${WORK}/drill.log" \
    && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["passed"] and d["engine"] == "mongodb" and d["rows_found"] == 5005' "${ARCHIVE}.drill.json"; then
    pass "Restore drill restores into a throwaway MongoDB and verifies every collection's count"
  else
    fail "MongoDB drill: $(grep -E 'ERROR|FAIL' "${WORK}/drill.log" | tail -n 3)"
  fi

  # 5. The drill catches missing data
  cp "${ARCHIVE}.manifest.json" "${WORK}/manifest.bak"
  python3 -I - "${ARCHIVE}.manifest.json" << 'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for t in m["tables"]:
    if t["table"] == "pages":
        t["rows"] += 7
m["total_rows"] += 7
json.dump(m, open(sys.argv[1], "w"))
PY
  if ! run "${ATLAS_ROOT}/scripts/restore.sh" --app="${APP}" --target=test > "${WORK}/bad.log" 2>&1 \
    && grep -q "notes.pages has 5,000 documents, expected 5,007" "${WORK}/bad.log"; then
    pass "A drill fails, naming the collection, when restored data does not match the backup"
  else
    fail "Mismatch not caught: $(grep -E 'ERROR|FAIL' "${WORK}/bad.log" | tail -n 2)"
  fi
  cp "${WORK}/manifest.bak" "${ARCHIVE}.manifest.json"

  # 6. Production restore after data loss
  mongo_eval 'db.getSiblingDB("notes").pages.deleteMany({ i: { $gte: 100 } }); db.getSiblingDB("billing").invoices.drop()' > /dev/null
  if run "${ATLAS_ROOT}/scripts/restore.sh" --app="${APP}" --target=production --force --file="${ARCHIVE}" > "${WORK}/prod.log" 2>&1 \
    && [ "$(mongo_eval 'print(db.getSiblingDB("notes").pages.countDocuments({}) + "/" + db.getSiblingDB("billing").invoices.countDocuments({}) + "/" + db.getSiblingDB("notes").recent.countDocuments({}))' | tail -n 1)" = "5000/2/9" ]; then
    pass "Production restore brings back deleted documents and dropped collections (views included), after a safety backup"
  else
    fail "Production restore: $(grep -E 'ERROR' "${WORK}/prod.log" | tail -n 2)"
  fi
fi

printf "\n\033[1mMongoDB Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
