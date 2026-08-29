#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Database Restore & Recovery Engine
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
if [ -f "${SCRIPT_DIR}/lib/notify.sh" ]; then
  source "${SCRIPT_DIR}/lib/notify.sh"
fi

APP_TARGET="${APP:-}"
BACKUP_FILE=""
FORCE=false
CUSTOM_CONFIG=""

print_usage() {
  cat << 'HELP'
Atlas Database Restore Engine (V1)

Usage:
  atlas restore run [options]

Options:
  -a, --app=APP_NAME      Application identifier to restore
  -f, --file=PATH         Path to local .sql.gz backup file
  -c, --config=PATH       Path to atlas.yml
  --force                 Bypass interactive confirmation (USE WITH CAUTION)
  -h, --help              Show this help message
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--app) APP_TARGET="$2"; shift 2 ;;
    --app=*) APP_TARGET="${1#*=}"; shift ;;
    -f|--file) BACKUP_FILE="$2"; shift 2 ;;
    --file=*) BACKUP_FILE="${1#*=}"; shift ;;
    -c|--config) CUSTOM_CONFIG="$2"; shift 2 ;;
    --config=*) CUSTOM_CONFIG="${1#*=}"; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) log_error "Unknown option: $1"; print_usage; exit 1 ;;
  esac
done

if [ -z "${APP_TARGET}" ]; then
  log_error "Missing required --app argument."
  print_usage
  exit 1
fi
validate_identifier "${APP_TARGET}" "application name"

CONFIG_FILE="$(get_atlas_config "${CUSTOM_CONFIG}")"
container="$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_db_container "${APP_TARGET}")"
db_user="$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_db_user "${APP_TARGET}")"
db_name="$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_db_name "${APP_TARGET}")"

if [ -z "${container}" ]; then
  log_error "No database container found for application '${APP_TARGET}'"
  exit 1
fi
validate_identifier "${container}" "database container name"

if [ -z "${BACKUP_FILE}" ]; then
  backup_dir="${ATLAS_BACKUP_DIR:-/var/backups}/${APP_TARGET}"
  BACKUP_FILE="$(find "${backup_dir}" -maxdepth 1 -name "${APP_TARGET}-*.sql.gz" | sort | tail -n 1)"
  if [ -z "${BACKUP_FILE}" ]; then
    log_error "No backup file found in ${backup_dir}"
    exit 1
  fi
fi

if [ ! -f "${BACKUP_FILE}" ]; then
  log_error "Backup archive does not exist: ${BACKUP_FILE}"
  exit 1
fi

if [ -f "${BACKUP_FILE}.sha256" ]; then
  log_info "Verifying SHA-256 checksum..."
  if ! (cd "$(dirname "${BACKUP_FILE}")" && sha256sum -c "$(basename "${BACKUP_FILE}.sha256")" >/dev/null 2>&1); then
    log_error "SHA-256 checksum verification failed! Archive may be corrupted."
    exit 1
  fi
  log_success "Checksum verified."
fi

if [ "${FORCE}" != true ]; then
  echo ""
  echo "⚠️  CAUTION: DESTRUCTIVE OPERATION"
  echo "Target Application: ${APP_TARGET}"
  echo "Target Container:   ${container}"
  echo "Target Database:    ${db_name:-ALL}"
  echo "Source Archive:     ${BACKUP_FILE}"
  echo ""
  read -p "Are you sure you want to overwrite database data? [y/N]: " -r confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    log_warn "Restore cancelled by user."
    exit 0
  fi
fi

log_info "Starting database restoration for '${APP_TARGET}'..."
restore_cmd="psql -U ${db_user}"
if [ -n "${db_name}" ]; then
  restore_cmd="${restore_cmd} -d ${db_name}"
fi

if ! zcat "${BACKUP_FILE}" | docker exec -i "${container}" ${restore_cmd} >/dev/null; then
  log_error "Database restore failed!"
  exit 1
fi

log_success "Database restored successfully from ${BACKUP_FILE}"
