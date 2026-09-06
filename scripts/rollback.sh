#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template — Application Rollback Engine (Hardened V1)
# ==============================================================================
# Usage:
#   APP=myapp ./scripts/rollback.sh
#   ./scripts/rollback.sh --app=myapp [--target=<commit-sha|git-tag>]
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_TARGET="${APP:-}"
ROLLBACK_TARGET=""
DRY_RUN=false
CUSTOM_CONFIG=""

print_usage() {
  cat << EOF
Atlas Application Rollback Engine (V1 Hardened)

LIMITATIONS & ARCHITECTURE NOTICE:
  Atlas V1 rollback operates by reverting the application Git repository to a
  known healthy commit or tag (default: HEAD~1) and rebuilding the container stack.
  
  IMPORTANT: In-place container recreation causes a brief service restart window.
  Database schema migrations or stateful storage changes made by the newer code
  are NOT automatically rolled back. If a database rollback is required, use
  scripts/restore.sh to restore a pre-deployment database backup.

Usage:
  $(basename "$0") --app=APP_NAME [options]

Options:
  -a, --app=APP_NAME      Application identifier defined in apps.yml (required)
  -t, --target=REF        Target Git commit hash or tag to revert to (default: HEAD~1)
  -d, --dry-run           Simulate rollback steps without checking out or restarting
  -c, --config=PATH       Path to custom apps.yml configuration file
  -h, --help              Show this help message

Examples:
  # Roll back to immediate previous commit:
  APP=example-app ./scripts/rollback.sh

  # Roll back to specific tag or SHA:
  ./scripts/rollback.sh --app=example-app --target=v1.2.0
  ./scripts/rollback.sh --app=example-app --target=a1b2c3d
EOF
}

# Parse options
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
    -t=*|--target=*)
      ROLLBACK_TARGET="${1#*=}"
      shift
      ;;
    -t|--target)
      if [ -z "${2:-}" ]; then log_error "Option --target requires an argument"; exit 2; fi
      ROLLBACK_TARGET="$2"
      shift 2
      ;;
    -d|--dry-run)
      DRY_RUN=true
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

if [ -z "${APP_TARGET}" ]; then
  log_error "Missing required parameter: --app=APP_NAME (or set APP=APP_NAME)"
  print_usage
  exit 2
fi

# Step 1: Validate Application Name format
if ! validate_app_name "${APP_TARGET}"; then
  exit 1
fi

log_info "=================================================="
log_info "Atlas Rollback Engine"
log_info "Application: ${APP_TARGET}"
log_info "Started At:  $(iso_timestamp)"
log_info "=================================================="

if ! is_app_registered "${APP_TARGET}"; then
  log_error "Application '${APP_TARGET}' is not registered in apps.yml."
  exit 1
fi

APP_DIR="$(get_app_property "${APP_TARGET}" "directory")"
COMPOSE_FILE="$(get_app_property "${APP_TARGET}" "compose_file")"
if [ -z "${COMPOSE_FILE}" ] || [ "${COMPOSE_FILE}" = "null" ]; then
  COMPOSE_FILE="docker-compose.yml"
fi

if [ ! -d "${APP_DIR}" ]; then
  log_error "Application directory not found: ${APP_DIR}"
  exit 1
fi

cd "${APP_DIR}"

if [ ! -d ".git" ]; then
  log_error "Directory '${APP_DIR}' is not a Git repository. Cannot perform Git-based rollback."
  exit 1
fi

CURRENT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
TARGET_REF="${ROLLBACK_TARGET:-HEAD~1}"

# Validate target commit ref format against shell injection
if ! [[ "${TARGET_REF}" =~ ^[a-zA-Z0-9._/~^-]+$ ]]; then
  log_error "Invalid Git reference format: '${TARGET_REF}'"
  exit 1
fi

# Validate target commit exists
if ! git rev-parse --verify "${TARGET_REF}" >/dev/null 2>&1; then
  log_error "Rollback target '${TARGET_REF}' does not exist in Git history."
  exit 1
fi

TARGET_SHA="$(git rev-parse --short "${TARGET_REF}")"
TARGET_MSG="$(git log -1 --pretty=%B "${TARGET_REF}" | head -n 1)"

log_warn "Current commit:  ${CURRENT_SHA}"
log_warn "Rollback target: ${TARGET_SHA} (\"${TARGET_MSG}\")"

if [ "${DRY_RUN}" = "true" ]; then
  log_info "[DRY-RUN] Would checkout commit ${TARGET_SHA}"
  log_info "[DRY-RUN] Would validate compose file: ${COMPOSE_FILE}"
  log_info "[DRY-RUN] Would rebuild and start containers"
  log_info "[DRY-RUN] Would verify health via scripts/health-check.sh"
  log_success "[DRY-RUN] Rollback simulation complete."
  exit 0
fi

# Step 1: Checkout target commit
log_info "Checking out ${TARGET_SHA}..."
git checkout "${TARGET_SHA}" || {
  log_error "Failed to checkout rollback commit ${TARGET_SHA}."
  exit 1
}
log_pass "Checked out commit ${TARGET_SHA}."

# Step 2: Validate Compose syntax
log_info "Validating compose file ${COMPOSE_FILE}..."
require_cmd docker
if ! docker compose -f "${COMPOSE_FILE}" config -q; then
  log_error "Docker Compose syntax validation failed on target commit!"
  log_error "Reverting checkout back to ${CURRENT_SHA}..."
  git checkout "${CURRENT_SHA}"
  exit 1
fi

# Step 3: Rebuild and launch containers
log_info "Rebuilding and restarting containers at ${TARGET_SHA}..."
docker compose -f "${COMPOSE_FILE}" up -d --build --remove-orphans || {
  log_error "Failed to rebuild containers on rollback commit."
  exit 1
}

# Step 4: Health Check
log_info "Verifying health after rollback..."
sleep 3
if ! "${SCRIPT_DIR}/health-check.sh" --app="${APP_TARGET}" --retries=5 --timeout=5; then
  log_error "Post-rollback health check FAILED for '${APP_TARGET}'."
  exit 1
fi

log_info "=================================================="
log_success "ROLLBACK COMPLETED SUCCESSFULLY!"
log_info "Application: ${APP_TARGET}"
log_info "Reverted to: ${TARGET_SHA} (\"${TARGET_MSG}\")"
log_info "=================================================="
