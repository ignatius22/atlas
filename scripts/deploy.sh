#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template — Application Deployment Engine (Hardened V1)
# ==============================================================================
# Usage:
#   APP=myapp ./scripts/deploy.sh
#   ./scripts/deploy.sh --app=myapp [--branch=main] [--dry-run]
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_TARGET="${APP:-}"
BRANCH_OVERRIDE=""
DRY_RUN=false
SKIP_HEALTHCHECK=false
CUSTOM_CONFIG=""

print_usage() {
  cat << EOF
Atlas Application Deployment Engine (V1 Hardened)

Usage:
  $(basename "$0") --app=APP_NAME [options]

Options:
  -a, --app=APP_NAME      Application identifier defined in apps.yml (required)
  -b, --branch=BRANCH     Override deployment Git branch (e.g. --branch=release/v1.2)
  -d, --dry-run           Simulate all deployment checks without building or restarting
  --skip-healthcheck      Skip automated post-deployment health check verification
  -c, --config=PATH       Path to custom apps.yml configuration file
  -h, --help              Show this help message

Examples:
  APP=example-app ./scripts/deploy.sh
  ./scripts/deploy.sh --app=example-app --branch=main
  ./scripts/deploy.sh --app=example-app --dry-run
EOF
}

# Parse arguments
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
    -b=*|--branch=*)
      BRANCH_OVERRIDE="${1#*=}"
      shift
      ;;
    -b|--branch)
      if [ -z "${2:-}" ]; then log_error "Option --branch requires an argument"; exit 2; fi
      BRANCH_OVERRIDE="$2"
      shift 2
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-healthcheck)
      SKIP_HEALTHCHECK=true
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

START_TIME="$(date +%s)"
log_info "=================================================="
log_info "Atlas Deployment Engine"
log_info "Application: ${APP_TARGET}"
log_info "Started At:  $(iso_timestamp)"
log_info "=================================================="

# Step 2: Validate application exists in registry
if ! is_app_registered "${APP_TARGET}"; then
  log_error "Application '${APP_TARGET}' is not declared in apps.yml."
  exit 1
fi
log_pass "Application '${APP_TARGET}' found in registry."

# Step 3: Extract configuration properties
APP_DIR="$(get_app_property "${APP_TARGET}" "directory")"
COMPOSE_FILE="$(get_app_property "${APP_TARGET}" "compose_file")"
if [ -z "${COMPOSE_FILE}" ] || [ "${COMPOSE_FILE}" = "null" ]; then
  COMPOSE_FILE="docker-compose.yml"
fi
STRATEGY="$(get_app_property "${APP_TARGET}" "deployment.strategy")"
if [ -z "${STRATEGY}" ] || [ "${STRATEGY}" = "null" ]; then
  STRATEGY="compose"
fi
CONFIG_BRANCH="$(get_app_property "${APP_TARGET}" "deployment.branch")"
TARGET_BRANCH="${BRANCH_OVERRIDE:-${CONFIG_BRANCH:-main}}"
if [ "${TARGET_BRANCH}" = "null" ]; then TARGET_BRANCH="main"; fi
AUTO_PULL="$(get_app_property "${APP_TARGET}" "deployment.auto_pull")"
PRE_HOOK="$(get_app_property "${APP_TARGET}" "deployment.pre_deploy_hook")"
POST_HOOK="$(get_app_property "${APP_TARGET}" "deployment.post_deploy_hook")"

