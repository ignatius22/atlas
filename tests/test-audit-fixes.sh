#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Regression tests for the November 2026 audit findings
# ==============================================================================
#   1. One backup directory for every script (atlas_paths.py)
#   2. A drill that finds no backups fails instead of exiting 0
#   3. Dashboard: Host allowlist (DNS rebinding), token on root-running GETs,
#      one action at a time
#   4. Offsite restore uses an unpredictable private temp directory
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
PATHS="${ATLAS_ROOT}/scripts/lib/atlas_paths.py"

PASSED=0
FAILED=0
pass() { printf "  \033[32m✓ PASS\033[0m: %s\n" "$1"; PASSED=$((PASSED + 1)); }
fail() { printf "  \033[31m✗ FAIL\033[0m: %s\n" "$1"; FAILED=$((FAILED + 1)); }
skip() { printf "  \033[33m⚠ SKIP\033[0m: %s\n" "$1"; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "${SERVER_PID}" ]; then kill "${SERVER_PID}" 2> /dev/null || true; wait "${SERVER_PID}" 2> /dev/null || true; fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

# Run the resolver with a clean environment so the developer's own settings
# don't leak into the result.
resolve() { env -i PATH="${PATH}" "$@" python3 -I "${PATHS}" backup-dir 2> /dev/null; }

printf "\n\033[1m=== 1. Backup directory resolution ===\033[0m\n"

if [ "$(resolve ATLAS_BACKUP_DIR="${WORK}/a" ATLAS_BACKUP_STORAGE_DIR="${WORK}/b")" = "${WORK}/a" ]; then
  pass "ATLAS_BACKUP_DIR overrides everything"
else fail "ATLAS_BACKUP_DIR did not take precedence"; fi

if [ "$(resolve ATLAS_BACKUP_STORAGE_DIR="${WORK}/b")" = "${WORK}/b" ]; then
  pass "ATLAS_BACKUP_STORAGE_DIR from .env is honoured (it used to be ignored)"
else fail "ATLAS_BACKUP_STORAGE_DIR was ignored"; fi

printf 'backup:\n  storage_dir: "%s/c"\n' "${WORK}" > "${WORK}/backup.yml"
if [ "$(resolve ATLAS_BACKUP_CONFIG_FILE="${WORK}/backup.yml")" = "${WORK}/c" ]; then
  pass "backup.storage_dir in backup.yml is honoured"
else fail "backup.storage_dir was ignored"; fi

if [ "$(env -i PATH="${PATH}" ATLAS_BACKUP_CONFIG_FILE="${WORK}/missing.yml" python3 -I - "${ATLAS_ROOT}" << 'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/lib")
import atlas_paths
print(atlas_paths.backup_dir(env={}, root="/nonexistent"))
PY
)" = "/var/backups" ]; then
  pass "Defaults to /var/backups when nothing is configured"
else fail "Default backup directory is not /var/backups"; fi

for bad in "relative/dir" "/var/backups/../etc"; do
  if resolve ATLAS_BACKUP_DIR="${bad}" > /dev/null; then
    fail "Unsafe backup directory accepted: ${bad}"
  else
    pass "Unsafe backup directory rejected: ${bad}"
  fi
done

# common.sh exports the resolved value, so every script and child process agrees.
if [ "$(env -i PATH="${PATH}" HOME="${HOME}" ATLAS_BACKUP_STORAGE_DIR="${WORK}/b" bash -c "source '${ATLAS_ROOT}/scripts/lib/common.sh' && echo \"\${ATLAS_BACKUP_DIR}\"")" = "${WORK}/b" ]; then
  pass "common.sh exports ATLAS_BACKUP_DIR for every script"
else fail "common.sh did not export the resolved directory"; fi

if env -i PATH="${PATH}" HOME="${HOME}" ATLAS_BACKUP_DIR="relative" bash -c "source '${ATLAS_ROOT}/scripts/lib/common.sh'" > /dev/null 2>&1; then
  fail "Scripts start with an invalid backup directory"
else
  pass "Scripts refuse to start with an invalid backup directory"
fi

