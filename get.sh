#!/usr/bin/env bash
# ==============================================================================
# Atlas one-line installer
#
#   curl -fsSL https://raw.githubusercontent.com/ignatius22/atlas/master/get.sh | sudo bash
#
# Installs Atlas into /opt/atlas, finds the apps running on this server,
# protects them, and proves the first backup restores. Safe to run again:
# it upgrades the code and keeps your .env and config/apps.yml.
#
# Options (pass after `sudo bash -s --`):
#   --yes                  Never prompt; accept the discovered apps
#   --age-recipient=KEY    Use your own age public key (age1...) for offsite encryption
#   --ref=REF              Install a branch or tag (default: master)
#   --dir=PATH             Install directory (default: /opt/atlas)
#   --no-first-run         Skip the first backup and restore drill
#   --no-start             Do not enable the timers or the dashboard
#   --no-deps              Do not install packages (age, rclone, python3)
#   --no-discover          Do not scan running containers for apps
#
# The whole script lives in functions and runs only from the last line, so a
# download cut off halfway does nothing.
# ==============================================================================
set -Eeuo pipefail

REPO="${ATLAS_REPO:-ignatius22/atlas}"
REF="${ATLAS_REF:-master}"
INSTALL_DIR="${ATLAS_INSTALL_DIR:-/opt/atlas}"
ASSUME_YES=0
AGE_RECIPIENT="${ATLAS_AGE_RECIPIENT_INPUT:-}"
FIRST_RUN=1
START=1
DEPS=1
DISCOVER=1
WORK=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[90m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; D=""; N=""
fi

step() { printf "\n%s==>%s %s%s%s\n" "${G}" "${N}" "${B}" "$*" "${N}"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "    %s!%s %s\n" "${Y}" "${N}" "$*"; }
die() { printf "\n%sx%s %s\n" "${R}" "${N}" "$*" >&2; exit 1; }

# Prompts read from the terminal, since stdin is the script itself when piped.
can_prompt() { [ "${ASSUME_YES}" = 0 ] && { : < /dev/tty; } 2> /dev/null; }
ask() { # ask "Question" default -> echoes the answer
  local answer=""
  printf "    %s " "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || true
  printf "%s" "${answer:-$2}"
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      -y|--yes) ASSUME_YES=1 ;;
      --age-recipient=*) AGE_RECIPIENT="${arg#*=}" ;;
      --ref=*) REF="${arg#*=}" ;;
      --dir=*) INSTALL_DIR="${arg#*=}" ;;
      --no-first-run) FIRST_RUN=0 ;;
      --no-start) START=0 ;;
      --no-deps) DEPS=0 ;;
      --no-discover) DISCOVER=0 ;;
      -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]:-/dev/null}" 2> /dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "Unknown option: ${arg} (see --help)" ;;
    esac
  done
  if [ -n "${AGE_RECIPIENT}" ] && [[ ! "${AGE_RECIPIENT}" =~ ^age1[0-9a-z]{20,}$ ]]; then
    die "--age-recipient must be an age public key (starts with age1). Never pass the private key."
  fi
}

preflight() {
  step "Checking this server"
  [ "$(uname -s)" = "Linux" ] || die "Atlas runs on Linux servers."
  if [ "$(id -u)" -ne 0 ] && [ "${ATLAS_ALLOW_NONROOT:-0}" != 1 ]; then
    die "Run as root: curl -fsSL https://raw.githubusercontent.com/${REPO}/master/get.sh | sudo bash"
  fi
  if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
    info "Docker: $(docker version --format '{{.Server.Version}}' 2> /dev/null || echo running)"
  else
    warn "Docker is not running. Atlas backs up databases and volumes in Docker containers."
    DISCOVER=0
    FIRST_RUN=0
  fi
  command -v systemctl > /dev/null 2>&1 || { warn "No systemd found; schedule backups with cron instead."; START=0; }
}

install_deps() {
  [ "${DEPS}" = 1 ] || return 0
  local missing=() tool
  for tool in python3 age rclone curl tar gzip; do
    command -v "${tool}" > /dev/null 2>&1 || missing+=("${tool}")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  step "Installing ${missing[*]}"
  if command -v apt-get > /dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates > /dev/null
  elif command -v dnf > /dev/null 2>&1; then
    dnf install -y -q epel-release > /dev/null 2>&1 || true
    dnf install -y -q "${missing[@]}" > /dev/null
  elif command -v apk > /dev/null 2>&1; then
    apk add -q "${missing[@]}" bash
  else
    die "Install these first, then run again: ${missing[*]}"
  fi
  for tool in "${missing[@]}"; do
    command -v "${tool}" > /dev/null 2>&1 || die "Could not install ${tool}."
  done
}

