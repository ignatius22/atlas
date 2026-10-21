#!/usr/bin/env bash
# ==============================================================================
# Atlas — Scheduled Restore Drill
# ==============================================================================
# Restores the newest local backup of each app into a throwaway container and
# verifies every table's row count against the backup's manifest.
# Results are written next to each archive as <archive>.drill.json.
#
# Usage:
#   ./scripts/drill.sh --all
#   ./scripts/drill.sh --app=myapp
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/notify.sh
if [ -f "${SCRIPT_DIR}/lib/notify.sh" ]; then
  source "${SCRIPT_DIR}/lib/notify.sh"
fi

APP_TARGET=""
ALL_APPS=false
CUSTOM_CONFIG=""

print_usage() {
  cat << EOF
Atlas Restore Drill

Usage:
  $(basename "$0") --all | --app=APP_NAME [options]

Options:
  -a, --app=APP_NAME      Drill one application
  --all                   Drill every registered application with backups enabled
  -c, --config=PATH       Path to custom apps.yml configuration file
  -h, --help              Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a=*|--app=*) APP_TARGET="${1#*=}"; shift ;;
    -a|--app)
      if [ -z "${2:-}" ]; then log_error "Option --app requires an argument"; exit 2; fi
      APP_TARGET="$2"; shift 2 ;;
    --all) ALL_APPS=true; shift ;;
    -c=*|--config=*) CUSTOM_CONFIG="${1#*=}"; shift ;;
    -c|--config)
      if [ -z "${2:-}" ]; then log_error "Option --config requires an argument"; exit 2; fi
      CUSTOM_CONFIG="$2"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
  esac
done

if [ -n "${CUSTOM_CONFIG}" ]; then
  export ATLAS_CONFIG_FILE="${CUSTOM_CONFIG}"
fi

if [ "${ALL_APPS}" != "true" ] && [ -z "${APP_TARGET}" ]; then
  log_error "Specify --app=APP_NAME or --all."
  print_usage
  exit 2
fi

check_pyyaml_dependency
require_cmd docker

# One drill at a time (kernel lock: released automatically if this process dies)
if ! acquire_atlas_lock drill; then
  log_error "Another restore drill is already running (lock: ${ATLAS_LOCK_FILE}). Exiting."
  exit 1
fi

if [ "${ALL_APPS}" = "true" ]; then
  apps="$(list_registered_apps)"
else
  if ! validate_app_name "${APP_TARGET}"; then exit 1; fi
  apps="${APP_TARGET}"
fi

if [ -z "${apps}" ]; then
  log_error "No applications found in configuration registry."
  exit 1
fi

passed=0
failed=0
skipped=0
failed_apps=()

for app in ${apps}; do
  if [ "$(get_app_property "${app}" "database.backup")" = "false" ]; then
    log_info "Skipping '${app}': database backups are disabled."
    skipped=$((skipped + 1))
    continue
  fi
  if ! compgen -G "/var/backups/${app}/${app}-*.sql.gz" > /dev/null; then
    log_warn "Skipping '${app}': no local backups to test yet."
    skipped=$((skipped + 1))
    continue
  fi

  log_info "=== Restore drill: ${app} ==="
  restore_args=("--app=${app}" "--target=test")
  if [ -n "${CUSTOM_CONFIG}" ]; then restore_args+=("--config=${CUSTOM_CONFIG}"); fi
  # restore.sh records the result and sends the failure alert itself.
  if "${SCRIPT_DIR}/restore.sh" "${restore_args[@]}"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    failed_apps+=("${app}")
  fi
done

log_info "Restore drills finished: ${passed} passed, ${failed} failed, ${skipped} skipped."

if [ "${failed}" -gt 0 ]; then
  send_atlas_notification "FAILURE" "Atlas Restore Drills Failed" \
    "${failed} of $((passed + failed)) restore drills failed on host \`$(hostname)\`: ${failed_apps[*]}\nInspect: \`journalctl -u atlas-drill.service -n 200 --no-pager\`" || true
  exit 1
fi
exit 0
