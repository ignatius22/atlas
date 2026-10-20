#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Notifications and Dashboard Tests
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

PASSED=0
FAILED=0

assert_true() {
  local condition="$1"
  local desc="$2"
  
  if eval "${condition}"; then
    printf "  \033[32m✓ PASS\033[0m: %s\n" "${desc}"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31m✗ FAIL\033[0m: %s\n" "${desc}"
    FAILED=$((FAILED + 1))
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local desc="$3"
  
  if [ -f "${file}" ] && grep -E "${pattern}" "${file}" >/dev/null 2>&1; then
    printf "  \033[32m✓ PASS\033[0m: %s\n" "${desc}"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31m✗ FAIL\033[0m: %s (pattern '%s' not found in %s)\n" "${desc}" "${pattern}" "${file}"
    FAILED=$((FAILED + 1))
  fi
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local desc="$3"
  
  if [ -f "${file}" ] && ! grep -E -i "${pattern}" "${file}" >/dev/null 2>&1; then
    printf "  \033[32m✓ PASS\033[0m: %s\n" "${desc}"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31m✗ FAIL\033[0m: %s (pattern '%s' should not be present in %s)\n" "${desc}" "${pattern}" "${file}"
    FAILED=$((FAILED + 1))
  fi
}

printf "\n\033[1m=== Running Atlas Notifications & Dashboard Tests ===\033[0m\n"

# ------------------------------------------------------------------------------
# SECTION 1: Notifications Library Tests
# ------------------------------------------------------------------------------
printf "\n\033[1m[1. Notification Sanitization & Dispatch Tests]\033[0m\n"

NOTIFY_LIB="${ATLAS_ROOT}/scripts/lib/notify.sh"
assert_true "[ -f '${NOTIFY_LIB}' ]" "scripts/lib/notify.sh exists"

# Source notification library in subshell to test behavior
TMP_TEST_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_TEST_DIR}"
}
trap cleanup EXIT

MOCK_LOG="${TMP_TEST_DIR}/mock_webhook.log"

# Test 1.1: Success notifications are suppressed by default
(
  export ATLAS_NOTIFY_SUCCESS="false"
  export ATLAS_SLACK_WEBHOOK="http://127.0.0.1:9999/mock-slack"
  source "${NOTIFY_LIB}"
  # send_atlas_notification SUCCESS should exit cleanly without making network request
  send_atlas_notification "SUCCESS" "Should Be Suppressed" "Details"
)
assert_true "[ $? -eq 0 ]" "Success notification is suppressed by default when ATLAS_NOTIFY_SUCCESS=false"

# Test 1.2: Redaction of secrets from notification payload
(
  source "${NOTIFY_LIB}"
  SANITIZED="$(sanitize_notification_text "password=supersecret and token: secrettoken123 and AGE-SECRET-KEY-1XYZ")"
  echo "${SANITIZED}" > "${TMP_TEST_DIR}/sanitized.txt"
)
assert_file_contains "${TMP_TEST_DIR}/sanitized.txt" "password=\[REDACTED\]" "Passwords redacted from notification text"
assert_file_contains "${TMP_TEST_DIR}/sanitized.txt" "token=\[REDACTED\]" "Tokens redacted from notification text"
assert_file_contains "${TMP_TEST_DIR}/sanitized.txt" "\[REDACTED_AGE_KEY\]" "Age secret keys redacted from notification text"

# Test 1.3: Repeated scheduler failure tracking
(
  export ATLAS_SCHEDULER_STATE_DIR="${TMP_TEST_DIR}/sched_state"
  export ATLAS_SCHEDULER_ALERT_THRESHOLD=2
  source "${NOTIFY_LIB}"
  
  # First failure: count = 1
  record_scheduler_run_result "failure"
  assert_true "[ -f '${ATLAS_SCHEDULER_STATE_DIR}/consecutive_failures' ]" "Failure tracking file created"
  [ "$(cat "${ATLAS_SCHEDULER_STATE_DIR}/consecutive_failures")" = "1" ]
  
  # Second failure: count = 2 (meets threshold)
  record_scheduler_run_result "failure"
  [ "$(cat "${ATLAS_SCHEDULER_STATE_DIR}/consecutive_failures")" = "2" ]
  
  # Success resets counter
  record_scheduler_run_result "success"
  [ ! -f "${ATLAS_SCHEDULER_STATE_DIR}/consecutive_failures" ]
)
assert_true "[ $? -eq 0 ]" "Repeated scheduler failure increments counter and clean success resets counter"

# Test 1.4: Webhook URLs not exposed in Git or tracked files
assert_file_not_contains "${ATLAS_ROOT}/scripts/lib/notify.sh" "https://discord.com/api/webhooks/[0-9]+" "No live Discord webhook in notify.sh"
assert_file_not_contains "${ATLAS_ROOT}/scripts/lib/notify.sh" "https://hooks.slack.com/services/[0-9]+" "No live Slack webhook in notify.sh"

# ------------------------------------------------------------------------------
# SECTION 2: Dashboard Authentication & Unit Tests
# ------------------------------------------------------------------------------
printf "\n\033[1m[2. Dashboard Token Enforcement & Binding Tests]\033[0m\n"

DASHBOARD_SCRIPT="${ATLAS_ROOT}/dashboard/server.py"
DASHBOARD_LAUNCHER="${ATLAS_ROOT}/bin/atlas-dashboard"
DASHBOARD_UNIT="${ATLAS_ROOT}/infra/atlas-dashboard.service"

assert_true "[ -f '${DASHBOARD_SCRIPT}' ]" "dashboard/server.py exists"
assert_true "[ -f '${DASHBOARD_LAUNCHER}' ]" "bin/atlas-dashboard exists"
assert_true "[ -f '${DASHBOARD_UNIT}' ]" "infra/atlas-dashboard.service exists"

# Test 2.1: server.py refuses to start when ATLAS_DASHBOARD_TOKEN is missing
set +e
MISSING_TOKEN_OUT="$(env -u ATLAS_DASHBOARD_TOKEN python3 "${DASHBOARD_SCRIPT}" 2>&1)"
MISSING_TOKEN_CODE=$?
set -e
assert_true "[ ${MISSING_TOKEN_CODE} -ne 0 ]" "dashboard/server.py refuses to start without ATLAS_DASHBOARD_TOKEN (exit code ${MISSING_TOKEN_CODE})"

# Test 2.2: bin/atlas-dashboard refuses to start when ATLAS_DASHBOARD_TOKEN is missing
set +e
LAUNCHER_OUT="$(env -u ATLAS_DASHBOARD_TOKEN "${DASHBOARD_LAUNCHER}" 8888 2>&1)"
LAUNCHER_CODE=$?
set -e
assert_true "[ ${LAUNCHER_CODE} -ne 0 ]" "bin/atlas-dashboard refuses to start without ATLAS_DASHBOARD_TOKEN (exit code ${LAUNCHER_CODE})"

# Test 2.3: Dashboard unit file directives
assert_file_contains "${DASHBOARD_UNIT}" "Environment=ATLAS_DASHBOARD_HOST=127\.0\.0\.1" "Dashboard unit specifies 127.0.0.1 local binding"
assert_file_contains "${DASHBOARD_UNIT}" "EnvironmentFile=-/opt/atlas/\.env" "Dashboard unit specifies safe EnvironmentFile loading"
assert_file_contains "${DASHBOARD_UNIT}" "ExecStart=/opt/atlas/bin/atlas-dashboard 8888" "Dashboard unit executes bin/atlas-dashboard"

# Test 2.4: Installer installs and templates infra/atlas-dashboard.service
TMP_INSTALL="${TMP_TEST_DIR}/opt/custom-atlas"
TMP_BIN="${TMP_TEST_DIR}/usr/local/bin/atlas"
TMP_SYSTEMD="${TMP_TEST_DIR}/etc/systemd/system"

ATLAS_INSTALL_DIR="${TMP_INSTALL}" \
ATLAS_BIN_LINK="${TMP_BIN}" \
ATLAS_SYSTEMD_DIR="${TMP_SYSTEMD}" \
"${ATLAS_ROOT}/scripts/install.sh" >/dev/null 2>&1

INSTALLED_DASHBOARD_UNIT="${TMP_SYSTEMD}/atlas-dashboard.service"
assert_true "[ -f '${INSTALLED_DASHBOARD_UNIT}' ]" "Installer installs atlas-dashboard.service to target systemd directory"
assert_file_contains "${INSTALLED_DASHBOARD_UNIT}" "${TMP_INSTALL}/bin/atlas-dashboard" "Installer templates custom install directory in dashboard service"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
printf "\nNotifications & Dashboard Test Results: %d passed, %d failed\n" "${PASSED}" "${FAILED}"

if [ "${FAILED}" -eq 0 ]; then
  exit 0
else
  exit 1
fi
