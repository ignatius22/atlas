# Atlas Database Backup Architecture & Procedures

Atlas provides a non-destructive, authenticated database backup engine for production databases.

---

## 1. Backup Architecture

```text
[Cron / Operator]
       │
       ▼
./scripts/backup.sh --app=<app_name>
       │
       ├── 1. Read apps.yml & backup.yml (via PyYAML)
       ├── 2. Verify container state & health
       ├── 3. Execute pg_dump via docker exec
       │      (Credentials read dynamically from container env)
       │
       ▼
[Gzip Stream Compression - Level 9]
       │
       ├── 4. Validate non-empty archive (>50 decompressed bytes)
       ├── 5. Verify PostgreSQL dump headers (CREATE/ALTER/SET)
       ├── 6. Test gzip stream integrity (gzip -t)
       ├── 7. Generate SHA-256 Checksum (.sha256)
       ├── 8. Prune archives older than retention_days
       │
       ▼
/var/backups/<app_name>/<app_name>-<timestamp>.sql.gz
/var/backups/<app_name>/<app_name>-<timestamp>.sql.gz.sha256
```

---

## 2. Key Safety Features

* **Zero Plaintext Passwords:** Credentials are never written to disk or embedded in scripts. `scripts/backup.sh` queries the running container's environment variables dynamically.
* **SQL Content & Header Validation:** Archives are checked for valid PostgreSQL SQL headers and minimum uncompressed byte counts. 0-byte or truncated dumps are deleted immediately and trigger error exits.
* **Integrity Validation:** Every completed backup archive is verified immediately with `gzip -t`. Corrupt archives are rejected before replacing old backups.
* **Cryptographic Checksumming:** A `.sha256` checksum is created alongside every archive for tamper detection and restore verification.
* **Automatic Retention Pruning:** Backups older than `retention_days` (default: 14 days) are automatically deleted to prevent disk overflow.

---

## 3. Usage & Examples

### Manual Backup for a Single Application
```bash
./scripts/backup.sh --app=example-app
# or
make backup APP=example-app
```

### Back Up All Registered Applications
```bash
./scripts/backup.sh --all
# or
make backup-all
```

### Simulate Backup Without Modifying Disk (Dry-Run)
```bash
./scripts/backup.sh --app=example-app --dry-run
```

---

## 4. Archive Naming Convention

Backups follow an ISO-8601 UTC timestamp convention:
```text
/var/backups/example-app/example-app-20260824T020000Z.sql.gz
/var/backups/example-app/example-app-20260824T020000Z.sql.gz.sha256
```

---

## 5. Automated Cron Configuration

Configure `/etc/cron.d/atlas-backups` or the host crontab to stagger backups across off-peak hours:

```cron
# Atlas Automated Daily Database Backups
0 0 * * * root /path/to/atlas/scripts/backup.sh --app=app1 >> /var/log/atlas/backup-app1.log 2>&1
0 1 * * * root /path/to/atlas/scripts/backup.sh --app=app2 >> /var/log/atlas/backup-app2.log 2>&1
0 2 * * * root /path/to/atlas/scripts/backup.sh --app=app3 >> /var/log/atlas/backup-app3.log 2>&1
```
