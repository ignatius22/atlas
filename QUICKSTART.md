# Atlas Practical User Guide & Quickstart

A step-by-step guide for developers and operators to onboard applications, manage deployments, automate database backups, verify restorations, and configure disaster recovery using Atlas.

---

## 1. System Requirements

Before onboarding applications to Atlas on your VPS:
* **Operating System**: Linux (Ubuntu 22.04 LTS or 24.04 LTS recommended)
* **Docker**: Docker Engine 24+ & Docker Compose v2
* **Python**: Python 3.9+ with `pyyaml`
* **Encryption & Cloud Sync Tools**: `age` and `rclone` (or `aws-cli`)

---

## 2. Onboarding an Application (Step-by-Step)

Applications plug into Atlas declaratively without changing your application code.

### Step 2.1: Register the Application in `config/apps.yml`
Open `/opt/atlas/config/apps.yml` (or create it from `config/apps.example.yml`) and define your application:

```yaml
apps:
  # Unique application identifier
  my-app:
    # Directory where the application repository / docker-compose.yml lives
    directory: /var/www/my-app
    
    # Domain routed by Nginx reverse proxy
    domain: app.example.com
    
    # Internal port exposed by the web container
    port: 3000
    
    # Health endpoint probed after deployment
    health_endpoint: /api/health
    
    # Database backup and retention settings
    database:
      type: postgres             # Supported: 'postgres' or 'mariadb'/'mysql'
      container: my-app_postgres # Exact Docker container name running the database
      user: app_user             # Database user
      name: app_production       # Database name
      backup: true               # Enable automated snapshotting
      retention_days: 7          # Local backup retention window
```

---

## 3. Daily Operations & Workflows

### Step 3.1: Deploying or Updating the Application
When you want to deploy new code or restart the application:

```bash
/opt/atlas/scripts/deploy.sh --app=my-app
```

**What Atlas does automatically:**
1. Pulls the latest Git commit in `/var/www/my-app`.
2. Validates `docker-compose.yml` syntax.
3. Recreates containers in-place.
4. Probes `http://localhost:3000/api/health` to confirm the application is serving traffic.

---

### Step 3.2: Creating an Automated Database Snapshot
Atlas automatically creates database snapshots every 6 hours via systemd timer. You can also trigger an immediate snapshot on demand:

```bash
# Snapshot a specific application
/opt/atlas/scripts/backup.sh --app=my-app

# Snapshot all registered applications
/opt/atlas/scripts/backup.sh --all
```

**What Atlas produces in `/var/backups/my-app/`:**
* `my-app-<TIMESTAMP>.sql.gz`: Maximum gzip-compressed database dump.
* `my-app-<TIMESTAMP>.sql.gz.sha256`: SHA-256 integrity hash.
* `my-app-<TIMESTAMP>.sql.gz.meta.json`: Metadata manifest containing schema version, timestamp, and size.

---

### Step 3.3: Verifying Restorability in an Ephemeral Test Container

> **The Atlas Guarantee:** A backup is not trustworthy merely because it exists. Atlas verifies that it can actually be restored.

Test your backup safely in an isolated sandbox without touching production:

```bash
/opt/atlas/scripts/restore.sh --app=my-app --target=test
```

**How the test restore works:**
1. Verifies the SHA-256 checksum of the local archive.
2. Spins up an isolated, temporary Docker container (`test_my-app_db`).
3. Streams the database dump into the test container with `ON_ERROR_STOP=1`.
4. Validates table structure and row counts.
5. Automatically tears down the test container.

---

### Step 3.4: Replicating to Off-Site Cloud Storage (Zero-Knowledge)
To encrypt and replicate local backups to Cloudflare R2 or AWS S3:

```bash
/opt/atlas/scripts/sync-offsite.sh --app=my-app
```

**What happens:**
1. **Asymmetric Encryption**: Encrypts the archive using `age` (public X25519 recipient key). The VPS stores zero private decryption keys.
2. **Cloud Upload**: Uploads the encrypted archive (`.age`), checksum, and manifest to cloud object storage.
3. **Verification Gate**: Atlas queries cloud storage to confirm the file physically exists.
4. **Durability Authorization**: Writes `.synced` marker on the local host.
   * *Durability Invariant:* Local retention will **never** delete a local backup unless this `.synced` marker exists.

---

## 4. System Diagnostics with Atlas Doctor

Audit your VPS health, container status, security settings, and backup integrity in one command:

```bash
/opt/atlas/bin/doctor
```

Doctor validates:
* **System Resources**: CPU cores, RAM availability, swap usage, and disk space.
* **Docker Runtime**: Unhealthy container detection and Compose engine version.
* **Nginx Gateway**: Configuration syntax and reverse proxy routing.
* **Host Security**: SSH key-only enforcement, root login restrictions, and UFW firewall.
* **Data Integrity**: Backup directory existence, archive gzip validity, SHA-256 verification, and active scheduler (`systemd.timer` / `cron`).
* **Application Registry**: Application workspace directories and health check probes.

---

## 5. Emergency Playbooks

### Scenario A: Fast Application Rollback
If a code deployment causes errors, roll back to the previous stable Git commit:

```bash
/opt/atlas/scripts/rollback.sh --app=my-app --commit=HEAD~1
```

---

### Scenario B: Production Database Restore
In a real disaster where the production database must be restored from backup:

```bash
/opt/atlas/scripts/restore.sh --app=my-app --target=production
```

**Safety safeguards during production restore:**
1. Prompts for explicit operator confirmation.
2. Temporarily stops the web application container to prevent data mutations.
3. Drops and recreates the production database.
4. Executes single-transaction restore with `ON_ERROR_STOP=1`.
5. Restarts the web application container and runs health probes.

---

### Scenario C: Complete Server Loss (Rebuilding on Fresh VPS)
If the VPS host is completely lost:
1. Provision a fresh Ubuntu 24.04 VPS.
2. Clone Atlas and run `/opt/atlas/scripts/setup-server.sh`.
3. Configure your cloud credentials in `/etc/atlas/atlas.env`.
4. Run `/opt/atlas/scripts/restore-offsite.sh --app=my-app` providing your offsite private age key.

---

## 6. Command Reference Cheat Sheet

| Task | Command |
| :--- | :--- |
| **System Diagnostics** | `/opt/atlas/bin/doctor` |
| **Deploy Application** | `/opt/atlas/scripts/deploy.sh --app=<name>` |
| **Rollback Application** | `/opt/atlas/scripts/rollback.sh --app=<name> --commit=<hash>` |
| **Create Local Backup** | `/opt/atlas/scripts/backup.sh --app=<name>` |
| **Batch Backup All Apps** | `/opt/atlas/scripts/backup.sh --all` |
| **Test Restore (Sandbox)** | `/opt/atlas/scripts/restore.sh --app=<name> --target=test` |
| **Production Restore** | `/opt/atlas/scripts/restore.sh --app=<name> --target=production` |
| **Off-Site Cloud Sync** | `/opt/atlas/scripts/sync-offsite.sh --app=<name>` |
| **Check Scheduler Status** | `systemctl list-timers atlas-backup.timer` |
| **View Backup Service Logs** | `journalctl -u atlas-backup.service -n 50 --no-pager` |

