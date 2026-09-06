#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Off-Site Disaster Recovery & Encryption Tests (V1.1)
# ==============================================================================

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${ATLAS_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/notify.sh
source "${ATLAS_ROOT}/scripts/lib/notify.sh"

PASSED=0
FAILED=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "${expected}" == "${actual}" ]; then
    echo "  ✓ PASS: ${msg}"
    PASSED=$((PASSED + 1))
  else
    echo "  ✗ FAIL: ${msg}"
    echo "    Expected: ${expected}"
    echo "    Actual:   ${actual}"
    FAILED=$((FAILED + 1))
  fi
}

echo "=== 1. CLI Usage & Help Tests ==="
set +e
"${ATLAS_ROOT}/scripts/sync-offsite.sh" --help >/dev/null 2>&1
assert_eq 0 $? "sync-offsite.sh --help exits with 0"

"${ATLAS_ROOT}/scripts/restore-offsite.sh" --help >/dev/null 2>&1
assert_eq 0 $? "restore-offsite.sh --help exits with 0"
set -e

echo "=== 2. Notification Secret Redaction & Webhook Tests ==="
RAW_MSG="Failed backup for user postgres with password=SuperSecretPassword123 and key AGE-SECRET-KEY-1QWERTY123456"
CLEAN_MSG="$(sanitize_notification_text "${RAW_MSG}")"
echo "${CLEAN_MSG}" | grep -qv "SuperSecretPassword123"
assert_eq 0 $? "Password successfully redacted from notification text"
echo "${CLEAN_MSG}" | grep -qv "AGE-SECRET-KEY-1QWERTY123456"
assert_eq 0 $? "Age secret key successfully redacted from notification text"

# Test webhook resilience against unreachable endpoint (must not crash)
set +e
ATLAS_GENERIC_WEBHOOK="http://127.0.0.1:59999/nonexistent" send_atlas_notification "INFO" "Test" "Details" >/dev/null 2>&1
assert_eq 0 $? "send_atlas_notification gracefully handles unreachable webhook without crashing"
set -e

echo "=== 3. Off-Site Mock Sync & Recovery Cycle ==="
TMP_DIR="/tmp/atlas_test_offsite_$$"
mkdir -p "${TMP_DIR}/backups/testapp"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# Create mock valid gzip backup
MOCK_SQL="${TMP_DIR}/test.sql"
cat << 'EOF_SQL' > "${MOCK_SQL}"
-- PostgreSQL database dump
SET statement_timeout = 0;
CREATE TABLE test_table (id serial primary key, name text);
INSERT INTO test_table VALUES (1, 'Atlas DR Test');
EOF_SQL

MOCK_ARCHIVE="${TMP_DIR}/backups/testapp/testapp-20260824T120000Z.sql.gz"
gzip -9 < "${MOCK_SQL}" > "${MOCK_ARCHIVE}"
sha256sum "${MOCK_ARCHIVE}" > "${MOCK_ARCHIVE}.sha256"

# Test dry-run sync
set +e
"${ATLAS_ROOT}/scripts/sync-offsite.sh" --app=testapp --file="${MOCK_ARCHIVE}" --dry-run >/dev/null 2>&1
assert_eq 0 $? "sync-offsite.sh --dry-run completes successfully"

# Test unencrypted block when key is missing
"${ATLAS_ROOT}/scripts/sync-offsite.sh" --app=testapp --file="${MOCK_ARCHIVE}" >/dev/null 2>&1
assert_eq 1 $? "sync-offsite.sh blocks unencrypted offsite replication when key missing"
set -e

echo "=== 4. Age Cryptographic Boundary & Failure Tests ==="
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  # Keypair A
  KEY_A="${TMP_DIR}/key_a.txt"
  age-keygen -o "${KEY_A}" 2>/dev/null
  PUB_A="$(grep -E '^# public key: ' "${KEY_A}" | cut -d' ' -f4)"
  
  # Keypair B
  KEY_B="${TMP_DIR}/key_b.txt"
  age-keygen -o "${KEY_B}" 2>/dev/null
  PUB_B="$(grep -E '^# public key: ' "${KEY_B}" | cut -d' ' -f4)"
  
  # Encrypt with Key A
  ENC_FILE="${TMP_DIR}/test_encrypted.age"
  age -r "${PUB_A}" -o "${ENC_FILE}" "${MOCK_ARCHIVE}"
  assert_eq 0 $? "age encrypts archive with Public Key A"
  
  # Decrypt with correct Key A -> Should succeed
  DEC_FILE_A="${TMP_DIR}/decrypted_a.sql.gz"
  age -d -i "${KEY_A}" -o "${DEC_FILE_A}" "${ENC_FILE}" >/dev/null 2>&1
  assert_eq 0 $? "age decrypts cleanly with matching Key A"
  
  # Decrypt with WRONG Key B -> Must fail
  set +e
  DEC_FILE_B="${TMP_DIR}/decrypted_b.sql.gz"
  age -d -i "${KEY_B}" -o "${DEC_FILE_B}" "${ENC_FILE}" >/dev/null 2>&1
  assert_eq 1 $? "age rejects decryption with non-matching Key B"
  
  # Decrypt corrupted ciphertext -> Must fail
  CORRUPT_ENC="${TMP_DIR}/corrupt.age"
  cp "${ENC_FILE}" "${CORRUPT_ENC}"
  # Tamper with middle bytes
  dd if=/dev/urandom of="${CORRUPT_ENC}" bs=1 count=32 seek=100 conv=notrunc >/dev/null 2>&1
  age -d -i "${KEY_A}" -o "${TMP_DIR}/corrupt_dec.sql.gz" "${CORRUPT_ENC}" >/dev/null 2>&1
  assert_eq 1 $? "age rejects corrupted / tampered ciphertext"
  set -e
  
  # Multi-recipient encryption (Key A and Key B)
  MULTI_ENC="${TMP_DIR}/multi_enc.age"
  age -r "${PUB_A}" -r "${PUB_B}" -o "${MULTI_ENC}" "${MOCK_ARCHIVE}"
  # Both Key A and Key B must be able to decrypt
  age -d -i "${KEY_A}" -o "${TMP_DIR}/dec_multi_a.sql.gz" "${MULTI_ENC}" >/dev/null 2>&1
  assert_eq 0 $? "Multi-recipient archive decryptable by Key A"
  age -d -i "${KEY_B}" -o "${TMP_DIR}/dec_multi_b.sql.gz" "${MULTI_ENC}" >/dev/null 2>&1
  assert_eq 0 $? "Multi-recipient archive decryptable by Key B (Escrow/Rotation key)"
fi

echo "=== 5. Mutex Concurrency Lock Protection Tests ==="
LOCK_DIR="/tmp/atlas_sync_offsite.lock.d"
mkdir -p "${LOCK_DIR}"
set +e
"${ATLAS_ROOT}/scripts/sync-offsite.sh" --app=testapp --dry-run >/dev/null 2>&1
LOCK_RET=$?
set -e
assert_eq 1 "${LOCK_RET}" "sync-offsite.sh refuses to run when mutex lock directory exists"
rm -rf "${LOCK_DIR}"

echo "=== 6. Test Suite Summary ==="
echo "Passed: ${PASSED}, Failed: ${FAILED}"
if [ "${FAILED}" -gt 0 ]; then
  exit 1
fi
exit 0