fetch_source() {
  # ATLAS_SOURCE_DIR installs from a local checkout (used by the tests).
  if [ -n "${ATLAS_SOURCE_DIR:-}" ]; then
    SOURCE="${ATLAS_SOURCE_DIR}"
    return 0
  fi
  step "Downloading Atlas (${REF})"
  WORK="$(mktemp -d)"
  local kind="heads"
  [[ "${REF}" =~ ^v[0-9] ]] && kind="tags"
  curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/refs/${kind}/${REF}" -o "${WORK}/atlas.tar.gz" \
    || die "Could not download ${REPO}@${REF}."
  mkdir -p "${WORK}/src"
  tar -xzf "${WORK}/atlas.tar.gz" -C "${WORK}/src" --strip-components=1
  SOURCE="${WORK}/src"
}

install_code() {
  local previous=""
  [ -f "${INSTALL_DIR}/VERSION" ] && previous="$(tr -d '[:space:]' < "${INSTALL_DIR}/VERSION")"
  if [ -d "${INSTALL_DIR}/.git" ] && [ -z "${ATLAS_SOURCE_DIR:-}" ]; then
    step "Updating the git checkout in ${INSTALL_DIR}"
    git -C "${INSTALL_DIR}" fetch -q origin "${REF}"
    git -C "${INSTALL_DIR}" merge -q --ff-only FETCH_HEAD \
      || die "${INSTALL_DIR} has local changes or a different history. Update it with git, then run again."
    SOURCE="${INSTALL_DIR}"
  else
    step "Installing to ${INSTALL_DIR}"
  fi
  local log
  log="$(mktemp)"
  ATLAS_INSTALL_DIR="${INSTALL_DIR}" bash "${SOURCE}/scripts/install.sh" > "${log}" 2>&1 \
    || { cat "${log}" >&2; rm -f "${log}"; die "Installer failed."; }
  rm -f "${log}"
  chmod +x "${INSTALL_DIR}"/bin/* "${INSTALL_DIR}"/scripts/*.sh 2> /dev/null || true
  local now
  now="$(tr -d '[:space:]' < "${INSTALL_DIR}/VERSION")"
  if [ -n "${previous}" ]; then info "Atlas ${previous} -> ${now}"; else info "Atlas ${now}"; fi
}

# Set KEY=VALUE in .env, replacing an existing line or appending one.
set_env() {
  local key="$1" value="$2" file="${INSTALL_DIR}/.env" tmp
  if grep -q "^${key}=" "${file}"; then
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v k="${key}" -v v="${value}" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "${file}" > "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

get_env() {
  sed -n "s/^$1=//p" "${INSTALL_DIR}/.env" | tail -n 1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'
}

configure_env() {
  step "Configuring ${INSTALL_DIR}/.env"
  local env="${INSTALL_DIR}/.env"
  if [ ! -f "${env}" ]; then
    (umask 077 && cat > "${env}" << 'EOF'
# Atlas settings. Written by get.sh; edit freely, re-running get.sh keeps your values.
ATLAS_BACKUP_STORAGE_DIR=/var/backups

# Offsite copies are encrypted with this age PUBLIC key. The private key never lives here.
ATLAS_AGE_RECIPIENT=

# Offsite storage (Cloudflare R2, AWS S3, Backblaze B2 or any S3-compatible bucket)
ATLAS_OFFSITE_PROVIDER=auto
ATLAS_S3_BUCKET=
ATLAS_S3_ENDPOINT=
ATLAS_S3_ACCESS_KEY=
ATLAS_S3_SECRET_KEY=

# Alerts (any you set are used)
ATLAS_DISCORD_WEBHOOK=
ATLAS_SLACK_WEBHOOK=
ATLAS_TELEGRAM_BOT_TOKEN=
ATLAS_TELEGRAM_CHAT_ID=
ATLAS_NOTIFY_SUCCESS=false

# External watchdog, e.g. a healthchecks.io check URL (period 6 h, grace 2 h)
ATLAS_HEARTBEAT_URL=

# Dashboard (127.0.0.1 only; reach it through an SSH tunnel)
ATLAS_DASHBOARD_TOKEN=
ATLAS_DASHBOARD_HOST=127.0.0.1
EOF
    )
    info "Created .env"
  else
    info "Keeping your existing .env"
  fi
  chmod 600 "${env}"

  local token
  token="$(get_env ATLAS_DASHBOARD_TOKEN)"
  if [[ ! "${token}" =~ ^[A-Za-z0-9_-]{32,}$ ]] || [[ "${token}" == generate_a_secure* ]]; then
    set_env ATLAS_DASHBOARD_TOKEN "$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    TOKEN_CREATED=1
    info "Generated a dashboard token"
  fi

  local current
  current="$(get_env ATLAS_AGE_RECIPIENT)"
  if [ -n "${AGE_RECIPIENT}" ]; then
    set_env ATLAS_AGE_RECIPIENT "${AGE_RECIPIENT}"
    info "Offsite encryption key set (${AGE_RECIPIENT:0:12}...)"
  elif [[ "${current}" =~ ^age1[0-9a-z]{20,}$ ]]; then
    info "Offsite encryption key already set (${current:0:12}...)"
  elif can_prompt; then
    create_age_key
  else
    set_env ATLAS_AGE_RECIPIENT ""
    warn "No offsite encryption key yet. Run again with --age-recipient=age1... (from age-keygen on your laptop)."
  fi
}

# Generate a keypair, show the private key once, and keep only the public key.
create_age_key() {
  local pair pub priv
  pair="$(age-keygen 2> /dev/null)"
  pub="$(printf '%s\n' "${pair}" | sed -n 's/^# public key: //p')"
  priv="$(printf '%s\n' "${pair}" | grep '^AGE-SECRET-KEY-')"
  {
    printf "\n    %sYour backup decryption key. Save it in your password manager now.%s\n" "${B}" "${N}"
    printf "    Atlas does not keep a copy. Without it, offsite backups cannot be decrypted.\n\n"
    printf "      %s\n\n" "${priv}"
  } > /dev/tty
  while [ "$(ask "Type SAVED once it is stored somewhere other than this server:" "")" != "SAVED" ]; do :; done
  unset pair priv
  set_env ATLAS_AGE_RECIPIENT "${pub}"
  info "Offsite encryption key set (${pub:0:12}...); the private key was not written to disk"
}

discover_apps() {
  [ "${DISCOVER}" = 1 ] || return 0
  local config="${INSTALL_DIR}/config/apps.yml"
  step "Looking for apps on this server"
  local proposal
  if ! proposal="$(python3 -I "${INSTALL_DIR}/scripts/lib/discover.py" --config "${config}" 2>&1)"; then
    warn "Could not scan containers: ${proposal}"
    return 0
  fi
  printf '%s\n' "${proposal}" | grep -v 'Review, then run with --write' | sed 's/^/    /'
  if ! printf '%s\n' "${proposal}" | grep -q '^  [a-z0-9]'; then
    return 0 # nothing new to add
  fi
  if can_prompt && [[ "$(ask "Protect these apps? [Y/n]" y)" =~ ^[Nn] ]]; then
    warn "Skipped. Add apps later with: atlas discover --write"
    return 0
  fi
  python3 -I "${INSTALL_DIR}/scripts/lib/discover.py" --config "${config}" --write | sed 's/^/    /'
}

app_count() {
  local config="${INSTALL_DIR}/config/apps.yml"
  [ -f "${config}" ] || { echo 0; return; }
  python3 -I - "${config}" "${INSTALL_DIR}/scripts/lib/vendor" << 'PY' 2> /dev/null || echo 0
import sys
sys.path.append(sys.argv[2])
import yaml
apps = (yaml.safe_load(open(sys.argv[1])) or {}).get("apps") or {}
print(len(apps) if isinstance(apps, dict) else 0)
PY
}

first_run() {
  [ "${FIRST_RUN}" = 1 ] || return 0
  [ "$(app_count)" -gt 0 ] || return 0
  local log
  log="$(mktemp)"
  step "Taking the first backup"
  if "${INSTALL_DIR}/scripts/backup.sh" --all > "${log}" 2>&1; then BACKUP_OK=1; else BACKUP_OK=0; fi
  grep -E '\[(SUCCESS|ERROR)\]' "${log}" | sed 's/^/    /' || true
  step "Proving it restores (restore drill)"
  if "${INSTALL_DIR}/scripts/drill.sh" --all > "${log}" 2>&1; then DRILL_OK=1; else DRILL_OK=0; fi
  grep -E 'PASSED|FAILED|finished' "${log}" | sed 's/^/    /' || true
  # "N passed, M failed": a drill only passed if something was actually tested.
  DRILL_PASSED="$(sed -n 's/.*finished: \([0-9]*\) passed.*/\1/p' "${log}" | tail -n 1)"
  if [ "${BACKUP_OK}" = 1 ] && [ "${DRILL_OK}" = 1 ] && [ "${DRILL_PASSED:-0}" -gt 0 ]; then
    DRILL_RESULT="passed"
  elif [ "${BACKUP_OK}" = 0 ]; then
    DRILL_RESULT="backup-failed"
  else
    DRILL_RESULT="failed"
  fi
  rm -f "${log}"
}

