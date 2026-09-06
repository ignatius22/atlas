# Atlas V1.1 Disaster Recovery & Bare-Metal Recovery Runbook

This runbook provides actionable, step-by-step procedures for recovering applications and databases under any disaster scenario.

---

## 1. Disaster Recovery Scenarios

### SCENARIO A: Accidental Database Corruption / Dropped Table (VPS Intact)
**Severity:** MEDIUM | **Estimated Recovery Time:** < 1 minute | **Data Loss:** Since last backup.

1. SSH into the VPS:
   ```bash
   ssh root@153.75.251.207
   ```
2. Locate the latest valid local backup in `/var/backups/<app>/`:
   ```bash
   ls -lah /var/backups/<app>/
   ```
3. Execute the interactive restore engine:
   ```bash
   /opt/atlas/scripts/restore.sh --app=<app> --target=production
   ```
4. When prompted, enter the confirmation phrase:
   ```text
   CONFIRM-RESTORE-TO-PRODUCTION
   ```
5. Atlas will automatically take a pre-restore safety dump, then restore the transaction cleanly using `-v ON_ERROR_STOP=1 --single-transaction`.
6. Verify application health:
   ```bash
   /opt/atlas/scripts/health-check.sh --app=<app>
   ```

---

### SCENARIO B: Local Database Container Loss or Volume Corruption (VPS Intact)
**Severity:** HIGH | **Estimated Recovery Time:** < 3 minutes.

1. Ensure the PostgreSQL volume is recreated:
   ```bash
   cd /var/www/<app>
   docker compose down
   docker compose up -d <db_service>
   ```
2. Wait for PostgreSQL to become healthy:
   ```bash
   docker exec <db_container> pg_isready
   ```
3. Restore the latest backup:
   ```bash
   /opt/atlas/scripts/restore.sh --app=<app> --target=production --force
   ```
4. Restart application services:
   ```bash
   docker compose up -d
   ```
5. Run Atlas Doctor and health checks:
   ```bash
   /opt/atlas/bin/doctor
   /opt/atlas/scripts/health-check.sh --app=<app>
   ```

---

### SCENARIO C: Complete VPS Destruction (Hardware Loss / Datacenter Failure)
**Severity:** CRITICAL | **Estimated Recovery Time:** 20–35 minutes | **Target RTO:** < 30 mins.

#### Phase 1: Infrastructure Provisioning (Human + Cloud Provider)
1. Provision a fresh VPS (Ubuntu 24.04 LTS x86_64, minimum 2 CPU, 4GB RAM, 50GB NVMe).
2. Assign static public IP or prepare DNS update.
3. Configure SSH public key authentication and disable root password auth.

#### Phase 2: Host Toolchain & Atlas Bootstrap (Automated)
1. SSH into the fresh VPS as root:
   ```bash
   ssh root@<NEW_VPS_IP>
   ```
2. Update OS and install base dependencies:
   ```bash
   apt-get update && apt-get install -y git curl jq gzip tar ufw python3 python3-yaml age
   ```
3. Install Docker Engine and Compose plugin:
   ```bash
   curl -fsSL https://get.docker.com | sh
   systemctl enable --now docker
   ```
4. Clone the Atlas Production Template to `/opt/atlas`:
   ```bash
   git clone https://github.com/<org>/atlas-production-template.git /opt/atlas
   cd /opt/atlas
   chmod 750 /opt/atlas
   chmod +x /opt/atlas/bin/* /opt/atlas/scripts/*.sh
   ```

#### Phase 3: Secrets & Cloud Credentials Configuration (Human Operator)
1. Copy the production `.env` and `apps.yml` to `/opt/atlas/`:
   ```bash
   cp /opt/atlas/.env.example /opt/atlas/.env
   # Populate ATLAS_S3_BUCKET, ATLAS_S3_ACCESS_KEY, ATLAS_S3_SECRET_KEY, ATLAS_AGE_RECIPIENT
   chmod 600 /opt/atlas/.env
   ```
2. Clone application code repositories into `/var/www/<app>` (e.g. `/var/www/catalogflow`, `/var/www/sand2keys`, `/var/www/wdni`).

#### Phase 4: Off-Site Database Retrieval & Decryption (Automated Engine)
1. Retrieve and restore each database from Cloudflare R2 / AWS S3 using the offline `age` private key:
   ```bash
   # Provide the offline age identity key via environment or temporary key file
   export ATLAS_AGE_IDENTITY="AGE-SECRET-KEY-1..."
   
   /opt/atlas/scripts/restore-offsite.sh --app=catalogflow --target=production
   /opt/atlas/scripts/restore-offsite.sh --app=sand2keys --target=production
   /opt/atlas/scripts/restore-offsite.sh --app=wdni --target=production
   
   unset ATLAS_AGE_IDENTITY
   ```

#### Phase 5: Service Start & Network Ingress (Automated)
1. Start application Docker Compose stacks:
   ```bash
   cd /var/www/catalogflow && docker compose up -d
   cd /var/www/sand2keys && docker compose up -d
   cd /var/www/wdni && docker compose -f docker-compose.prod.yml up -d
   ```
2. Update DNS records (A/AAAA) to point domain names to `<NEW_VPS_IP>`.
3. Verify overall system integrity:
   ```bash
   /opt/atlas/bin/doctor
   /opt/atlas/scripts/health-check.sh --all
   ```

---

### SCENARIO D: VPS Compromise / Host Ransomware
**Severity:** CRITICAL | **Action:** Total Host Tear-Down.

1. **DO NOT ATTEMPT IN-PLACE REMEDIATION.** A compromised root host cannot be trusted.
2. Immediately terminate or isolate the compromised VPS network interface.
3. Immediately revoke the VPS cloud IAM API credentials (`ATLAS_S3_ACCESS_KEY`) from the AWS/Cloudflare console.
4. Verify that historical backups in the cloud bucket were protected by S3 Object Lock / WORM immutability.
5. Rotate all application secrets, database passwords, and API keys.
6. Execute **Scenario C (Complete VPS Destruction)** to provision a clean host from scratch.

---

### SCENARIO E: Loss of Encryption Private Key
**Severity:** HIGH.

1. Asymmetric encryption with `age` allows encrypting to **multiple public keys** simultaneously.
2. If the primary operator key is lost, use the **offline escrow/recovery key** defined in `ATLAS_AGE_RECIPIENT_BACKUP`.
3. Generate a new keypair immediately using `age-keygen`.
4. Update `ATLAS_AGE_RECIPIENT` across `/opt/atlas/config/backup.yml`.

---

## 2. Disaster Recovery Measurement Log (RTO / RPO Tracking)

| Stage | Action | Measured Duration | Status |
|---|---|---|---|
| **T0** | Disaster Declared & Confirmed | 0m 00s | Procedural |
| **T1** | Fresh VPS Provisioned & SSH Access Ready | ~5–10 mins | Provider Dependent |
| **T2** | Base Toolchain & Docker Installed | ~2–4 mins | Scripted |
| **T3** | Atlas Repository & App Repos Cloned | ~1–2 mins | Scripted |
| **T4** | Encrypted Cloud Backups Downloaded | ~1 min (Fast Cloud Egress) | Validated |
| **T5** | Asymmetric Decryption & DB Restore | ~30 seconds (All 3 DBs) | Validated |
| **T6** | Containers Started & Health Checks Passed | ~1–2 mins | Validated |
| **T7** | DNS Propagation & SSL Active | ~5–15 mins | DNS TTL Dependent |
| **TOTAL** | **Target Recovery Time (RTO)** | **~15–35 minutes** | **Pending Full Drill** |
