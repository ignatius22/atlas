#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Database Backup Engine
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
CUSTOM_CONFIG=""

print_usage() {
  cat << 'HELP'
Atlas Database Backup Engine (V1)

Usage:
  atlas backup create [options]

Options:
  -a, --app=APP_NAME      Application identifier to back up
  --all                   Back up all configured applications
  -c, --config=PATH       Path to atlas.yml configuration file
  -d, --dry-run           Simulate backup steps without dumping data
  -h, --help              Show this help message
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--app) APP_TARGET="$2"; shift 2 ;;
    --app=*) APP_TARGET="${1#*=}"; shift ;;
    --all) ALL_APPS=true; shift ;;
    -c|--config) CUSTOM_CONFIG="$2"; shift 2 ;;
    --config=*) CUSTOM_CONFIG="${1#*=}"; shift ;;
    -d|--dry-run) DRY_RUN=true; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) log_error "Unknown option: $1"; print_usage; exit 1 ;;
  esac
done

CONFIG_FILE="$(get_atlas_config "${CUSTOM_CONFIG}")"
if [ ! -f "${CONFIG_FILE}" ]; then
  log_error "Configuration file not found: ${CONFIG_FILE}"
  exit 1
fi

python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" validate >/dev/null

backup_single_app() {
  local app="$1"
  validate_identifier "${app}" "application name"

  local container
  container="$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_db_container "${app}")"
  if [ -z "${container}" ]; then
    log_warn "Application '${app}' has no database container configured or backup is disabled. Skipping."
    return 0
  fi
  validate_identifier "${container}" "database container name"

  local db_user
  db_user="$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_db_user "${app}")"
  local db_name
  db_name="$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_db_name "${app}")"
  local retention_days
  retention_days="${RETENTION_DAYS:-$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_retention "${app}")}"

  local storage_dir="${ATLAS_BACKUP_DIR:-/var/backups}/${app}"
  mkdir -p "${storage_dir}"

  local timestamp
  timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  local backup_file="${storage_dir}/${app}-${timestamp}.sql.gz"
  local temp_file="${backup_file}.tmp"

  log_info "Starting backup for '${app}' (Container: ${container})..."

  if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] Would execute pg_dump on ${container} -> ${backup_file}"
    return 0
  fi

  if ! docker ps --format '{{.Names}}' | grep -Eq "^${container}$"; then
    log_error "Database container '${container}' is not running!"
    return 1
  fi

  local dump_cmd="pg_dump -U ${db_user}"
  if [ -n "${db_name}" ]; then
    dump_cmd="${dump_cmd} -d ${db_name}"
  else
    dump_cmd="${dump_cmd} -A"
  fi

  if ! docker exec "${container}" ${dump_cmd} | gzip -9 > "${temp_file}"; then
    rm -f "${temp_file}"
    log_error "pg_dump failed for '${app}'"
    return 1
  fi

  mv "${temp_file}" "${backup_file}"
  sha256sum "${backup_file}" > "${backup_file}.sha256"

  local size
  size="$(du -h "${backup_file}" | cut -f1)"
  log_success "Backup completed for '${app}': ${backup_file} (${size})"

  if [ -n "${retention_days}" ] && [ "${retention_days}" -gt 0 ]; then
    find "${storage_dir}" -name "${app}-*.sql.gz*" -mtime "+${retention_days}" -delete 2>/dev/null || true
  fi
}

if [ "${ALL_APPS}" = true ]; then
  apps_list="$(python3 "${SCRIPT_DIR}/lib/yaml_parser.py" "${CONFIG_FILE}" get_db_apps)"
  for a in ${apps_list}; do
    backup_single_app "${a}"
  done
elif [ -n "${APP_TARGET}" ]; then
  backup_single_app "${APP_TARGET}"
else
  log_error "No application specified. Use --app=APP_NAME or --all"
  print_usage
  exit 1
fi
