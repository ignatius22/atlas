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
# Sync a Single Specific Backup File to Cloud Storage
# ------------------------------------------------------------------------------
sync_single_file() {
  local app="$1"
  local backup_file="$2"
  
  if [ -z "${backup_file}" ] || [ ! -f "${backup_file}" ]; then
    log_error "Backup file not found: '${backup_file}'"
    return 1
  fi
  
  local synced_marker="${backup_file}.synced"
  if [ -f "${synced_marker}" ]; then
    log_info "Backup already synced and verified (.synced exists): $(basename "${backup_file}")"
    return 0
  fi
  
  log_info "Processing sync for: $(basename "${backup_file}")"
  
  # Step 1: Pre-Sync Integrity Verification
  if ! gzip -t "${backup_file}" 2>/dev/null; then
    log_error "Local archive failed gzip integrity check: ${backup_file}"
    send_atlas_notification "CRITICAL" "Off-Site Sync Aborted" "Local archive '${backup_file}' is corrupt." || true
    return 1
  fi
  
  if [ -f "${backup_file}.sha256" ]; then
    local expected_sum
    expected_sum="$(cut -d' ' -f1 < "${backup_file}.sha256")"
    local actual_sum
    actual_sum="$(sha256sum "${backup_file}" | cut -d' ' -f1)"
    if [ "${expected_sum}" != "${actual_sum}" ]; then
      log_error "SHA-256 Checksum mismatch on source archive!"
      send_atlas_notification "CRITICAL" "Off-Site Sync Aborted" "Checksum mismatch on '${backup_file}'." || true
      return 1
    fi
  fi
  log_pass "Local archive integrity and checksum validated: $(basename "${backup_file}")"
  
  # Step 2: Asymmetric Encryption
  local recipient_key="${ATLAS_AGE_RECIPIENT:-}"
  local encrypted_file="${backup_file}.age"
  local manifest_file="${backup_file}.meta.json"
  
  if [ "${DRY_RUN}" = "true" ]; then
    log_info "[DRY-RUN] Would encrypt '${backup_file}' -> '${encrypted_file}'"
    log_info "[DRY-RUN] Recipient Key: ${recipient_key:-'(simulated-key)'}"
    log_info "[DRY-RUN] Target Remote: s3://${ATLAS_S3_BUCKET:-atlas-production-backups}/${app}/"
    return 0
  fi
  
  # Asymmetric Client-Side Encryption (Zero-Knowledge Invariant)
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
  local remote_enc_name="$(basename "${encrypted_file}")"
  
  # Step 4 & 5: Upload to Cloud Object Storage with Bounded Retry (Max 3 attempts, exponential backoff)
  local max_attempts=3
  local attempt=1
  local backoff_sec=5
  local sync_success=false

  while [ "${attempt}" -le "${max_attempts}" ]; do
    log_info "Attempt ${attempt}/${max_attempts}: Synchronizing to Cloud Storage (${bucket}/${remote_prefix})..."
    
    local upload_ok=true
    case "${provider}" in
      rclone)
        require_cmd rclone
        export RCLONE_S3_PROVIDER="${ATLAS_S3_PROVIDER:-Cloudflare}"
        export RCLONE_S3_ENDPOINT="${ATLAS_S3_ENDPOINT:-}"
        export RCLONE_S3_ACCESS_KEY_ID="${ATLAS_S3_ACCESS_KEY:-}"
        export RCLONE_S3_SECRET_ACCESS_KEY="${ATLAS_S3_SECRET_KEY:-}"
        export RCLONE_S3_NO_CHECK_BUCKET="true"
        
        if ! rclone copyto "${encrypted_file}" ":s3:${bucket}/${remote_prefix}/${remote_enc_name}" --s3-no-check-bucket; then
          log_warn "rclone upload failed for ${remote_enc_name} (attempt ${attempt}/${max_attempts})"
          upload_ok=false
        fi
        if [ "${upload_ok}" = "true" ] && [ -f "${encrypted_file}.sha256" ]; then
          if ! rclone copyto "${encrypted_file}.sha256" ":s3:${bucket}/${remote_prefix}/${remote_enc_name}.sha256" --s3-no-check-bucket; then
            log_warn "rclone checksum upload failed (attempt ${attempt}/${max_attempts})"
            upload_ok=false
          fi
        fi
        if [ "${upload_ok}" = "true" ]; then
          if ! rclone copyto "${manifest_file}" ":s3:${bucket}/${remote_prefix}/$(basename "${manifest_file}")" --s3-no-check-bucket; then
            log_warn "rclone manifest upload failed (attempt ${attempt}/${max_attempts})"
            upload_ok=false
          fi
        fi
        
        # Step 5: Remote Verification Gate
        if [ "${upload_ok}" = "true" ]; then
          log_info "Verifying remote object existence on Cloud Storage..."
          if rclone lsf ":s3:${bucket}/${remote_prefix}/${remote_enc_name}" --s3-no-check-bucket 2>/dev/null | grep -q "^${remote_enc_name}$"; then
            sync_success=true
            break
          else
            log_warn "Remote verification failed for '${remote_enc_name}' (attempt ${attempt}/${max_attempts})"
          fi
        fi
        ;;
        
      aws)
        require_cmd aws
        local endpoint_arg=()
        if [ -n "${ATLAS_S3_ENDPOINT:-}" ]; then
          endpoint_arg=(--endpoint-url "${ATLAS_S3_ENDPOINT}")
        fi
        if ! aws s3 cp "${endpoint_arg[@]}" "${encrypted_file}" "s3://${bucket}/${remote_prefix}/${remote_enc_name}"; then
          upload_ok=false
        fi
        if [ "${upload_ok}" = "true" ] && [ -f "${encrypted_file}.sha256" ]; then
          if ! aws s3 cp "${endpoint_arg[@]}" "${encrypted_file}.sha256" "s3://${bucket}/${remote_prefix}/${remote_enc_name}.sha256"; then
            upload_ok=false
          fi
        fi
        if [ "${upload_ok}" = "true" ]; then
          if ! aws s3 cp "${endpoint_arg[@]}" "${manifest_file}" "s3://${bucket}/${remote_prefix}/$(basename "${manifest_file}")"; then
            upload_ok=false
          fi
        fi
        
        if [ "${upload_ok}" = "true" ]; then
          if aws s3 ls "${endpoint_arg[@]}" "s3://${bucket}/${remote_prefix}/${remote_enc_name}" | grep -q "${remote_enc_name}"; then
            sync_success=true
            break
          else
            log_warn "Remote verification failed for '${remote_enc_name}' (attempt ${attempt}/${max_attempts})"
          fi
        fi
        ;;
        
      local-mock)
        local mock_dir="/var/backups/offsite-mock/${remote_prefix}"
        mkdir -p "${mock_dir}"
        cp "${encrypted_file}" "${mock_dir}/"
        if [ -f "${encrypted_file}.sha256" ]; then cp "${encrypted_file}.sha256" "${mock_dir}/"; fi
        cp "${manifest_file}" "${mock_dir}/"
        
        if [ -s "${mock_dir}/${remote_enc_name}" ]; then
          log_pass "Verified mock remote storage: ${mock_dir}/${remote_enc_name}"
          sync_success=true
          break
        else
          log_warn "Mock remote verification failed (attempt ${attempt}/${max_attempts})"
        fi
        ;;
        
      *)
        log_error "Unsupported off-site provider: ${provider}"
        return 1
        ;;
    esac

    if [ "${attempt}" -lt "${max_attempts}" ]; then
      log_warn "Sync attempt ${attempt} failed. Retrying in ${backoff_sec}s (bounded retry)..."
      sleep "${backoff_sec}"
      backoff_sec=$((backoff_sec * 2))
    fi
    attempt=$((attempt + 1))
  done

  if [ "${sync_success}" != "true" ]; then
    log_error "Off-site sync failed after ${max_attempts} attempts for '${app}': ${remote_enc_name}"
    send_atlas_notification "FAILURE" "Off-Site Backup Upload Failed" "Application: \`${app}\`\nArtifact: \`${remote_enc_name}\`\nError: Remote cloud storage rejected upload after ${max_attempts} bounded attempts" || true
    return 1
  fi
  
  # Step 6: Atomic Durability Marker Creation
  local temp_marker="${synced_marker}.tmp.$$"
  cat << EOF_SYNC > "${temp_marker}"
{
  "application": "${app}",
  "synced_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "source_file": "$(basename "${backup_file}")",
  "encrypted_file": "${remote_enc_name}",
  "remote_destination": "s3://${bucket}/${remote_prefix}/${remote_enc_name}",
  "encrypted_bytes": ${enc_bytes},
  "encrypted_sha256": "${enc_sha}",
  "verified": true
}
EOF_SYNC
  mv -f "${temp_marker}" "${synced_marker}"
  log_pass "Durability authorization marker recorded: ${synced_marker}"
  
  log_success "Off-site sync & verification completed for '$(basename "${backup_file}")'."
  send_atlas_notification "SUCCESS" "Off-Site Backup Sync Successful" "Application: \`${app}\`\nArtifact: \`${remote_enc_name}\`\nSize: \`${enc_bytes} bytes\`" || true
  return 0
}

