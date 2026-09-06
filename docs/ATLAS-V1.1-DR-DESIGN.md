# Atlas V1.1 Disaster Recovery & Off-Site Replication Architecture

## 1. Executive Overview

Atlas Production Template V1 established a reliable, non-destructive, and verified local backup engine for PostgreSQL applications. However, local backups on the same physical host protect only against user error or local database corruption; they offer zero protection against host hardware failure, datacenter outages, hypervisor destruction, or VPS ransomware compromise.

**Atlas V1.1** introduces an enterprise-grade, **zero-trust off-site disaster recovery architecture** designed around:
1. **Asymmetric Client-Side Encryption (`age`)**: Backups are encrypted on the VPS using a public key. The decryption private key is **never** stored on the VPS.
2. **Storage Provider Agnostic Synchronization**: Native support for Cloudflare R2, AWS S3, or any S3-compatible object storage via standard providers (`rclone`, `aws-cli`, or SigV4 REST).
3. **Immutable / Object-Lock Retention**: Remote buckets enforce Write-Once-Read-Many (WORM) policies and lifecycle expiration, preventing compromised VPS credentials from destroying historical archives.
4. **Independent Restore Verification**: Automated disposable container restore pipelines capable of validating backups without touching production.

---

## 2. End-to-End Backup & Replication Pipeline

```
[ PostgreSQL Database ]
          │
          │ 1. Read-only stream (pg_dump --no-owner --clean --if-exists)
          ▼
[ Local Backup Engine (backup.sh) ]
          │
          │ 2. Compress & Validate (gzip -9, check headers, verify >50 bytes)
          ▼
/var/backups/<app>/<app>-<timestamp>.sql.gz
/var/backups/<app>/<app>-<timestamp>.sql.gz.sha256
          │
          │ 3. Asymmetric Encryption (age -r <AGE_RECIPIENT_PUBKEY>)
          ▼
/var/backups/<app>/<app>-<timestamp>.sql.gz.age
/var/backups/<app>/<app>-<timestamp>.sql.gz.age.sha256
          │
          │ 4. Off-Site Sync (sync-offsite.sh with mutex locking)
          ▼
[ Cloud Object Storage (Cloudflare R2 / AWS S3) ]
  s3://<bucket>/atlas-backups/<app>/<year>/<month>/<app>-<timestamp>.sql.gz.age
          │
          │ 5. Remote Object Verification (head-object & size check)
          ▼
[ Notification / Alerting Layer (notify.sh) ]
  (Discord / Slack / Telegram / Webhook)
```

---

## 3. Asymmetric Encryption Flow & Key Management

### The Zero-Trust Encryption Model
To prevent a root-level VPS compromise from exposing historical database backups, Atlas V1.1 mandates **asymmetric public-key encryption** using `age` (Actually Good Encryption) or GPG:

* **Public Key (Recipient Key):**
  * Format: `age1...` (e.g. `age1ql3z7hjykgpwpw33...`)
  * Stored on VPS in `/opt/atlas/config/backup.yml` or `/opt/atlas/.env` (`ATLAS_AGE_RECIPIENT`).
  * Used exclusively to **encrypt** `.sql.gz` archives prior to network transmission.
  * Poses **zero confidentiality risk** if read by an attacker.
* **Private Key (Identity Key):**
  * Format: `AGE-SECRET-KEY-1...`
  * **MUST NEVER EXIST ON THE VPS IN PLAINTEXT.**
  * Must be stored securely in an offline password manager (1Password, Bitwarden), hardware security module (YubiKey), or encrypted cold storage.
  * Required **only** during disaster recovery when restoring to a new host or during offline test audits.

```
[ VPS / Production Host ]                       [ Offline Operator / DR Site ]
        │                                                     │
  Public Key (age1...)                                  Private Key (AGE-SECRET-KEY...)
        │                                                     │
   Encrypts Backup ─────────── Cloud Bucket ───────────► Decrypts & Restores
   (Cannot Decrypt)         (Encrypted at Rest)          (Full Recovery)
```

---

## 4. Remote Storage Layout & Directory Structure

Remote object keys follow a deterministic, human-readable, and date-partitioned layout:

```text
s3://<bucket-name>/
└── atlas-backups/
    ├── <app-name>/
    │   ├── 2026/
    │   │   ├── 08/
    │   │   │   ├── <app>-20260824T102625Z.sql.gz.age
    │   │   │   ├── <app>-20260824T102625Z.sql.gz.age.sha256
    │   │   │   └── <app>-20260824T102625Z.meta.json
    │   └── latest.json (Optional metadata pointer)
```

### Metadata Manifest (`.meta.json`)
Accompanying every encrypted archive is a lightweight JSON manifest containing non-sensitive provenance:
```json
{
  "application": "sand2keys",
  "timestamp": "2026-08-24T10:26:25Z",
  "database_type": "postgres",
  "database_version": "16.14",
  "uncompressed_bytes": 249987,
  "compressed_bytes": 41588,
  "encrypted_bytes": 41656,
  "sha256_unencrypted": "43c4139fad350130a92e3cecdee556f5880a653c6adacec9c7087cd1ee5d83be",
  "sha256_encrypted": "9b12a84f...",
  "encryption_type": "age-v1",
  "recipient_pubkey": "age1..."
}
```

---

## 5. Cloud IAM Permissions & Least-Privilege Policy

