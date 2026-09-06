#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template — Safe Database Restore Engine (Hardened V1)
# ==============================================================================
# Usage:
#   ./scripts/restore.sh --app=myapp --file=/var/backups/myapp/dump.sql.gz --target=test
#   ./scripts/restore.sh --app=myapp --file=/var/backups/myapp/dump.sql.gz --target=production
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_TARGET="${APP:-}"
BACKUP_FILE=""
TARGET_ENV="test" # Default is safe: test / temporary
FORCE=false
ALLOW_EXTERNAL_PATH=false
CUSTOM_CONFIG=""

print_usage() {
  cat << EOF
Atlas Database Restore Engine (V1 Hardened)

SAFETY NOTICE:
  By default, restore operations target a temporary, isolated test container.
  Restoring into a production database requires --target=production and explicit confirmation.

Usage:
  $(basename "$0") --app=APP_NAME [options]

Options:
  -a, --app=APP_NAME      Application identifier (e.g. --app=example-app)
  -f, --file=PATH         Path to the gzipped SQL backup archive (.sql.gz)
                          (Defaults to the latest valid archive in /var/backups/APP_NAME)
  -t, --target=ENV        Target environment: 'test' (default) or 'production'
  --allow-external-file   Allow restoring a file located outside /var/backups/APP_NAME
  --force                 Bypass interactive confirmation prompt (for automated pipelines)
  -c, --config=PATH       Path to custom apps.yml configuration file
  -h, --help              Show this help message

Examples:
  # Safe verification restore in an ephemeral container (default):
  ./scripts/restore.sh --app=example-app --target=test

  # Production restore (requires confirmation and auto-creates pre-restore backup):
  ./scripts/restore.sh --app=example-app --file=/var/backups/example-app/example-app-20260824.sql.gz --target=production
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
    -f=*|--file=*)
      BACKUP_FILE="${1#*=}"
      shift
      ;;
    -f|--file)
      if [ -z "${2:-}" ]; then log_error "Option --file requires an argument"; exit 2; fi
      BACKUP_FILE="$2"
      shift 2
      ;;
    -t=*|--target=*)
      TARGET_ENV="${1#*=}"
      shift
      ;;
    -t|--target)
      if [ -z "${2:-}" ]; then log_error "Option --target requires an argument"; exit 2; fi
      TARGET_ENV="$2"
      shift 2
      ;;
    --allow-external-file)
      ALLOW_EXTERNAL_PATH=true
      shift
      ;;
    --force)
      FORCE=true
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

# Step 1: Validate Application Name (prevent path traversal)
if [ -z "${APP_TARGET}" ]; then
  log_error "Missing required option: --app=APP_NAME"
  print_usage
  exit 2
fi

if ! validate_app_name "${APP_TARGET}"; then
  exit 1
fi

if ! is_app_registered "${APP_TARGET}"; then
  log_error "Application '${APP_TARGET}' is not registered in configuration."
  exit 1
fi

# Step 2: Locate & Validate Backup File
APP_BACKUP_DIR="/var/backups/${APP_TARGET}"

if [ -z "${BACKUP_FILE}" ]; then
  # Automatically select the latest archive from the application's designated backup directory
  if [ -d "${APP_BACKUP_DIR}" ]; then
    LATEST="$(find "${APP_BACKUP_DIR}" -maxdepth 1 -type f -name "${APP_TARGET}-*.sql.gz" | sort -r | head -n 1 || true)"
    if [ -n "${LATEST}" ]; then
      log_info "No --file specified. Using latest archive: ${LATEST}"
      BACKUP_FILE="${LATEST}"
    fi
  fi
fi

if [ -z "${BACKUP_FILE}" ]; then
  log_error "No backup archive found for application '${APP_TARGET}'. Specify a file with --file=PATH."
  exit 2
fi

# Check file existence first before path resolution
if [ ! -f "${BACKUP_FILE}" ]; then
  log_error "Backup file does not exist or is not a regular file: '${BACKUP_FILE}'"
  exit 2
fi