# ------------------------------------------------------------------------------
# Sync Function for an Application (Discovers Backlog or Processes Explicit File)
# ------------------------------------------------------------------------------
sync_app_backup() {
  local app="$1"
  local explicit_file="${2:-}"
  
  if ! validate_app_name "${app}"; then
    return 1
  fi
  
  log_info "=================================================="
  log_info "Starting Off-Site Sync for application: ${app}"
  log_info "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  
  local app_backup_dir="/var/backups/${app}"
  
  # Explicit file mode
  if [ -n "${explicit_file}" ]; then
    sync_single_file "${app}" "${explicit_file}"
    return $?
  fi
  
  if [ ! -d "${app_backup_dir}" ]; then
    log_error "Backup directory not found: ${app_backup_dir}"
    return 1
  fi
  
  # Backlog discovery: find all .sql.gz archives that lack a .synced marker
  # Sorted in chronological order (oldest first) so backlogs drain in sequence
  local unsynced_backups=()
  while IFS= read -r -d '' bfile; do
    if [ ! -f "${bfile}.synced" ]; then
      unsynced_backups+=("${bfile}")
    fi
  done < <(find "${app_backup_dir}" -maxdepth 1 -type f -name "${app}-*.sql.gz" -print0 2>/dev/null | sort -z || true)
  
  if [ "${#unsynced_backups[@]}" -eq 0 ]; then
    log_info "All local backups for '${app}' are verified off-site (.synced). Nothing to sync."
    return 0
  fi
  
  log_info "Discovered ${#unsynced_backups[@]} unsynced backup(s) for '${app}'."
  local app_failures=0
  for bfile in "${unsynced_backups[@]}"; do
    if ! sync_single_file "${app}" "${bfile}"; then
      app_failures=$((app_failures + 1))
      log_error "Failed to sync backup: $(basename "${bfile}")"
    fi
  done
  
  if [ "${app_failures}" -gt 0 ]; then
    log_error "${app_failures} backup(s) failed off-site replication for '${app}'."
    return 1
  fi
  
  log_success "All backlog backups synced and verified for '${app}'."
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
    record_scheduler_run_result "success" || true
  else
    log_error "One or more applications failed off-site replication."
    send_atlas_notification "FAILURE" "Atlas Batch Off-Site Sync Failed" "One or more applications failed off-site replication on host \`$(hostname)\`." || true
    record_scheduler_run_result "failure" || true
    exit 1
  fi
elif [ -n "${APP_TARGET}" ]; then
  if sync_app_backup "${APP_TARGET}" "${EXPLICIT_FILE}"; then
    record_scheduler_run_result "success" || true
  else
    record_scheduler_run_result "failure" || true
    exit 1
  fi
else
  log_error "Missing required option: Specify --app=APP_NAME or --all."
  print_usage
  exit 1
fi
