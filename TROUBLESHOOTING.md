# Troubleshooting

Start with these three. Between them they explain most problems:

```bash
atlas status                                  # each app: newest backup, offsite copy, last drill, problems
journalctl -u atlas-backup -n 100 --no-pager  # last backup and upload run
journalctl -u atlas-drill -n 100 --no-pager   # last restore drill
```

Search this page for the message you see.

## Backups

**`Database container 'x' was not found on this host`** or **`is not running`**
The name in `apps.yml` does not match a running container. Compare with `docker ps --format '{{.Names}}'`. Coolify and Dokploy sometimes add a suffix that changes on redeploy; run `atlas discover` to see the current name.

**`pg_dump failed for 'x': ...`**, **`mysql dump failed for 'x': ...`**, **`mongodump failed for 'x': ...`**
The rest of the line is the database tool's own error. The usual ones:
- `database "x" does not exist`: set `database.name` to the real name (`docker exec <container> psql -U <user> -l`).
- `role "x" does not exist` or `Access denied for user`: set `database.user`. For MySQL, use `root` if the container sets `MYSQL_ROOT_PASSWORD`; for other users Atlas reads `MYSQL_PASSWORD`.
- `Authentication failed` (MongoDB): the container must set `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD` (or Bitnami's `MONGODB_ROOT_*`).

**`No database name for 'x'. Set database.name in apps.yml.`**
MySQL and MariaDB need the database name, either in `apps.yml` or in the container's `MYSQL_DATABASE` / `MARIADB_DATABASE`.

**`Backup verification failed: ... truncated or unreadable`** or **`... empty or too small`**
The dump stopped part way, usually because the disk is full or the database container restarted during the dump. Check `df -h /var/backups`, then run `atlas backup create <app>` again. The failed file was discarded; your previous backups are untouched.

**`Docker volume 'x' for 'y' was not found`** or **`Directory '...' does not exist`**
A `files:` entry points at something that is not there. Check `docker volume ls` and fix `apps.yml`, then run `atlas config validate`.

**`Another Atlas backup process is currently running`**
A backup is already running; this run exited without doing anything. If no backup is running (`pgrep -af backup.sh`), it is safe to run again: kernel locks are released when a process ends, so they cannot be left behind.

**The disk keeps filling up**
Archives that have not reached the bucket are never deleted, by design. Look for `PRESERVING un-replicated backup` in the backup log. Fix offsite uploads (below) and the backlog uploads and then ages out normally. Lower `retention_days` only after that.

## Offsite uploads

**`Client-side encryption key (ATLAS_AGE_RECIPIENT) is not configured`**
Set your age public key in `/opt/atlas/.env`, or run the installer again with `--age-recipient=age1...`.

**`Off-site sync failed after 3 attempts`**
The bucket rejected the upload or could not be reached. Test the credentials directly:

```bash
set -a; . /opt/atlas/.env; set +a
RCLONE_S3_PROVIDER="${ATLAS_S3_PROVIDER:-Cloudflare}" RCLONE_S3_ENDPOINT="$ATLAS_S3_ENDPOINT" \
RCLONE_S3_ACCESS_KEY_ID="$ATLAS_S3_ACCESS_KEY" RCLONE_S3_SECRET_ACCESS_KEY="$ATLAS_S3_SECRET_KEY" \
  rclone lsf ":s3:$ATLAS_S3_BUCKET/" --s3-no-check-bucket
```

`AccessDenied` means wrong keys or no permission on this bucket; `no such host` means a wrong endpoint. For AWS S3 set `ATLAS_S3_PROVIDER=AWS`. Once fixed, `atlas backup sync --all` uploads everything still missing.

## Restore drills

**`Restored data does not match the backup: public.orders has 1,234 rows, expected 1,300`**
The backup restored, but with less data than it was supposed to contain. Take this seriously: run `atlas backup create <app>` and `atlas restore drill <app>` again. If a fresh backup fails the same way, the dump is losing data (often a table the dump user cannot read). Open an issue with the drill log.

**`SQL error while restoring: ...`**
The dump does not restore cleanly. Common causes: an extension or role that exists in production but not in a fresh container (`ERROR: extension "x" is not available`), or a dump from a newer server than the drill image. Set `database.restore_image` to an image with the same version and extensions as production, for example `postgis/postgis:16-3.4`.

**`Temporary database did not accept connections within N seconds`**
The throwaway container did not start in time, usually on a busy or small server. Check `docker logs` for a container named `atlas_restore_test_*` while a drill runs, and free some memory. The drill retries at the next schedule.

**`Could not start a temporary database from image x`**
The image cannot be pulled (rate limit, private registry) or does not exist. Pull it once by hand, or set `database.restore_image`.

**`Another restore drill is already running`**
Only one drill runs at a time. Wait for it, or check `systemctl status atlas-drill`.

## Watchdog

**`heartbeat: ATLAS_HEARTBEAT_URL not set; skipped`**: add the URL to `.env` (see the [user guide](docs/USER_GUIDE.md#6-watchdog-and-alerts)).

**`heartbeat: ATLAS_HEARTBEAT_URL looks wrong`**: usually a doubled `https://`. It should look like `https://hc-ping.com/<uuid>`.

**`heartbeat not delivered: ...`**: the server could not reach the watchdog. Backups are not affected. Check `curl -I https://hc-ping.com`.

**The check is red but backups look fine**: open the check's last ping on healthchecks.io. Its body lists each problem, for example `shop: no copy confirmed offsite`. `atlas status` shows the same report.

## Dashboard

**It does not start**: `journalctl -u atlas-dashboard -n 50`. `ATLAS_DASHBOARD_TOKEN is not configured` means `.env` has no token. Running the installer again creates one.

**`localhost:8888` refuses to connect on your laptop**: the SSH tunnel is not running. Start it with `ssh -N -L 8888:127.0.0.1:8888 you@your-server` and keep that terminal open.

**It shows an old version after an upgrade**: `sudo systemctl restart atlas-dashboard`, then reload the page.

## Still stuck

Run `atlas doctor` (read-only) and open an issue with its output and the relevant journal lines. Remove hostnames and bucket names if you prefer.
