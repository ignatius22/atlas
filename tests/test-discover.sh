#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — atlas discover
# ==============================================================================
# Starts labeled containers that look like real Compose projects, then checks
# what discover proposes and that --write produces a config backup.sh accepts.
# Requires a Docker daemon; skips otherwise.
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
DISCOVER="${ATLAS_ROOT}/scripts/lib/discover.py"

PASSED=0
FAILED=0
pass() { printf "  \033[32m✓ PASS\033[0m: %s\n" "$1"; PASSED=$((PASSED + 1)); }
fail() { printf "  \033[31m✗ FAIL\033[0m: %s\n" "$1"; FAILED=$((FAILED + 1)); }

T="dsc$$"
WORK="$(mktemp -d)"
BIND="${HOME}/atlas-discover-${T}"
cleanup() {
  for c in "${T}_db" "${T}_web" "${T}_worker" "${T}_cache"; do docker rm -f "${c}" > /dev/null 2>&1 || true; done
  docker volume rm -f "${T}_uploads" "${T}_pgdata" "${T}_cache" > /dev/null 2>&1 || true
  rm -rf "${WORK}" "${BIND}"
}
trap cleanup EXIT

printf "\n\033[1m=== atlas discover Tests ===\033[0m\n"

if ! docker info > /dev/null 2>&1; then
  printf "  \033[33m⚠ SKIP\033[0m: Docker daemon not reachable; discover tests skipped\n"
  exit 0
fi
for img in postgres:16-alpine alpine:3.20; do
  if ! docker image inspect "${img}" > /dev/null 2>&1 && ! docker pull -q "${img}" > /dev/null 2>&1; then
    printf "  \033[33m⚠ SKIP\033[0m: Could not pull %s; discover tests skipped\n" "${img}"
    exit 0
  fi
done

mkdir -p "${BIND}/storage"
L=(--label "com.docker.compose.project=${T}-blog" --label "com.docker.compose.project.working_dir=/srv/blog")
docker run -d --name "${T}_db" "${L[@]}" -e POSTGRES_USER=blogger -e POSTGRES_DB=blogdb -e POSTGRES_PASSWORD=do-not-leak-this \
  -v "${T}_pgdata:/var/lib/postgresql/data" postgres:16-alpine > /dev/null
docker run -d --name "${T}_web" "${L[@]}" -v "${T}_uploads:/app/uploads" -v "${T}_cache:/app/cache" \
  -v "${BIND}/storage:/app/storage" -v /var/run/docker.sock:/var/run/docker.sock alpine:3.20 sleep 600 > /dev/null
docker run -d --name "${T}_worker" "${L[@]}" -v "${T}_uploads:/app/uploads" alpine:3.20 sleep 600 > /dev/null
# A container in no project with nothing worth backing up must not become an app.
docker run -d --name "${T}_cache" alpine:3.20 sleep 600 > /dev/null

python3 -I "${DISCOVER}" --json > "${WORK}/out.json"
if python3 -I - "${WORK}/out.json" "${T}" "${BIND}/storage" << 'PY'
import json, sys
out, t, bind = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
app = out["new"][f"{t}-blog"]
db = app["database"]
assert (db["type"], db["container"], db["name"], db["user"]) == ("postgres", f"{t}_db", "blogdb", "blogger"), db
assert app["directory"] == "/srv/blog"
assert app["files"]["volumes"] == [f"{t}_uploads"], app["files"]          # data volume, cache and duplicates left out
assert app["files"]["paths"] == [bind], app["files"]                      # docker.sock left out
assert not any(k.startswith(f"{t}_cache") for k in out["new"]), out["new"].keys()
PY
then
  pass "Groups a Compose project: database with name/user, upload volume and storage folder; skips data, cache volumes and the docker socket"
else
  fail "Discover proposal: $(head -c 600 "${WORK}/out.json")"
fi

if ! grep -q "do-not-leak-this" "${WORK}/out.json" && ! python3 -I "${DISCOVER}" | grep -q "do-not-leak-this"; then
  pass "Database passwords are never printed"
else
  fail "Discover printed a database password"
fi

cat > "${WORK}/apps.yml" << 'EOF'
version: "1.0"
apps:
  existing:
    name: "Existing"   # keep this comment
    directory: "/tmp"
settings:
  keep: true
EOF
python3 -I "${DISCOVER}" --config "${WORK}/apps.yml" --write > /dev/null
if python3 -I - "${WORK}/apps.yml" "${T}" "${ATLAS_ROOT}/scripts/lib/vendor" << 'PY'
import sys
sys.path.append(sys.argv[3])
import yaml
text = open(sys.argv[1]).read()
d = yaml.safe_load(text)
assert "existing" in d["apps"] and f"{sys.argv[2]}-blog" in d["apps"], d["apps"].keys()
assert d["settings"] == {"keep": True}
assert "# keep this comment" in text
PY
then
  pass "--write adds new apps inside the apps block, keeps comments and other settings"
else
  fail "--write result: $(cat "${WORK}/apps.yml")"
fi

if ls "${WORK}"/apps.yml.bak-* > /dev/null 2>&1 \
  && python3 -I "${DISCOVER}" --config "${WORK}/apps.yml" | grep -q "already in"; then
  pass "--write saves a backup copy, and a second run changes nothing"
else
  fail "Backup copy or idempotence"
fi

# A configured app without a files section gets a ready-to-paste suggestion.
printf 'apps:\n  %s-blog:\n    database: {type: postgres, container: %s_db}\n' "${T}" "${T}" > "${WORK}/nofiles.yml"
if python3 -I "${DISCOVER}" --config "${WORK}/nofiles.yml" > "${WORK}/hint.txt" \
  && grep -q "its files are not backed up" "${WORK}/hint.txt" && grep -q "\"${T}_uploads\"" "${WORK}/hint.txt" \
  && cmp -s "${WORK}/nofiles.yml" <(printf 'apps:\n  %s-blog:\n    database: {type: postgres, container: %s_db}\n' "${T}" "${T}"); then
  pass "Configured apps missing a files section get a files block to paste, and the config is left untouched"
else
  fail "Files suggestion for configured app: $(cat "${WORK}/hint.txt")"
fi

if [ -w /var/backups ] || mkdir -p /var/backups 2> /dev/null; then
  if ATLAS_LOCK_DIR="${WORK}" "${ATLAS_ROOT}/scripts/backup.sh" --app="${T}-blog" --skip-files --config="${WORK}/apps.yml" > "${WORK}/b.log" 2>&1; then
    pass "backup.sh backs up the discovered app with no manual edits"
  else
    fail "backup.sh on discovered config: $(grep ERROR "${WORK}/b.log" | tail -n 2)"
  fi
  rm -rf "/var/backups/${T}-blog"
fi

printf "\n\033[1mDiscover Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
