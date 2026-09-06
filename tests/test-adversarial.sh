#!/usr/bin/env bash
# ==============================================================================
# Atlas Adversarial & Failure-Path Test Suite
# ==============================================================================
# Tests edge cases, malicious inputs, failure propagation, corrupted archives,
# and safety abort mechanisms across Atlas V1 engines.
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

PASSED=0
FAILED=0

TMP_WORKSPACE="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_WORKSPACE}"
}
trap cleanup EXIT

assert_exit_code() {
  local expected="$1"
  local cmd="$2"
  local desc="$3"
  
  set +e
  eval "${cmd}" >/dev/null 2>&1
  local code=$?
  set -e
  
  if [ "${code}" -eq "${expected}" ]; then
    printf "  \033[32m✓ PASS\033[0m: %s (exit code %d)\n" "${desc}" "${code}"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31m✗ FAIL\033[0m: %s (expected %d, got %d)\n" "${desc}" "${expected}" "${code}"
    FAILED=$((FAILED + 1))
  fi
}

printf "\n\033[1m\033[35m=== Running Atlas Adversarial & Failure-Path Tests ===\033[0m\n\n"

# ------------------------------------------------------------------------------
# 1. Malicious Input & Command Injection Tests
# ------------------------------------------------------------------------------
printf "\033[1m[1. Injection & Malicious Argument Handling]\033[0m\n"

PWN_FILE="${TMP_WORKSPACE}/pwned_marker"
MALICIOUS_APP="test;\$(touch ${PWN_FILE});"
DUMMY_BACKUP="${TMP_WORKSPACE}/dummy.sql.gz"
echo "MOCK" | gzip -9 > "${DUMMY_BACKUP}"

assert_exit_code 1 "${ATLAS_ROOT}/scripts/backup.sh --app='${MALICIOUS_APP}' --config=${ATLAS_ROOT}/config/apps.example.yml" "backup.sh rejects command injection app name"
assert_exit_code 1 "${ATLAS_ROOT}/scripts/health-check.sh --app='${MALICIOUS_APP}' --config=${ATLAS_ROOT}/config/apps.example.yml" "health-check.sh rejects command injection app name"
assert_exit_code 1 "${ATLAS_ROOT}/scripts/deploy.sh --app='${MALICIOUS_APP}' --config=${ATLAS_ROOT}/config/apps.example.yml" "deploy.sh rejects command injection app name"
assert_exit_code 1 "${ATLAS_ROOT}/scripts/restore.sh --app='${MALICIOUS_APP}' --file=${DUMMY_BACKUP} --allow-external-file --config=${ATLAS_ROOT}/config/apps.example.yml" "restore.sh rejects command injection app name"

if [ -f "${PWN_FILE}" ]; then
  printf "  \033[31m✗ FAIL\033[0m: Command injection executed! Marker file was created.\n"
  FAILED=$((FAILED + 1))
else
  printf "  \033[32m✓ PASS\033[0m: Command injection was safely prevented (no marker created)\n"
  PASSED=$((PASSED + 1))
fi

# ------------------------------------------------------------------------------
# 2. Path Traversal & External File Tests
# ------------------------------------------------------------------------------
printf "\n\033[1m[2. Path Traversal & File Boundary Resistance]\033[0m\n"

assert_exit_code 1 "${ATLAS_ROOT}/scripts/backup.sh --app='../../etc/passwd' --config=${ATLAS_ROOT}/config/apps.example.yml" "backup.sh rejects path traversal in app argument"
assert_exit_code 2 "${ATLAS_ROOT}/scripts/restore.sh --app=example-app --config=${ATLAS_ROOT}/config/apps.example.yml --file='/nonexistent/etc/shadow/fake.sql.gz'" "restore.sh rejects non-existent backup file path"
assert_exit_code 2 "${ATLAS_ROOT}/scripts/restore.sh --app=example-app --file=${DUMMY_BACKUP} --config=${ATLAS_ROOT}/config/apps.example.yml" "restore.sh rejects external file without --allow-external-file flag"

# ------------------------------------------------------------------------------
# 3. Corrupted & Tampered Archive Verification in restore.sh
# ------------------------------------------------------------------------------
printf "\n\033[1m[3. Archive Corruption & Checksum Tampering Tests]\033[0m\n"

# Create a corrupt (truncated) gzip archive
CORRUPT_ARCHIVE="${TMP_WORKSPACE}/corrupt.sql.gz"
echo "THIS IS NOT VALID GZIP DATA" > "${CORRUPT_ARCHIVE}"

assert_exit_code 1 "${ATLAS_ROOT}/scripts/restore.sh --app=example-app --file=${CORRUPT_ARCHIVE} --allow-external-file --config=${ATLAS_ROOT}/config/apps.example.yml --target=test" "restore.sh aborts on corrupted gzip stream"

# Create a valid gzip archive with a tampered SHA-256 checksum file
VALID_ARCHIVE="${TMP_WORKSPACE}/valid.sql.gz"
echo "CREATE TABLE valid (id int);" | gzip -9 > "${VALID_ARCHIVE}"
echo "0000000000000000000000000000000000000000000000000000000000000000  valid.sql.gz" > "${VALID_ARCHIVE}.sha256"

assert_exit_code 1 "${ATLAS_ROOT}/scripts/restore.sh --app=example-app --file=${VALID_ARCHIVE} --allow-external-file --config=${ATLAS_ROOT}/config/apps.example.yml --target=test" "restore.sh aborts on SHA-256 checksum mismatch"

# ------------------------------------------------------------------------------
# 4. Production Restore Safety & Confirmation Bypass Tests
# ------------------------------------------------------------------------------
printf "\n\033[1m[4. Production Restore Safeguard & Confirmation Tests]\033[0m\n"

# Verify that an incorrect confirmation string aborts production restore with code 1
assert_exit_code 1 "echo 'WRONG_CONFIRMATION_STRING' | ${ATLAS_ROOT}/scripts/restore.sh --app=example-app --file=${VALID_ARCHIVE} --allow-external-file --config=${ATLAS_ROOT}/config/apps.example.yml --target=production" "restore.sh aborts production restore when confirmation string does not match"

# Verify that empty confirmation (EOF) aborts production restore with code 1
assert_exit_code 1 "echo '' | ${ATLAS_ROOT}/scripts/restore.sh --app=example-app --file=${VALID_ARCHIVE} --allow-external-file --config=${ATLAS_ROOT}/config/apps.example.yml --target=production" "restore.sh aborts production restore on empty confirmation string"

# ------------------------------------------------------------------------------
# 5. Deployment Engine Failure & Hook Injection Handling
# ------------------------------------------------------------------------------
printf "\n\033[1m[5. Deployment Engine Failure & Hook Security Handling]\033[0m\n"

# Deploy against an app pointing to a missing directory
APP_MISSING_DIR_CONFIG="${TMP_WORKSPACE}/missing_dir.yml"
cat << EOF > "${APP_MISSING_DIR_CONFIG}"
apps:
  missing-dir-app:
    directory: "/tmp/nonexistent_atlas_directory_xyz"
    compose_file: "docker-compose.yml"
EOF

assert_exit_code 1 "${ATLAS_ROOT}/scripts/deploy.sh --app=missing-dir-app --config=${APP_MISSING_DIR_CONFIG}" "deploy.sh aborts when application directory does not exist"

# Deploy against an app pointing to a missing compose file
MOCK_APP_DIR="${TMP_WORKSPACE}/mock_app"
mkdir -p "${MOCK_APP_DIR}"
APP_MISSING_COMPOSE_CONFIG="${TMP_WORKSPACE}/missing_compose.yml"
cat << EOF > "${APP_MISSING_COMPOSE_CONFIG}"
apps:
  missing-compose-app:
    directory: "${MOCK_APP_DIR}"
    compose_file: "missing-docker-compose.yml"
EOF

assert_exit_code 1 "${ATLAS_ROOT}/scripts/deploy.sh --app=missing-compose-app --config=${APP_MISSING_COMPOSE_CONFIG}" "deploy.sh aborts when compose file does not exist"

# Deploy attempting shell injection via pre_deploy_hook
APP_HOOK_INJECTION="${TMP_WORKSPACE}/hook_injection.yml"
cat << EOF > "${APP_HOOK_INJECTION}"
apps:
  hook-inject-app:
    directory: "${MOCK_APP_DIR}"
    compose_file: "docker-compose.yml"
    deployment:
      pre_deploy_hook: "echo pwned; rm -rf /tmp/pwned"
EOF

assert_exit_code 1 "${ATLAS_ROOT}/scripts/deploy.sh --app=hook-inject-app --config=${APP_HOOK_INJECTION}" "deploy.sh rejects shell injection characters in pre_deploy_hook"

# ------------------------------------------------------------------------------
# 6. SSL Setup Script Validation
# ------------------------------------------------------------------------------
printf "\n\033[1m[6. SSL Setup Script Validation]\033[0m\n"

assert_exit_code 2 "${ATLAS_ROOT}/scripts/setup-ssl.sh" "setup-ssl.sh with no domain returns code 2"
assert_exit_code 2 "${ATLAS_ROOT}/scripts/setup-ssl.sh -d 'invalid_domain_name'" "setup-ssl.sh rejects invalid domain format with code 2"
assert_exit_code 2 "${ATLAS_ROOT}/scripts/setup-ssl.sh -d 'example.com; rm -rf /'" "setup-ssl.sh rejects command injection in domain flag"

# ------------------------------------------------------------------------------
# 7. Dashboard Security, Authentication & Injection Resistance
# ------------------------------------------------------------------------------
printf "\n\033[1m[7. Dashboard Security, Authentication & Injection Resistance]\033[0m\n"

python3 - << 'EOF'
import os
import sys
import json
import time
import socket
import threading
import urllib.request
import urllib.error
from pathlib import Path

# Add project root to path
test_dir = Path.cwd()
sys.path.insert(0, str(test_dir))
from dashboard import server

# 1. Test validate_app_name allowlist
valid_cases = ["catalogflow", "sand2keys", "wdni_prod", "app-123", "--all"]
for v in valid_cases:
    ok, app, err = server.validate_app_name(v, allow_all=True)
    assert ok, f"Expected '{v}' to be valid, got error: {err}"

invalid_cases = [
    "catalogflow; id",
    "catalogflow && id",
    "catalogflow | id",
    "$(id)",
    "`id`",
    "../../../etc",
    "foo/bar",
    "foo baz",
    "app\nreboot",
    "app\x00inject",
    "",
    "   ",
]
for inv in invalid_cases:
    ok, app, err = server.validate_app_name(inv, allow_all=True)
    assert not ok, f"Expected '{inv}' to be rejected, but got accepted"

# Non-string rejection
ok, _, _ = server.validate_app_name(12345, allow_all=True)
assert not ok, "Expected integer app to be rejected"

# 2. Spin up test server on ephemeral port
test_port = 8998
test_token = "atlas-test-secret-token"
os.environ["ATLAS_DASHBOARD_PORT"] = str(test_port)
os.environ["ATLAS_DASHBOARD_HOST"] = "127.0.0.1"
os.environ["ATLAS_DASHBOARD_TOKEN"] = test_token

assert server.HOST == "127.0.0.1" or os.environ.get("ATLAS_DASHBOARD_HOST") == "127.0.0.1"

httpd = server.HTTPServer(("127.0.0.1", test_port), server.AtlasDashboardHandler)
t = threading.Thread(target=httpd.serve_forever, daemon=True)
t.start()
time.sleep(0.3)

base_url = f"http://127.0.0.1:{test_port}"

def make_req(path, data=None, headers=None):
    url = f"{base_url}{path}"
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    req_body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=req_body, headers=req_headers, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read().decode("utf-8"), dict(resp.getheaders())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8"), dict(e.headers)

# 3. Test Auth on mutating endpoints
for endpoint in ["/api/actions/backup", "/api/actions/sync", "/api/actions/restore-test"]:
    st, body, _ = make_req(endpoint, data={"app": "test"})
    assert st == 401, f"Expected 401 without auth header on {endpoint}, got {st}"
    
    st, body, _ = make_req(endpoint, data={"app": "test"}, headers={"X-Atlas-Token": "invalid-token"})
    assert st == 401, f"Expected 401 with invalid token on {endpoint}, got {st}"

# 4. Test CORS
st, body, headers = make_req("/api/status")
lower_headers = {k.lower(): v for k, v in headers.items()}
assert "access-control-allow-origin" not in lower_headers, "Wildcard Access-Control-Allow-Origin must not be present"

# 5. Test Injection payload rejection via API
auth_headers = {"X-Atlas-Token": test_token}
pwn_file = "/tmp/atlas_dashboard_test_pwned"
if os.path.exists(pwn_file):
    os.remove(pwn_file)

for payload in [
    {"app": f"catalogflow; touch {pwn_file}"},
    {"app": f"catalogflow && touch {pwn_file}"},
    {"app": f"`touch {pwn_file}`"},
    {"app": f"$(touch {pwn_file})"},
    {"app": "foo | bar"},
    {"app": "../../../etc"},
]:
    st, body, _ = make_req("/api/actions/backup", data=payload, headers=auth_headers)
    assert st == 400, f"Expected HTTP 400 for payload {payload}, got {st}: {body}"
    assert not os.path.exists(pwn_file), f"Command injection executed for {payload}!"

# 6. Test restore-test endpoint requires app
st, body, _ = make_req("/api/actions/restore-test", data={"app": "--all"}, headers=auth_headers)
assert st == 400, f"Expected HTTP 400 for restore-test with --all, got {st}"

httpd.shutdown()
EOF
if [ $? -eq 0 ]; then
  printf "  \033[32m✓ PASS\033[0m: Dashboard input validation, X-Atlas-Token auth & CORS verified\n"
  PASSED=$((PASSED + 1))
else
  printf "  \033[31m✗ FAIL\033[0m: Dashboard security verification failed\n"
  FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
printf "\n\033[1mAdversarial Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
