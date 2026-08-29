#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Off-Site Backup Recovery & Disaster Recovery Drill Engine
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
if [ -f "${SCRIPT_DIR}/lib/notify.sh" ]; then
  source "${SCRIPT_DIR}/lib/notify.sh"
fi

APP_TARGET="${APP:-}"
REMOTE_FILE=""
KEY_FILE=""
TARGET_ENV="test"
LIST_MODE=false
CUSTOM_CONFIG=""

print_usage() {
  cat << 'HELP'
Atlas Off-Site Backup Recovery & DR Verification (V1)

Usage:
  atlas restore test [options]    # Ephemeral isolated verification drill
  atlas restore run --offsite ... # Production recovery

Options:
  -a, --app=APP_NAME       Application identifier to recover
  -f, --file=FILENAME      Remote file to retrieve (Default: latest available)
  -k, --key-file=PATH      Path to Age private key file
  --target=TARGET          Target environment: 'test' (default) or 'production'
  -l, --list               List available remote archives
  -c, --config=PATH        Path to atlas.yml
  -h, --help               Show this help message
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--app) APP_TARGET="$2"; shift 2 ;;
    --app=*) APP_TARGET="${1#*=}"; shift ;;
    -f|--file) REMOTE_FILE="$2"; shift 2 ;;
    --file=*) REMOTE_FILE="${1#*=}"; shift ;;
    -k|--key-file) KEY_FILE="$2"; shift 2 ;;
    --key-file=*) KEY_FILE="${1#*=}"; shift ;;
    --target=*) TARGET_ENV="${1#*=}"; shift ;;
    -l|--list) LIST_MODE=true; shift ;;
    -c|--config) CUSTOM_CONFIG="$2"; shift 2 ;;
    --config=*) CUSTOM_CONFIG="${1#*=}"; shift ;;
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

S3_BUCKET="${ATLAS_S3_BUCKET:-}"
S3_ENDPOINT="${ATLAS_S3_ENDPOINT:-}"
PROVIDER="${ATLAS_OFFSITE_PROVIDER:-s3}"

if [ "${LIST_MODE}" = true ]; then
  log_info "Available remote backups for '${APP_TARGET}':"
  if [ "${PROVIDER}" = "local-mock" ]; then
    ls -lh "/tmp/atlas_mock_s3/${APP_TARGET}" 2>/dev/null || echo "No mock archives found."
  elif command -v rclone >/dev/null 2>&1; then
    rclone lsf ":s3:${S3_BUCKET}/${APP_TARGET}/" \
      --s3-provider=Cloudflare \
      --s3-endpoint="${S3_ENDPOINT}" \
      --s3-access-key-id="${ATLAS_S3_ACCESS_KEY:-}" \
      --s3-secret-access-key="${ATLAS_S3_SECRET_KEY:-}"
  else
    aws s3 ls "s3://${S3_BUCKET}/${APP_TARGET}/" ${S3_ENDPOINT:+--endpoint-url "${S3_ENDPOINT}"}
  fi
  exit 0
fi

umask 077
WORK_DIR="$(mktemp -d -p "/var/backups/.tmp" 2>/dev/null || mktemp -d)"
chmod 700 "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

AGE_KEY_PATH="${KEY_FILE}"
if [ -z "${AGE_KEY_PATH}" ] && [ -n "${ATLAS_AGE_IDENTITY:-}" ]; then
  AGE_KEY_PATH="${WORK_DIR}/identity.key"
  echo "${ATLAS_AGE_IDENTITY}" > "${AGE_KEY_PATH}"
  chmod 600 "${AGE_KEY_PATH}"
fi

if [ -z "${AGE_KEY_PATH}" ] || [ ! -f "${AGE_KEY_PATH}" ]; then
  log_error "Age private key required for decryption. Provide --key-file=/path/to/key.txt or ATLAS_AGE_IDENTITY"
  exit 1
fi

log_info "Retrieving encrypted archive from off-site storage for '${APP_TARGET}'..."
LOCAL_ENC_FILE="${WORK_DIR}/backup.sql.gz.age"

if [ "${PROVIDER}" = "local-mock" ]; then
  latest_mock="$(find "/tmp/atlas_mock_s3/${APP_TARGET}" -name "*.age" 2>/dev/null | sort | tail -n 1)"
  if [ -z "${latest_mock}" ] || [ ! -f "${latest_mock}" ]; then
    log_error "No remote backup archives found in mock storage."
    exit 1
  fi
  cp "${latest_mock}" "${LOCAL_ENC_FILE}"
elif command -v rclone >/dev/null 2>&1; then
  if ! rclone copyto ":s3:${S3_BUCKET}/${APP_TARGET}/${REMOTE_FILE:-latest.age}" "${LOCAL_ENC_FILE}" \
    --s3-provider=Cloudflare \
    --s3-endpoint="${S3_ENDPOINT}" \
    --s3-access-key-id="${ATLAS_S3_ACCESS_KEY:-}" \
    --s3-secret-access-key="${ATLAS_S3_SECRET_KEY:-}"; then
    log_error "Failed to retrieve remote archive from S3/R2."
    exit 1
  fi
else
  if ! aws s3 cp "s3://${S3_BUCKET}/${APP_TARGET}/${REMOTE_FILE:-latest.age}" "${LOCAL_ENC_FILE}" ${S3_ENDPOINT:+--endpoint-url "${S3_ENDPOINT}"}; then
    log_error "Failed to retrieve remote archive from AWS S3."
    exit 1
  fi
fi

log_info "Decrypting archive using Age identity..."
DECRYPTED_FILE="${WORK_DIR}/backup.sql.gz"
if ! age -d -i "${AGE_KEY_PATH}" -o "${DECRYPTED_FILE}" "${LOCAL_ENC_FILE}" 2>/dev/null; then
  log_error "Age decryption failed! Identity key mismatch or corrupted archive."
  exit 1
fi

if [ "${TARGET_ENV}" = "test" ]; then
  log_info "Starting ephemeral test container to verify database recovery..."
  TEST_CONTAINER="atlas_verify_${APP_TARGET}_$$"
  docker run -d --name "${TEST_CONTAINER}" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=atlas_test \
    -e POSTGRES_DB=postgres \
    postgres:16-alpine >/dev/null

  for i in {1..30}; do
    if docker exec "${TEST_CONTAINER}" pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  start_ts="$(date +%s%N)"
  if ! zcat "${DECRYPTED_FILE}" | docker exec -i "${TEST_CONTAINER}" psql -U postgres -d postgres >/dev/null 2>&1; then
    docker rm -f "${TEST_CONTAINER}" >/dev/null 2>&1 || true
    log_error "DR drill restoration failed on test container!"
    exit 1
  fi
  end_ts="$(date +%s%N)"
  elapsed_ms="$(( (end_ts - start_ts) / 1000000 ))"

  table_count="$(docker exec "${TEST_CONTAINER}" psql -U postgres -d postgres -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" | tr -d ' ')"
  docker rm -f "${TEST_CONTAINER}" >/dev/null 2>&1 || true

  log_success "DR Verification Drill PASSED for '${APP_TARGET}'! Tables restored: ${table_count}, Measured RTO: ${elapsed_ms}ms"
else
  "${SCRIPT_DIR}/restore.sh" --app="${APP_TARGET}" --file="${DECRYPTED_FILE}"
fi
