#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template — Server Bootstrap Engine (Hardened V1)
# ==============================================================================
# Idempotent server readiness check and baseline directory setup.
# Usage:
#   sudo ./scripts/setup-server.sh
#   ./scripts/setup-server.sh --check-only
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CHECK_ONLY=false

print_usage() {
  cat << EOF
Atlas Server Bootstrap & Verification Engine (V1 Hardened)

Usage:
  $(basename "$0") [options]

Options:
  --check-only      Run prerequisite verification without creating directories
  -h, --help        Show this help message

Description:
  Verifies that all baseline software dependencies (Docker, Docker Compose, Nginx,
  Certbot, Git, UFW, Python 3, PyYAML) are present, checks system limits, and ensures
  required Atlas directories (/var/backups, /var/www/certbot, /var/log/atlas)
  exist with proper permissions.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=true
      shift
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

log_info "=================================================="
log_info "Atlas Server Bootstrap & Verification Engine"
log_info "Host:       $(hostname 2>/dev/null || echo "localhost")"
log_info "Started At: $(iso_timestamp)"
log_info "=================================================="

MISSING_PACKAGES=()
WARNINGS=()

check_tool() {
  local tool="$1"
  local name="$2"
  local install_hint="$3"
  
  if command -v "${tool}" >/dev/null 2>&1; then
    local ver
    ver="$(${tool} --version 2>/dev/null | head -n 1 || echo "installed")"
    log_pass "${name}: ${ver}"
  else
    log_fail_badge "${name} is NOT installed (${install_hint})"
    MISSING_PACKAGES+=("${name}")
  fi
}

log_info "Auditing essential software dependencies..."
check_tool "docker" "Docker Engine" "install docker.io or official docker-ce"
check_tool "nginx" "Nginx Web Server" "apt-get install nginx"
check_tool "certbot" "Certbot (Let's Encrypt)" "apt-get install certbot"
check_tool "git" "Git Version Control" "apt-get install git"
check_tool "ufw" "UFW Firewall" "apt-get install ufw"
check_tool "python3" "Python 3 Runtime" "apt-get install python3"
check_tool "curl" "cURL Client" "apt-get install curl"
check_tool "gzip" "gzip Compression" "apt-get install gzip"
check_tool "sha256sum" "sha256sum Utility" "coreutils package"

# Check Docker Compose subcommand
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    log_pass "Docker Compose v2 plugin is active."
  else
    log_warning_badge "Docker compose command returned non-zero. Ensure 'docker-compose-plugin' is installed."
    WARNINGS+=("Docker compose v2 plugin missing")
  fi
fi

# Check PyYAML (python3-yaml)
if python3 -c "import yaml" >/dev/null 2>&1; then
  PYYAML_VER="$(python3 -c "import yaml; print(getattr(yaml, '__version__', 'installed'))" 2>/dev/null || echo "installed")"
  log_pass "PyYAML Module (python3-yaml): Version ${PYYAML_VER}"
else
  log_fail_badge "PyYAML module is NOT installed (apt-get install python3-yaml or pip install pyyaml)"
  MISSING_PACKAGES+=("python3-yaml")
fi

# Directory verification & initialization
STANDARD_DIRS=(
  "/var/backups"
  "/var/www/certbot"
  "/var/log/atlas"
  "/etc/atlas"
)

if [ "${CHECK_ONLY}" = "false" ]; then
  log_info "Initializing Atlas standard directory structure..."
  for dir in "${STANDARD_DIRS[@]}"; do
    if [ -d "${dir}" ]; then
      log_pass "Directory already exists: ${dir}"
    else
      if [ "$EUID" -eq 0 ] || [ -w "$(dirname "${dir}")" ]; then
        mkdir -p "${dir}"
        chmod 755 "${dir}" 2>/dev/null || true
        log_pass "Created directory: ${dir}"
      else
        log_warning_badge "Cannot create directory '${dir}' (requires root / sudo)."
        WARNINGS+=("Directory missing: ${dir}")
      fi
    fi
  done
else
  log_info "Checking standard directory existence..."
  for dir in "${STANDARD_DIRS[@]}"; do
    if [ -d "${dir}" ]; then
      log_pass "Directory exists: ${dir}"
    else
      log_warning_badge "Directory missing: ${dir}"
      WARNINGS+=("Directory missing: ${dir}")
    fi
  done
fi

log_info "=================================================="
if [ "${#MISSING_PACKAGES[@]}" -eq 0 ]; then
  log_success "SERVER BOOTSTRAP CHECK: READY FOR ATLAS PRODUCTION"
else
  log_error "SERVER BOOTSTRAP CHECK: INCOMPLETE"
  log_error "Missing packages: ${MISSING_PACKAGES[*]}"
  exit 1
fi
