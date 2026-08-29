#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Linux / macOS Installation Script
# ==============================================================================
set -Eeuo pipefail

INSTALL_DIR="${ATLAS_INSTALL_DIR:-/opt/atlas}"
BIN_LINK="${ATLAS_BIN_LINK:-/usr/local/bin/atlas}"

echo "Installing Atlas V1 to ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}"
# Copy all files including dotfiles
cp -a . "${INSTALL_DIR}/"

mkdir -p "$(dirname "${BIN_LINK}")"
ln -sf "${INSTALL_DIR}/bin/atlas" "${BIN_LINK}"
chmod +x "${BIN_LINK}"

echo "[OK] Atlas installed successfully. Run 'atlas init' to get started."
