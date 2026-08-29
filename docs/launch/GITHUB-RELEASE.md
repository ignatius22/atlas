# Atlas v1.0.0 — Production-Grade Disaster Recovery for Docker

Atlas v1.0.0 is officially released! 🎉

Atlas transforms standard Docker VPS deployments into resilient platforms with zero-trust encrypted backups, automated off-site replication, and ephemeral disaster-recovery drills.

### Key Capabilities:
- **Asymmetric Envelope Encryption:** Client-side Age (X25519) encryption before S3/Cloudflare R2 upload.
- **Ephemeral DR Drills:** Spawns isolated Docker containers to restore and verify table counts, measuring exact RTO.
- **Infrastructure Doctor:** Scans for exposed ports, container restart loops, disk pressure, and crypto configuration.
- **Clean POSIX CLI:** Unified `atlas` binary with JSON output support for CI automation.

### Quick Install:
```bash
git clone https://github.com/ignatius22/atlas.git /opt/atlas
cd /opt/atlas
sudo ./scripts/install.sh
atlas init
```
