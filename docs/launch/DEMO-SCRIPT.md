# Atlas 90-Second Demo Terminal Recording Script

**00:00 - 00:10 (The Problem):**
Narrator: "You have a cron job dumping Postgres to S3. But do you actually know if that backup can be restored right now?"

**00:10 - 00:25 (Diagnostics):**
Command: `atlas doctor`
Visual: Terminal shows system health, zero exposed database ports, and Age crypto ready.

**00:25 - 00:45 (Backup & Encryption):**
Command: `atlas backup create web-app`
Visual: Streams atomic pg_dump, generates SHA-256 checksum.
Command: `atlas backup sync web-app`
Visual: Encrypts with Age public key and uploads to Cloudflare R2.

**00:45 - 01:00 (Chaos Simulation):**
Command: `docker rm -f webapp_postgres`
Visual: The live database container is deleted.

**01:00 - 01:20 (Ephemeral DR Recovery Drill):**
Command: `atlas restore test web-app --key-file=offline.key`
Visual: Atlas downloads encrypted archive, decrypts in a private scratch directory, boots a disposable Postgres container, restores schema, and counts tables.
Terminal Output: `[OK] DR Verification Drill PASSED! Tables restored: 24, Measured RTO: 340ms`

**01:20 - 01:30 (Conclusion):**
Narrator: "That is the difference between hoping you have a backup and knowing you can recover. Atlas v1.0.0 is open-source and ready."
