# I Deleted My Database on Purpose: Introducing Atlas v1.0.0

A backup isn't a backup until you've successfully restored it.

Most teams set up a cron job to run `pg_dump` and upload a `.sql.gz` to S3. But what happens when you actually need to recover? Corrupted gzip headers, missing environment variables, or schema mismatches often mean the backup you relied on is completely unusable.

We built **Atlas** to solve this.

Atlas is a lightweight, zero-trust infrastructure and disaster-recovery toolkit for Dockerized applications. It:
1. Streams atomic PostgreSQL backups.
2. Encrypts them on your server with asymmetric Age (X25519) public keys.
3. Replicates to Cloudflare R2, AWS S3, or MinIO.
4. **Automatically spins up an ephemeral disposable container, restores the archive, checks row counts, and reports your real measured RTO.**

It also includes `atlas doctor` to find exposed database ports and infrastructure bottlenecks in seconds.

Check out the project: https://github.com/ignatius22/atlas
