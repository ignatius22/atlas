#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Off-Site Backup Replication Engine
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
if [ -f "${SCRIPT_DIR}/lib/notify.sh" ]; then
  source "${SCRIPT_DIR}/lib/notify.sh"
fi

APP_TARGET="${APP:-}"
ALL_APPS=false
DRY_RUN=false
EXPLICIT_FILE=""
CUSTOM_CONFIG=""

print_usage() {
  cat << 'HELP'
Atlas Off-Site Backup Replication Engine (V1)

Usage:
  atlas backup sync [options]

Options:
  -a, --app=APP_NAME      Application identifier to sync
  --all                   Sync all configured applications
  -f, --file=PATH         Explicit backup file to encrypt and sync
  -c, --config=PATH       Path to atlas.yml
  -d, --dry-run           Simulate encryption and sync without uploading
  -h, --help              Show this help message
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--app) APP_TARGET="$2"; shift 2 ;;
    --app=*) APP_TARGET="${1#*=}"; shift ;;
    --all) ALL_APPS=true; shift ;;
    -f|--file) EXPLICIT_FILE="$2"; shift 2 ;;
    --file=*) EXPLICIT_FILE="${1#*=}"; shift ;;
    -c|--config) CUSTOM_CONFIG="$2"; shift 2 ;;
    --config=*) CUSTOM_CONFIG="${1#*=}"; shift ;;
    -d|--dry-run) DRY_RUN=true; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) log_error "Unknown option: $1"; print_usage; exit 1 ;;
  esac
done

CONFIG_FILE="$(get_atlas_config "${CUSTOM_CONFIG}")"
AGE_RECIPIENT="${ATLAS_AGE_RECIPIENT:-}"
S3_BUCKET="${ATLAS_S3_BUCKET:-}"
S3_ENDPOINT="${ATLAS_S3_ENDPOINT:-}"
PROVIDER="${ATLAS_OFFSITE_PROVIDER:-s3}"

if [ -z "${AGE_RECIPIENT}" ]; then
  log_error "ATLAS_AGE_RECIPIENT is not set. Set it in .env or environment."
  exit 1
fi

if [ -z "${S3_BUCKET}" ] && [ "${PROVIDER}" != "local-mock" ]; then
  log_error "ATLAS_S3_BUCKET is not set."
  exit 1
fi

sync_single_file() {
  local file="$1"
  local app="$2"
  validate_identifier "${app}" "application name"

  if [ ! -f "${file}" ]; then
    log_error "Backup file not found: ${file}"
    return 1
  fi

  local base_name
  base_name="$(basename "${file}")"
  local encrypted_file="${file}.age"

  log_info "Encrypting ${base_name} with Age recipient ${AGE_RECIPIENT:0:12}..."

  if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] Would encrypt and upload ${file} to s3://${S3_BUCKET}/${app}/${base_name}.age"
    return 0
  fi

  age -r "${AGE_RECIPIENT}" -o "${encrypted_file}" "${file}"
  sha256sum "${encrypted_file}" > "${encrypted_file}.sha256"

  local remote_dest="s3://${S3_BUCKET}/${app}/${base_name}.age"
  log_info "Uploading encrypted archive to ${remote_dest}..."

  if [ "${PROVIDER}" = "local-mock" ]; then
    mkdir -p "/tmp/atlas_mock_s3/${app}"
    cp "${encrypted_file}" "${encrypted_file}.sha256" "/tmp/atlas_mock_s3/${app}/"
  elif command -v rclone >/dev/null 2>&1; then
    rclone copyto "${encrypted_file}" ":s3:${S3_BUCKET}/${app}/${base_name}.age" \
      --s3-provider=Cloudflare \
      --s3-endpoint="${S3_ENDPOINT}" \
      --s3-access-key-id="${ATLAS_S3_ACCESS_KEY:-}" \
      --s3-secret-access-key="${ATLAS_S3_SECRET_KEY:-}"
    rclone copyto "${encrypted_file}.sha256" ":s3:${S3_BUCKET}/${app}/${base_name}.age.sha256" \
      --s3-provider=Cloudflare \
      --s3-endpoint="${S3_ENDPOINT}" \
      --s3-access-key-id="${ATLAS_S3_ACCESS_KEY:-}" \
      --s3-secret-access-key="${ATLAS_S3_SECRET_KEY:-}"
  elif command -v aws >/dev/null 2>&1; then
    aws s3 cp "${encrypted_file}" "${remote_dest}" ${S3_ENDPOINT:+--endpoint-url "${S3_ENDPOINT}"}
    aws s3 cp "${encrypted_file}.sha256" "${remote_dest}.sha256" ${S3_ENDPOINT:+--endpoint-url "${S3_ENDPOINT}"}
  else
    log_error "Neither rclone nor aws-cli is installed for off-site sync."
    return 1
  fi

  log_success "Replication complete for '${app}': ${base_name}.age"
}

sync_app_latest() {
  local app="$1"
  local backup_dir="${ATLAS_BACKUP_DIR:-/var/backups}/${app}"
  if [ ! -d "${backup_dir}" ]; then
    log_warn "No local backups directory for '${app}' at ${backup_dir}"
    return 0
  fi
  local latest_file
  latest_file="$(find "${backup_dir}" -maxdepth 1 -name "${app}-*.sql.gz" | sort | tail -n 1)"
  if [ -z "${latest_file}" ]; then
    log_warn "No .sql.gz backup archives found for '${app}'"
    return 0
  fi
  sync_single_file "${latest_file}" "${app}"
}

if [ -n "${EXPLICIT_FILE}" ]; then
  app_name="${APP_TARGET:-manual}"
  sync_single_file "${EXPLICIT_FILE}" "${app_name}"
elif [ "${ALL_APPS}" = true ]; then
  apps_list="$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_db_apps)"
  for a in ${apps_list}; do
    sync_app_latest "${a}"
  done
elif [ -n "${APP_TARGET}" ]; then
  sync_app_latest "${APP_TARGET}"
else
  log_error "No target specified. Use --app=APP_NAME, --all, or --file=PATH"
  print_usage
  exit 1
fi