# No script may hardcode the directory again (the offsite-mock provider is a
# fake bucket for tests, not the local backup directory).
offenders="$(grep -rnE '"/var/backups(/|")' "${ATLAS_ROOT}/scripts" "${ATLAS_ROOT}/bin" "${ATLAS_ROOT}/dashboard/server.py" \
  | grep -v '/var/backups/offsite-mock' | grep -v 'KEY_SCAN_DIRS' | grep -vE '^[^:]+:[0-9]+:\s*#' \
  | grep -v 'scripts/lib/atlas_paths.py' | grep -v 'scripts/setup-server.sh' || true)"
if [ -z "${offenders}" ]; then
  pass "No script hardcodes /var/backups"
else
  fail "Hardcoded /var/backups found:"; printf '%s\n' "${offenders}"
fi

printf "\n\033[1m=== 2. Drill with no backups ===\033[0m\n"

if ! command -v flock > /dev/null 2>&1 || ! command -v docker > /dev/null 2>&1; then
  skip "flock or docker not available; drill exit-code test skipped"
else
  cat > "${WORK}/apps.yml" << 'YAML'
apps:
  ghost:
    database:
      type: postgres
      container: ghost_db
      name: ghost
      user: ghost
YAML
  mkdir -p "${WORK}/backups/ghost"
  set +e
  ATLAS_BACKUP_DIR="${WORK}/backups" ATLAS_LOCK_DIR="${WORK}/locks" \
    "${ATLAS_ROOT}/scripts/drill.sh" --all --config="${WORK}/apps.yml" > "${WORK}/drill.out" 2>&1
  rc=$?
  set -e
  if [ "${rc}" -ne 0 ] && grep -q "No backups of 'ghost'" "${WORK}/drill.out"; then
    pass "Drill fails (exit ${rc}) when a configured app has no backups"
  else
    fail "Drill exited ${rc} with no backups to verify"; cat "${WORK}/drill.out"
  fi
fi

printf "\n\033[1m=== 3. Dashboard request handling ===\033[0m\n"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
mkdir -p "${WORK}/backups"
ATLAS_DASHBOARD_TOKEN="test-token-0123456789abcdef0123456789" ATLAS_DASHBOARD_PORT="${PORT}" \
  ATLAS_BACKUP_DIR="${WORK}/backups" python3 -I "${ATLAS_ROOT}/dashboard/server.py" > "${WORK}/server.log" 2>&1 &
SERVER_PID=$!

# http.client lets the test set any Host header, as a rebinding browser would.
request() { # request METHOD PATH HOST [TOKEN] -> prints the status code
  python3 -I - "${PORT}" "$@" << 'PY'
import http.client, sys
port, method, path, host = sys.argv[1:5]
headers = {"Host": host, "Content-Type": "application/json"}
if len(sys.argv) > 5:
    headers["X-Atlas-Token"] = sys.argv[5]
conn = http.client.HTTPConnection("127.0.0.1", int(port), timeout=10)
conn.request(method, path, body="{}" if method == "POST" else None, headers=headers)
print(conn.getresponse().status)
PY
}

for _ in $(seq 1 50); do
  [ "$(request GET /api/health "127.0.0.1:${PORT}" 2> /dev/null)" = "200" ] && break
  sleep 0.2
done

check() { # check EXPECTED DESCRIPTION METHOD PATH HOST [TOKEN]
  local expected="$1" desc="$2"; shift 2
  local got
  got="$(request "$@" 2> /dev/null || echo error)"
  if [ "${got}" = "${expected}" ]; then pass "${desc} (${got})"; else fail "${desc}: expected ${expected}, got ${got}"; fi
}

check 200 "Request addressed to 127.0.0.1 is served" GET /api/health "127.0.0.1:${PORT}"
check 200 "localhost on another tunnel port is served" GET /api/health "localhost:9999"
check 421 "Rebinding Host header is refused" GET /api/health "evil.example:${PORT}"
check 421 "Lookalike Host header is refused" GET /api/status "localhost.evil.example"
check 421 "Static files are refused to a foreign Host too" GET / "evil.example"
check 401 "/api/doctor needs the token" GET /api/doctor "localhost:${PORT}"
check 401 "/api/preflight needs the token" GET /api/preflight "localhost:${PORT}"
check 401 "Actions need the token" POST /api/actions/backup "localhost:${PORT}"
check 401 "A wrong token is refused" POST /api/actions/sync "localhost:${PORT}" "wrong-token"
check 404 "Unknown POST paths are 404" POST /api/actions/nope "localhost:${PORT}" "test-token-0123456789abcdef0123456789"

if grep -q "ThreadingHTTPServer(" "${ATLAS_ROOT}/dashboard/server.py" && grep -q "ACTION_LOCK.acquire(blocking=False)" "${ATLAS_ROOT}/dashboard/server.py"; then
  pass "Dashboard is threaded and runs one action at a time"
else fail "Dashboard is not threaded with a single-action lock"; fi

printf "\n\033[1m=== 4. Offsite restore temp directory ===\033[0m\n"

if grep -q 'RESTORE_WORK_DIR="$(mktemp -d' "${ATLAS_ROOT}/scripts/restore-offsite.sh" \
   && ! grep -q 'atlas_restore_work_' "${ATLAS_ROOT}/scripts/restore-offsite.sh"; then
  pass "Offsite restore uses mktemp -d, not a predictable /tmp path"
else fail "Offsite restore still uses a predictable temp path"; fi

if grep -q '(umask 077 && cp "${KEY_FILE}"' "${ATLAS_ROOT}/scripts/restore-offsite.sh"; then
  pass "Private key copy is created with umask 077"
else fail "Private key copy is not created private"; fi

printf "\n  %d passed, %d failed\n" "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
