#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Clean Uninstallation Script
# ==============================================================================
set -Eeuo pipefail

INSTALL_DIR="${ATLAS_INSTALL_DIR:-/opt/atlas}"
BIN_LINK="${ATLAS_BIN_LINK:-/usr/local/bin/atlas}"

echo "Uninstalling Atlas V1..."

rm -f "${BIN_LINK}"
echo "Removed binary symlink at ${BIN_LINK}"

read -p "Do you also want to remove ${INSTALL_DIR}? [y/N]: " -r confirm
if [[ "${confirm}" =~ ^[Yy]$ ]]; then
  rm -rf "${INSTALL_DIR}"
  echo "Removed ${INSTALL_DIR}"
fi

echo "[OK] Atlas uninstallation complete."
