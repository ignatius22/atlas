#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template - Off-Site Backup Replication Engine (V1.1)
# ==============================================================================
# Encrypts local database backups with asymmetric keys (age) and synchronizes
# them securely to Cloud Object Storage (Cloudflare R2 / AWS S3).
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source core libraries
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/notify.sh
if [ -f "${SCRIPT_DIR}/lib/notify.sh" ]; then
  source "${SCRIPT_DIR}/lib/notify.sh"
fi

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
print_usage() {
  cat << EOF
Atlas Off-Site Backup Replication Engine (V1.1)

Usage:
  $(basename "$0") [options]

Options:
  -a, --app=APP_NAME      Application identifier to sync (e.g. --app=catalogflow)
  --all                   Sync all registered applications with off-site sync enabled
  -f, --file=PATH         Explicit local backup file to encrypt and sync
  -d, --dry-run           Simulate encryption and sync without uploading
  -h, --help              Show this help message

Environment Variables:
  ATLAS_OFFSITE_PROVIDER  Remote provider: 'rclone', 's3', 'r2', 'local-mock' (Default: 'auto')
  ATLAS_S3_BUCKET         Target bucket name (e.g. 'atlas-production-backups')
  ATLAS_S3_ENDPOINT       Custom S3 endpoint URL (Required for Cloudflare R2 / MinIO)
  ATLAS_AGE_RECIPIENT     Public key for client-side encryption (age1...)
  ATLAS_S3_ACCESS_KEY     Storage Access Key ID
  ATLAS_S3_SECRET_KEY     Storage Secret Access Key

Examples:
  $(basename "$0") --app=sand2keys
  $(basename "$0") --all
  $(basename "$0") --app=wdni --dry-run
EOF
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
APP_TARGET=""
SYNC_ALL="false"
EXPLICIT_FILE=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--app)
      APP_TARGET="$2"
      shift 2
      ;;
    --app=*)
      APP_TARGET="${1#*=}"
      shift
      ;;
    --all)
      SYNC_ALL="true"
      shift
      ;;
    -f|--file)
      EXPLICIT_FILE="$2"
      shift 2
      ;;
    --file=*)
      EXPLICIT_FILE="${1#*=}"
      shift
      ;;
    -d|--dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

# Load environment configuration if available
load_atlas_env

# Global Lock to prevent concurrent sync collisions
LOCK_DIR="/tmp/atlas_sync_offsite.lock.d"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log_error "Another off-site sync process is currently running. Exiting."
  exit 1