# Check for path safety: require explicit flag if outside designated app backup dir
DIR_OF_FILE="$(dirname "${BACKUP_FILE}")"
if [ -d "${DIR_OF_FILE}" ]; then
  REAL_BACKUP_PATH="$(cd "${DIR_OF_FILE}" && pwd)/$(basename "${BACKUP_FILE}")"
  if [[ "${REAL_BACKUP_PATH}" != "${APP_BACKUP_DIR}/"* ]] && [ "${ALLOW_EXTERNAL_PATH}" != "true" ]; then
    log_error "Security Warning: '${BACKUP_FILE}' is outside the designated backup directory '${APP_BACKUP_DIR}'."
    log_error "To restore from an external or arbitrary path, you must pass --allow-external-file explicitly."
    exit 2
  fi
fi

log_info "=================================================="
log_info "Atlas Database Restore Engine"
log_info "Application: ${APP_TARGET}"
log_info "Archive:     ${BACKUP_FILE}"
log_info "Target:      ${TARGET_ENV}"
log_info "=================================================="

# Step 3: Verify Archive Gzip Integrity & Content
log_info "Validating archive integrity and SQL content..."
if [ ! -s "${BACKUP_FILE}" ]; then
  log_error "Backup archive is empty (0 bytes): ${BACKUP_FILE}"
  exit 1
fi

if ! gzip -t "${BACKUP_FILE}" 2>/dev/null; then
  log_error "Gzip integrity check failed for ${BACKUP_FILE}"
  exit 1
fi

# Verify decompressed content contains PostgreSQL dump markers
DECOMPRESSED_BYTES="$(gzip -dc "${BACKUP_FILE}" 2>/dev/null | wc -c | tr -d ' ')"
if [ "${DECOMPRESSED_BYTES}" -lt 50 ]; then
  log_error "Decompressed archive is empty or too small (${DECOMPRESSED_BYTES} bytes)."
  exit 1
fi

if ! (set +o pipefail; gzip -dc "${BACKUP_FILE}" 2>/dev/null | head -n 30) | grep -qE "(PostgreSQL database dump|SET statement_timeout|CREATE |ALTER |DROP |COPY )"; then
  log_error "Archive does not contain recognizable PostgreSQL dump content."
  exit 1
fi
log_pass "Gzip stream integrity and SQL dump headers verified."

# Step 4: Verify SHA-256 Checksum if present
if [ -f "${BACKUP_FILE}.sha256" ]; then
  log_info "Verifying SHA-256 checksum..."
  EXPECTED_SUM="$(cut -d' ' -f1 < "${BACKUP_FILE}.sha256")"
  ACTUAL_SUM="$(sha256sum "${BACKUP_FILE}" | cut -d' ' -f1)"
  if [ "${EXPECTED_SUM}" != "${ACTUAL_SUM}" ]; then
    log_error "SHA-256 Checksum mismatch!"
    log_error "  Expected: ${EXPECTED_SUM}"
    log_error "  Actual:   ${ACTUAL_SUM}"
    exit 1
  fi
  log_pass "Checksum verified (${ACTUAL_SUM:0:12}...)."
fi

# Load DB configuration
DB_TYPE="$(get_app_property "${APP_TARGET}" "database.type")"
if [ -z "${DB_TYPE}" ] || [ "${DB_TYPE}" = "null" ]; then DB_TYPE="postgres"; fi
PROD_CONTAINER="$(get_app_property "${APP_TARGET}" "database.container")"
DB_USER="$(get_app_property "${APP_TARGET}" "database.user")"
DB_NAME="$(get_app_property "${APP_TARGET}" "database.name")"

