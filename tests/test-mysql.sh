#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — MySQL / MariaDB Backup & Restore Drill Tests
# ==============================================================================
# Parser unit tests always run. End-to-end tests (backup.sh -> drill -> real
# production restore) run against mariadb:11 and mysql:8.4 when a Docker
# daemon is reachable and the images can be pulled.
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
CONTAINERS=()
APPS=()
cleanup() {
  for c in "${CONTAINERS[@]+"${CONTAINERS[@]}"}"; do docker rm -f "${c}" > /dev/null 2>&1 || true; done
  for a in "${APPS[@]+"${APPS[@]}"}"; do rm -rf "/var/backups/${a}" 2> /dev/null || true; done
  rm -rf "${WORK}"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
printf "\n\033[1m=== MySQL Dump Manifest Unit Tests ===\033[0m\n"
# ------------------------------------------------------------------------------
# MySQL 8 style: one INSERT per line, strings containing ( ) ; ' and escapes.
cat > "${WORK}/mysql.sql" << 'SQL'
-- MySQL dump 10.13  Distrib 8.4.0, for Linux (x86_64)
CREATE TABLE `contacts` (
  `id` int NOT NULL
);
INSERT INTO `contacts` VALUES (1,'O\'Brien','semi;colon (paren'),(2,'two)) ((','back\\slash');
CREATE TABLE `odd``name` (`x` int);
INSERT INTO `odd``name` VALUES (1),(2),(3);
CREATE TABLE `empty_t` (`x` int);
-- Dump completed on 2026-10-21  3:50:41
SQL
# MariaDB 11 style: the INSERT is split across lines, one row per line.
cat > "${WORK}/maria.sql" << 'SQL'
/*M!999999\- enable the sandbox mode */
-- MariaDB dump 10.20-11.8.9-MariaDB, for debian-linux-gnu (x86_64)
CREATE TABLE `users` (`id` int, `bio` text);
INSERT INTO `users` VALUES
(1,'line one\nline two'),
(2,'it\'s (a) test;'),
(3,NULL);
-- Dump completed on 2026-10-21  3:40:00
SQL

check_manifest() {
  python3 -I "${MANIFEST_PY}" manifest "$1" > "${WORK}/m.json" && python3 -I - "${WORK}/m.json" "$2" << 'PY'
import json, sys
m = json.load(open(sys.argv[1]))
expected = json.loads(sys.argv[2])
got = {t["table"]: t["rows"] for t in m["tables"]}
assert m["engine"] == "mysql", m["engine"]
assert got == expected, (got, expected)
PY
}

if check_manifest "${WORK}/mysql.sql" '{"contacts": 2, "odd`name": 3, "empty_t": 0}'; then
  pass "MySQL single-line INSERTs: rows counted with quotes, parens and semicolons inside strings"
else
  fail "MySQL single-line INSERT parsing"
fi

if check_manifest "${WORK}/maria.sql" '{"users": 3}'; then
  pass "MariaDB multi-line INSERTs: one row per line counted correctly"
else
  fail "MariaDB multi-line INSERT parsing"
fi

head -n 6 "${WORK}/maria.sql" > "${WORK}/maria-cut.sql"
grep -v "Dump completed" "${WORK}/mysql.sql" > "${WORK}/mysql-nofooter.sql"
if ! python3 -I "${MANIFEST_PY}" manifest "${WORK}/maria-cut.sql" > /dev/null 2>&1 \
  && ! python3 -I "${MANIFEST_PY}" manifest "${WORK}/mysql-nofooter.sql" > /dev/null 2>&1; then
  pass "Truncated MySQL dumps are rejected (cut mid-INSERT, or missing the 'Dump completed' footer)"
else
  fail "Truncated MySQL dump was accepted"
fi

python3 -I "${MANIFEST_PY}" manifest "${WORK}/mysql.sql" > "${WORK}/m.json"
if python3 -I "${MANIFEST_PY}" count-sql "${WORK}/m.json" | grep -q 'FROM `odd``name`'; then
  pass "Count query uses backtick quoting for MySQL identifiers"
else
  fail "MySQL count query quoting"
fi

# ------------------------------------------------------------------------------
printf "\n\033[1m=== End-to-End MySQL & MariaDB Drills ===\033[0m\n"
# ------------------------------------------------------------------------------
run_engine() {
  local type="$1" image="$2" client="$3"
  local app="mysqltest${type}$$"
  local container="atlas_${app}"
  if ! docker image inspect "${image}" > /dev/null 2>&1 && ! docker pull -q "${image}" > /dev/null 2>&1; then
    printf "  \033[33m⚠ SKIP\033[0m: Could not pull %s\n" "${image}"
    return 0
  fi
  CONTAINERS+=("${container}")
  APPS+=("${app}")
  docker run -d --name "${container}" -e MYSQL_ROOT_PASSWORD=rootpw -e MARIADB_ROOT_PASSWORD=rootpw \
    -e MYSQL_DATABASE=shop -e MARIADB_DATABASE=shop -e MYSQL_USER=app -e MARIADB_USER=app \
    -e MYSQL_PASSWORD=apppw -e MARIADB_PASSWORD=apppw "${image}" > /dev/null
  for _ in $(seq 180); do
    if docker exec -e MYSQL_PWD=apppw "${container}" "${client}" --protocol=tcp -h127.0.0.1 -uapp shop -e 'SELECT 1' > /dev/null 2>&1; then break; fi
    sleep 1
  done
  docker exec -i -e MYSQL_PWD=apppw "${container}" "${client}" --protocol=tcp -h127.0.0.1 -uapp --default-character-set=utf8mb4 shop 2> /dev/null << 'SQL'
CREATE TABLE users (id INT PRIMARY KEY, email VARCHAR(100), bio TEXT, avatar BLOB);
INSERT INTO users VALUES (1, 'a@x.com', 'it''s (tricky); right?', 0xDEADBEEF), (2, 'b@x.com', 'paren ) and ( \\ slash', NULL);
CREATE TABLE `order items` (id INT, qty INT);
CREATE TABLE empty_t (x INT);
SQL
  # 1,000 more users and 250 order items via a numbers table (works on MySQL and MariaDB).
  docker exec -i -e MYSQL_PWD=apppw "${container}" "${client}" --protocol=tcp -h127.0.0.1 -uapp shop 2> /dev/null << 'SQL'
CREATE TABLE d (n INT); INSERT INTO d VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
INSERT INTO users (id, email, bio) SELECT 3 + a.n + b.n*10 + c.n*100, 'u@x.com', 'x' FROM d a, d b, d c;
INSERT INTO `order items` SELECT a.n + b.n*10, 1 FROM d a, d b, d c WHERE c.n < 3 AND a.n + b.n*10 < 84;
DROP TABLE d;
SQL

  cat > "${WORK}/${app}.yml" << EOF
version: "1.0"
apps:
  ${app}:
    directory: "/tmp"
    database: { type: "${type}", container: "${container}", name: "shop", user: "app", restore_image: "${image}", backup: true }
EOF
  local cfg="${WORK}/${app}.yml"
  if ATLAS_LOCK_DIR="${WORK}" "${ATLAS_ROOT}/scripts/backup.sh" --app="${app}" --config="${cfg}" > "${WORK}/${app}-backup.log" 2>&1 \
    && grep -q "3 tables, 1,254 rows" "${WORK}/${app}-backup.log"; then
    pass "${type}: backup.sh dumps the database and records 3 tables, 1,254 rows"
  else
    fail "${type}: backup: $(grep -E 'ERROR|Contents' "${WORK}/${app}-backup.log" | tail -n 3)"
    return 0
  fi
  local archive
  archive="$(ls -1 /var/backups/${app}/${app}-*.sql.gz | tail -n 1)"

  if ATLAS_LOCK_DIR="${WORK}" "${ATLAS_ROOT}/scripts/drill.sh" --app="${app}" --config="${cfg}" > "${WORK}/${app}-drill.log" 2>&1 \
    && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["passed"] and d["rows_found"] == 1254, d' "${archive}.drill.json"; then
    pass "${type}: restore drill restores into ${image} and verifies every table's row count"
  else
    fail "${type}: drill: $(grep -E 'ERROR|FAIL' "${WORK}/${app}-drill.log" | tail -n 3)"
  fi

  docker exec -e MYSQL_PWD=apppw "${container}" "${client}" --protocol=tcp -h127.0.0.1 -uapp shop -e 'DELETE FROM users WHERE id > 10' > /dev/null 2>&1
  if ATLAS_LOCK_DIR="${WORK}" "${ATLAS_ROOT}/scripts/restore.sh" --app="${app}" --file="${archive}" --target=production --force --config="${cfg}" > "${WORK}/${app}-restore.log" 2>&1 \
    && [ "$(docker exec -e MYSQL_PWD=apppw "${container}" "${client}" --protocol=tcp -h127.0.0.1 -uapp -N -B shop -e 'SELECT COUNT(*) FROM users' 2> /dev/null)" = "1002" ]; then
    pass "${type}: production restore brings deleted rows back (1,002 users)"
  else
    fail "${type}: production restore: $(grep -E 'ERROR' "${WORK}/${app}-restore.log" | tail -n 3)"
  fi
}

if [ -n "${PG_VERSION:-}" ] && [ "${PG_VERSION}" != "16" ]; then
  # The CI matrix varies Postgres only; run the MySQL end-to-end tests once.
  printf "  \033[33m⚠ SKIP\033[0m: End-to-end MySQL tests run in the PG_VERSION=16 job only\n"
elif ! docker info > /dev/null 2>&1; then
  printf "  \033[33m⚠ SKIP\033[0m: Docker daemon not reachable; end-to-end MySQL tests skipped\n"
elif ! { [ -w /var/backups ] || mkdir -p /var/backups 2> /dev/null; }; then
  printf "  \033[33m⚠ SKIP\033[0m: /var/backups not writable; end-to-end MySQL tests skipped\n"
else
  run_engine mariadb mariadb:11 mariadb
  run_engine mysql mysql:8.4 mysql
fi

printf "\n\033[1mMySQL Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
