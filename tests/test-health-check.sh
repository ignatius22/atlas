#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Health Check Engine Tests
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

PASSED=0
FAILED=0

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

printf "\n\033[1m=== Running Atlas Health Check Engine Tests ===\033[0m\n"

# Test 1: Help flag returns 0
assert_exit_code 0 "${ATLAS_ROOT}/scripts/health-check.sh --help" "health-check.sh --help returns code 0"

# Test 2: Missing app argument returns code 2
assert_exit_code 2 "${ATLAS_ROOT}/scripts/health-check.sh" "health-check.sh with no arguments returns code 2"

# Test 3: Unregistered app returns code 1
assert_exit_code 1 "${ATLAS_ROOT}/scripts/health-check.sh --app=nonexistent-app-xyz --config=${ATLAS_ROOT}/config/apps.example.yml" "health-check.sh on unregistered app returns code 1"

# Test 4: Mocked HTTP probe testing via isolated test harness
TMP_DIR="$(mktemp -d)"
MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# Create a deterministic mock curl script in MOCK_BIN
cat << 'EOF' > "${MOCK_BIN}/curl"
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == *"healthy-endpoint"* ]]; then
    printf "200"
    exit 0
  fi
  if [[ "$arg" == *"failing-endpoint"* ]]; then
    printf "500"
    exit 0
  fi
done
printf "000"
exit 7
EOF
chmod +x "${MOCK_BIN}/curl"

MOCK_CONFIG_PASS="${TMP_DIR}/apps.pass.yml"
cat << EOF > "${MOCK_CONFIG_PASS}"
apps:
  mock-pass-service:
    directory: "${TMP_DIR}"
    services:
      web:
        healthcheck: "http://example.local/healthy-endpoint"
EOF

assert_exit_code 0 "PATH=\"${MOCK_BIN}:${PATH}\" ${ATLAS_ROOT}/scripts/health-check.sh --app=mock-pass-service --config=${MOCK_CONFIG_PASS} --timeout=1" "health-check.sh succeeds when HTTP probe returns 200"

# Test 5: Mocked failing HTTP probe returns code 1
MOCK_CONFIG_FAIL="${TMP_DIR}/apps.fail.yml"
cat << EOF > "${MOCK_CONFIG_FAIL}"
apps:
  mock-fail-service:
    directory: "${TMP_DIR}"
    services:
      web:
        healthcheck: "http://example.local/failing-endpoint"
EOF

assert_exit_code 1 "PATH=\"${MOCK_BIN}:${PATH}\" ${ATLAS_ROOT}/scripts/health-check.sh --app=mock-fail-service --config=${MOCK_CONFIG_FAIL} --timeout=1 --retries=1" "health-check.sh fails when HTTP probe returns non-200"

printf "\nHealth Check Tests Summary: %d passed, %d failed\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
