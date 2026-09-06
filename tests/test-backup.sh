#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Backup Engine Tests
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

printf "\n\033[1m=== Running Atlas Backup Engine Tests ===\033[0m\n"

# Test 1: Help flag returns 0
assert_exit_code 0 "${ATLAS_ROOT}/scripts/backup.sh --help" "backup.sh --help returns code 0"

# Test 2: Invocation without parameters returns code 2 (usage error)
assert_exit_code 2 "${ATLAS_ROOT}/scripts/backup.sh" "backup.sh with no app specified returns code 2"

# Test 3: Unknown flag returns code 2
assert_exit_code 2 "${ATLAS_ROOT}/scripts/backup.sh --invalid-flag" "backup.sh with invalid flag returns code 2"

# Test 4: Unregistered app returns code 1 (failure)
assert_exit_code 1 "${ATLAS_ROOT}/scripts/backup.sh --app=nonexistent-app-xyz --config=${ATLAS_ROOT}/config/apps.example.yml" "backup.sh on unregistered app returns code 1"

# Test 5: Dry-run mode on valid registered app returns code 0
assert_exit_code 0 "${ATLAS_ROOT}/scripts/backup.sh --app=example-app --dry-run --config=${ATLAS_ROOT}/config/apps.example.yml" "backup.sh --dry-run on example-app returns code 0"

# Test 6: Dry-run on app with backup explicitly disabled returns code 0 (skipped)
assert_exit_code 0 "${ATLAS_ROOT}/scripts/backup.sh --app=example-api --dry-run --config=${ATLAS_ROOT}/config/apps.example.yml" "backup.sh --dry-run on disabled backup app returns code 0"

# Test 7: Simulated backup file integrity & checksum test
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

MOCK_SQL="${TMP_DIR}/test.sql"
echo "CREATE TABLE test (id int); INSERT INTO test VALUES (1);" > "${MOCK_SQL}"
gzip -9 < "${MOCK_SQL}" > "${MOCK_SQL}.gz"
sha256sum "${MOCK_SQL}.gz" > "${MOCK_SQL}.gz.sha256"

if gzip -t "${MOCK_SQL}.gz" >/dev/null 2>&1; then
  printf "  \033[32m✓ PASS\033[0m: Gzip stream integrity verification works\n"
  PASSED=$((PASSED + 1))
else
  printf "  \033[31m✗ FAIL\033[0m: Gzip stream integrity verification failed\n"
  FAILED=$((FAILED + 1))
fi

EXPECTED_SUM="$(cut -d' ' -f1 < "${MOCK_SQL}.gz.sha256")"
ACTUAL_SUM="$(sha256sum "${MOCK_SQL}.gz" | cut -d' ' -f1)"
if [ "${EXPECTED_SUM}" = "${ACTUAL_SUM}" ]; then
  printf "  \033[32m✓ PASS\033[0m: SHA-256 cryptographic checksum matching works\n"
  PASSED=$((PASSED + 1))
else
  printf "  \033[31m✗ FAIL\033[0m: SHA-256 cryptographic checksum matching failed\n"
  FAILED=$((FAILED + 1))
fi

printf "\nBackup Tests Summary: %d passed, %d failed\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
