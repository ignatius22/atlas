#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Linux / macOS Installation Script
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR="${ATLAS_INSTALL_DIR:-/opt/atlas}"
BIN_LINK="${ATLAS_BIN_LINK:-/usr/local/bin/atlas}"
SYSTEMD_DIR="${ATLAS_SYSTEMD_DIR:-/etc/systemd/system}"

echo "Installing Atlas V1 to ${INSTALL_DIR}..."

# Validate that source unit files exist before attempting installation
if [ ! -f "${SOURCE_ROOT}/systemd/atlas-backup.service" ] || [ ! -f "${SOURCE_ROOT}/systemd/atlas-backup.timer" ]; then
  echo "Error: Required systemd unit files (systemd/atlas-backup.service, systemd/atlas-backup.timer) not found in ${SOURCE_ROOT}." >&2
  exit 1
fi

if [ ! -f "${SOURCE_ROOT}/infra/atlas-dashboard.service" ]; then
  echo "Error: Required dashboard systemd unit file (infra/atlas-dashboard.service) not found in ${SOURCE_ROOT}." >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
# Copy files only if source and target directories are distinct
REAL_SOURCE="$(cd "${SOURCE_ROOT}" && pwd -P)"
REAL_TARGET="$(cd "${INSTALL_DIR}" && pwd -P)"
if [ "${REAL_SOURCE}" != "${REAL_TARGET}" ]; then
  cp -a "${SOURCE_ROOT}/." "${INSTALL_DIR}/"
fi

mkdir -p "$(dirname "${BIN_LINK}")"
ln -sf "${INSTALL_DIR}/bin/atlas" "${BIN_LINK}"
chmod +x "${BIN_LINK}"

# Install systemd unit files if systemd directory is accessible or on systemd hosts
if [ -d "${SYSTEMD_DIR}" ] || [ -n "${ATLAS_SYSTEMD_DIR:-}" ] || command -v systemctl >/dev/null 2>&1; then
  echo "Installing systemd unit files into ${SYSTEMD_DIR}..."
  mkdir -p "${SYSTEMD_DIR}"

  # Adapt paths in the service files if using a custom installation directory
  if [ "${INSTALL_DIR}" != "/opt/atlas" ]; then
    sed "s|/opt/atlas|${INSTALL_DIR}|g" "${INSTALL_DIR}/systemd/atlas-backup.service" > "${SYSTEMD_DIR}/atlas-backup.service"
    sed "s|/opt/atlas|${INSTALL_DIR}|g" "${INSTALL_DIR}/infra/atlas-dashboard.service" > "${SYSTEMD_DIR}/atlas-dashboard.service"
  else
    cp "${INSTALL_DIR}/systemd/atlas-backup.service" "${SYSTEMD_DIR}/atlas-backup.service"
    cp "${INSTALL_DIR}/infra/atlas-dashboard.service" "${SYSTEMD_DIR}/atlas-dashboard.service"
  fi
  cp "${INSTALL_DIR}/systemd/atlas-backup.timer" "${SYSTEMD_DIR}/atlas-backup.timer"

  chmod 0644 "${SYSTEMD_DIR}/atlas-backup.service" "${SYSTEMD_DIR}/atlas-backup.timer" "${SYSTEMD_DIR}/atlas-dashboard.service"

  # Validate that the unit files exist in destination before claiming success
  if [ ! -f "${SYSTEMD_DIR}/atlas-backup.service" ] || [ ! -f "${SYSTEMD_DIR}/atlas-backup.timer" ] || [ ! -f "${SYSTEMD_DIR}/atlas-dashboard.service" ]; then
    echo "Error: Failed to install systemd unit files into ${SYSTEMD_DIR}." >&2
    exit 1
  fi

  # Reload systemd daemon if systemctl command is present
  if command -v systemctl >/dev/null 2>&1; then
    echo "Reloading systemd daemon (systemctl daemon-reload)..."
    systemctl daemon-reload || true
  fi

  echo "Systemd unit files installed successfully."
  echo ""
  echo "To enable and start the automated 6-hour persistent backup scheduler, run:"
  echo "  sudo systemctl enable --now atlas-backup.timer"
  echo ""
  echo "To enable the internal web dashboard (binds to 127.0.0.1:8888), configure"
  echo "ATLAS_DASHBOARD_TOKEN in ${INSTALL_DIR}/.env and run:"
  echo "  sudo systemctl enable --now atlas-dashboard.service"
  echo ""
fi

# Validate that unit files exist in INSTALL_DIR
if [ ! -f "${INSTALL_DIR}/systemd/atlas-backup.service" ] || [ ! -f "${INSTALL_DIR}/systemd/atlas-backup.timer" ] || [ ! -f "${INSTALL_DIR}/infra/atlas-dashboard.service" ]; then
  echo "Error: Installation verification failed: unit files missing in ${INSTALL_DIR}." >&2
  exit 1
fi

echo "[OK] Atlas installed successfully. Run 'atlas init' to get started."