start_services() {
  [ "${START}" = 1 ] || return 0
  step "Scheduling backups and daily restore drills"
  systemctl daemon-reload
  systemctl enable --now atlas-backup.timer atlas-drill.timer > /dev/null 2>&1 \
    && info "Backups every 6 hours, restore drill daily at 03:30 UTC" \
    || warn "Could not enable the timers; see: systemctl status atlas-backup.timer"
  if systemctl enable atlas-dashboard.service > /dev/null 2>&1 && systemctl restart atlas-dashboard.service; then
    info "Dashboard running on 127.0.0.1:8888"
  else
    warn "Dashboard did not start; see: journalctl -u atlas-dashboard -n 50"
  fi
}

summary() {
  local apps host
  apps="$(app_count)"
  host="$(hostname -I 2> /dev/null | awk '{print $1}')"
  printf "\n%sAtlas is installed.%s %s app(s) configured" "${B}" "${N}" "${apps}"
  case "${DRILL_RESULT:-}" in
    passed) printf ", and the first restore drill %spassed%s (%s verified).\n" "${G}" "${N}" "$([ "${DRILL_PASSED}" = 1 ] && echo "1 backup" || echo "${DRILL_PASSED} backups")" ;;
    backup-failed) printf ", but the first backup %sfailed%s. Fix the error above, then run: atlas backup create --all\n" "${R}" "${N}" ;;
    failed) printf ", but the first restore drill %sfailed%s. Details: atlas restore drill\n" "${R}" "${N}" ;;
    *) printf ".\n" ;;
  esac
  printf "\n%sDashboard%s  from your laptop: ssh -L 8888:127.0.0.1:8888 %s@%s, then open http://localhost:8888\n" \
    "${B}" "${N}" "${SUDO_USER:-root}" "${host:-your-server}"
  if [ "${TOKEN_CREATED:-0}" = 1 ]; then
    printf "           token for actions: %s\n" "$(get_env ATLAS_DASHBOARD_TOKEN)"
  else
    printf "           token for actions: sudo grep ATLAS_DASHBOARD_TOKEN %s/.env\n" "${INSTALL_DIR}"
  fi
  printf "\n%sStill to do%s\n" "${B}" "${N}"
  local todo=0
  if [ -z "$(get_env ATLAS_AGE_RECIPIENT)" ]; then
    todo=$((todo + 1)); printf "  %d. Offsite encryption key: re-run with --age-recipient=age1...\n" "${todo}"
  fi
  if [ -z "$(get_env ATLAS_S3_BUCKET)" ]; then
    todo=$((todo + 1)); printf "  %d. Offsite storage: set ATLAS_S3_* in %s/.env. Until then backups stay on this server only.\n" "${todo}" "${INSTALL_DIR}"
  fi
  if [ -z "$(get_env ATLAS_HEARTBEAT_URL)" ]; then
    todo=$((todo + 1)); printf "  %d. Watchdog: create a free healthchecks.io check and set ATLAS_HEARTBEAT_URL, so you hear about it if this server goes quiet.\n" "${todo}"
  fi
  if [ "${apps}" = 0 ]; then
    todo=$((todo + 1)); printf "  %d. Apps: start your containers, then run: atlas discover --write\n" "${todo}"
  fi
  [ "${todo}" = 0 ] && printf "  Nothing. Check 'atlas status' any time.\n"
  printf "\n%sDocs: https://github.com/%s%s\n" "${D}" "${REPO}" "${N}"
}

cleanup() { [ -n "${WORK}" ] && rm -rf "${WORK}"; return 0; }

main() {
  trap cleanup EXIT
  parse_args "$@"
  preflight
  install_deps
  fetch_source
  install_code
  configure_env
  discover_apps
  first_run
  start_services
  summary
}

main "$@"
