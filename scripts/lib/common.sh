#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template — Common Shell Library
# ==============================================================================
# Sourced by all Atlas scripts for consistent logging, config lookup,
# input validation, and PyYAML preflight verification.
# ==============================================================================

set -Eeuo pipefail

# Determine script & project root paths
ATLAS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_SCRIPTS_DIR="$(cd "${ATLAS_LIB_DIR}/.." && pwd)"
ATLAS_ROOT_DIR="$(cd "${ATLAS_SCRIPTS_DIR}/.." && pwd)"

# Ensure PyYAML vendor path is accessible to Python subprocesses
export PYTHONPATH="${ATLAS_LIB_DIR}/vendor:${PYTHONPATH:-}"

# Safe .env loader without arbitrary code execution or quote issues
load_atlas_env() {
  local env_file="${ATLAS_ROOT_DIR}/.env"
  if [ -f "${env_file}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
      line="$(echo "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [[ "${line}" =~ ^# ]] || [ -z "${line}" ]; then
        continue
      fi
      if [[ "${line}" =~ ^[A-Za-z0-9_]+= ]]; then
        local key="${line%%=*}"
        local val="${line#*=}"
        val="${val#\"}"
        val="${val%\"}"
        val="${val#\'}"
        val="${val%\'}"
        export "${key}=${val}"
      fi
    done < "${env_file}"
  fi
}
load_atlas_env

# Color & Style definitions (disabled if not on interactive terminal or NO_COLOR set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_RESET="\033[0m"
  COLOR_BOLD="\033[1m"
  COLOR_RED="\033[31m"
  COLOR_GREEN="\033[32m"
  COLOR_YELLOW="\033[33m"
  COLOR_BLUE="\033[34m"
  COLOR_CYAN="\033[36m"
  COLOR_GRAY="\033[90m"
else
  COLOR_RESET=""
  COLOR_BOLD=""
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_CYAN=""
  COLOR_GRAY=""
fi

# Loggers
log_info() {
  printf "${COLOR_BLUE}[INFO]${COLOR_RESET} %s\n" "$*"
}

log_success() {
  printf "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} %s\n" "$*"
}

log_warn() {
  printf "${COLOR_YELLOW}[WARN]${COLOR_RESET} %s\n" "$*" >&2
}

log_error() {
  printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$*" >&2
}

log_pass() {
  printf "  ${COLOR_GREEN}✓ PASS${COLOR_RESET} %s\n" "$*"
}

log_warning_badge() {
  printf "  ${COLOR_YELLOW}⚠ WARN${COLOR_RESET} %s\n" "$*"
}

log_fail_badge() {
  printf "  ${COLOR_RED}✗ FAIL${COLOR_RESET} %s\n" "$*"
}

# Timestamp functions
iso_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

filename_timestamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

# Strict Application Name Validation (prevents path traversal and injection)
validate_app_name() {
  local app="$1"
  if [ -z "${app}" ]; then
    log_error "Application identifier cannot be empty."
    return 2
  fi
  if ! [[ "${app}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid application identifier '${app}'. Must contain only alphanumeric characters, dashes, and underscores (^[a-zA-Z0-9_-]+$). Path traversal and shell characters are rejected."
    return 1
  fi
}

# Preflight check for PyYAML
check_pyyaml_dependency() {
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    log_error "PyYAML (python3-yaml) is required but not found."
    log_error "Install via: sudo apt-get install python3-yaml (or pip install pyyaml)"
    return 2
  fi
}

# Find Atlas Application Registry Config File
find_apps_config() {
  if [ -n "${ATLAS_CONFIG_FILE:-}" ] && [ -f "${ATLAS_CONFIG_FILE}" ]; then
    echo "${ATLAS_CONFIG_FILE}"
    return 0
  fi
  if [ -f "${ATLAS_ROOT_DIR}/config/apps.yml" ]; then
    echo "${ATLAS_ROOT_DIR}/config/apps.yml"
    return 0
  fi
  if [ -f "${ATLAS_ROOT_DIR}/config/apps.yaml" ]; then
    echo "${ATLAS_ROOT_DIR}/config/apps.yaml"
    return 0
  fi
  if [ -f "${ATLAS_ROOT_DIR}/config/apps.example.yml" ]; then
    echo "${ATLAS_ROOT_DIR}/config/apps.example.yml"
    return 0
  fi
  return 1
}

# Find Atlas Backup Config File
find_backup_config() {
  if [ -n "${ATLAS_BACKUP_CONFIG_FILE:-}" ] && [ -f "${ATLAS_BACKUP_CONFIG_FILE}" ]; then
    echo "${ATLAS_BACKUP_CONFIG_FILE}"
    return 0
  fi
  if [ -f "${ATLAS_ROOT_DIR}/config/backup.yml" ]; then
    echo "${ATLAS_ROOT_DIR}/config/backup.yml"
    return 0
  fi
  if [ -f "${ATLAS_ROOT_DIR}/config/backup.example.yml" ]; then
    echo "${ATLAS_ROOT_DIR}/config/backup.example.yml"
    return 0
  fi
  return 1
}

# Python YAML helper wrapper
query_yaml() {
  local file="$1"
  local query="$2"
  "${ATLAS_LIB_DIR}/yaml_parser.py" "${file}" "${query}" 2>/dev/null || true
}

query_yaml_keys() {
  local file="$1"
  local query="$2"
  "${ATLAS_LIB_DIR}/yaml_parser.py" "${file}" --keys "${query}" 2>/dev/null || true
}

# Query application properties
get_app_property() {
  local app="$1"
  local prop="$2"
  local config_file
  config_file="$(find_apps_config)" || {
    log_error "No apps.yml configuration file found in ${ATLAS_ROOT_DIR}/config/"
    return 1
  }
  query_yaml "${config_file}" "apps.${app}.${prop}"
}

# Check if application is defined in registry
is_app_registered() {
  local app="$1"
  local config_file
  config_file="$(find_apps_config)" || return 1
  "${ATLAS_LIB_DIR}/yaml_parser.py" "${config_file}" --has "apps.${app}" >/dev/null 2>&1
}

# List all registered applications
list_registered_apps() {
  local config_file
  config_file="$(find_apps_config)" || return 1
  query_yaml_keys "${config_file}" "apps"
}

# Validate command exists
require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required tool '${cmd}' is not installed or not in PATH."
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Process locks
# ------------------------------------------------------------------------------
# acquire_atlas_lock <name>
# Takes a non-blocking kernel lock (flock) on <lock dir>/<name>.lock, held until
# this process and any children holding the descriptor exit. Because the kernel
# releases it when the process dies (crash, kill -9, OOM, reboot), a lock can
# never be left behind to block future runs, unlike a lock directory.
# Lock dir: $ATLAS_LOCK_DIR, else /run/atlas, else /tmp.
# Returns 1 if another process holds the lock.
acquire_atlas_lock() {
  local name="$1"
  local dir="${ATLAS_LOCK_DIR:-/run/atlas}"
  if ! mkdir -p "${dir}" 2>/dev/null || [ ! -w "${dir}" ]; then
    dir="/tmp"
  fi
  ATLAS_LOCK_FILE="${dir}/${name}.lock"
  if ! command -v flock >/dev/null 2>&1; then
    log_error "Required tool 'flock' (util-linux) is not installed."
    return 1
  fi
  # Bash picks a free descriptor and stores it in ATLAS_LOCK_FD (no eval needed).
  exec {ATLAS_LOCK_FD}>"${ATLAS_LOCK_FILE}"
  flock -n "${ATLAS_LOCK_FD}"
}
