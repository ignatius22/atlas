# Disaster Recovery Runbook

Step-by-step procedures for complete bare-metal reconstruction of Docker stacks.

## Scenario: Complete VPS Loss

1. **Boot Clean Instance:** Provision a fresh Ubuntu 24.04 LTS instance.
2. **Install Atlas:**
   ```bash
   sudo apt-get update && sudo apt-get install -y docker.io docker-compose age rclone
   git clone https://github.com/ignatius22/atlas.git /opt/atlas
   cd /opt/atlas
   sudo ./scripts/install.sh
   ```
3. **Configure Object Storage:** Populate `.env` with your S3/R2 credentials.
4. **Download & Decrypt Database:**
   ```bash
   atlas restore run <app-name> --file=<remote-archive>.sql.gz.age --key-file=/path/to/offline-key.txt
   ```
