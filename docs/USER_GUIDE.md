# Atlas user guide

This guide covers installing Atlas, adding apps, offsite storage, restore drills, alerts, the dashboard and day-to-day operation. For recovering from a lost database or server, see [RECOVERY.md](../RECOVERY.md). When something fails, see [TROUBLESHOOTING.md](../TROUBLESHOOTING.md).

## Contents

1. [Requirements](#1-requirements)
2. [Install](#2-install)
3. [Add your apps](#3-add-your-apps)
4. [Offsite storage and encryption](#4-offsite-storage-and-encryption)
5. [Restore drills](#5-restore-drills)
6. [Watchdog and alerts](#6-watchdog-and-alerts)
7. [Dashboard](#7-dashboard)
8. [What Atlas writes to disk](#8-what-atlas-writes-to-disk)
9. [Schedules, retention and locks](#9-schedules-retention-and-locks)
10. [Upgrade and uninstall](#10-upgrade-and-uninstall)
11. [Command reference](#11-command-reference)

## 1. Requirements

- Linux with systemd (Ubuntu 22.04 or 24.04, Debian 12 and similar)
- Docker, with your databases running in containers
- Python 3 (PyYAML is bundled)
- `age` and `rclone`; the installer adds them on apt, dnf and apk systems
- Root on the server

Atlas does not need inbound ports. The dashboard listens on 127.0.0.1 only.

## 2. Install

```bash
curl -fsSL https://raw.githubusercontent.com/ignatius22/atlas/master/get.sh | sudo bash
```

The installer:

1. Installs Atlas to `/opt/atlas` and the `atlas` command to `/usr/local/bin`.
2. Writes `/opt/atlas/.env` (mode 600) and generates a dashboard token.
3. At a terminal, creates an age keypair, shows you the private key once and keeps only the public key. Save the private key in your password manager before you type `SAVED`: without it, offsite backups cannot be decrypted.
4. Runs `atlas discover` and, after you confirm, adds the apps it finds to `config/apps.yml`.
5. Takes the first backup and runs the first restore drill.
6. Enables `atlas-backup.timer`, `atlas-drill.timer` and the dashboard.
7. Prints what is left to set up.

Options go after `bash -s --`:

| Option | Effect |
| --- | --- |
| `--yes` | Never prompt; accept the discovered apps |
| `--age-recipient=age1...` | Use your own age public key (needed with `--yes`, since the private key cannot be shown safely in a log) |
| `--ref=v1.2.0` | Install a tag or branch instead of `master` |
| `--dir=PATH` | Install somewhere other than `/opt/atlas` |
| `--no-first-run` | Skip the first backup and drill |
| `--no-start` | Do not enable the timers and dashboard |
| `--no-deps` | Do not install packages |
| `--no-discover` | Do not scan containers |

Example of an unattended install with your own key:

```bash
age-keygen -o atlas-key.txt          # on your laptop; keep this file safe
curl -fsSL https://raw.githubusercontent.com/ignatius22/atlas/master/get.sh \
  | sudo bash -s -- --yes --age-recipient=age1...
```

## 3. Add your apps

### Let Atlas find them

```bash
atlas discover           # shows what it would add
atlas discover --write   # adds it to config/apps.yml and keeps a .bak copy
```

Discover groups running containers by Docker Compose project, which also covers Coolify and Dokploy. For each project it proposes:

- the database container (PostgreSQL, MySQL, MariaDB or MongoDB), with the database name and user from the container's environment;
- named volumes and host folders mounted by the project's other containers, such as uploads and storage.

It leaves out database data volumes (the dump covers them), caches, queues, Redis, Certbot folders and the Docker socket. It never reads or prints passwords, and never changes an app that is already in the file. If a configured app has volumes but no `files:` section, it prints the block to paste.

### Or write them by hand

`/opt/atlas/config/apps.yml`:

```yaml
apps:
  shop:
    name: "Shop"
    directory: "/srv/shop"            # optional, used by the deploy helpers
    database:
      type: postgres                  # postgres, mysql, mariadb or mongodb
      container: shop_db              # exact container name
      name: shop                      # database name
      user: shop                      # database user
      backup: true                    # set false to skip the database
      retention_days: 14              # local copies, default 14
      restore_image: postgres:16      # optional; default is the image the container runs
    files:
      volumes: [shop_uploads]         # Docker named volumes
      paths: [/srv/shop/storage]      # host folders
      exclude: ["cache", "*.log"]     # matched against names and relative paths
      every_hours: 24                 # minimum hours between files backups, default 24
      retention_days: 7               # default 7
```

Notes per database:

- **PostgreSQL.** If `user` or `name` is empty, Atlas uses the container's `POSTGRES_USER` and `POSTGRES_DB`. The password comes from `POSTGRES_PASSWORD` inside the container.
- **MySQL and MariaDB.** `name` is required unless the container sets `MYSQL_DATABASE` or `MARIADB_DATABASE`. With `user: root`, the root password variable is used; otherwise `MYSQL_PASSWORD` or `MARIADB_PASSWORD`. Dumps use `--single-transaction`, so InnoDB tables are consistent without locking.
- **MongoDB.** Every database is dumped unless `name` is set. Credentials come from `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD` (or Bitnami's `MONGODB_ROOT_USER` and `MONGODB_ROOT_PASSWORD`).

Passwords are read inside the container and never appear on a command line, in logs or in `apps.yml`.

An app can have a database, files, or both. Check the file with `atlas config validate`, then take a backup:

```bash
atlas backup create shop
atlas backup create --all
```

## 4. Offsite storage and encryption

Local backups protect you from a bad deploy, not from losing the server. Add any S3-compatible bucket in `/opt/atlas/.env`:

```dotenv
ATLAS_S3_BUCKET=my-atlas-backups
ATLAS_S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
ATLAS_S3_ACCESS_KEY=...
ATLAS_S3_SECRET_KEY=...
ATLAS_S3_PROVIDER=Cloudflare      # rclone provider name: Cloudflare, AWS, Backblaze, Minio, Other
```

Cloudflare R2's free tier is enough for most small servers. Give the key access to this one bucket only.

Then upload what is waiting:

```bash
atlas backup sync --all
```

For each archive, Atlas:

1. encrypts it with `ATLAS_AGE_RECIPIENT` (your age public key);
2. uploads it to `atlas-backups/<app>/<year>/<month>/` in the bucket, with up to 3 attempts 5, 10 and 20 seconds apart;
3. lists the object in the bucket and checks its size and recorded checksum;
4. only then writes `<archive>.synced` next to the local file.

The backup timer runs this after every backup. After an outage it uploads every archive still missing, oldest first. List what is offsite with `atlas backup list shop`.

The private key never goes on the server. Atlas encrypts with the public key only, so someone who takes over the server cannot read your offsite backups.

## 5. Restore drills

A drill proves a backup restores. Every night at 03:30 UTC, `atlas-drill.timer` runs one for every app; run one yourself any time:

```bash
atlas restore drill          # every app
atlas restore drill shop     # one app
```

For a database backup, the drill:

1. checks the archive's SHA-256;
2. starts a throwaway container from the same image production runs (or `database.restore_image`);
3. restores the dump into it, stopping at the first error;
4. counts the rows in every table (documents in every collection for MongoDB) and compares them with the manifest written at backup time;
5. writes `<archive>.drill.json` and removes the container.

For a files backup, it reads every file in the archive and compares its size and checksum with the manifest.

A failed drill sends an alert with the reason, for example `public.orders has 1,234 rows, expected 1,300`, and marks the app red in the dashboard. Drills never touch your production database or files.

## 6. Watchdog and alerts

### The watchdog

A server cannot report that it has died. After every backup and drill run, Atlas sends a short report (backup ages, offsite status, drill results; never data or keys) to a dead-man's-switch service. You hear about it when a run finds a problem, and when reports stop arriving.

1. Create a free check at [healthchecks.io](https://healthchecks.io) with a 6-hour period and a 2-hour grace time. Uptime Kuma push monitors and Better Stack heartbeats also work.
2. Add its ping URL to `/opt/atlas/.env`: `ATLAS_HEARTBEAT_URL=https://hc-ping.com/<uuid>`
3. Run `atlas heartbeat send`. The check should turn green.

The report covers the apps in `apps.yml`. It flags: a backup older than 7 hours (26 for files), nothing confirmed offsite, a failed drill, no drill for 48 hours, an app with no backups yet, and a run that exited with an error. Problems go to `<URL>/fail`; set `ATLAS_HEARTBEAT_FAIL_URL` for a different URL. `ATLAS_HEARTBEAT_SECRET` adds an `X-Atlas-Signature: sha256=<HMAC>` header. See the report without sending it with `atlas heartbeat status`.

### Chat alerts

Failures can also go straight to chat. Set any of these in `.env`:

| Variable | Destination |
| --- | --- |
| `ATLAS_DISCORD_WEBHOOK` | Discord channel webhook |
| `ATLAS_SLACK_WEBHOOK` | Slack incoming webhook |
| `ATLAS_TELEGRAM_BOT_TOKEN` and `ATLAS_TELEGRAM_CHAT_ID` | Telegram bot |
| `ATLAS_GENERIC_WEBHOOK` | Any URL that accepts a JSON POST |

Alerts fire on a failed backup, upload or drill. `ATLAS_NOTIFY_SUCCESS=true` also sends successes.

## 7. Dashboard

The dashboard shows each app's chain: dumped, checksummed, encrypted, confirmed offsite, restore-tested, with a plain verdict at the top. It listens on `127.0.0.1:8888` only. From your laptop:

```bash
ssh -N -L 8888:127.0.0.1:8888 you@your-server
# then open http://localhost:8888
```

Viewing needs no token. Running a backup, upload or drill from the page asks once per tab for `ATLAS_DASHBOARD_TOKEN` from `.env`. Do not publish the port to the internet. More in [dashboard/README.md](../dashboard/README.md).

## 8. What Atlas writes to disk

For each app, in `/var/backups/<app>/`:

| File | Written by | Meaning |
| --- | --- | --- |
| `<app>-<UTC time>.sql.gz` | backup | The compressed dump (a mongodump archive for MongoDB, despite the name) |
| `….sql.gz.sha256` | backup | Checksum of the archive |
| `….sql.gz.manifest.json` | backup | Tables and row counts read from the dump |
| `….sql.gz.age`, `….sql.gz.age.sha256` | sync | The encrypted copy that was uploaded, kept until retention removes the archive |
| `….sql.gz.meta.json` | sync | Host, app and checksums, uploaded next to the encrypted copy |
| `….sql.gz.synced` | sync | Present only after the encrypted copy was confirmed in the bucket |
| `….sql.gz.drill.json` | drill | Result of the last drill of this archive |
| `<app>-files-<UTC time>.tar.gz` (+ the same companions) | backup | Files and volumes archive |

In the bucket, each archive is stored under `atlas-backups/<app>/<year>/<month>/` as `<archive>.age` with its `.age.sha256` and `.meta.json`. Retention removes all of an archive's local companions together.

## 9. Schedules, retention and locks

| What | When | Unit |
| --- | --- | --- |
| Backup, then offsite upload, then heartbeat | 00:00, 06:00, 12:00, 18:00 UTC (+ up to 5 min random delay) | `atlas-backup.timer` |
| Restore drills, then heartbeat | 03:30 UTC (+ up to 15 min) | `atlas-drill.timer` |

Both timers use `Persistent=true`: a run missed while the server was off happens when it boots. Check them with `systemctl list-timers 'atlas-*'` and read logs with `journalctl -u atlas-backup -n 100` or `journalctl -u atlas-drill -n 100`.

Files backups run inside the backup service but only every `files.every_hours` (default 24). Force one with `atlas backup create shop --files-now`; skip them with `--skip-files`.

**Retention.** A local archive is deleted when it is older than its `retention_days` **and** has a `.synced` marker. Archives that never reached the bucket are kept, however old, and logged as preserved. Atlas never deletes anything in the bucket; set a lifecycle rule there if you want old copies removed.

**Locks.** Backup, upload and drill each take a kernel lock under `/run/atlas` (set `ATLAS_LOCK_DIR` to move it). A second run of the same kind exits straight away; different kinds run side by side. Locks disappear when the process ends, even if it crashes.

**Without systemd,** run the same commands from cron. Cron does not catch up missed runs:

```cron
0 0,6,12,18 * * * root /opt/atlas/scripts/backup.sh --all; /opt/atlas/scripts/sync-offsite.sh --all
30 3 * * * root /opt/atlas/scripts/drill.sh --all
```

## 10. Upgrade and uninstall

**Upgrade** by running the installer again. It keeps `.env`, `apps.yml` and the dashboard token, and fast-forwards `/opt/atlas` if it is a git checkout.

**Uninstall** with `sudo /opt/atlas/scripts/uninstall.sh`. It removes the timers, services and the `atlas` command, then asks whether to delete `/opt/atlas`. Backups in `/var/backups` and in your bucket are left alone.

## 11. Command reference

| Command | What it does |
| --- | --- |
| `atlas discover [--write]` | Propose, or add, apps from running containers |
| `atlas config validate` | Check `apps.yml` |
| `atlas backup create <app>\|--all [--files-now\|--skip-files\|--files-only]` | Back up now |
| `atlas backup sync <app>\|--all` | Encrypt and upload archives not yet offsite |
| `atlas backup list <app>` | List the app's offsite archives |
| `atlas restore drill [<app>]` | Restore-test the newest backup of one app or all apps |
| `atlas restore test <app>` | Download, decrypt and restore-test an offsite archive (needs the private key) |
| `atlas restore run <app> --target=production [--file=PATH]` | Restore a local archive into production |
| `atlas restore files <app> [--to=DIR]` | Extract a files archive into a new directory |
| `atlas status` | Every app's newest backup, offsite copy and last drill, with any problems |
| `atlas heartbeat status\|send` | Show or send the watchdog report |
| `atlas doctor` | Read-only check of the host, Docker, backups and timers |
| `atlas crypto gen-key` | Print a new age keypair |
| `atlas version` | Show the installed version |