# Step 5: Execute Restore against Target Environment
case "${TARGET_ENV}" in
  test|temporary|temp)
    log_info "Mode: ISOLATED TEST RESTORE"
    log_info "Spawning temporary PostgreSQL container..."
    
    TEMP_NAME="atlas_restore_test_${APP_TARGET}_$(date +%s)"
    TEST_USER="${DB_USER:-test_user}"
    if [ "${TEST_USER}" = "null" ]; then TEST_USER="test_user"; fi
    TEST_DB="${DB_NAME:-test_db}"
    if [ "${TEST_DB}" = "null" ]; then TEST_DB="test_db"; fi
    TEST_PASS="atlas_test_password_2026"
    
    # Cleanup trap
    cleanup_test_container() {
      log_info "Cleaning up temporary test container '${TEMP_NAME}'..."
      docker stop "${TEMP_NAME}" >/dev/null 2>&1 || true
      docker rm -f "${TEMP_NAME}" >/dev/null 2>&1 || true
    }
    trap cleanup_test_container EXIT
    
    docker run -d --name "${TEMP_NAME}" \
      -e POSTGRES_USER="${TEST_USER}" \
      -e POSTGRES_PASSWORD="${TEST_PASS}" \
      -e POSTGRES_DB="${TEST_DB}" \
      postgres:16-alpine >/dev/null
      
    log_info "Waiting for temporary database to accept connections..."
    sleep 2
    for i in {1..30}; do
      if docker exec "${TEMP_NAME}" pg_isready -U "${TEST_USER}" -d "${TEST_DB}" >/dev/null 2>&1; then
        if docker exec -e PGPASSWORD="${TEST_PASS}" "${TEMP_NAME}" psql -U "${TEST_USER}" -d "${TEST_DB}" -c "SELECT 1;" >/dev/null 2>&1; then
          break
        fi
      fi
      sleep 1
      if [ "$i" -eq 30 ]; then
        log_error "Temporary test database container failed to start in 30s."
        exit 1
      fi
    done
    
    log_info "Restoring SQL dump into test database with ON_ERROR_STOP=1..."
    # -v ON_ERROR_STOP=1 ensures any SQL error aborts with non-zero exit code
    gzip -dc "${BACKUP_FILE}" | docker exec -i "${TEMP_NAME}" \
      sh -c 'export PGPASSWORD="${POSTGRES_PASSWORD:-}"; exec psql -v ON_ERROR_STOP=1 -U "$1" -d "$2"' _ "${TEST_USER}" "${TEST_DB}" || {
        log_error "Database restore failed! SQL error encountered."
        exit 1
      }
    
    log_success "Database restore executed without errors."
    log_info "Inspecting restored relations..."
    docker exec -i "${TEMP_NAME}" sh -c 'export PGPASSWORD="${POSTGRES_PASSWORD:-}"; exec psql -U "$1" -d "$2" -c "\dt"' _ "${TEST_USER}" "${TEST_DB}" || true
    
    log_success "TEST RESTORE VERIFICATION COMPLETED SUCCESSFULLY!"
    ;;

  production|prod)
    log_warn "=================================================="
    log_warn "DANGER: YOU ARE ATTEMPTING TO RESTORE INTO PRODUCTION!"
    log_warn "Target Container: ${PROD_CONTAINER}"
    log_warn "Target Database:  ${DB_NAME}"
    log_warn "Existing production data will be OVERWRITTEN."
    log_warn "=================================================="
    
    if [ "${FORCE}" != "true" ]; then
      printf "%s\n" "To proceed, type exactly: CONFIRM-RESTORE-TO-PRODUCTION"
      read -r confirmation
      if [ "${confirmation}" != "CONFIRM-RESTORE-TO-PRODUCTION" ]; then
        log_error "Confirmation string mismatch. Restore operation aborted."
        exit 1
      fi
    fi
    
    # Trigger an emergency safety pre-restore backup
    log_info "Creating emergency pre-restore safety backup of production database..."
    "${SCRIPT_DIR}/backup.sh" --app="${APP_TARGET}" || {
      log_error "Pre-restore safety backup failed. Aborting restore to protect production state."
      exit 1
    }
    
    # Execute restore against production container
    log_info "Executing restore against production container '${PROD_CONTAINER}'..."
    
    if [ -z "${DB_USER}" ] || [ "${DB_USER}" = "null" ]; then
      DB_USER="$(docker exec "${PROD_CONTAINER}" printenv POSTGRES_USER 2>/dev/null || echo "postgres")"
    fi
    if [ -z "${DB_NAME}" ] || [ "${DB_NAME}" = "null" ]; then
      DB_NAME="$(docker exec "${PROD_CONTAINER}" printenv POSTGRES_DB 2>/dev/null || echo "${DB_USER}")"
    fi
    
    # Execute restore using -v ON_ERROR_STOP=1 --single-transaction
    gzip -dc "${BACKUP_FILE}" | docker exec -i "${PROD_CONTAINER}" \
      sh -c 'export PGPASSWORD="${POSTGRES_PASSWORD:-}"; exec psql -v ON_ERROR_STOP=1 --single-transaction -U "$1" -d "$2"' _ "${DB_USER}" "${DB_NAME}" || {
        log_error "Production database restore failed during SQL execution!"
        exit 1
      }
      
    log_success "Production database restore completed successfully."
    ;;

  *)
    log_error "Unknown target environment: '${TARGET_ENV}'. Must be 'test' or 'production'."
    exit 2
    ;;
esac
