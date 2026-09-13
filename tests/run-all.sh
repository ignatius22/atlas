#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Comprehensive Test Runner
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

printf "\n\033[1m\033[36m==================================================\033[0m\n"
printf "\033[1m\033[36m        ATLAS V1 AUTOMATED TEST SUITE             \033[0m\n"
printf "\033[1m\033[36m==================================================\033[0m\n\n"

FAILURES=0

run_test_suite() {
  local suite_script="$1"
  local name="$2"
  
  printf "\033[1m[%s]\033[0m Running %s...\n" "$(date +%H:%M:%S)" "${name}"
  if "${suite_script}"; then
    printf "\033[32m>>> %s: SUITE PASSED\033[0m\n\n" "${name}"
  else
    printf "\033[31m>>> %s: SUITE FAILED\033[0m\n\n" "${name}"
    FAILURES=$((FAILURES + 1))
  fi
}

run_test_suite "${TEST_DIR}/test-doctor.sh" "Doctor Diagnostic Tests"
run_test_suite "${TEST_DIR}/test-backup.sh" "Backup Engine Tests"
run_test_suite "${TEST_DIR}/test-health-check.sh" "Health Check Tests"
run_test_suite "${TEST_DIR}/test-yaml.sh" "PyYAML Configuration Reader Tests"
run_test_suite "${TEST_DIR}/test-adversarial.sh" "Adversarial & Failure-Path Tests"
run_test_suite "${TEST_DIR}/test-offsite.sh" "Off-Site DR & Replication Tests"
run_test_suite "${TEST_DIR}/test-systemd.sh" "Systemd Scheduler & Installer Tests"
run_test_suite "${TEST_DIR}/test-notifications-dashboard.sh" "Notifications & Dashboard Tests"

printf "\033[1m\033[36m==================================================\033[0m\n"
if [ "${FAILURES}" -eq 0 ]; then
  printf "\033[1m\033[32mALL ATLAS TEST SUITES PASSED SUCCESSFULLY (0 failures)\033[0m\n"
  printf "\033[1m\033[36m==================================================\033[0m\n\n"
  exit 0
else
  printf "\033[1m\033[31mATLAS TEST SUITE FAILED (%d failing suites)\033[0m\n" "${FAILURES}"
  printf "\033[1m\033[36m==================================================\033[0m\n\n"
  exit 1
fi
