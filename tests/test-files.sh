#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — File & Volume Backup Tests
# ==============================================================================
# Unit tests for scripts/lib/files_backup.py always run. The end-to-end flow
# (backup.sh -> sync-offsite.sh -> drill.sh -> restore-files.sh with a real
# Docker volume) runs when a Docker daemon is reachable and /var/backups is
# writable.
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
FB="${ATLAS_ROOT}/scripts/lib/files_backup.py"

PASSED=0
FAILED=0
pass() { printf "  \033[32m✓ PASS\033[0m: %s\n" "$1"; PASSED=$((PASSED + 1)); }
fail() { printf "  \033[31m✗ FAIL\033[0m: %s\n" "$1"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
APP="filetest$$"
VOLUME="atlas_filetest_$$"
cleanup() {
  docker volume rm -f "${VOLUME}" > /dev/null 2>&1 || true
  rm -rf "${WORK}" "/var/backups/${APP}" "/var/backups/offsite-mock/atlas-backups/${APP}" 2> /dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
printf "\n\033[1m=== Files Archive Unit Tests ===\033[0m\n"
# ------------------------------------------------------------------------------
SRC="${WORK}/src"
mkdir -p "${SRC}/img/deep" "${SRC}/cache"
printf 'hello' > "${SRC}/img/a.txt"
head -c 200000 /dev/urandom > "${SRC}/img/deep/b.bin"
printf 'x' > "${SRC}/cache/tmp"
printf 'log' > "${SRC}/app.log"
ln -s img/a.txt "${SRC}/inside-link"
ln -s /etc/passwd "${SRC}/escaping-link"
mkfifo "${SRC}/pipe"

if python3 -I "${FB}" create "${WORK}/a.tar.gz" "${WORK}/a.json" --path "${SRC}" --exclude cache --exclude '*.log' > /dev/null \
  && python3 -I - "${WORK}/a.json" << 'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["files"] == 2 and m["bytes"] == 200005, m
assert m["skipped_count"] == 1 and "pipe" in m["skipped"][0], m["skipped"]
assert len(m["digest"]) == 64
PY
then
  pass "Archive holds regular files, applies excludes, records skipped special files"
else
  fail "Archive creation and manifest"
fi

if python3 -I "${FB}" verify "${WORK}/a.tar.gz" "${WORK}/a.json" > /dev/null; then
  pass "Verify passes on an untouched archive"
else
  fail "Verify on an untouched archive"
fi

cp "${WORK}/a.json" "${WORK}/b.json"
python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m["digest"]="0"*64; json.dump(m, open(p,"w"))' "${WORK}/b.json"
if ! python3 -I "${FB}" verify "${WORK}/a.tar.gz" "${WORK}/b.json" > "${WORK}/b.out" && grep -q "contents differ" "${WORK}/b.out"; then
  pass "Verify detects file contents that differ from the backup"
else
  fail "Verify did not detect changed contents"
fi

if python3 -I "${FB}" restore "${WORK}/a.tar.gz" "${WORK}/out" > /dev/null 2> "${WORK}/restore.err"; then
  R="$(find "${WORK}/out/paths" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if cmp -s "${SRC}/img/deep/b.bin" "${R}/img/deep/b.bin" && [ -L "${R}/inside-link" ] && [ ! -e "${R}/escaping-link" ] && [ ! -L "${R}/escaping-link" ]; then
    pass "Restore is byte-identical, keeps internal links and drops links that escape the restore directory"
  else
    fail "Restore contents or link handling"
  fi
else
  fail "Restore failed: $(cat "${WORK}/restore.err")"
fi

mkdir -p "${WORK}/notempty" && touch "${WORK}/notempty/x"
if ! python3 -I "${FB}" restore "${WORK}/a.tar.gz" "${WORK}/notempty" > /dev/null 2>&1; then
  pass "Restore refuses to write into a non-empty directory"
else
  fail "Restore wrote into a non-empty directory"
fi

# ------------------------------------------------------------------------------
printf "\n\033[1m=== End-to-End Files Backup (real Docker volume) ===\033[0m\n"
# ------------------------------------------------------------------------------
if ! docker info > /dev/null 2>&1; then
  printf "  \033[33m⚠ SKIP\033[0m: Docker daemon not reachable; end-to-end files test skipped\n"
elif ! { [ -w /var/backups ] || mkdir -p /var/backups 2> /dev/null; }; then
  printf "  \033[33m⚠ SKIP\033[0m: /var/backups not writable; end-to-end files test skipped\n"
elif ! docker volume create "${VOLUME}" > /dev/null 2>&1 || ! MOUNT="$(docker volume inspect -f '{{.Mountpoint}}' "${VOLUME}")" || ! { [ -w "${MOUNT}" ] || sudo -n true 2> /dev/null; }; then
  printf "  \033[33m⚠ SKIP\033[0m: Docker volume mountpoint not writable here; end-to-end files test skipped\n"
else
  SUDO=""
  [ -w "${MOUNT}" ] || SUDO="sudo -n"
  ${SUDO} mkdir -p "${MOUNT}/uploads"
  for i in $(seq 1 25); do head -c $((i * 512)) /dev/urandom | ${SUDO} tee "${MOUNT}/uploads/f${i}.jpg" > /dev/null; done
  mkdir -p "${WORK}/site/storage"
  printf 'settings' > "${WORK}/site/storage/config.json"

  cat > "${WORK}/apps.yml" << EOF
version: "1.0"
apps:
  ${APP}:
    directory: "/tmp"
    files:
      volumes: ["${VOLUME}"]
      paths: ["${WORK}/site"]
EOF
  export ATLAS_CONFIG_FILE="${WORK}/apps.yml"
  export ATLAS_LOCK_DIR="${WORK}/locks"

  if ${SUDO} env ATLAS_CONFIG_FILE="${ATLAS_CONFIG_FILE}" ATLAS_LOCK_DIR="${ATLAS_LOCK_DIR}" "${ATLAS_ROOT}/scripts/backup.sh" --app="${APP}" > "${WORK}/b1.log" 2>&1 \
    && ARCHIVE="$(ls -1 /var/backups/${APP}/${APP}-files-*.tar.gz 2> /dev/null | head -n 1)" && [ -n "${ARCHIVE}" ] \
    && grep -q "26 files" "${WORK}/b1.log"; then
    pass "backup.sh archives a Docker volume and a host directory for an app with no database"
  else
    fail "backup.sh files backup: $(tail -n 3 "${WORK}/b1.log")"
    ARCHIVE=""
  fi

  if [ -n "${ARCHIVE}" ]; then
    ${SUDO} env ATLAS_CONFIG_FILE="${ATLAS_CONFIG_FILE}" ATLAS_LOCK_DIR="${ATLAS_LOCK_DIR}" "${ATLAS_ROOT}/scripts/backup.sh" --app="${APP}" > "${WORK}/b2.log" 2>&1 || true
    if grep -q "less than 24h ago" "${WORK}/b2.log" && [ "$(ls -1 /var/backups/${APP}/${APP}-files-*.tar.gz | wc -l)" -eq 1 ]; then
      pass "A second run within every_hours skips the files backup"
    else
      fail "files.every_hours throttle"
    fi

    KEY="$(age-keygen 2> /dev/null | grep -o 'age1[a-z0-9]*' || true)"
    if [ -n "${KEY}" ] && ${SUDO} env ATLAS_CONFIG_FILE="${ATLAS_CONFIG_FILE}" ATLAS_LOCK_DIR="${ATLAS_LOCK_DIR}" ATLAS_AGE_RECIPIENT="${KEY}" ATLAS_OFFSITE_PROVIDER=local-mock \
      "${ATLAS_ROOT}/scripts/sync-offsite.sh" --app="${APP}" > "${WORK}/sync.log" 2>&1 && [ -f "${ARCHIVE}.synced" ]; then
      pass "Offsite sync encrypts, uploads and confirms the files archive (.synced)"
    else
      fail "Offsite sync of files archive: $(tail -n 3 "${WORK}/sync.log")"
    fi

    if ${SUDO} env ATLAS_CONFIG_FILE="${ATLAS_CONFIG_FILE}" ATLAS_LOCK_DIR="${ATLAS_LOCK_DIR}" "${ATLAS_ROOT}/scripts/drill.sh" --app="${APP}" > "${WORK}/drill.log" 2>&1 \
      && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["passed"] and d["files_found"] == 26, d' "${ARCHIVE}.drill.json"; then
      pass "Drill reads the files archive end to end and records 26 files verified"
    else
      fail "Files drill: $(tail -n 3 "${WORK}/drill.log")"
    fi

    if ${SUDO} env ATLAS_CONFIG_FILE="${ATLAS_CONFIG_FILE}" "${ATLAS_ROOT}/bin/atlas" restore files "${APP}" --to="${WORK}/restored" > "${WORK}/rf.log" 2>&1 \
      && ${SUDO} diff -r "${MOUNT}" "${WORK}/restored/volumes/${VOLUME}" > /dev/null; then
      pass "atlas restore files restores the volume byte for byte into a new directory"
    else
      fail "atlas restore files: $(tail -n 3 "${WORK}/rf.log")"
    fi
    ${SUDO} rm -rf "${WORK}/restored" 2> /dev/null || true
    ${SUDO} rm -rf "/var/backups/${APP}" "/var/backups/offsite-mock/atlas-backups/${APP}" 2> /dev/null || true
  fi
fi

printf "\n\033[1mFiles Backup Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
