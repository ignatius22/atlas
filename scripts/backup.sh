#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template — Database Backup Engine (Hardened V1)
# ==============================================================================
# Usage:
#   APP=myapp ./scripts/backup.sh
#   ./scripts/backup.sh --app=myapp
#   ./scripts/backup.sh --all
#   ./scripts/backup.sh --app=myapp --dry-run
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/notify.sh
if [ -f "${SCRIPT_DIR}/lib/notify.sh" ]; then
  source "${SCRIPT_DIR}/lib/notify.sh"
fi

APP_TARGET="${APP:-}"
ALL_APPS=false
DRY_RUN=false
CUSTOM_CONFIG=""

print_usage() {
  cat << EOF
Atlas Database Backup Engine (V1 Hardened)

Usage:
  $(basename "$0") [options]

Options:
  -a, --app=APP_NAME      Application identifier to back up (e.g. --app=myapp)
  --all                   Back up all registered applications with backup enabled
  -c, --config=PATH       Path to custom apps.yml configuration file
  -d, --dry-run           Simulate backup steps without dumping data
  -h, --help              Show this help message

Environment Variables:
  APP                     Application identifier (alternative to --app)
  ATLAS_CONFIG_FILE       Custom apps.yml path
  RETENTION_DAYS          Override backup retention days

Examples:
  APP=example-app ./scripts/backup.sh
  ./scripts/backup.sh --app=example-app --dry-run
  ./scripts/backup.sh --all
EOF
}

# Parse command line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -a=*|--app=*)
      APP_TARGET="${1#*=}"
      shift
      ;;
    -a|--app)
      if [ -z "${2:-}" ]; then log_error "Option --app requires an argument"; exit 2; fi
      APP_TARGET="$2"
      shift 2
      ;;
    --all)
      ALL_APPS=true
      shift
      ;;
    -c=*|--config=*)
      CUSTOM_CONFIG="${1#*=}"
      shift
      ;;
    -c|--config)
      if [ -z "${2:-}" ]; then log_error "Option --config requires an argument"; exit 2; fi
      CUSTOM_CONFIG="$2"
      shift 2
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      print_usage
      exit 2
      ;;
  esac
done

if [ -n "${CUSTOM_CONFIG}" ]; then
  export ATLAS_CONFIG_FILE="${CUSTOM_CONFIG}"
fi

# Preflight check for PyYAML
check_pyyaml_dependency

# Global Mutex to prevent concurrent backup collisions
LOCK_DIR="/tmp/atlas_backup.lock.d"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log_error "Another Atlas backup process is currently running (Lock: ${LOCK_DIR}). Exiting."
  exit 1
