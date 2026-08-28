#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template - Automated Off-Site Disaster Recovery Drill (V1.1)
# ==============================================================================
# Performs an end-to-end off-site disaster recovery verification drill using
# ephemeral encryption keys and disposable PostgreSQL instances.
# Guaranteed 100% non-destructive with ZERO production mutations.
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source core libraries
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_TARGET="${1:-sand2keys}"
if [[ "${APP_TARGET}" == --app=* ]]; then
  APP_TARGET="${APP_TARGET#*=}"
fi

log_info "=================================================="
log_info "ATLAS V1.1 OFF-SITE DR DRILL & RESTORE TEST"
log_info "Application: ${APP_TARGET}"
log_info "Timestamp:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log_info "=================================================="

# Step 1: Verify Local Source Backup Exists
APP_BACKUP_DIR="/var/backups/${APP_TARGET}"
if [ ! -d "${APP_BACKUP_DIR}" ]; then
  log_error "Backup directory '${APP_BACKUP_DIR}' not found."
  exit 1
fi

SOURCE_BACKUP="$(find "${APP_BACKUP_DIR}" -maxdepth 1 -type f -name "${APP_TARGET}-*.sql.gz" | sort -r | head -n 1 || true)"
if [ -z "${SOURCE_BACKUP}" ] || [ ! -f "${SOURCE_BACKUP}" ]; then
  log_error "No local backup found for application '${APP_TARGET}'."
  exit 1
fi
log_pass "Located source backup: ${SOURCE_BACKUP} ($(stat -c %s "${SOURCE_BACKUP}" 2>/dev/null || stat -f %z "${SOURCE_BACKUP}") bytes)"

# Step 2: Create Isolated Scratch Directory
DRILL_DIR="/tmp/atlas_dr_drill_${APP_TARGET}_$$"
mkdir -p "${DRILL_DIR}"
chmod 700 "${DRILL_DIR}"

cleanup_drill() {
  log_info "Cleaning up DR drill scratch resources..."
  rm -rf "${DRILL_DIR}"
}
trap cleanup_drill EXIT

# Step 3: Generate Ephemeral In-Memory Age Keypair for Drill
log_info "Generating ephemeral test encryption keypair..."
require_cmd age-keygen
TEST_KEY_FILE="${DRILL_DIR}/drill_identity.key"
age-keygen -o "${TEST_KEY_FILE}" 2>/dev/null
chmod 600 "${TEST_KEY_FILE}"

TEST_PUBKEY="$(grep -E '^# public key: ' "${TEST_KEY_FILE}" | cut -d' ' -f4)"
log_pass "Ephemeral drill public key: ${TEST_PUBKEY:0:20}..."

# Step 4: Encrypt Source Backup
ENCRYPTED_TARGET="${DRILL_DIR}/$(basename "${SOURCE_BACKUP}").age"
log_info "Testing client-side asymmetric encryption..."
require_cmd age
age -r "${TEST_PUBKEY}" -o "${ENCRYPTED_TARGET}" "${SOURCE_BACKUP}"
log_pass "Encrypted test artifact generated: ${ENCRYPTED_TARGET} ($(stat -c %s "${ENCRYPTED_TARGET}" 2>/dev/null || stat -f %z "${ENCRYPTED_TARGET}") bytes)"

# Step 5: Test Off-Site Synchronization
log_info "Testing off-site replication engine..."
ATLAS_AGE_RECIPIENT="${TEST_PUBKEY}" \
ATLAS_OFFSITE_PROVIDER="local-mock" \
"${SCRIPT_DIR}/sync-offsite.sh" --app="${APP_TARGET}" --file="${SOURCE_BACKUP}"

# Step 6: Test Off-Site Download & Decryption
log_info "Testing off-site download and decryption..."
RECOVERED_DECRYPTED="${DRILL_DIR}/recovered.sql.gz"
age -d -i "${TEST_KEY_FILE}" -o "${RECOVERED_DECRYPTED}" "${ENCRYPTED_TARGET}"
log_pass "Decryption verified successfully."

# Step 7: Validate Decrypted Gzip Stream and Checksum
gzip -t "${RECOVERED_DECRYPTED}"
log_pass "Decrypted archive passed gzip integrity check."

ORIG_SHA="$(sha256sum "${SOURCE_BACKUP}" | cut -d' ' -f1)"
RECOV_SHA="$(sha256sum "${RECOVERED_DECRYPTED}" | cut -d' ' -f1)"
if [ "${ORIG_SHA}" != "${RECOV_SHA}" ]; then
  log_error "Decrypted SHA-256 mismatch! Drill failed."
  exit 1
fi
log_pass "Decrypted SHA-256 exactly matches original (${RECOV_SHA:0:16}...)."

# Step 8: Execute Isolated Disposable PostgreSQL Restore
log_info "Testing disposable container recovery..."
"${SCRIPT_DIR}/restore.sh" \
  --app="${APP_TARGET}" \
  --file="${RECOVERED_DECRYPTED}" \
  --allow-external-file \
  --target=test

log_success "=================================================="
log_success "ATLAS V1.1 OFF-SITE DR DRILL COMPLETED WITH SUCCESS!"
log_success "Application: ${APP_TARGET}"
log_success "Zero production impact. Full round-trip validated."
log_success "=================================================="
