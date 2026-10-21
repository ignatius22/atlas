#!/usr/bin/env bash
# ==============================================================================
# Atlas — Restore Files and Volumes
# ==============================================================================
# Extracts a files archive into a NEW directory. It never writes into live
# volumes or app directories: you review the restored copy, then move it in.
#
# Usage:
#   ./scripts/restore-files.sh --app=myapp [--file=ARCHIVE] [--to=DIR]
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_TARGET=""
ARCHIVE=""
TARGET_DIR=""

print_usage() {
  cat << EOF
Atlas Files Restore

Usage:
  $(basename "$0") --app=APP_NAME [--file=ARCHIVE] [--to=DIR]

Options:
  -a, --app=APP_NAME   Application whose files to restore
  -f, --file=ARCHIVE   Files archive (default: newest ${APP_TARGET:-<app>}-files-*.tar.gz)
  -t, --to=DIR         Empty or new directory to restore into
                       (default: /var/restore/<archive name>)
  -h, --help           Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a=*|--app=*) APP_TARGET="${1#*=}"; shift ;;
    -a|--app) APP_TARGET="${2:-}"; shift 2 ;;
    -f=*|--file=*) ARCHIVE="${1#*=}"; shift ;;
    -f|--file) ARCHIVE="${2:-}"; shift 2 ;;
    -t=*|--to=*) TARGET_DIR="${1#*=}"; shift ;;
    -t|--to) TARGET_DIR="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
  esac
done

if [ -z "${APP_TARGET}" ]; then
  log_error "Missing required option: --app=APP_NAME"
  print_usage
  exit 2
fi
validate_app_name "${APP_TARGET}" || exit 1

if [ -z "${ARCHIVE}" ]; then
  ARCHIVE="$(find "/var/backups/${APP_TARGET}" -maxdepth 1 -type f -name "${APP_TARGET}-files-*.tar.gz" 2>/dev/null | sort -r | head -n 1 || true)"
fi
if [ -z "${ARCHIVE}" ] || [ ! -f "${ARCHIVE}" ]; then
  log_error "No files archive found for '${APP_TARGET}'."
  exit 2
fi

if [ -f "${ARCHIVE}.sha256" ]; then
  if [ "$(cut -d' ' -f1 < "${ARCHIVE}.sha256")" != "$(sha256sum "${ARCHIVE}" | cut -d' ' -f1)" ]; then
    log_error "Checksum mismatch for ${ARCHIVE}. Refusing to restore a modified or corrupted archive."
    exit 1
  fi
  log_pass "Checksum verified."
fi

if [ -z "${TARGET_DIR}" ]; then
  TARGET_DIR="/var/restore/$(basename "${ARCHIVE}" .tar.gz)"
fi

log_info "Restoring $(basename "${ARCHIVE}") into ${TARGET_DIR} ..."
python3 -I "${SCRIPT_DIR}/lib/files_backup.py" restore "${ARCHIVE}" "${TARGET_DIR}" > /dev/null

if [ -f "${ARCHIVE}.manifest.json" ]; then
  log_info "Restored sources:"
  python3 -I - "${ARCHIVE}.manifest.json" "${TARGET_DIR}" << 'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
for s in m["sources"]:
    where = f"{sys.argv[2]}/{s['prefix']}"
    origin = f"Docker volume '{s['name']}'" if s["kind"] == "volume" else s["name"]
    print(f"  {origin}: {s['files']:,} files -> {where}")
PYEOF
fi

log_success "Files restored. Nothing live was changed."
cat << EOF
To put a source back, stop the app first, then copy it into place, for example:
  rsync -a --delete "${TARGET_DIR}/volumes/<volume>/" "\$(docker volume inspect -f '{{.Mountpoint}}' <volume>)/"
  rsync -a --delete "${TARGET_DIR}/paths/<label>/" /original/path/
EOF