fi
cleanup_backup_lock() {
  rm -rf "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup_backup_lock EXIT INT TERM

# Load global backup defaults
BACKUP_CONFIG_FILE="$(find_backup_config || true)"
GLOBAL_BACKUP_DIR="/var/backups"
GLOBAL_RETENTION=14

if [ -n "${BACKUP_CONFIG_FILE}" ] && [ -f "${BACKUP_CONFIG_FILE}" ]; then
  C_DIR="$(query_yaml "${BACKUP_CONFIG_FILE}" "backup.storage_dir")"
  if [ -n "${C_DIR}" ] && [ "${C_DIR}" != "null" ]; then GLOBAL_BACKUP_DIR="${C_DIR}"; fi
  C_RET="$(query_yaml "${BACKUP_CONFIG_FILE}" "backup.default_retention_days")"
  if [ -n "${C_RET}" ] && [ "${C_RET}" != "null" ]; then GLOBAL_RETENTION="${C_RET}"; fi
fi

# Function to execute database backup for a single application
backup_single_app() {
  local app="$1"
  local start_time
  start_time="$(date +%s)"
  
  # Step 1: Validate application name against regex to prevent path traversal
  if ! validate_app_name "${app}"; then
    return 1
  fi
  
  log_info "=================================================="
  log_info "Starting backup for application: ${app}"
  log_info "Timestamp: $(iso_timestamp)"
  
  if ! is_app_registered "${app}"; then
    log_error "Application '${app}' is not registered in configuration."
    return 1
  fi
  
  local db_enabled
  db_enabled="$(get_app_property "${app}" "database.backup")"
  if [ "${db_enabled}" = "false" ]; then
    log_info "Database backup is explicitly disabled for '${app}'. Skipping."
    return 0
  fi
  
  local db_type
  db_type="$(get_app_property "${app}" "database.type")"
  if [ -z "${db_type}" ] || [ "${db_type}" = "null" ]; then
    db_type="postgres" # Default database adapter
  fi
  
  local container
  container="$(get_app_property "${app}" "database.container")"
  if [ -z "${container}" ] || [ "${container}" = "null" ]; then
    log_error "No database container specified for '${app}' (database.container is empty)."
    return 1
  fi
  
  # Validate container name against injection
  if ! [[ "${container}" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    log_error "Invalid container name '${container}' configured for '${app}'."
    return 1
  fi
  
  local db_name
  db_name="$(get_app_property "${app}" "database.name")"
  local db_user
  db_user="$(get_app_property "${app}" "database.user")"
  
  local retention="${RETENTION_DAYS:-}"
  if [ -z "${retention}" ]; then
    retention="$(get_app_property "${app}" "database.retention_days")"
    if [ -z "${retention}" ] || [ "${retention}" = "null" ]; then
      retention="${GLOBAL_RETENTION}"
    fi
  fi
  
  local target_dir="${GLOBAL_BACKUP_DIR}/${app}"
  local stamp
  stamp="$(filename_timestamp)"
  local target_file="${target_dir}/${app}-${stamp}.sql.gz"
  
  if [ "${DRY_RUN}" = "true" ]; then
    log_info "[DRY-RUN] Target Directory:   ${target_dir}"
    log_info "[DRY-RUN] Container:          ${container}"
    log_info "[DRY-RUN] Database Type:      ${db_type}"
    log_info "[DRY-RUN] Target File:        ${target_file}"
    log_info "[DRY-RUN] Retention Policy:   ${retention} days"
    return 0
  fi
  
  mkdir -p "${target_dir}"
  
  # Check if docker is available
  require_cmd docker
  
  # Verify container is running
  if ! docker inspect "${container}" >/dev/null 2>&1; then
    log_error "Database container '${container}' was not found on this host."
    send_atlas_notification "FAILURE" "Database Backup Failed" "Application: \`${app}\`\nContainer: \`${container}\`\nError: Container not found on host \`$(hostname)\`." || true
    record_scheduler_run_result "failure" || true
    return 1
  fi
  
  local container_running
  container_running="$(docker inspect --format '{{.State.Running}}' "${container}" 2>/dev/null || echo "false")"
  if [ "${container_running}" != "true" ]; then
    log_error "Database container '${container}' is not running."
    send_atlas_notification "FAILURE" "Database Backup Failed" "Application: \`${app}\`\nContainer: \`${container}\`\nError: Container is not in running state on \`$(hostname)\`." || true
    record_scheduler_run_result "failure" || true
    return 1
  fi
  
  # Temporary holding file during dump stream
  local temp_target="${target_file}.tmp.$$"
  
  # Safety cleanup trap on failure
  cleanup_failed_backup() {
    rm -f "${temp_target}" "${target_file}" "${target_file}.sha256"
    send_atlas_notification "FAILURE" "Database Backup Failed" "Application: \`${app}\`\nContainer: \`${container}\`\nHost: \`$(hostname)\`" || true
  }
  trap cleanup_failed_backup ERR
  
  case "${db_type}" in
    postgres|postgresql)
      log_info "Executing PostgreSQL dump from container '${container}'..."
      
      # Extract credentials dynamically from container env if not explicitly provided
      if [ -z "${db_user}" ] || [ "${db_user}" = "null" ]; then
        db_user="$(docker exec "${container}" printenv POSTGRES_USER 2>/dev/null || echo "postgres")"
      fi
      if [ -z "${db_name}" ] || [ "${db_name}" = "null" ]; then
        db_name="$(docker exec "${container}" printenv POSTGRES_DB 2>/dev/null || echo "${db_user}")"
      fi
      
      # Stream pg_dump through gzip directly to temporary target archive
      # set -o pipefail ensures failure on pg_dump aborts the pipeline
      docker exec -i "${container}" sh -c 'export PGPASSWORD="${POSTGRES_PASSWORD:-}"; exec pg_dump -U "$1" -d "$2" --no-owner --clean --if-exists' _ "${db_user}" "${db_name}" \
        | gzip -9 > "${temp_target}"
      ;;
      
    *)
      log_error "Unsupported database type '${db_type}'. Currently supported: 'postgres'."
      return 1
      ;;
  esac
  
  # --------------------------------------------------------------------------
  # HARDENED VERIFICATION (Prevent 0-byte or corrupted false-positive backups)
  # --------------------------------------------------------------------------
  log_info "Validating backup integrity and SQL content..."
  
  # Check 1: File must exist
  if [ ! -f "${temp_target}" ]; then
    log_error "Backup artifact was not created: ${temp_target}"
    cleanup_failed_backup
    return 1
  fi
  
  # Check 2: Gzip stream integrity
  if ! gzip -t "${temp_target}" 2>/dev/null; then
    log_error "Gzip stream integrity check failed: ${temp_target}"
    cleanup_failed_backup
    return 1
  fi
  
  # Check 3: Decompressed SQL stream byte count (Must be > 50 bytes)
  local decompressed_bytes
  decompressed_bytes="$(gzip -dc "${temp_target}" 2>/dev/null | wc -c | tr -d ' ')"
  if [ "${decompressed_bytes}" -lt 50 ]; then
    log_error "Backup verification failed: Decompressed SQL stream is empty or too small (${decompressed_bytes} bytes)."
    cleanup_failed_backup
    return 1
  fi
  
  # Check 4: Header verification (Must contain valid PostgreSQL dump markers)
  local sql_header
  sql_header="$( (set +o pipefail; gzip -dc "${temp_target}" 2>/dev/null | head -n 30) || true )"
  if ! echo "${sql_header}" | grep -qE "(PostgreSQL database dump|SET statement_timeout|CREATE |ALTER |DROP |COPY )"; then
    log_error "Backup verification failed: Archive does not contain valid PostgreSQL dump headers."
    cleanup_failed_backup
    return 1
  fi
  
  # Move temporary target into final target filename
  mv -f "${temp_target}" "${target_file}"
  
  # Check 5: Generate SHA-256 Checksum
  sha256sum "${target_file}" > "${target_file}.sha256"
  
  local file_size
  file_size="$(du -sh "${target_file}" | cut -f1)"
  local checksum
  checksum="$(cut -d' ' -f1 < "${target_file}.sha256")"
  
  # Check 6: Enforce retention policy strictly within target_dir
  local pruned_count=0
  local preserved_count=0
  if [ "${retention}" -gt 0 ]; then
    while IFS= read -r -d '' old_file; do
      if [ -n "${old_file}" ] && [ -f "${old_file}" ]; then
        if [ -f "${old_file}.synced" ]; then
          log_info "Pruning replicated expired backup: $(basename "${old_file}")"
          rm -f "${old_file}" "${old_file}.sha256" "${old_file}.age" "${old_file}.age.sha256" "${old_file}.meta.json" "${old_file}.synced"
          pruned_count=$((pruned_count + 1))
        else
          log_warn "PRESERVING un-replicated backup despite retention expiry: $(basename "${old_file}") (missing .synced durability marker)"
          preserved_count=$((preserved_count + 1))
        fi
      fi
    done < <(find "${target_dir}" -maxdepth 1 -type f -name "${app}-*.sql.gz" -mtime "+${retention}" -print0 2>/dev/null || true)
  fi
  
  # Disable error trap on clean exit
  trap - ERR
  
  local end_time
  end_time="$(date +%s)"
  local duration=$((end_time - start_time))
  
  log_success "Backup completed and verified for '${app}' in ${duration}s"
  log_info "  Archive:           ${target_file}"
  log_info "  Compressed Size:   ${file_size}"
  log_info "  Decompressed Size: ${decompressed_bytes} bytes"
  log_info "  SHA-256 Checksum:  ${checksum}"
  log_info "  Retention:         Kept <= ${retention} days (pruned ${pruned_count} replicated files, preserved ${preserved_count} un-replicated files)"
  return 0
}

# Main execution logic
if [ "${ALL_APPS}" = "true" ]; then
  apps_list="$(list_registered_apps)"
  if [ -z "${apps_list}" ]; then
    log_error "No applications found in configuration registry."
    record_scheduler_run_result "failure" || true
    exit 1
  fi
  
  failures=0
  for single_app in ${apps_list}; do
    if ! backup_single_app "${single_app}"; then
      failures=$((failures + 1))
    fi
  done
  
  if [ "${failures}" -gt 0 ]; then
    log_error "Backup run completed with ${failures} failure(s)."
    send_atlas_notification "FAILURE" "Atlas Batch Backup Failed" "Backup run completed with ${failures} failure(s) on host \`$(hostname)\`." || true
    record_scheduler_run_result "failure" || true
    exit 1
  fi
  record_scheduler_run_result "success" || true
  log_success "All registered application backups completed successfully."
  exit 0
fi

if [ -z "${APP_TARGET}" ]; then
  log_error "No application specified. Use --app=APP_NAME or set APP=APP_NAME (or use --all)."
  print_usage
  exit 2
fi

if backup_single_app "${APP_TARGET}"; then
  record_scheduler_run_result "success" || true
else
  record_scheduler_run_result "failure" || true
  exit 1
fi
