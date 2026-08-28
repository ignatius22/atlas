# Atlas V1.1 Production Backup Cron Migration Plan

This document defines the safe, zero-downtime procedure for transitioning the production host from legacy, unencrypted cron jobs to the Atlas V1.1 Unified Automated Disaster Recovery Engine.

---

## 1. Current State vs Target State

### Current Legacy Schedule (Unencrypted, Local-Only)
| App | Schedule (UTC) | Script | Limitations |
|---|---|---|---|
| **WDNI** | `00:00` | `/var/www/wdni/scripts/vps-backup.sh` | No encryption, no header verification, no off-site replication, no alerting |
| **CatalogFlow** | `01:00` | `/usr/local/bin/backup-catalogflow.sh` | No encryption, basic `[ -s ]` check only, no off-site replication |
| **Sand2Keys** | `02:00` | `/usr/local/bin/backup-sand2keys.sh` | No encryption, basic `[ -s ]` check only, no off-site replication |

### Target Atlas V1.1 Schedule (Asymmetric Encryption, Cloud Sync, Alerting)
* **Frequency:** 6-Hour RPO (`00:00`, `06:00`, `12:00`, `18:00` UTC) or 12-Hour RPO (`00:00`, `12:00` UTC).
* **Command:** `/opt/atlas/scripts/backup.sh --all && /opt/atlas/scripts/sync-offsite.sh --all >> /var/log/atlas-backup.log 2>&1`
* **Features:**
  * Strict atomic dump streaming with `set -o pipefail`.
  * Triple-layer integrity verification (Gzip check, >50B stream size, SQL dump header signature).
  * Companion `.sha256` and `.meta.json` generation.
  * Asymmetric `age` client-side encryption (Public recipient key on VPS, Master private key strictly offline).
  * Cloud Object Storage replication (Cloudflare R2 / AWS S3) with WORM immutability.
  * Webhook alert delivery on failures.
  * Atomic directory mutex locking (`/tmp/atlas_sync_offsite.lock.d`) preventing concurrency collisions.

---

## 2. Five-Stage Migration Strategy

```
[ STAGE 1: CURRENT STATE ]
  Legacy cron active at 00:00, 01:00, 02:00 UTC
           │
           ▼
[ STAGE 2: COEXISTENCE & VERIFICATION ]
  Add Atlas at 03:00 UTC alongside legacy jobs
  Zero interference; verify 7 consecutive days of valid off-site archives
           │
           ▼
[ STAGE 3: FREQUENCY ACCELERATION (6-12h RPO) ]
  Transition Atlas to 00:00, 06:00, 12:00, 18:00 UTC
           │
           ▼
[ STAGE 4: LEGACY CRON DECOMMISSIONING ]
  Comment out legacy crontab entries
           │
           ▼
[ STAGE 5: POST-CUTOVER STABILIZATION ]
  Validate health checks, Doctor diagnostics, and off-site test restores
```

---

## 3. Stage-by-Stage Operational Runbook

### Stage 1: Pre-Migration Validation
1. Verify that Cloudflare R2 / AWS S3 credentials and public recipient key are configured in `/opt/atlas/.env`:
   ```bash
   test -n "$(grep ATLAS_AGE_RECIPIENT /opt/atlas/.env 2>/dev/null)" && echo "Encryption Key: OK"
   test -n "$(grep ATLAS_S3_ACCESS_KEY /opt/atlas/.env 2>/dev/null)" && echo "Cloud Credentials: OK"
   ```
2. Execute a dry-run test of the full multi-app workflow:
   ```bash
   /opt/atlas/scripts/backup.sh --all --dry-run
   /opt/atlas/scripts/sync-offsite.sh --all --dry-run
   ```

### Stage 2: Coexistence Phase (Atlas @ 03:00 UTC)
1. Add Atlas to the root crontab without removing legacy entries:
   ```bash
   (crontab -l 2>/dev/null; echo "0 3 * * * /opt/atlas/scripts/backup.sh --all && /opt/atlas/scripts/sync-offsite.sh --all >> /var/log/atlas-backup.log 2>&1") | crontab -
   ```
2. Monitor `/var/log/atlas-backup.log` for 7 days.
3. Validate that off-site archives pass test decryption and disposable container restore:
   ```bash
   /opt/atlas/scripts/test-offsite-backup.sh --app=catalogflow
   /opt/atlas/scripts/test-offsite-backup.sh --app=sand2keys
   /opt/atlas/scripts/test-offsite-backup.sh --app=wdni
   ```

### Stage 3: Cutover to Target 6-Hour RPO Schedule
1. Edit root crontab using `crontab -e`:
   ```cron
   # @reboot /admin/firstbootkvm yes; netplan apply
   
   # ==============================================================================
   # Atlas V1.1 Production Automated Disaster Recovery Engine
   # Schedule: Every 6 Hours (00:00, 06:00, 12:00, 18:00 UTC)
   # ==============================================================================
   0 0,6,12,18 * * * /opt/atlas/scripts/backup.sh --all && /opt/atlas/scripts/sync-offsite.sh --all >> /var/log/atlas-backup.log 2>&1
   
   # --- DECOMMISSIONED LEGACY JOBS (Disabled on Cutover) ---
   # 0 0 * * * cd /var/www/wdni && /var/www/wdni/scripts/vps-backup.sh >> /var/log/wdni-backup.log 2>&1
   # 0 1 * * * /usr/local/bin/backup-catalogflow.sh >> /var/log/catalogflow-backup.log 2>&1
   # 0 2 * * * /usr/local/bin/backup-sand2keys.sh >> /var/log/sand2keys-backup.log 2>&1
   ```

---

## 4. Rollback Procedure

If any unexpected database load or replication anomaly occurs:
1. Re-enable legacy crontab entries:
   ```bash
   crontab -e
   # Uncomment the 00:00, 01:00, 02:00 entries and comment out the Atlas entry
   ```
2. Check Atlas logs:
   ```bash
   tail -n 100 /var/log/atlas-backup.log
   ```
3. Run diagnostic health checks:
   ```bash
   /opt/atlas/bin/doctor
   /opt/atlas/scripts/health-check.sh --all
   ```
