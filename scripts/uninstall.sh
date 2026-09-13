#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Clean Uninstallation Script
# ==============================================================================
set -Eeuo pipefail

INSTALL_DIR="${ATLAS_INSTALL_DIR:-/opt/atlas}"
BIN_LINK="${ATLAS_BIN_LINK:-/usr/local/bin/atlas}"
SYSTEMD_DIR="${ATLAS_SYSTEMD_DIR:-/etc/systemd/system}"

echo "Uninstalling Atlas V1..."

# Disable and remove systemd timers and services if present
if [ -f "${SYSTEMD_DIR}/atlas-backup.timer" ] || [ -f "${SYSTEMD_DIR}/atlas-backup.service" ] || [ -f "${SYSTEMD_DIR}/atlas-dashboard.service" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    echo "Disabling systemd units..."
    systemctl disable --now atlas-backup.timer 2>/dev/null || true
    systemctl disable --now atlas-dashboard.service 2>/dev/null || true
  fi
  rm -f "${SYSTEMD_DIR}/atlas-backup.timer" "${SYSTEMD_DIR}/atlas-backup.service" "${SYSTEMD_DIR}/atlas-dashboard.service"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi
  echo "Removed systemd units from ${SYSTEMD_DIR}"
fi

rm -f "${BIN_LINK}"
echo "Removed binary symlink at ${BIN_LINK}"

if [ -t 0 ]; then
  read -p "Do you also want to remove ${INSTALL_DIR}? [y/N]: " -r confirm
  if [[ "${confirm}" =~ ^[Yy]$ ]]; then
    rm -rf "${INSTALL_DIR}"
    echo "Removed ${INSTALL_DIR}"
  fi
else
  # Non-interactive mode (e.g. scripts/tests)
  echo "Non-interactive session detected; leaving ${INSTALL_DIR} intact unless manually removed."
fi

echo "[OK] Atlas uninstallation complete."
