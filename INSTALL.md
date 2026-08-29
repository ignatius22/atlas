# Installation Guide

## Automated Installation
```bash
git clone https://github.com/ignatius22/atlas.git /opt/atlas
cd /opt/atlas
sudo ./scripts/install.sh
```

## Manual Installation
1. Install system prerequisites:
   ```bash
   sudo apt-get update && sudo apt-get install -y age rclone python3-yaml docker.io
   ```
2. Symlink binary:
   ```bash
   sudo ln -sf /opt/atlas/bin/atlas /usr/local/bin/atlas
   ```

## Uninstallation
```bash
sudo /opt/atlas/scripts/uninstall.sh
```
