#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — PyYAML Configuration Reader Tests
# ==============================================================================
# Tests edge cases, colons, hashes in strings/passwords, multiline strings,
# hyphenated keys, and malformed syntax.
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

PASSED=0
FAILED=0

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

assert_output_equals() {
  local expected="$1"
  local cmd="$2"
  local desc="$3"
  
  set +e
  local actual
  actual="$(eval "${cmd}" 2>&1)"
  local code=$?
  set -e
  
  if [ "${code}" -eq 0 ] && [ "${actual}" = "${expected}" ]; then
    printf "  \033[32m✓ PASS\033[0m: %s\n" "${desc}"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31m✗ FAIL\033[0m: %s\n" "${desc}"
    printf "    Expected: '%s'\n" "${expected}"
    printf "    Actual:   '%s' (exit code %d)\n" "${actual}" "${code}"
    FAILED=$((FAILED + 1))
  fi
}

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

printf "\n\033[1m\033[34m=== Running Atlas PyYAML Configuration Reader Tests ===\033[0m\n\n"

# Test 1: URLs containing colons and query parameters
URL_TEST_FILE="${TMP_DIR}/test_url.yml"
cat << 'EOF' > "${URL_TEST_FILE}"
apps:
  api-service:
    services:
      web:
        healthcheck: "http://127.0.0.1:4000/api/v1/health?token=abc:123"
EOF

assert_output_equals "http://127.0.0.1:4000/api/v1/health?token=abc:123" \
  "${ATLAS_ROOT}/scripts/lib/yaml_parser.py ${URL_TEST_FILE} apps.api-service.services.web.healthcheck" \
  "Parses URLs containing colons and query strings without truncation"

# Test 2: URLs containing hash fragments (#)
URL_HASH_FILE="${TMP_DIR}/test_url_hash.yml"
cat << 'EOF' > "${URL_HASH_FILE}"
apps:
  spa-service:
    healthcheck: "https://example.com/app/#/health-status"
EOF

assert_output_equals "https://example.com/app/#/health-status" \
  "${ATLAS_ROOT}/scripts/lib/yaml_parser.py ${URL_HASH_FILE} apps.spa-service.healthcheck" \
  "Parses URLs containing '#' hash fragments inside quotes"

# Test 3: Passwords containing '#' characters
PASS_HASH_FILE="${TMP_DIR}/test_pass_hash.yml"
cat << 'EOF' > "${PASS_HASH_FILE}"
apps:
  db-service:
    database:
      password: "P@ss#w0rd#With#Multiple#Hashes!123"
EOF

assert_output_equals "P@ss#w0rd#With#Multiple#Hashes!123" \
  "${ATLAS_ROOT}/scripts/lib/yaml_parser.py ${PASS_HASH_FILE} apps.db-service.database.password" \
  "Preserves '#' characters inside quoted passwords"

# Test 4: Arrays and domain lists
ARRAY_FILE="${TMP_DIR}/test_array.yml"
cat << 'EOF' > "${ARRAY_FILE}"
apps:
  web-app:
    domains:
      - "example.com"
      - "www.example.com"
      - "api.example.com"
EOF

assert_output_equals "example.com" \
  "${ATLAS_ROOT}/scripts/lib/yaml_parser.py ${ARRAY_FILE} apps.web-app.domains.0" \
  "Parses arrays and indexes first element correctly"

assert_output_equals "api.example.com" \
  "${ATLAS_ROOT}/scripts/lib/yaml_parser.py ${ARRAY_FILE} apps.web-app.domains.2" \
  "Parses arrays and indexes third element correctly"

# Test 5: Multiline folded and block scalars (> and |)
MULTILINE_FILE="${TMP_DIR}/test_multiline.yml"
cat << 'EOF' > "${MULTILINE_FILE}"
apps:
  app-with-multiline:
    description: >
      Line one of the description.
      Line two of the description.
    literal_block: |
      First line
      Second line
EOF

set +e
DESC_VAL="$("${ATLAS_ROOT}/scripts/lib/yaml_parser.py" "${MULTILINE_FILE}" apps.app-with-multiline.description)"
set -e
if [[ "${DESC_VAL}" == *"Line one"* ]] && [[ "${DESC_VAL}" == *"Line two"* ]]; then
  printf "  \033[32m✓ PASS\033[0m: Multiline folded scalar (>) parsed correctly\n"
  PASSED=$((PASSED + 1))
else
  printf "  \033[31m✗ FAIL\033[0m: Multiline folded scalar failed to preserve content\n"
  FAILED=$((FAILED + 1))
fi

# Test 6: Hyphenated application identifiers and keys
HYPHEN_FILE="${TMP_DIR}/test_hyphen.yml"
cat << 'EOF' > "${HYPHEN_FILE}"
apps:
  my-production-micro-service-v1:
    resource-limits:
      max-memory-limit: "512M"
EOF

assert_output_equals "512M" \
  "${ATLAS_ROOT}/scripts/lib/yaml_parser.py ${HYPHEN_FILE} apps.my-production-micro-service-v1.resource-limits.max-memory-limit" \
  "Handles hyphenated application keys and nested hyphenated attributes"

# Test 7: Malformed YAML syntax is detected and rejected with exit code 2
MALFORMED_FILE="${TMP_DIR}/test_malformed.yml"
cat << 'EOF' > "${MALFORMED_FILE}"
apps:
  bad_yaml:
    unclosed_string: "this string has no closing quote
    nested: [
EOF

assert_exit_code 2 "${ATLAS_ROOT}/scripts/lib/yaml_parser.py ${MALFORMED_FILE}" "Rejects malformed YAML with exit code 2"

# Test 8: Duplicate keys handling
DUPLICATE_KEY_FILE="${TMP_DIR}/test_dup.yml"
cat << 'EOF' > "${DUPLICATE_KEY_FILE}"
apps:
  dup-app:
    key_name: "initial_value"
    key_name: "overwritten_value"
EOF

assert_output_equals "overwritten_value" \
  "${ATLAS_ROOT}/scripts/lib/yaml_parser.py ${DUPLICATE_KEY_FILE} apps.dup-app.key_name" \
  "Handles duplicate key mapping predictably according to YAML 1.2 spec"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
printf "\n\033[1mPyYAML Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
