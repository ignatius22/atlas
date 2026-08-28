# Atlas Disaster Recovery & Database Restore Playbook

> [!CAUTION]
> **Production Restore Warning:** Restoring into a live production database overwrites or modifies existing data. Always verify the backup archive in an isolated test environment first.

---

## 1. Safe Verification: Isolated Test Restore

Before restoring a backup into production (or as part of routine disaster recovery drills), always execute a test restore:

```bash
./scripts/restore.sh --app=example-app --file=/var/backups/example-app/example-app-20260824.sql.gz --target=test
```

### What Test Mode Does:
1. **Validates Gzip Integrity:** Ensures the archive is not truncated or corrupted.
2. **Validates SHA-256 Checksum:** Verifies cryptographic match against `.sha256`.
3. **Spawns Ephemeral Container:** Boots an isolated PostgreSQL 16 container (`atlas_restore_test_*`).
4. **Imports Database Dump:** Executes the SQL dump into the temporary database.
5. **Inspects Schemas & Row Counts:** Queries table relations to verify schema completeness.
6. **Destroys Test Container:** Cleanly removes the test container without impacting production resources.

---

## 2. Production Database Restore

If a production incident requires rolling back data to a previous backup snapshot:

```bash
./scripts/restore.sh --app=example-app --file=/var/backups/example-app/example-app-20260824.sql.gz --target=production
```

### Safeguards Enforced by Atlas:
1. **Interactive Confirmation:** You must type `CONFIRM-RESTORE-TO-PRODUCTION` to proceed (or supply `--force` in automated DR pipelines).
2. **Pre-Restore Snapshot:** `restore.sh` automatically creates an emergency safety backup of the current production database before applying the dump.
3. **Clean Transactional Import:** Imports data using `--clean --if-exists` to replace existing tables cleanly.

---

## 3. Full Host Disaster Recovery

If the entire VPS is lost and rebuilt from scratch on a new server:

### Step 1: Bootstrap New Server
```bash
git clone https://github.com/org/atlas-production-template.git /opt/atlas
cd /opt/atlas
sudo ./scripts/setup-server.sh
```

### Step 2: Restore Atlas Registry & Environment
```bash
cp /path/to/secured/backup/apps.yml config/apps.yml
cp /path/to/secured/backup/.env .env
```

### Step 3: Clone Application Repositories
```bash
git clone https://github.com/org/my-app.git /var/www/my-app
cp /path/to/secured/backup/my-app.env /var/www/my-app/.env
```

### Step 4: Launch Application Infrastructure
```bash
./scripts/deploy.sh --app=my-app
```

### Step 5: Restore Database Dumps
```bash
./scripts/restore.sh --app=my-app --file=/path/to/secured/backup/my-app-latest.sql.gz --target=production
```

### Step 6: Re-issue SSL Certificates
```bash
./scripts/setup-ssl.sh -d app.example.com -m admin@example.com
```

### Step 7: Run Doctor Diagnostic
```bash
./bin/doctor
```
