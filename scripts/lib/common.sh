#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Common Shell Library
# ==============================================================================
set -Eeuo pipefail

ATLAS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_SCRIPTS_DIR="$(cd "${ATLAS_LIB_DIR}/.." && pwd)"
ATLAS_ROOT_DIR="$(cd "${ATLAS_SCRIPTS_DIR}/.." && pwd)"

export PYTHONPATH="${ATLAS_LIB_DIR}/vendor:${PYTHONPATH:-}"

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

get_atlas_config() {
  local custom="${1:-}"
  if [ -n "${custom}" ] && [ -f "${custom}" ]; then
    echo "${custom}"
    return 0
  fi
  if [ -n "${ATLAS_CONFIG_FILE:-}" ] && [ -f "${ATLAS_CONFIG_FILE}" ]; then
    echo "${ATLAS_CONFIG_FILE}"
    return 0
  fi
  if [ -f "${ATLAS_ROOT_DIR}/atlas.yml" ]; then
    echo "${ATLAS_ROOT_DIR}/atlas.yml"
    return 0
  fi
  if [ -f "${ATLAS_ROOT_DIR}/config/atlas.yml" ]; then
    echo "${ATLAS_ROOT_DIR}/config/atlas.yml"
    return 0
  fi
  if [ -f "${ATLAS_ROOT_DIR}/atlas.example.yml" ]; then
    echo "${ATLAS_ROOT_DIR}/atlas.example.yml"
    return 0
  fi
  echo "${ATLAS_ROOT_DIR}/config/atlas.example.yml"
}

validate_identifier() {
  local val="$1"
  local name="${2:-identifier}"
  if [[ ! "${val}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "[ERROR] Invalid ${name}: '${val}'. Must match ^[a-zA-Z0-9_-]+$" >&2
    return 1
  fi
  return 0
}

log_info() { echo "[INFO]  $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }
log_warn() { echo "[WARN]  $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*" >&2; }
log_error() { echo "[ERROR] $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*" >&2; }
log_success() { echo "[OK]    $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }
