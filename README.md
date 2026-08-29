# Atlas

> **Disaster recovery verification, zero-trust backup automation, and infrastructure diagnostics for Dockerized applications.**

[![Atlas CI](https://github.com/ignatius22/atlas/actions/workflows/ci.yml/badge.svg)](https://github.com/ignatius22/atlas/actions)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Atlas transforms standard single/multi-VPS Docker deployments into resilient, self-healing platforms. It provides automated, atomic PostgreSQL dumps, client-side asymmetric Age envelope encryption, tamper-evident SHA-256 checksums, off-site S3 / Cloudflare R2 replication, and automated disaster-recovery drills in isolated ephemeral containers.

---

## 🎯 The Core Promise

> **A backup is not trustworthy merely because it exists. Atlas verifies that it can actually be restored.**

Most backup systems stop at dumping and uploading an archive. You only discover your backup is corrupt, truncated, or unreadable when a real disaster occurs. Atlas closes this loop by automatically provisioning isolated ephemeral containers, loading your schema, verifying row counts, and measuring exact Recovery Time Objectives (RTO).

---

## ⚡ 60-Second Quickstart

### 1. Installation
```bash
git clone https://github.com/ignatius22/atlas.git /opt/atlas
cd /opt/atlas
sudo ./scripts/install.sh
```

### 2. Initialize Stack
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

### 4. Hero Demonstration: Backup, Replicate & Verify Recovery
```bash
# 1. Audit host and container security
atlas doctor

# 2. Create local atomic encrypted backup
atlas backup create web-app

# 3. Replicate encrypted backup to S3/R2
atlas backup sync web-app

# 4. Run an isolated ephemeral disaster recovery drill
atlas restore test web-app
```

---

## 🔒 Security Architecture
- **Client-Side Asymmetric Encryption:** Backups are encrypted before leaving your server using an Age public recipient key (`age1...`). Even if your cloud storage bucket is compromised, data cannot be decrypted without the offline private key.
- **Atomic File Streams:** Dumps are streamed to temporary `.tmp` buffers before atomic rename, guaranteeing zero corrupted partial archives.
- **Isolated DR Verification:** Restorations are verified by spinning up disposable Docker containers, loading the schema, verifying tables, and measuring exact Recovery Time Objectives (RTO).
- **Strict Input Validation:** All container and application identifiers are validated against strict regex (`^[a-zA-Z0-9_-]+$`) before execution.

---

## 📖 Complete Documentation
- [Quickstart Guide](QUICKSTART.md)
- [Installation Guide](INSTALL.md)
- [Configuration Reference](CONFIGURATION.md)
- [Disaster Recovery Runbook](RUNBOOK.md)
- [Security Model & Disclosure Policy](SECURITY.md)
- [Contributing Guidelines](CONTRIBUTING.md)
- [Architecture Deep Dive](docs/architecture.md)
- [Commercial Roadmap & Strategy](docs/COMMERCIAL-ROADMAP.md)

---

## 📄 License
Atlas is open-source software licensed under the [Apache 2.0 License](LICENSE).
