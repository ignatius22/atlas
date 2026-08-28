#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template - Off-Site Backup Recovery Engine (V1.1)
# ==============================================================================
# Downloads encrypted backups from Cloud Object Storage, verifies checksums,
# decrypts using an externally supplied private key, and validates restoration.
# Defaults strictly to isolated disposable test environments.
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

print_usage() {
  cat << EOF
Atlas Off-Site Backup Recovery Engine (V1.1)

Usage:
  $(basename "$0") [options]

Options:
  -a, --app=APP_NAME       Application identifier to restore (e.g. --app=sand2keys)
  -f, --file=FILENAME      Remote file name or path to restore (Default: latest available)
  -k, --key-file=PATH      Path to age private key file for decryption
  --target=TARGET          Target environment: 'test' (default) or 'production'
  -l, --list               List available remote backups for application
  -h, --help               Show this help message

Environment Variables:
  ATLAS_AGE_IDENTITY       Private key string for decryption (AGE-SECRET-KEY-1...)
  ATLAS_S3_BUCKET          Target bucket name
  ATLAS_OFFSITE_PROVIDER   Remote provider: 'rclone', 's3', 'local-mock'

Examples:
  $(basename "$0") --app=sand2keys --list
  $(basename "$0") --app=sand2keys --key-file=/path/to/key.txt
  ATLAS_AGE_IDENTITY="AGE-SECRET-KEY-1..." $(basename "$0") --app=wdni
EOF
}

APP_TARGET=""
REMOTE_FILE=""
KEY_FILE=""
TARGET_ENV="test"
LIST_ONLY="false"

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
    -f|--file)
      REMOTE_FILE="$2"
      shift 2
      ;;
    --file=*)
      REMOTE_FILE="${1#*=}"
      shift
      ;;
    -k|--key-file)
      KEY_FILE="$2"
      shift 2
      ;;
    --key-file=*)
      KEY_FILE="${1#*=}"
      shift
      ;;
    --target=*)
      TARGET_ENV="${1#*=}"
      shift
      ;;
    -l|--list)
      LIST_ONLY="true"
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

if [ -z "${APP_TARGET}" ]; then
  log_error "Missing required option: --app=APP_NAME"
  print_usage
  exit 1
fi

if ! validate_app_name "${APP_TARGET}"; then
  exit 1
fi

# Load environment configuration if available
load_atlas_env

BUCKET="${ATLAS_S3_BUCKET:-atlas-production-backups}"
PROVIDER="${ATLAS_OFFSITE_PROVIDER:-auto}"
if [ "${PROVIDER}" = "auto" ]; then
  if command -v rclone >/dev/null 2>&1; then
    PROVIDER="rclone"
  elif command -v aws >/dev/null 2>&1; then
    PROVIDER="aws"
  else
    PROVIDER="local-mock"
  fi
fi

# Step 1: Export Provider Credentials
if [ "${PROVIDER}" = "rclone" ]; then
  export RCLONE_S3_PROVIDER="${ATLAS_S3_PROVIDER:-Cloudflare}"
  export RCLONE_S3_ENDPOINT="${ATLAS_S3_ENDPOINT:-}"
  export RCLONE_S3_ACCESS_KEY_ID="${ATLAS_S3_ACCESS_KEY:-}"
  export RCLONE_S3_SECRET_ACCESS_KEY="${ATLAS_S3_SECRET_KEY:-}"
  export RCLONE_S3_NO_CHECK_BUCKET="true"
elif [ "${PROVIDER}" = "aws" ]; then
  export AWS_ACCESS_KEY_ID="${ATLAS_S3_ACCESS_KEY:-}"
  export AWS_SECRET_ACCESS_KEY="${ATLAS_S3_SECRET_KEY:-}"
fi

# Step 2: List Remote Backups if requested
if [ "${LIST_ONLY}" = "true" ]; then
  log_info "Listing remote backups for application '${APP_TARGET}'..."
  case "${PROVIDER}" in
    rclone)
      rclone lsf ":s3:${BUCKET}/atlas-backups/${APP_TARGET}/" --recursive --s3-no-check-bucket
      ;;
    aws)
      aws s3 ls "s3://${BUCKET}/atlas-backups/${APP_TARGET}/" --recursive
      ;;
    local-mock)
      find "/var/backups/offsite-mock/atlas-backups/${APP_TARGET}" -type f 2>/dev/null || echo "No mock backups found."
      ;;
  esac
  exit 0
fi

# Step 2: Download Remote Backup to Temporary Working Directory
RESTORE_WORK_DIR="/tmp/atlas_restore_work_${APP_TARGET}_$$"
mkdir -p "${RESTORE_WORK_DIR}"
chmod 700 "${RESTORE_WORK_DIR}"

cleanup_work_dir() {
  rm -rf "${RESTORE_WORK_DIR}"
}
trap cleanup_work_dir EXIT

log_info "=================================================="
log_info "Atlas Off-Site Backup Recovery Engine"
log_info "Application: ${APP_TARGET}"
log_info "Target Mode: ${TARGET_ENV}"
log_info "Provider:    ${PROVIDER}"
log_info "=================================================="

