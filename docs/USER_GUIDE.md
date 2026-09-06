# Atlas v1.1.0 Complete User Guide & Operations Manual

---

## Table of Contents
1. [Welcome to Atlas](#1-welcome-to-atlas)
2. [Atlas in 5 Minutes](#2-atlas-in-5-minutes)
3. [Key Concepts & Glossary](#3-key-concepts--glossary)
4. [Requirements & Prerequisites](#4-requirements--prerequisites)
5. [Installation Guide](#5-installation-guide)
6. [Configuration Reference](#6-configuration-reference)
7. [Understanding the Directory Structure](#7-understanding-the-directory-structure)
8. [Your First Backup Walkthrough](#8-your-first-backup-walkthrough)
9. [Understanding Backup Artifacts & Ledger](#9-understanding-backup-artifacts--ledger)
10. [Off-Site Cloud Replication](#10-off-site-cloud-replication)
11. [The Durability Invariant](#11-the-durability-invariant)
12. [Retention & Local Storage Management](#12-retention--local-storage-management)
13. [Database Restoration (Test vs. Production)](#13-database-restoration-test-vs-production)
14. [Disaster Recovery & Ephemeral Restore Drills](#14-disaster-recovery--ephemeral-restore-drills)
15. [Automated Scheduling (Systemd vs. Cron)](#15-automated-scheduling-systemd-vs-cron)
16. [Monitoring & Diagnostics with Atlas Doctor](#16-monitoring--diagnostics-with-atlas-doctor)
17. [Hardened Web Dashboard & API](#17-hardened-web-dashboard--api)
18. [Security Model & Threat Mitigations](#18-security-model--threat-mitigations)
19. [Failure Modes & System Behavior](#19-failure-modes--system-behavior)
20. [Operator Troubleshooting Guide](#20-operator-troubleshooting-guide)
21. [Emergency Disaster Recovery Runbook](#21-emergency-disaster-recovery-runbook)
22. [Operational Verification Checklists](#22-operational-verification-checklists)
23. [RPO / RTO Contract & Boundaries](#23-rpo--rto-contract--boundaries)
24. [Production Deployment Checklist](#24-production-deployment-checklist)
25. [Security Hardening Checklist](#25-security-hardening-checklist)
26. [Frequently Asked Questions (FAQ)](#26-frequently-asked-questions-faq)
27. [Complete Command Reference](#27-complete-command-reference)
28. [Further Reading & Architecture Docs](#28-further-reading--architecture-docs)

---

## 1. Welcome to Atlas

### What is Atlas?
Atlas is an application-agnostic infrastructure, backup, and disaster recovery framework designed specifically for Linux Virtual Private Servers (VPS). Built using auditable, standard Unix tools—Bash, Python 3 standard library, Docker Compose, and Nginx—Atlas standardizes application deployment, automated snapshotting, asymmetric zero-knowledge offsite replication, and verification drills without the overhead of heavy cluster orchestrators like Kubernetes.

### What Problem Does Atlas Solve?
Traditional single-host backup scripts suffer from silent, catastrophic failure modes:
* **Premature Retention Deletion**: When cloud replication fails due to an expired API key or network flap, naive cron retention scripts continue pruning older local backups. Over time, all local copies disappear while remote storage holds zero valid copies.
* **Untested Restorability**: Backups that finish with exit code 0 often fail during an emergency because of corrupted SQL syntax, missing table locks, or schema version mismatches.
* **Secret Key Leakage**: Many backup scripts store the decryption private key on the production VPS, ensuring that any host compromise exposes all historical offsite backups.
* **Silent Scheduler Failure**: Host reboots and transient maintenance windows cause standard `cron` to permanently skip scheduled runs, silently degrading Recovery Point Objectives (RPO) from 6 hours to days or weeks.

### The Central Philosophy
> **A backup is not trustworthy merely because it exists. Atlas verifies that it can actually be restored.**
>
> **The Durability Invariant:** No local backup is deleted by retention unless Atlas has established that a corresponding, recoverable off-site copy exists in remote cloud storage.

---

## 2. Atlas in 5 Minutes

Here is the entire Atlas lifecycle from database to disaster recovery:

```text
Database Container (PostgreSQL / MySQL / MariaDB)
   │
   ▼
[1] Database Dump (pg_dump / mariadb-dump streamed directly via docker exec)
   │
   ▼
[2] Compression (Gzip maximum compression -9 -> .sql.gz)
   │
   ▼
[3] Integrity Checksum (SHA-256 hash -> .sql.gz.sha256)
   │
   ▼
[4] Metadata Manifest (Schema version, timestamp, byte size -> .sql.gz.meta.json)
   │
   ▼
LOCAL BACKUP STORAGE (/var/backups/<app>/)
   │
   ├──> [Retention Engine] Strictly preserves all archives lacking .synced authorization
   │
   ▼
[5] Asymmetric Encryption (Age X25519 public recipient key -> .sql.gz.age)
   │
   ▼
[6] Cloud Replication (3-attempt bounded retry with 5s/10s/20s backoff -> Cloudflare R2 / AWS S3)
   │
   ▼
[7] Remote Verification Gate (Query cloud storage object listing via rclone/aws)
   │
   ▼
[8] .synced Durability Authorization (Atomic write of .synced ledger marker)
   │
   ▼
[9] DR Restore Verification (Isolated Docker sandbox container restore + schema/row validation)
```

---

## 3. Key Concepts & Glossary

| Term | Plain-English Definition |
| :--- | :--- |
| **Backup** | A point-in-time snapshot of application database state compressed into a `.sql.gz` archive. |
| **Disaster Recovery (DR)** | The complete set of automated procedures to restore services after catastrophic host or data loss. |
| **RPO (Recovery Point Objective)** | **How much data you can afford to lose**. Atlas targets a **6-Hour Scheduled Snapshot RPO** under normal operation. |
| **RTO (Recovery Time Objective)** | **How quickly you can restore service**. Atlas restores single databases in under 3 minutes and full hosts in under 15 minutes. |
| **Durability Invariant** | The core safety guarantee that local backups are **never deleted** unless an offsite verified copy exists. |
| **Authorization Marker (`.synced`)** | A physical ledger file written only after remote cloud storage confirms receipt of an archive. |
| **Zero-Knowledge Encryption** | Backups are encrypted with a public key (`age1...`); the private decryption key is **never stored on the VPS**. |
| **Restore Drill** | An automated test that restores a backup into an ephemeral, temporary Docker container to prove restorability. |
| **Advisory Lock (`flock -n`)** | Linux kernel file locks that prevent concurrent script executions and auto-release instantly on process termination. |
| **Persistent Timer** | A `systemd.timer` configuration (`Persistent=true`) that automatically catches up missed runs immediately upon host boot. |
| **Bounded Retry** | A finite 3-attempt backoff mechanism (5s, 10s, 20s) preventing hung processes during network flaps. |

---

## 4. Requirements & Prerequisites

### Required (Production & Testing)
* **Linux Operating System**: Ubuntu 22.04 LTS or 24.04 LTS (Debian 12+ and Rocky Linux 9+ also supported).
* **Docker Engine**: Version 24.0+ and **Docker Compose v2** (`docker compose`).
* **Python**: Python 3.9+ with `pyyaml` installed.
* **Gzip & Core Utilities**: `gzip`, `tar`, `sha256sum`, `flock`, `curl`.
* **Asymmetric Encryption**: `age` (v1.0.0+).
* **Cloud Storage CLI**: `rclone` (v1.60.0+) or `aws-cli` v2.

### Optional / Provider-Specific
* **Cloud Object Storage**: Cloudflare R2, AWS S3, Wasabi, or Backblaze B2 bucket.
* **Systemd**: Linux host with systemd (used for `atlas-backup.timer` 6-hour scheduler).

---

## 5. Installation Guide

### Option A: Recommended Production Installation (Linux VPS)

Run these commands as `root` or a `sudo` user on your production server:

```bash
# 1. Clone the repository to /opt/atlas
sudo git clone https://github.com/ignatius22/atlas.git /opt/atlas
cd /opt/atlas

# 2. Run the automated server bootstrap script
sudo ./scripts/setup-server.sh

# 3. Create your production environment configuration
sudo cp config/atlas.example.env /etc/atlas/atlas.env
sudo chmod 600 /etc/atlas/atlas.env

# 4. Verify system health and permissions
./bin/doctor
```

### Option B: Local Development / Testing Installation (macOS / Linux)

For running unit and adversarial test suites on a local machine:

```bash
# 1. Clone repository
git clone https://github.com/ignatius22/atlas.git infra-prod
cd infra-prod

# 2. Install dependencies via brew (macOS) or apt (Ubuntu)
# macOS: brew install age rclone python3
# Ubuntu: sudo apt install age rclone python3 python3-pip && pip install pyyaml

# 3. Run automated verification suite
./tests/run-all.sh
```

---

## 6. Configuration Reference

Atlas reads configuration from `/etc/atlas/atlas.env`, `/opt/atlas/config/atlas.env`, or `.env`.

### Environment Variables (`/etc/atlas/atlas.env`)

| Variable | Required? | Purpose | Example Value | Security Notes |
| :--- | :---: | :--- | :--- | :--- |
| `ATLAS_AGE_RECIPIENT` | **Yes** (for sync) | Public X25519 age recipient key | `age1ql3z7hjy54pw3...` (62 chars) | **Public key only**. Never store the private key here. |
| `ATLAS_S3_PROVIDER` | No | Object storage provider | `Cloudflare` (or `AWS`) | Informational provider type. |
| `ATLAS_S3_ENDPOINT` | **Yes** (for R2/S3) | S3 API endpoint URL | `https://<account_id>.r2.cloudflarestorage.com` | Standard HTTPS endpoint. |
| `ATLAS_S3_BUCKET` | **Yes** | Target cloud storage bucket | `atlas-production-backups` | Bucket must exist in cloud provider. |
| `ATLAS_S3_ACCESS_KEY` | **Yes** | S3 API Access Key ID | `a8f93bc091...` | **Secret**. Managed by cloud IAM. |
| `ATLAS_S3_SECRET_KEY` | **Yes** | S3 API Secret Access Key | `7c891a2e54...` | **High Secret**. Do not commit to Git. |
| `ATLAS_OFFSITE_PROVIDER` | No | Tool to use for offsite upload | `auto`, `rclone`, or `aws` | Defaults to `auto` (detects `rclone` -> `aws`). |
| `ATLAS_DASHBOARD_TOKEN` | **Yes** (for API) | Auth bearer token for Web API | `atlas_sec_89f3a1...` | **Secret**. Checked via `X-Atlas-Token` header. |
| `ATLAS_DASHBOARD_PORT` | No | Port for dashboard web server | `8888` | Defaults to `8888`. |
| `ATLAS_DASHBOARD_HOST` | No | Host bind interface | `127.0.0.1` | **Security default: 127.0.0.1 (localhost only)**. |

### Application Registry (`/opt/atlas/config/apps.yml`)

Declare every application in `/opt/atlas/config/apps.yml`:

```yaml
apps:
  catalogflow:
    directory: /var/www/catalogflow
    domain: catalogflow.example.com
    port: 3000
    health_endpoint: /api/health
    database:
      type: postgres
      container: catalogflow_postgres
      user: catalog_user
      name: catalog_production
      backup: true
      retention_days: 7
```

---

## 7. Understanding the Directory Structure

```text
/opt/atlas/
├── bin/
│   ├── atlas                  # Central unified CLI tool
│   └── doctor                 # 6-section production diagnostic audit engine
│
├── config/
│   ├── apps.example.yml       # Application registry template
│   ├── apps.yml               # Active production application registry
│   └── atlas.example.env      # Environment variable template
│
├── dashboard/
│   ├── server.py              # Hardened zero-dependency Python 3 HTTP API
│   └── index.html             # Real-time infrastructure status interface
│
├── scripts/
│   ├── lib/
│   │   ├── common.sh          # Logging, env discovery & validation helpers
│   │   └── yaml_parser.py     # Safe PyYAML query engine
│   ├── backup.sh              # Local database dump, gzip, sha256 & retention engine
│   ├── sync-offsite.sh        # Age encryption, bounded retry & remote verification
│   ├── restore.sh             # Isolated test restore & production recovery engine
│   ├── restore-offsite.sh     # Cloud download & decryption disaster recovery tool
│   ├── deploy.sh              # Docker Compose deployment & health verification
│   ├── rollback.sh            # Git/Compose container rollback engine
│   ├── health-check.sh        # Application HTTP/HTTPS & container probe
│   ├── setup-server.sh        # Idempotent server initialization
│   └── setup-ssl.sh           # Let's Encrypt Certbot reverse-proxy configuration
│
├── systemd/
│   ├── atlas-backup.service   # Native oneshot backup & sync service unit
│   └── atlas-backup.timer     # 6-Hour UTC persistent catch-up timer unit
│
├── tests/
│   ├── run-all.sh             # Master automated test runner
│   ├── test-backup.sh         # Local backup test suite
│   ├── test-offsite.sh        # Durability ledger & backlog sync tests
│   ├── test-doctor.sh         # Diagnostic CLI tests
│   └── test-adversarial.sh    # Security, auth, CORS & injection test suite
│
└── docs/
    ├── USER_GUIDE.md          # Complete User Manual (this document)
    ├── ARCHITECTURE.md        # Deep architectural design & durability invariants
    ├── RUNBOOK.md             # Emergency operations & incident playbooks
    └── DISASTER_RECOVERY.md   # Cold-start server reconstruction guide
```

---

## 8. Your First Backup Walkthrough

Let's create your first verified database backup step-by-step.

### Step 1: Verify Host Readiness
```bash
/opt/atlas/bin/doctor
```
*Expected Output:* You should see `RESULT: PASS` across all hardware, Docker, security, and registry sections.

### Step 2: Trigger a Backup
```bash
/opt/atlas/scripts/backup.sh --app=catalogflow
```
*Expected Output:*
```text
[INFO] Atlas Backup Engine starting for app: catalogflow
[INFO] Dumping PostgreSQL database 'catalog_production' from container 'catalogflow_postgres'...
[INFO] Compressing SQL stream with gzip -9...
[INFO] Generated archive: /var/backups/catalogflow/catalogflow-20260906T080000Z.sql.gz (8.2 KB)
[INFO] Computing SHA-256 integrity checksum...
[INFO] Writing metadata manifest...
[INFO] Checking local retention policy (preserving all un-synced archives)...
[PASS] Backup complete for catalogflow
```

### Step 3: Inspect the Generated Files
```bash
ls -la /var/backups/catalogflow/
```
You will see three files created:
1. `catalogflow-20260906T080000Z.sql.gz` (Compressed dump)
2. `catalogflow-20260906T080000Z.sql.gz.sha256` (SHA-256 hash)
3. `catalogflow-20260906T080000Z.sql.gz.meta.json` (Metadata manifest)

---

## 9. Understanding Backup Artifacts & Ledger

Atlas uses strict file naming conventions in `/var/backups/<app>/`:

| Artifact | Purpose | Created By | Consumed By | Safe to Delete? |
| :--- | :--- | :--- | :--- | :---: |
| `<app>-<TS>.sql.gz` | Complete compressed database snapshot | `backup.sh` | `restore.sh`, `sync-offsite.sh` | **No** (Managed by retention) |
| `<app>-<TS>.sql.gz.sha256` | SHA-256 checksum for corruption detection | `backup.sh` | `restore.sh`, `doctor` | **No** (Integrity proof) |
| `<app>-<TS>.sql.gz.meta.json` | Manifest containing schema, rows, size | `backup.sh` | `doctor`, dashboard API | **No** (Metadata ledger) |
| `<app>-<TS>.sql.gz.age` | Asymmetric X25519 encrypted archive | `sync-offsite.sh` | Cloud upload / R2 | **Yes** (Ephemeral on host) |
| `<app>-<TS>.sql.gz.synced` | **Durability Authorization Record** | `sync-offsite.sh` | `backup.sh` retention engine | **CRITICAL: NEVER DELETE** |

### Why the `.synced` Marker is Critical
The `.synced` file is not just a status flag—it is a **cryptographic authorization token**. The local retention engine in `backup.sh` will **refuse to delete** any local backup file unless its exact corresponding `.synced` file exists.

---

## 10. Off-Site Cloud Replication

### The Replication Flow
```bash
/opt/atlas/scripts/sync-offsite.sh --app=catalogflow
```

1. **Discovery**: `sync-offsite.sh` scans `/var/backups/catalogflow/` for any `.sql.gz` file lacking a `.synced` marker.
2. **Encryption**: Encrypts the archive using `age -r ${ATLAS_AGE_RECIPIENT}` into `<app>-<TS>.sql.gz.age`.
3. **Bounded Retry Upload**: Attempts upload to Cloudflare R2 / S3 up to **3 times** with exponential backoff (5s, 10s, 20s).
4. **Remote Verification Gate**: Queries the cloud storage bucket via `rclone lsf` or `aws s3 ls` to verify the object was written.
5. **Durability Authorization**: Writes `<app>-<TS>.sql.gz.synced`.

### Historical Backlog Draining
If the internet connection fails for several days, Atlas creates local backups normally. When connectivity recovers, `sync-offsite.sh` automatically discovers all un-replicated archives and syncs them in chronological order (oldest to newest).

---

## 11. The Durability Invariant

> **The Durability Invariant:** No local backup is deleted unless Atlas has established that the required remote recoverable copy exists.

### Failure Scenario Walkthrough

```text
[T = 0h]  Backup A created locally -> Sync succeeds -> Backup A.synced created
[T = 6h]  Backup B created locally -> Cloud outage occurs -> Sync fails -> NO Backup B.synced
[T = 12h] Backup C created locally -> Cloud outage continues -> NO Backup C.synced
[T = 18h] Retention runs (retention_days: 1)
          ├─ Backup A is older than 24h AND has .synced -> DELETED SAFELY
          ├─ Backup B is older than 24h BUT lacks .synced -> STRICTLY PRESERVED
          └─ Backup C is preserved
[T = 24h] Cloud connectivity restored
          └─ sync-offsite.sh discovers backlog (Backup B & C)
          └─ Uploads B & C -> Remote verification passes -> Writes .synced
[T = 30h] Next retention run -> Backup B now has .synced -> DELETED SAFELY
```

---

## 12. Retention & Local Storage Management

* **Configuration**: Configured per application in `config/apps.yml` (`retention_days: 7`).
* **Evaluation**: Evaluated at the conclusion of every `backup.sh` run.
* **Safety Rules**:
  1. Only `.sql.gz` files that are strictly older than `retention_days * 86400` seconds are candidates for pruning.
  2. Any candidate file missing `${file}.synced` is skipped and preserved locally.
  3. When an archive is pruned, its corresponding `.sha256`, `.meta.json`, and `.synced` files are cleaned up simultaneously.

---

## 13. Database Restoration (Test vs. Production)

Atlas provides two distinct restoration targets:

### Target 1: Ephemeral Sandbox Test (`--target=test`)
```bash
/opt/atlas/scripts/restore.sh --app=catalogflow --target=test
```
* **Production Impact**: **Zero**.
* **Behavior**: Launches a temporary container (`test_catalogflow_db`), streams the backup with `ON_ERROR_STOP=1`, verifies schema/row counts, and destroys the container.

### Target 2: Live Production Recovery (`--target=production`)
```bash
/opt/atlas/scripts/restore.sh --app=catalogflow --target=production
```
* **Production Impact**: **Full database overwrite**.
* **Safeguards**:
  1. Prompts for typed interactive confirmation (`YES, RESTORE PRODUCTION`).
  2. Stops the application container to block concurrent incoming writes.
  3. Drops and recreates the production database.
  4. Restores schema and data in a single transaction.
  5. Restarts the application and verifies `/api/health`.

---

## 14. Disaster Recovery & Ephemeral Restore Drills

### The Complete Restore Drill Sequence
```text
Encrypted Backup (.sql.gz.age in Cloudflare R2 / S3)
   │
   ▼
Download via restore-offsite.sh
   │
   ▼
Decrypt using operator's private key (age -d -i key.txt)
   │
   ▼
Verify SHA-256 Checksum against .sql.gz.sha256
   │
   ▼
Launch isolated ephemeral Docker container (test_<app>_db)
   │
   ▼
Stream database restore with ON_ERROR_STOP=1
   │
   ▼
Query pg_catalog / information_schema for table count & row integrity
   │
   ▼
Clean teardown of ephemeral container
```

---

## 15. Automated Scheduling (Systemd vs. Cron)

Atlas v1.1.0 uses **native systemd timers** as the authoritative production scheduler.

### Enable the 6-Hour Persistent Systemd Timer
```bash
sudo cp /opt/atlas/systemd/atlas-backup.service /etc/systemd/system/
sudo cp /opt/atlas/systemd/atlas-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-backup.timer
```

### Why Systemd `Persistent=true` Matters
* **Legacy Cron**: If your server is down for maintenance at 06:00 UTC, cron skips the run permanently. Your data loss window doubles to 12+ hours.
* **Atlas Systemd Timer**: With `Persistent=true`, systemd records timestamps in `/var/lib/systemd/timers/`. If the server reboots at 06:15 UTC, systemd catches up and executes the missed backup immediately upon boot.

### Inspect Timer Status
```bash
systemctl list-timers atlas-backup.timer
journalctl -u atlas-backup.service -n 50 --no-pager
```

---

## 16. Monitoring & Diagnostics with Atlas Doctor

Run the comprehensive 6-section diagnostic audit at any time:

```bash
/opt/atlas/bin/doctor
```

### Doctor Audit Sections
1. **System & Hardware**: CPU cores, RAM available, swap usage, disk capacity (>75% warning, >85% failure).
2. **Docker Runtime**: Docker Engine version, Compose v2 availability, unhealthy container scan.
3. **Nginx Reverse Proxy**: Host Nginx status, syntax test (`nginx -t`), containerized Nginx detection.
4. **Host Security**: SSH key-only authentication, root login restrictions, UFW firewall state.
5. **Backups & Data Protection**: `/var/backups` verification, latest backup age, gzip validity, SHA-256 hash match, active scheduler check (`atlas-backup.timer` priority over cron).
6. **Application Registry**: `apps.yml` syntax, workspace directory existence, and `/api/health` probes.

---

## 17. Hardened Web Dashboard & API

Atlas includes a zero-dependency Python 3 HTTP status API and web dashboard.

### Starting the Dashboard
```bash
export ATLAS_DASHBOARD_TOKEN="your-secure-token"
export ATLAS_DASHBOARD_PORT=8888
/opt/atlas/dashboard/server.py
```

### Security Defaults
* **Localhost Binding**: Binds strictly to `127.0.0.1`. Access remotely via SSH port forwarding:
  ```bash
  ssh -L 8888:127.0.0.1:8888 root@your-vps-ip
  ```
* **Authentication**: All mutating endpoints (`/api/actions/backup`, `/api/actions/sync`, `/api/actions/restore-test`) require header `X-Atlas-Token: your-secure-token` evaluated with constant-time `hmac.compare_digest`.
* **Zero Shell Execution**: Subprocess calls use structured arrays with strict alphanumeric parameter allowlists (`^[a-zA-Z0-9][a-zA-Z0-9_-]*$`).

---

## 18. Security Model & Threat Mitigations

| Threat | Atlas Mitigation |
| :--- | :--- |
| **Command Injection in API** | Zero `shell=True`, structured `subprocess.run(["backup.sh", "--app", app])` arrays, strict regex validation. |
| **Timing Attacks on API Token** | Constant-time `hmac.compare_digest()` token validation. |
| **Unauthorized Remote API Access** | Default binding to `127.0.0.1` (no public interface exposure without SSH/TLS proxy). |
| **Decryption Key Theft via VPS Root Breach** | Asymmetric `age` encryption: VPS holds public recipient key only; private key stored in secure offline vault. |
| **Tampered / Corrupted Backup Archives** | Mandatory SHA-256 checksum verification before any restore operation. |
| **Production DB Overwrite during Testing** | Restore drills target isolated ephemeral test containers (`test_<app>_db`). |
| **Concurrent Process Collisions** | Non-blocking kernel advisory locks (`flock -n`) on `/var/run/atlas/*.lock`. |

---

## 19. Failure Modes & System Behavior

| Failure Event | What Atlas Does | What the Operator Should Do |
| :--- | :--- | :--- |
| **Database dump fails** | Temp file discarded; error logged; notification sent; no `.synced` marker written. | Check database container logs and disk space. |
| **Network outage during upload** | 3-attempt bounded retry fails; local backup retained; `.synced` not written. | None required; backlog will sync automatically when network returns. |
| **Remote verification fails** | Uploaded file not found in bucket listing; `.synced` not written. | Check R2/S3 bucket permissions and API token validity. |
| **Host reboots during scheduled run** | `Persistent=true` in `atlas-backup.timer` triggers catch-up backup on boot. | None required. |
| **Process killed (SIGKILL / OOM)** | Kernel automatically releases `flock`; temp files ignored. | Address OOM condition; run `/opt/atlas/bin/doctor`. |
| **Local disk exceeds 85%** | `bin/doctor` reports FAIL; retention prunes verified archives. | Increase disk size or decrease `retention_days`. |

---

## 20. Operator Troubleshooting Guide

### "My backup is not being created"
1. Run `/opt/atlas/bin/doctor` to verify Docker and database container health.
2. Check if another backup process is holding the lock: `lsof /var/run/atlas/backup.lock`.
3. Test dumping manually: `docker exec <container> pg_dump -U <user> <db> > /dev/null`.

### "Old local backups are not being deleted"
* **Diagnosis**: Check if the old backups have a corresponding `.synced` marker: `ls -la /var/backups/<app>/`.
* **Explanation**: If offsite replication failed, Atlas **intentionally preserves** local backups to prevent total data loss.
* **Resolution**: Run `/opt/atlas/scripts/sync-offsite.sh --app=<app>` to synchronize the backlog.

### "Systemd timer is not triggering"
1. Check timer state: `systemctl list-timers atlas-backup.timer`.
2. Check service logs: `journalctl -u atlas-backup.service -n 50 --no-pager`.
3. Enable and start: `sudo systemctl enable --now atlas-backup.timer`.

### "Dashboard API returns HTTP 401 Unauthorized"
* Provide the secret token in the request header:
  ```bash
  curl -H "X-Atlas-Token: $(grep ATLAS_DASHBOARD_TOKEN /etc/atlas/atlas.env | cut -d= -f2)" http://127.0.0.1:8888/api/status
  ```

---

## 21. Emergency Disaster Recovery Runbook

```text
================================================================================
                    EMERGENCY OUTAGE RECOVERY RUNBOOK
================================================================================

1. TRIAGE & ASSESS
   $ /opt/atlas/bin/doctor
   Identify whether the issue is Container Down, Database Corruption, or Host Loss.

2. LOCATE THE LATEST RECOVERABLE BACKUP
   $ ls -lt /var/backups/<app>/<app>-*.sql.gz | head -n 1
   Verify checksum:
   $ sha256sum -c /var/backups/<app>/<latest>.sql.gz.sha256

3. RUN A SANDBOX TEST RESTORE FIRST
   $ /opt/atlas/scripts/restore.sh --app=<app> --target=test
   Confirm the SQL stream restores cleanly without syntax or schema errors.

4. RESTORE TO PRODUCTION (IF CONFIRMED)
   $ /opt/atlas/scripts/restore.sh --app=<app> --target=production
   Type 'YES, RESTORE PRODUCTION' when prompted.

5. VERIFY SERVICE HEALTH
   $ /opt/atlas/scripts/health-check.sh --app=<app>
   $ /opt/atlas/bin/doctor
================================================================================
```

---

## 22. Operational Verification Checklists

### Daily / Automated Checks
* [ ] Doctor health check reports `RESULT: PASS` (`/opt/atlas/bin/doctor`).
* [ ] Systemd timer active (`systemctl is-active atlas-backup.timer`).
* [ ] Latest backup generated within the last 7 hours.
* [ ] `.synced` authorization marker present for latest archive.

### Monthly Disaster Recovery Verification
* [ ] Execute test restore drill (`/opt/atlas/scripts/restore.sh --app=<app> --target=test`).
* [ ] Download an archive from Cloudflare R2 / S3 and test offline decryption (`restore-offsite.sh`).
* [ ] Audit disk space on `/var/backups`.

---

## 23. RPO / RTO Contract & Boundaries

> **Authoritative RPO Definition:**
>
> *"Atlas performs scheduled database snapshots every 6 hours under normal operation, with Persistent systemd catch-up for missed host-side triggers and bounded retries for transient offsite failures. Extended host or network outages can still increase effective RPO."*

* **Recovery Point Objective (RPO)**:
  * **Normal Operation**: 6-Hour Scheduled Snapshot RPO.
  * **Host Reboot / Maintenance**: 6 hours + downtime duration (caught up immediately upon boot via `Persistent=true`).
  * **Extended Network Outage**: Backlog drains upon reconnection; if host is destroyed during outage, data since last successful sync is lost.
* **Recovery Time Objective (RTO)**:
  * Ephemeral test restore: ~30 seconds.
  * Live production database restore: 1 to 3 minutes (depending on database size).
  * Cold-start fresh VPS host rebuild: 10 to 15 minutes.
* **Continuous Streaming (PITR)**: Atlas does **not** provide sub-minute Point-in-Time Recovery (WAL streaming). Applications requiring sub-minute RPO should implement active replication or continuous WAL archiving.

---

## 24. Production Deployment Checklist

```text
[ ] VPS running Ubuntu 22.04 / 24.04 LTS with Docker Compose v2.
[ ] Atlas cloned to /opt/atlas and setup-server.sh executed.
[ ] Application registered in /opt/atlas/config/apps.yml.
[ ] Environment configuration secured in /etc/atlas/atlas.env (chmod 600).
[ ] Public age recipient key configured (ATLAS_AGE_RECIPIENT).
[ ] Cloud storage credentials configured (ATLAS_S3_ENDPOINT, ATLAS_S3_ACCESS_KEY, etc.).
[ ] Initial backup tested: /opt/atlas/scripts/backup.sh --app=<app>.
[ ] Offsite sync tested: /opt/atlas/scripts/sync-offsite.sh --app=<app>.
[ ] Sandbox restore drill verified: /opt/atlas/scripts/restore.sh --app=<app> --target=test.
[ ] Native systemd timer enabled: sudo systemctl enable --now atlas-backup.timer.
[ ] Diagnostic doctor verified: /opt/atlas/bin/doctor -> RESULT: PASS.
```

---

## 25. Security Hardening Checklist

```text
[ ] SSH password authentication disabled (PermitRootLogin prohibit-password / Key-only).
[ ] UFW firewall active with only ports 22, 80, and 443 open.
[ ] Dashboard bound to 127.0.0.1 (ATLAS_DASHBOARD_HOST=127.0.0.1).
[ ] Strong dashboard auth token set (ATLAS_DASHBOARD_TOKEN).
[ ] Private age identity key stored OFFLINE in password manager / cold vault (NOT on VPS).
[ ] /etc/atlas/atlas.env permissions set to 0600 (root:root).
[ ] No secrets committed to Git repository.
```

---

## 26. Frequently Asked Questions (FAQ)

#### Q: Is Atlas just a backup script?
**A:** No. Atlas is an end-to-end disaster recovery and infrastructure lifecycle framework. It couples atomic database dumps with zero-knowledge encryption, remote cloud verification gates, automated durability ledgers, and sandboxed test restoration drills.

#### Q: Does Atlas guarantee zero data loss?
**A:** No. Atlas provides a discrete **6-Hour Scheduled Snapshot RPO**. Transactions committed between scheduled snapshots can be lost if a catastrophic host destruction occurs before the next snapshot.

#### Q: Where should my age private decryption key live?
**A:** In your secure password manager, offline vault, or developer workstation. **Never store the private key on the production VPS.** The VPS only needs the public recipient key (`age1...`).

#### Q: What happens if Cloudflare R2 or AWS S3 goes down?
**A:** Atlas performs bounded retries and logs the failure. Crucially, the local retention engine detects that the `.synced` marker is missing and **refuses to delete** local backups until cloud connectivity returns and the backlog is verified.

#### Q: Can Atlas restore multiple applications?
**A:** Yes. Atlas supports multiple applications defined in `config/apps.yml` (e.g. `catalogflow`, `sand2keys`, `wdni`).

#### Q: What happens if one app fails during `backup.sh --all`?
**A:** Atlas isolates application failures. If App A fails, an alert is logged and Atlas proceeds to snapshot App B and App C.

---

## 27. Complete Command Reference

### Diagnostics & Management
```bash
/opt/atlas/bin/doctor                              # Full 6-section system diagnostic audit
/opt/atlas/bin/doctor --json                       # Output diagnostics in JSON format
/opt/atlas/bin/atlas status                        # Check overall infrastructure status
```

### Application Deployment & Updates
```bash
/opt/atlas/scripts/deploy.sh --app=<app>           # Pull code, rebuild containers, verify health
/opt/atlas/scripts/rollback.sh --app=<app>         # Revert to previous Git commit
/opt/atlas/scripts/health-check.sh --app=<app>     # Probe application HTTP/HTTPS health
```

### Database Backup & Replication
```bash
/opt/atlas/scripts/backup.sh --app=<app>           # Snapshot single application database
/opt/atlas/scripts/backup.sh --all                 # Snapshot all registered applications
/opt/atlas/scripts/sync-offsite.sh --app=<app>     # Encrypt and upload single app backlog
/opt/atlas/scripts/sync-offsite.sh --all           # Encrypt and upload all application backlogs
```

### Database Restoration & Verification
```bash
/opt/atlas/scripts/restore.sh --app=<app> --target=test        # Safe sandbox restore drill
/opt/atlas/scripts/restore.sh --app=<app> --target=production  # Live production database recovery
/opt/atlas/scripts/restore-offsite.sh --app=<app>              # Download & decrypt cloud backup
```

### Scheduler & Dashboard
```bash
sudo systemctl list-timers atlas-backup.timer      # View scheduled backup countdown
sudo journalctl -u atlas-backup.service -n 50      # View backup execution logs
/opt/atlas/dashboard/server.py                     # Start hardened Web Dashboard API
```

---

## 28. Further Reading & Architecture Docs

* **[README.md](../README.md)** — Project overview, core thesis, and engineering case study.
* **[Architecture Diagram (SVG)](architecture.svg)** — Modern visual blueprint and durability lifecycle map.
* **[Architecture Source (Mermaid)](architecture.mmd)** — Auditable Mermaid diagram specification.
* **[OPERATIONS.md](../OPERATIONS.md)** — Daily operational playbooks and maintenance checklists.
* **[DEPLOYMENT.md](../DEPLOYMENT.md)** — Application onboarding and Docker Compose conventions.
* **[BACKUP.md](../BACKUP.md)** — Detailed backup policies, snapshot lifecycle, and retention mechanics.
* **[RECOVERY.md](../RECOVERY.md)** — Comprehensive Disaster Recovery and cold-start rebuild guide.
* **[SECURITY.md](../SECURITY.md)** — Host hardening, container isolation, and encryption standards.
* **[TROUBLESHOOTING.md](../TROUBLESHOOTING.md)** — Extended diagnostic procedures and error codes.