# Validate branch name against shell injection
if ! [[ "${TARGET_BRANCH}" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  log_error "Invalid Git branch format: '${TARGET_BRANCH}'"
  exit 1
fi

# Step 4: Verify target directory
if [ -z "${APP_DIR}" ] || [ "${APP_DIR}" = "null" ]; then
  log_error "No directory specified for '${APP_TARGET}' in configuration."
  exit 1
fi

if [ "${DRY_RUN}" = "true" ]; then
  log_info "[DRY-RUN] Target Directory:   ${APP_DIR}"
  log_info "[DRY-RUN] Compose File:       ${COMPOSE_FILE}"
  log_info "[DRY-RUN] Git Branch:         ${TARGET_BRANCH}"
  log_info "[DRY-RUN] Strategy:           ${STRATEGY}"
  log_info "[DRY-RUN] Pre-deploy hook:    ${PRE_HOOK:-none}"
  log_info "[DRY-RUN] Post-deploy hook:   ${POST_HOOK:-none}"
  log_success "[DRY-RUN] All pre-flight validation checks passed."
  exit 0
fi

if [ ! -d "${APP_DIR}" ]; then
  log_error "Deployment directory does not exist: ${APP_DIR}"
  exit 1
fi
log_pass "Directory exists: ${APP_DIR}"

cd "${APP_DIR}"

# Step 5: Verify Git state & pull updates (if git repo)
GIT_COMMIT="unknown"
if [ -d ".git" ] && command -v git >/dev/null 2>&1; then
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  log_info "Current Git branch: ${CURRENT_BRANCH} (Target: ${TARGET_BRANCH})"
  
  if [ "${AUTO_PULL}" != "false" ]; then
    log_info "Fetching latest Git changes from origin/${TARGET_BRANCH}..."
    git fetch origin "${TARGET_BRANCH}" || log_warn "Git fetch failed. Proceeding with local repository state."
    
    if [ "${CURRENT_BRANCH}" != "${TARGET_BRANCH}" ]; then
      log_info "Switching to branch '${TARGET_BRANCH}'..."
      git checkout "${TARGET_BRANCH}" || {
        log_error "Failed to checkout branch '${TARGET_BRANCH}'."
        exit 1
      }
    fi
    
    log_info "Pulling latest commits..."
    git pull origin "${TARGET_BRANCH}" || {
      log_error "Git pull failed. Aborting deployment to avoid inconsistent state."
      exit 1
    }
  fi
  
  GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  GIT_MSG="$(git log -1 --pretty=%B 2>/dev/null | head -n 1 || echo "")"
  log_pass "Deploying Git Commit: ${GIT_COMMIT} (\"${GIT_MSG}\")"
fi

# Step 6: Validate Compose configuration syntax
if [ ! -f "${COMPOSE_FILE}" ]; then
  log_error "Compose file '${COMPOSE_FILE}' not found in ${APP_DIR}."
  exit 1
fi

require_cmd docker
log_info "Validating Docker Compose configuration syntax..."
if ! docker compose -f "${COMPOSE_FILE}" config -q; then
  log_error "Docker Compose syntax validation failed for ${COMPOSE_FILE}."
  exit 1
fi
log_pass "Docker Compose syntax is valid."

# Helper to execute hooks safely without eval
execute_safe_hook() {
  local hook_path="$1"
  local hook_type="$2"
  
  if [ -z "${hook_path}" ] || [ "${hook_path}" = "null" ]; then
    return 0
  fi
  
  # Reject hooks containing dangerous shell characters
  local dangerous_pattern='[;&|`$()<>]'
  if [[ "${hook_path}" =~ ${dangerous_pattern} ]]; then
    log_error "Security rejection: ${hook_type} contains illegal shell characters: '${hook_path}'."
    log_error "Hooks must specify an executable script file path, not inline shell commands."
    return 1
  fi
  
  # Resolve path relative to application directory if not absolute
  local resolved_path="${hook_path}"
  if [[ "${resolved_path}" != /* ]]; then
    resolved_path="${APP_DIR}/${hook_path}"
  fi
  
  if [ ! -f "${resolved_path}" ]; then
    log_error "${hook_type} script not found: ${resolved_path}"
    return 1
  fi
  
  if [ ! -x "${resolved_path}" ]; then
    log_error "${hook_type} script is not executable: ${resolved_path} (run: chmod +x ${resolved_path})"
    return 1
  fi
  
  log_info "Executing ${hook_type} script: ${resolved_path}..."
  "${resolved_path}" || {
    log_error "${hook_type} script failed with non-zero exit code."
    return 1
  }
  log_pass "${hook_type} script completed successfully."
}

# Step 7: Execute Pre-Deploy Hook (if configured)
if ! execute_safe_hook "${PRE_HOOK}" "pre_deploy_hook"; then
  log_error "Aborting deployment due to pre-deploy hook failure."
  exit 1
fi

# Step 8: Build and deploy containers
log_info "Building and launching containers via Docker Compose..."
docker compose -f "${COMPOSE_FILE}" up -d --build --remove-orphans || {
  log_error "Docker Compose up command failed."
  exit 1
}
log_pass "Containers rebuilt and launched successfully."

# Step 9: Automated Health Verification
if [ "${SKIP_HEALTHCHECK}" = "false" ]; then
  log_info "Performing post-deployment health check verification..."
  sleep 3
  
  if ! "${SCRIPT_DIR}/health-check.sh" --app="${APP_TARGET}" --retries=5 --timeout=5; then
    log_error "Deployment health verification FAILED for '${APP_TARGET}'."
    log_error "Review container logs with: docker compose -f ${APP_DIR}/${COMPOSE_FILE} logs --tail=50"
    exit 1
  fi
  log_pass "Post-deployment health verification passed."
fi

# Step 10: Execute Post-Deploy Hook (if configured)
if ! execute_safe_hook "${POST_HOOK}" "post_deploy_hook"; then
  log_warn "Post-deploy hook encountered an issue."
fi

END_TIME="$(date +%s)"
DURATION=$((END_TIME - START_TIME))

log_info "=================================================="
log_success "DEPLOYMENT COMPLETED SUCCESSFULLY!"
log_info "Application: ${APP_TARGET}"
log_info "Git Commit:  ${GIT_COMMIT}"
log_info "Duration:    ${DURATION}s"
log_info "=================================================="
