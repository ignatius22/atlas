#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Doctor Diagnostic Tests
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

printf "\n\033[1m=== Running Atlas Doctor Tests ===\033[0m\n"

# Test 1: Help flag returns 0
assert_exit_code 0 "${ATLAS_ROOT}/bin/doctor --help" "doctor --help returns code 0"

# Test 2: Invalid flag returns code 2
assert_exit_code 2 "${ATLAS_ROOT}/bin/doctor --invalid-flag-1234" "doctor with unknown option returns code 2"

# Test 3: Missing option value returns code 2
assert_exit_code 2 "${ATLAS_ROOT}/bin/doctor --config" "doctor --config without argument returns code 2"

# Test 4: Doctor execution with example config returns valid status (0 or 1, not 2 usage error)
set +e
"${ATLAS_ROOT}/bin/doctor" --config="${ATLAS_ROOT}/config/apps.example.yml" >/dev/null 2>&1
RUN_CODE=$?
set -e
if [ "${RUN_CODE}" -eq 0 ] || [ "${RUN_CODE}" -eq 1 ]; then
  printf "  \033[32m✓ PASS\033[0m: doctor runs with example config without syntax error (exit code %d)\n" "${RUN_CODE}"
  PASSED=$((PASSED + 1))
else
  printf "  \033[31m✗ FAIL\033[0m: doctor crashed with invalid exit code %d\n" "${RUN_CODE}"
  FAILED=$((FAILED + 1))
fi

# Test 5: Doctor execution with non-existent config file returns code 1 or 2
set +e
"${ATLAS_ROOT}/bin/doctor" --config="/nonexistent/path/apps.yml" >/dev/null 2>&1
MISSING_CODE=$?
set -e
if [ "${MISSING_CODE}" -ge 1 ]; then
  printf "  \033[32m✓ PASS\033[0m: doctor fails appropriately on missing config file (exit code %d)\n" "${MISSING_CODE}"
  PASSED=$((PASSED + 1))
else
  printf "  \033[31m✗ FAIL\033[0m: doctor unexpectedly succeeded on missing config (exit code %d)\n" "${MISSING_CODE}"
  FAILED=$((FAILED + 1))
fi

printf "\nDoctor Tests Summary: %d passed, %d failed\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
