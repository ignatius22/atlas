#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Restore Drill & Backup Manifest Tests
# ==============================================================================
# Unit tests for scripts/lib/dump_manifest.py always run.
# The end-to-end drill (real pg_dump -> backup.sh -> restore drill) runs when a
# Docker daemon is reachable, using postgres:${PG_VERSION:-16}-alpine, so the CI
# matrix exercises every supported Postgres version.
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
MANIFEST_PY="${ATLAS_ROOT}/scripts/lib/dump_manifest.py"

PASSED=0
FAILED=0
pass() { printf "  \033[32m✓ PASS\033[0m: %s\n" "$1"; PASSED=$((PASSED + 1)); }
fail() { printf "  \033[31m✗ FAIL\033[0m: %s\n" "$1"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
SRC_CONTAINER="atlas_drilltest_src_$$"
APP="drilltest$$"
cleanup() {
  docker rm -f "${SRC_CONTAINER}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" "/var/backups/${APP}" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
printf "\n\033[1m=== Backup Manifest Unit Tests ===\033[0m\n"
# ------------------------------------------------------------------------------
cat > "${WORK}/dump.sql" << 'SQL'
--
-- PostgreSQL database dump
--
CREATE TABLE public.users (id integer, email text);
CREATE TABLE billing."Invoice Items" (id integer);
CREATE TABLE public."weird.name""q" (x integer);
CREATE TABLE public.empty_t (x integer);
COPY public.users (id, email) FROM stdin;
1	a@example.com
2	line one\nline two
3	tab\there
\.
COPY billing."Invoice Items" (id) FROM stdin;
1
2
\.
COPY public."weird.name""q" (x) FROM stdin;
7
\.
COPY public.empty_t (x) FROM stdin;
\.
SQL
gzip -c "${WORK}/dump.sql" > "${WORK}/dump.sql.gz.tmp.123"

if python3 -I "${MANIFEST_PY}" manifest "${WORK}/dump.sql.gz.tmp.123" > "${WORK}/m.json" \
  && python3 -I - "${WORK}/m.json" << 'PY'
import json, sys
m = json.load(open(sys.argv[1]))
rows = {(t["schema"], t["table"]): t["rows"] for t in m["tables"]}
assert rows == {
    ("public", "users"): 3,
    ("billing", "Invoice Items"): 2,
    ("public", 'weird.name"q'): 1,
    ("public", "empty_t"): 0,
}, rows
assert m["table_count"] == 4 and m["total_rows"] == 6
PY
then
  pass "Manifest counts rows per table from a gzip dump with a .tmp name, quoted and dotted identifiers, and empty tables"
else
  fail "Manifest parsing of a gzip dump"
fi

head -n 11 "${WORK}/dump.sql" > "${WORK}/truncated.sql"
if ! python3 -I "${MANIFEST_PY}" manifest "${WORK}/truncated.sql" > /dev/null 2>&1; then
  pass "Manifest rejects a dump truncated inside a COPY block"
else
  fail "Manifest accepted a truncated dump"
fi

printf 'CREATE TABLE public.t (x int);\nINSERT INTO public.t VALUES (1);\n' > "${WORK}/inserts.sql"
if ! python3 -I "${MANIFEST_PY}" manifest "${WORK}/inserts.sql" > /dev/null 2>&1; then
  pass "Manifest refuses to report 0 tables for a dump that defines tables but has no COPY data"
else
  fail "Manifest reported an empty manifest for a dump with tables"
fi

python3 -I "${MANIFEST_PY}" count-sql "${WORK}/m.json" > "${WORK}/count.sql"
if grep -q 'FROM "public"."weird.name""q"' "${WORK}/count.sql" && grep -q 'FROM "billing"."Invoice Items"' "${WORK}/count.sql"; then
  pass "Count query quotes schema and table identifiers safely"
else
  fail "Count query identifier quoting"
fi

# manifest order: billing.Invoice Items, public.empty_t, public.users, public.weird.name"q
printf '0\t2\n1\t0\n2\t3\n3\t1\n' > "${WORK}/ok.tsv"
printf '0\t2\n1\t0\n2\t1\n' > "${WORK}/bad.tsv"
if python3 -I "${MANIFEST_PY}" compare "${WORK}/m.json" "${WORK}/ok.tsv" > /dev/null \
  && ! python3 -I "${MANIFEST_PY}" compare "${WORK}/m.json" "${WORK}/bad.tsv" > "${WORK}/bad.json" \
  && grep -q '"row count differs"' "${WORK}/bad.json" && grep -q '"missing"' "${WORK}/bad.json"; then
  pass "Comparison passes on matching counts and reports differing and missing tables"
else
  fail "Comparison of restored counts"
fi

# ------------------------------------------------------------------------------
printf "\n\033[1m=== End-to-End Restore Drill (real PostgreSQL) ===\033[0m\n"
# ------------------------------------------------------------------------------
PG_IMAGE="postgres:${PG_VERSION:-16}-alpine"
if ! docker info > /dev/null 2>&1; then
  printf "  \033[33m⚠ SKIP\033[0m: Docker daemon not reachable; end-to-end drill skipped\n"
elif ! docker image inspect "${PG_IMAGE}" > /dev/null 2>&1 && ! docker pull -q "${PG_IMAGE}" > /dev/null 2>&1; then
  printf "  \033[33m⚠ SKIP\033[0m: Could not pull %s; end-to-end drill skipped\n" "${PG_IMAGE}"
elif [ ! -w /var/backups ] && ! mkdir -p /var/backups 2> /dev/null; then
  printf "  \033[33m⚠ SKIP\033[0m: /var/backups not writable; end-to-end drill skipped\n"
else
  docker run -d --name "${SRC_CONTAINER}" -e POSTGRES_USER=app -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=shop "${PG_IMAGE}" > /dev/null
  for _ in $(seq 60); do
    if docker exec "${SRC_CONTAINER}" psql -U app -d shop -c 'SELECT 1' > /dev/null 2>&1; then break; fi
    sleep 1
  done
  docker exec -i "${SRC_CONTAINER}" psql -q -U app -d shop > /dev/null << 'SQL'
CREATE TABLE users (id serial PRIMARY KEY, email text, bio text);
INSERT INTO users (email, bio) SELECT 'u' || g || '@x.com', E'multi\nline' FROM generate_series(1, 1234) g;
CREATE SCHEMA billing;
CREATE TABLE billing."Invoice Items" (id int);
INSERT INTO billing."Invoice Items" SELECT g FROM generate_series(1, 57) g;
CREATE TABLE empty_t (x int);
SQL

  cat > "${WORK}/apps.yml" << EOF
version: "1.0"
apps:
  ${APP}:
    directory: "/tmp"
    database:
      type: "postgres"
      container: "${SRC_CONTAINER}"
      name: "shop"
      user: "app"
      restore_image: "${PG_IMAGE}"
      backup: true
EOF

  if "${ATLAS_ROOT}/scripts/backup.sh" --app="${APP}" --config="${WORK}/apps.yml" > "${WORK}/backup.log" 2>&1; then
    ARCHIVE="$(ls -1 /var/backups/${APP}/${APP}-*.sql.gz | tail -n 1)"
    if python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); assert (m["table_count"], m["total_rows"]) == (3, 1291), m' "${ARCHIVE}.manifest.json"; then
      pass "backup.sh writes a manifest with exact table and row counts (3 tables, 1,291 rows)"
    else
      fail "backup.sh manifest contents"
    fi
  else
    fail "backup.sh failed: $(tail -n 3 "${WORK}/backup.log")"
    ARCHIVE=""
  fi

  if [ -n "${ARCHIVE}" ]; then
    if ATLAS_LOCK_DIR="${WORK}" "${ATLAS_ROOT}/scripts/drill.sh" --app="${APP}" --config="${WORK}/apps.yml" > "${WORK}/drill.log" 2>&1 \
      && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["passed"] and d["tables_verified"] == 3 and d["rows_found"] == 1291, d' "${ARCHIVE}.drill.json"; then
      pass "Restore drill restores into a throwaway container and verifies every table's row count"
    else
      fail "Restore drill on a good backup: $(tail -n 3 "${WORK}/drill.log")"
    fi

    # Simulate a restore that silently loses rows: the manifest expects more than the dump holds.
    cp "${ARCHIVE}.manifest.json" "${WORK}/manifest.bak"
    python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m["tables"][-1]["rows"] += 5; json.dump(m, open(p, "w"))' "${ARCHIVE}.manifest.json"
    if ! ATLAS_LOCK_DIR="${WORK}" "${ATLAS_ROOT}/scripts/drill.sh" --app="${APP}" --config="${WORK}/apps.yml" > "${WORK}/drill-bad.log" 2>&1 \
      && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert not d["passed"] and "does not match" in d["reason"], d' "${ARCHIVE}.drill.json"; then
      pass "Restore drill fails and records why when restored row counts differ from the backup"
    else
      fail "Restore drill did not catch a row-count mismatch"
    fi
    cp "${WORK}/manifest.bak" "${ARCHIVE}.manifest.json"

    # Archives made before manifests existed are still verifiable.
    rm -f "${ARCHIVE}.manifest.json"
    if ATLAS_LOCK_DIR="${WORK}" "${ATLAS_ROOT}/scripts/drill.sh" --app="${APP}" --config="${WORK}/apps.yml" > "${WORK}/drill-legacy.log" 2>&1; then
      pass "Restore drill verifies older archives by deriving the manifest from the dump"
    else
      fail "Restore drill on an archive without a manifest"
    fi

    if [ -z "$(docker ps -aq --filter "name=atlas_restore_test_${APP}")" ]; then
      pass "Drill containers are removed afterwards"
    else
      fail "Drill left containers behind"
    fi
  fi
fi

printf "\n\033[1mRestore Drill Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