fi
cleanup_lock() {
  rm -rf "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup_lock EXIT

# ------------------------------------------------------------------------------
# Sync Function for a Single Application
# ------------------------------------------------------------------------------
sync_app_backup() {
  local app="$1"
  local backup_file="${2:-}"
  
  if ! validate_app_name "${app}"; then
    return 1
  fi
  
  log_info "=================================================="
  log_info "Starting Off-Site Sync for application: ${app}"
  log_info "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  
  local app_backup_dir="/var/backups/${app}"
  if [ -z "${backup_file}" ]; then
    if [ ! -d "${app_backup_dir}" ]; then
      log_error "Backup directory not found: ${app_backup_dir}"
      return 1
    fi
    backup_file="$(find "${app_backup_dir}" -maxdepth 1 -type f -name "${app}-*.sql.gz" | sort -r | head -n 1 || true)"
  fi
  
  if [ -z "${backup_file}" ] || [ ! -f "${backup_file}" ]; then
    log_error "No local backup file found to sync for '${app}'."
    return 1
  fi
  
  log_info "Source Local Archive: ${backup_file}"
  
  # Step 1: Pre-Sync Integrity Verification
  if ! gzip -t "${backup_file}" 2>/dev/null; then
    log_error "Local archive failed gzip integrity check: ${backup_file}"
    send_atlas_notification "CRITICAL" "Off-Site Sync Aborted" "Local archive '${backup_file}' is corrupt."
    return 1
  fi
  
  if [ -f "${backup_file}.sha256" ]; then
    local expected_sum
    expected_sum="$(cut -d' ' -f1 < "${backup_file}.sha256")"
    local actual_sum
    actual_sum="$(sha256sum "${backup_file}" | cut -d' ' -f1)"
    if [ "${expected_sum}" != "${actual_sum}" ]; then
      log_error "SHA-256 Checksum mismatch on source archive!"
      send_atlas_notification "CRITICAL" "Off-Site Sync Aborted" "Checksum mismatch on '${backup_file}'."
      return 1
    fi
  fi
  log_pass "Local archive integrity and checksum validated."
  
  # Step 2: Asymmetric Encryption
  local recipient_key="${ATLAS_AGE_RECIPIENT:-}"
  local encrypted_file="${backup_file}.age"
  local manifest_file="${backup_file}.meta.json"
  
  if [ "${DRY_RUN}" = "true" ]; then
    log_info "[DRY-RUN] Would encrypt '${backup_file}' -> '${encrypted_file}'"
    log_info "[DRY-RUN] Recipient Key: ${recipient_key:-'(simulated-key)'}"
    log_info "[DRY-RUN] Target Remote: s3://${ATLAS_S3_BUCKET:-atlas-backups}/${app}/"
    return 0
  fi
  
  # Step 2: Asymmetric Client-Side Encryption (Zero-Knowledge Invariant)
  if [ -z "${recipient_key}" ] && [ -z "${ATLAS_AGE_RECIPIENTS_FILE:-}" ]; then
    log_error "Off-site sync hard-fail: Client-side encryption key (ATLAS_AGE_RECIPIENT) is not configured."
    send_atlas_notification "FAILURE" "Off-Site Sync Blocked" "Missing encryption key for application '${app}'." || true
    return 1
  fi

  log_info "Encrypting archive with age public key(s)..."
  require_cmd age
  local age_args=()
  if [ -n "${ATLAS_AGE_RECIPIENTS_FILE:-}" ] && [ -f "${ATLAS_AGE_RECIPIENTS_FILE}" ]; then
    age_args+=(-R "${ATLAS_AGE_RECIPIENTS_FILE}")
  fi
  for r_key in $(echo "${recipient_key}" | tr ',' ' '); do
    if [ -n "${r_key}" ]; then
      age_args+=(-r "${r_key}")
    fi
  done
  if [ "${#age_args[@]}" -eq 0 ]; then
    log_error "No valid age recipient keys found."
    return 1
  fi
  age "${age_args[@]}" -o "${encrypted_file}" "${backup_file}"
  sha256sum "${encrypted_file}" > "${encrypted_file}.sha256"
  log_pass "Archive successfully encrypted (${encrypted_file})."
  
  # Step 3: Generate Metadata Manifest
  local src_bytes
  src_bytes="$(stat -c %s "${backup_file}" 2>/dev/null || stat -f %z "${backup_file}")"
  local enc_bytes
  enc_bytes="$(stat -c %s "${encrypted_file}" 2>/dev/null || stat -f %z "${encrypted_file}")"
  local enc_sha
  enc_sha="$(sha256sum "${encrypted_file}" | cut -d' ' -f1)"
  
  cat << EOF_META > "${manifest_file}"
{
  "application": "${app}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "source_file": "$(basename "${backup_file}")",
  "source_bytes": ${src_bytes},
  "encrypted_file": "$(basename "${encrypted_file}")",
  "encrypted_bytes": ${enc_bytes},
  "encrypted_sha256": "${enc_sha}",
  "encryption_type": "$([ -n "${recipient_key}" ] && echo "age-v1" || echo "none")",
  "host": "$(hostname)"
}
EOF_META

  # Step 4: Upload to Cloud Object Storage
  local bucket="${ATLAS_S3_BUCKET:-atlas-production-backups}"
  local year_month
  year_month="$(date -u +"%Y/%m")"
  local remote_prefix="atlas-backups/${app}/${year_month}"
  
  log_info "Synchronizing to Cloud Object Storage (${bucket}/${remote_prefix})..."
  
  # Provider Abstraction: rclone -> aws-cli -> local-mock
  local provider="${ATLAS_OFFSITE_PROVIDER:-auto}"
  if [ "${provider}" = "auto" ]; then
    if command -v rclone >/dev/null 2>&1; then
      provider="rclone"
    elif command -v aws >/dev/null 2>&1; then
      provider="aws"
    else
      provider="local-mock"
    fi
  fi
  
  case "${provider}" in
    rclone)
      require_cmd rclone
      export RCLONE_S3_PROVIDER="${ATLAS_S3_PROVIDER:-Cloudflare}"
      export RCLONE_S3_ENDPOINT="${ATLAS_S3_ENDPOINT:-}"
      export RCLONE_S3_ACCESS_KEY_ID="${ATLAS_S3_ACCESS_KEY:-}"
      export RCLONE_S3_SECRET_ACCESS_KEY="${ATLAS_S3_SECRET_KEY:-}"
      export RCLONE_S3_NO_CHECK_BUCKET="true"
      
      if ! rclone copyto "${encrypted_file}" ":s3:${bucket}/${remote_prefix}/$(basename "${encrypted_file}")" --s3-no-check-bucket; then
        log_error "Failed to upload encrypted archive to Cloudflare R2: $(basename "${encrypted_file}")"
        send_atlas_notification "FAILURE" "Off-Site Backup Upload Failed" "Application: \`${app}\`\nArtifact: \`$(basename "${encrypted_file}")\`\nError: Remote cloud storage rejected upload" || true
        return 1
      fi
      if [ -f "${encrypted_file}.sha256" ]; then
        if ! rclone copyto "${encrypted_file}.sha256" ":s3:${bucket}/${remote_prefix}/$(basename "${encrypted_file}.sha256")" --s3-no-check-bucket; then
          log_error "Failed to upload checksum file to Cloudflare R2"
          return 1
        fi
      fi
      if ! rclone copyto "${manifest_file}" ":s3:${bucket}/${remote_prefix}/$(basename "${manifest_file}")" --s3-no-check-bucket; then
        log_error "Failed to upload metadata manifest to Cloudflare R2"
        return 1
      fi
      ;;
      
    aws)
      require_cmd aws
      local endpoint_arg=()
      if [ -n "${ATLAS_S3_ENDPOINT:-}" ]; then
        endpoint_arg=(--endpoint-url "${ATLAS_S3_ENDPOINT}")
      fi
      aws s3 cp "${endpoint_arg[@]}" "${encrypted_file}" "s3://${bucket}/${remote_prefix}/$(basename "${encrypted_file}")"
      if [ -f "${encrypted_file}.sha256" ]; then
        aws s3 cp "${endpoint_arg[@]}" "${encrypted_file}.sha256" "s3://${bucket}/${remote_prefix}/$(basename "${encrypted_file}.sha256")"
      fi
      aws s3 cp "${endpoint_arg[@]}" "${manifest_file}" "s3://${bucket}/${remote_prefix}/$(basename "${manifest_file}")"
      ;;
      
    local-mock)
      log_warn "No cloud CLI (rclone/aws) found. Operating in local-mock sync mode."
      local mock_dir="/var/backups/offsite-mock/${remote_prefix}"
      mkdir -p "${mock_dir}"
      cp "${encrypted_file}" "${mock_dir}/"
      if [ -f "${encrypted_file}.sha256" ]; then cp "${encrypted_file}.sha256" "${mock_dir}/"; fi
      cp "${manifest_file}" "${mock_dir}/"
      log_pass "Synced to local mock repository: ${mock_dir}"
      ;;
      
    *)
      log_error "Unsupported off-site provider: ${provider}"
      return 1
      ;;
  esac
  
  log_success "Off-site sync completed successfully for '${app}'."
  send_atlas_notification "SUCCESS" "Off-Site Backup Sync Successful" "Application: \`${app}\`\nArtifact: \`$(basename "${encrypted_file}")\`\nSize: \`${enc_bytes} bytes\`"
  return 0
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
if [ "${SYNC_ALL}" = "true" ]; then
  log_info "Synchronizing all registered applications..."
  check_pyyaml_dependency
  
  APPS_LIST="$(list_registered_apps)"
  
  if [ -z "${APPS_LIST}" ]; then
    log_error "No applications found in configuration."
    exit 1
  fi
  
  OVERALL_STATUS=0
  for APP_NAME in ${APPS_LIST}; do
    sync_app_backup "${APP_NAME}" || OVERALL_STATUS=1
  done
  
  if [ "${OVERALL_STATUS}" -eq 0 ]; then
    log_success "All applications synced to off-site storage successfully."
  else
    log_error "One or more applications failed off-site replication."
    exit 1
  fi
elif [ -n "${APP_TARGET}" ]; then
  sync_app_backup "${APP_TARGET}" "${EXPLICIT_FILE}"
else
  log_error "Missing required option: Specify --app=APP_NAME or --all."
  print_usage
  exit 1
fi
