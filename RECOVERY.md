# Recovering with Atlas

Pick the case that matches what happened. Each one starts with a test restore, because a restore you have not checked is a guess.

| What happened | Go to |
| --- | --- |
| Bad migration, deleted rows, dropped table; the server is fine | [1. Roll back a database](#1-roll-back-a-database) |
| The database container or its volume is gone; the server is fine | [2. Rebuild a lost database](#2-rebuild-a-lost-database) |
| Uploads or other files were deleted or corrupted | [3. Restore files and volumes](#3-restore-files-and-volumes) |
| The whole server is gone | [4. Rebuild on a new server](#4-rebuild-on-a-new-server) |
| The server was compromised | [5. After a compromise](#5-after-a-compromise) |

## Before you need this

Keep three things somewhere other than the server, for example in your password manager:

1. **The age private key** (`AGE-SECRET-KEY-1...`). Without it the offsite backups cannot be decrypted, by you or anyone else.
2. **A copy of `/opt/atlas/.env`**: bucket name, endpoint and credentials.
3. **A copy of `/opt/atlas/config/apps.yml`**.

Then check once that you can actually decrypt an offsite backup (section 4, step 4, with `--target=test`). This is the one check Atlas cannot run for you, because the key is not on the server.

## 1. Roll back a database

List the local archives and pick the last good one:

```bash
ls -lt /var/backups/shop/*.sql.gz
```

Check it restores, without touching production:

```bash
atlas restore drill shop                                         # newest archive
./scripts/restore.sh --app=shop --target=test --file=/var/backups/shop/shop-20261020T060000Z.sql.gz
```

Restore it into production:

```bash
atlas restore run shop --target=production --file=/var/backups/shop/shop-20261020T060000Z.sql.gz
```

Atlas first takes a safety backup of the current database (so this step can itself be undone), then asks you to type `CONFIRM-RESTORE-TO-PRODUCTION`. How the data is replaced:

- **PostgreSQL:** the dump drops and recreates each object, applied in one transaction that stops at the first error, so a failed restore changes nothing.
- **MySQL and MariaDB:** the dump drops and recreates each table, stopping at the first error. Tables already restored before an error stay restored.
- **MongoDB:** each collection in the archive is dropped and restored. Collections that are not in the archive are left alone.

The app keeps running during the restore. Stop it first (`docker compose stop web`) if writes during the restore would cause trouble, and start it again after.

Restoring a database does not undo code. If a migration caused the problem, roll the code back too.

## 2. Rebuild a lost database

Start a fresh, empty database container with the same name, image and credentials as before, usually by bringing the app's Compose stack up again:

```bash
cd /srv/shop && docker compose up -d db
```

Wait until it accepts connections, then restore the newest local archive as in section 1:

```bash
atlas restore run shop --target=production
```

If the local archives went down with the volume, restore from the bucket instead (section 4, step 4).

## 3. Restore files and volumes

Files are restored into a new directory first, never over live data:

```bash
atlas restore files shop                          # newest archive, into /var/restore/<archive name>
atlas restore files shop --to=/var/restore/shop --file=/var/backups/shop/shop-files-20261020T000000Z.tar.gz
```

The checksum is verified before anything is written. The output lists each volume and folder it restored. Look through them, then copy back what you need:

```bash
# a Docker volume
rsync -a /var/restore/shop/volumes/shop_uploads/ "$(docker volume inspect -f '{{.Mountpoint}}' shop_uploads)/"
# a host folder
rsync -a /var/restore/shop/paths/<label>/ /srv/shop/storage/
```

Add `--delete` to rsync only if you want files created since the backup removed. Stop the app first if it writes to these files.

## 4. Rebuild on a new server

Atlas restores your data. Getting your apps running again (code, Compose files, app `.env` files, DNS, TLS) is up to your usual deploy process.

1. **Provision a server** with Docker, and point DNS at it when you are ready.
2. **Start your apps' containers**, including empty databases created with the same container names and credentials as before.
3. **Install Atlas without the first run**, using the same public key as before:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/ignatius22/atlas/master/get.sh \
     | sudo bash -s -- --yes --no-first-run --no-start --age-recipient=age1...
   ```

   Then copy your saved `.env` over `/opt/atlas/.env` (keep mode 600) and your saved `apps.yml` into `/opt/atlas/config/`.

4. **Check the offsite backup, then restore it.** For each app, list what is in the bucket, test-restore the newest archive, then restore it into production:

   ```bash
   atlas backup list shop
   sudo ATLAS_AGE_IDENTITY="AGE-SECRET-KEY-1..." /opt/atlas/scripts/restore-offsite.sh --app=shop --target=test
   sudo ATLAS_AGE_IDENTITY="AGE-SECRET-KEY-1..." /opt/atlas/scripts/restore-offsite.sh --app=shop --target=production
   ```

   Use `--key-file=/path/to/key.txt` instead of the variable if you prefer, and `--file=<name>` to pick an older archive. The key is written only to a private temporary file and removed afterwards. Clear your shell history afterwards if you pasted it.

5. **Restore files archives** from the bucket by hand (the offsite restore handles databases only). With the bucket settings from `.env`:

   ```bash
   export RCLONE_S3_PROVIDER=Cloudflare RCLONE_S3_ENDPOINT=... RCLONE_S3_ACCESS_KEY_ID=... RCLONE_S3_SECRET_ACCESS_KEY=...
   rclone lsf ":s3:my-atlas-backups/atlas-backups/shop/" --recursive | grep files-
   rclone copyto ":s3:my-atlas-backups/atlas-backups/shop/2026/10/shop-files-20261020T000000Z.tar.gz.age" ./shop-files.tar.gz.age
   age -d -i key.txt -o shop-files.tar.gz shop-files.tar.gz.age
   atlas restore files shop --file="$PWD/shop-files.tar.gz" --to=/var/restore/shop
   ```

   Then copy the files into place as in section 3.

6. **Turn protection back on:** `sudo systemctl enable --now atlas-backup.timer atlas-drill.timer`, then `atlas restore drill` and `atlas heartbeat send`.

## 5. After a compromise

Assume everything on the server is known to the attacker: database passwords, the bucket credentials in `.env`, the dashboard token. The offsite backups stay unreadable to them because the private key was never on the server, but they could delete objects if the bucket key allows it.

1. Rebuild on a new server (section 4) rather than cleaning the old one.
2. Create new bucket credentials and revoke the old ones. Rotate every database and app secret.
3. Restore from an archive taken **before** the compromise. Check its contents in a test restore before you trust it.
4. To keep a compromised server from deleting backups in future, give Atlas a bucket key that can write but not delete, and turn on object lock or versioning in the bucket. Atlas works with both.

**If the private key is lost** (as opposed to stolen), existing offsite backups cannot be decrypted by anyone. Generate a new keypair with `age-keygen`, put the new public key in `ATLAS_AGE_RECIPIENT`, and run a backup and sync straight away. Local archives on the server are unencrypted and still restorable.
