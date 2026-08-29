# Quickstart Guide

Get Atlas running on your server in under 5 minutes.

## 1. System Requirements
- Linux / macOS (Ubuntu 22.04 / 24.04 recommended)
- Docker Engine 24+
- Python 3.9+ with PyYAML
- `age` and `rclone` (or `aws-cli`)

## 2. Setup
```bash
git clone https://github.com/ignatius22/atlas.git /opt/atlas
cd /opt/atlas
sudo ./scripts/install.sh
atlas init
```

## 3. Verify
```bash
atlas config validate
atlas doctor
```