LOCAL_DOWNLOAD_FILE=""
if [ -n "${REMOTE_FILE}" ]; then
  LOCAL_DOWNLOAD_FILE="${RESTORE_WORK_DIR}/$(basename "${REMOTE_FILE}")"
  log_info "Downloading specific remote artifact: ${REMOTE_FILE}..."
  case "${PROVIDER}" in
    rclone)
      rclone copyto ":s3:${BUCKET}/${REMOTE_FILE}" "${LOCAL_DOWNLOAD_FILE}" --s3-no-check-bucket
      ;;
    aws)
      aws s3 cp "s3://${BUCKET}/${REMOTE_FILE}" "${LOCAL_DOWNLOAD_FILE}"
      ;;
    local-mock)
      cp "/var/backups/offsite-mock/${REMOTE_FILE}" "${LOCAL_DOWNLOAD_FILE}"
      ;;
  esac
else
  # Discover latest remote file
  log_info "Finding latest remote artifact for '${APP_TARGET}'..."
  case "${PROVIDER}" in
    rclone)
      LATEST_KEY="$(rclone lsf ":s3:${BUCKET}/atlas-backups/${APP_TARGET}/" --recursive --files-only --s3-no-check-bucket | grep -E '\.sql\.gz(\.age)?$' | sort -r | head -n 1 || true)"
      if [ -n "${LATEST_KEY}" ]; then
        rclone copyto ":s3:${BUCKET}/atlas-backups/${APP_TARGET}/${LATEST_KEY}" "${RESTORE_WORK_DIR}/$(basename "${LATEST_KEY}")" --s3-no-check-bucket
        LOCAL_DOWNLOAD_FILE="${RESTORE_WORK_DIR}/$(basename "${LATEST_KEY}")"
      fi
      ;;
    local-mock)
      LATEST_PATH="$(find "/var/backups/offsite-mock/atlas-backups/${APP_TARGET}" -type f -name '*.sql.gz*' 2>/dev/null | grep -E '\.sql\.gz(\.age)?$' | sort -r | head -n 1 || true)"
      if [ -n "${LATEST_PATH}" ]; then
        cp "${LATEST_PATH}" "${RESTORE_WORK_DIR}/"
        LOCAL_DOWNLOAD_FILE="${RESTORE_WORK_DIR}/$(basename "${LATEST_PATH}")"
      fi
      ;;
  esac
fi

if [ -z "${LOCAL_DOWNLOAD_FILE}" ] || [ ! -f "${LOCAL_DOWNLOAD_FILE}" ]; then
  log_error "No remote backup archive could be retrieved for '${APP_TARGET}'."
  exit 1
fi

log_pass "Retrieved remote archive: $(basename "${LOCAL_DOWNLOAD_FILE}") ($(stat -c %s "${LOCAL_DOWNLOAD_FILE}" 2>/dev/null || stat -f %z "${LOCAL_DOWNLOAD_FILE}") bytes)."

# Step 3: Asymmetric Decryption if encrypted
DECRYPTED_SQL_GZ="${RESTORE_WORK_DIR}/${APP_TARGET}-recovered.sql.gz"

if [[ "${LOCAL_DOWNLOAD_FILE}" == *.age ]]; then
  log_info "Artifact is encrypted with age. Initiating decryption..."
  require_cmd age
  
  TEMP_KEY_FILE="${RESTORE_WORK_DIR}/temp_identity.key"
  if [ -n "${KEY_FILE}" ] && [ -f "${KEY_FILE}" ]; then
    cp "${KEY_FILE}" "${TEMP_KEY_FILE}"
  elif [ -n "${ATLAS_AGE_IDENTITY:-}" ]; then
    printf "%s\n" "${ATLAS_AGE_IDENTITY}" > "${TEMP_KEY_FILE}"
  else
    log_error "Decryption failed: Private key not provided."
    log_error "Provide key via --key-file=PATH or ATLAS_AGE_IDENTITY='AGE-SECRET-KEY-1...'"
    exit 1
  fi
  chmod 600 "${TEMP_KEY_FILE}"
  
  age -d -i "${TEMP_KEY_FILE}" -o "${DECRYPTED_SQL_GZ}" "${LOCAL_DOWNLOAD_FILE}" || {
    log_error "Decryption failed! The provided private key does not match this backup."
    exit 1
  }
  rm -f "${TEMP_KEY_FILE}"
  log_pass "Archive successfully decrypted to ${DECRYPTED_SQL_GZ}."
else
  cp "${LOCAL_DOWNLOAD_FILE}" "${DECRYPTED_SQL_GZ}"
fi

# Step 4: Validate Gzip Integrity and Decompressed Content
if ! gzip -t "${DECRYPTED_SQL_GZ}" 2>/dev/null; then
  log_error "Decrypted archive failed gzip integrity check!"
  exit 1
fi

DECOMP_BYTES="$(gzip -dc "${DECRYPTED_SQL_GZ}" 2>/dev/null | wc -c | tr -d ' ')"
if [ "${DECOMP_BYTES}" -lt 50 ]; then
  log_error "Decrypted SQL dump is empty or too small (${DECOMP_BYTES} bytes)."
  exit 1
fi

log_pass "Archive verified (Decompressed SQL size: ${DECOMP_BYTES} bytes)."

# Step 5: Delegate to core restore engine
log_info "Delegating to core restore engine (--target=${TARGET_ENV})..."
"${SCRIPT_DIR}/restore.sh" \
  --app="${APP_TARGET}" \
  --file="${DECRYPTED_SQL_GZ}" \
  --allow-external-file \
  --target="${TARGET_ENV}"

log_success "Off-site restore verification completed successfully for '${APP_TARGET}'."