The VPS is granted only the minimum required IAM permissions. It is explicitly denied permission to delete or overwrite existing objects.

### AWS IAM Policy for VPS (Write-Only / Append-Only)
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAtlasUploadAndVerify",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::atlas-production-backups",
        "arn:aws:s3:::atlas-production-backups/*"
      ]
    },
    {
      "Sid": "DenyAtlasDestructiveActions",
      "Effect": "Deny",
      "Action": [
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:DeleteBucket",
        "s3:PutLifecycleConfiguration",
        "s3:PutBucketPolicy"
      ],
      "Resource": [
        "arn:aws:s3:::atlas-production-backups",
        "arn:aws:s3:::atlas-production-backups/*"
      ]
    }
  ]
}
```

---

## 6. Retention & Immutability Strategy (Object Lock / WORM)

1. **Local Retention (VPS Disk):**
   * Handled by `/opt/atlas/scripts/backup.sh`.
   * Standard retention: 14 days (fast local restores in seconds).
2. **Remote Retention (Cloud Bucket Lifecycle):**
   * Configured directly on the Cloudflare R2 / AWS S3 bucket lifecycle rules.
   * Standard retention: **30 days** (automatic object expiration handled by cloud provider).
3. **Immutability Mechanisms by Provider:**
   * **AWS S3:** Requires S3 Object Lock enabled at bucket creation (Bucket Versioning mandatory). Configure **Compliance Mode** with a 30-day retention period. In Compliance Mode, no user (including AWS root) can delete or shorten the retention period.
   * **Cloudflare R2:** R2 does not support native S3 Object Lock API headers (`x-amz-object-lock-*`) via standard S3 tokens. Immutability in Cloudflare R2 is enforced at the IAM token boundary:
     1. Create an API token scoped with **Object Read & Write** permissions only.
     2. Explicitly omit the **Object Delete** permission from the token.
     3. Configure bucket-level retention policies in the Cloudflare Dashboard.
   * **Security Guarantee:** Under either provider, a compromised host with root access cannot delete or tamper with historical off-site backup archives.

---

## 7. Threat Modeling & Failure Scenarios

### Scenario 1: Total VPS Destruction (Hardware Failure / Hypervisor Outage / Host Termination)
* **Impact:** All local containers, NVMe storage, and `/var/backups` are permanently lost.
* **Recovery Vector:**
  1. Provision a fresh Ubuntu 24.04 VPS.
  2. Clone Atlas repository and install prerequisites (`make install-deps`).
  3. Configure cloud read credentials.
  4. Run `/opt/atlas/scripts/restore-offsite.sh` supplying the offline `age` private key.
  5. Applications and databases are restored from the latest cloud snapshot.
* **Expected Data Loss (RPO):** Maximum time elapsed since last scheduled sync (e.g. 6–12 hours).

### Scenario 2: VPS Compromise / Host Ransomware
* **Impact:** Adversary obtains root access on the production host.
* **Mitigation:**
  1. **Confidentiality:** Attacker finds only public `age` key. They cannot decrypt historical `.sql.gz.age` files or read remote database backups.
  2. **Integrity:** IAM policy denies `s3:DeleteObject`. S3 Object Lock prevents overwriting historical versions. Attacker cannot delete remote backups.

### Scenario 3: Accidental Database Corruption / Dropped Table
* **Impact:** Production database is corrupt, but VPS host is intact.
* **Recovery Vector:** Fast local recovery using `/var/backups/<app>/` via `/opt/atlas/scripts/restore.sh --app=<app>` (RTO < 30 seconds).

### Scenario 4: Loss of Encryption Private Key
* **Impact:** Operator loses the offline `age` private key.
* **Mitigation:**
  * Multi-recipient encryption (`age -r <KEY1> -r <KEY2>`): Atlas supports encrypting to multiple public keys simultaneously (e.g. primary infrastructure key + disaster recovery escrow key).

---

## 8. Failure Handling & Alerting Architecture

The notification layer (`scripts/lib/notify.sh`) operates as a central event dispatcher:
* **Trigger Conditions:**
  * `ON_BACKUP_FAIL`: Non-zero exit from `pg_dump`, gzip corruption, or zero-byte dump.
  * `ON_ENCRYPT_FAIL`: Failure of `age` binary or missing recipient key.
  * `ON_SYNC_FAIL`: Network timeout, authentication error, or remote object existence verification failure.
  * `ON_RESTORE_TEST_FAIL`: Automated disposable recovery verification failed.
* **Secret Redaction:** `notify.sh` strictly filters and redacts environment variables, passwords, tokens, and authorization headers before sending payloads to external webhooks.

---

## 9. Measured RPO & RTO Projections

| Recovery Metric | Measured / Validated State | Target with Atlas V1.1 |
|---|---|---|
| **RPO (Local Error)** | **24 hours** (Daily midnight backup) | **6–12 hours** (Scheduled 2–4x daily) |
| **RPO (Total VPS Loss)** | **NOT PROVEN** (No off-site replication prior to V1.1) | **6–12 hours** (Cloud snapshot RPO) |
| **RTO (Local Restore on same host)** | **< 30 seconds** (CatalogFlow: 2s, Sand2Keys: 3s, WDNI: 2s) | **< 30 seconds** |
| **RTO (Bare-Metal VPS Rebuild from scratch)** | **NOT PROVEN** (Manual rebuild estimated at 30–45 mins) | **< 20 minutes** (Automated bootstrap runbook) |
