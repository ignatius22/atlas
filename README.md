# Atlas

> **Zero-trust disaster recovery and infrastructure health toolkit for production Dockerized applications.**

[![Atlas CI](https://github.com/ignatius22/atlas/actions/workflows/ci.yml/badge.svg)](https://github.com/ignatius22/atlas/actions)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Atlas transforms standard single/multi-VPS Docker deployments into resilient, self-healing platforms. It provides automated, atomic PostgreSQL dumps, client-side asymmetric Age envelope encryption, tamper-evident checksums, off-site Cloudflare R2 / AWS S3 replication, and automated disaster-recovery drills in isolated ephemeral containers.

---

## ⚡ 60-Second Quickstart

### 1. Installation
```bash
git clone https://github.com/ignatius22/atlas.git /opt/atlas
cd /opt/atlas
sudo ./scripts/install.sh
```

### 2. Initialize
```bash
atlas init
```
Generates `atlas.yml`, `.env`, and your asymmetric Age X25519 cryptographic keypair.

### 3. Define Applications in `atlas.yml`
```yaml
version: "1"
settings:
  backup_dir: "/var/backups"
  default_retention_days: 14

applications:
  web-app:
    name: "Production Web Platform"
    directory: "/var/www/webapp"
    database:
      type: "postgres"
      container: "webapp_postgres"
      backup: true
      user: "postgres"
      database: "webapp_prod"
```

### 4. Backup, Audit & Verify
```bash
# Audit host and container security
atlas doctor

# Create local atomic encrypted backup
atlas backup create web-app

# Replicate encrypted backup to S3/R2
atlas backup sync web-app

# Run an isolated ephemeral disaster recovery drill
atlas restore test web-app
```

---

## 🔒 Security Architecture
- **Zero-Knowledge Asymmetric Encryption:** Backups are encrypted before leaving your server using an Age public recipient key (`age1...`). Even in the event of a total S3/R2 storage compromise, data cannot be decrypted without the offline private key.
- **Atomic File Streams:** Dumps are streamed to temporary `.tmp` buffers before atomic rename, guaranteeing zero corrupted partial archives.
- **Isolated DR Verification:** Restorations are verified by spinning up disposable Docker containers, loading the schema, verifying tables, and measuring exact Recovery Time Objectives (RTO).

---

## 📖 Complete Documentation
- [Quickstart Guide](QUICKSTART.md)
- [Installation Guide](INSTALL.md)
- [Configuration Reference](CONFIGURATION.md)
- [Security Model & Disclosure Policy](SECURITY.md)
- [Disaster Recovery Runbook](RUNBOOK.md)
- [Contributing Guidelines](CONTRIBUTING.md)
- [Architecture Deep Dive](docs/architecture.md)

---

## 📄 License
Atlas is open-source software licensed under the [Apache 2.0 License](LICENSE).
