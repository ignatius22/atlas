# Changelog

All notable changes to Atlas will be documented in this file.

## [Unreleased]
### Added
- `atlas discover [--write]`: proposes `apps.yml` entries from running containers, grouped by Compose project (works with Coolify and Dokploy). Detects PostgreSQL, MySQL and MariaDB containers with database name and user, and upload volumes and folders on the app's other containers, skipping database data volumes, caches and the Docker socket. Never reads passwords; `--write` inserts new apps inside the `apps:` block, keeps comments, and saves a backup copy.
- External watchdog (heartbeat). After every backup and drill run, Atlas sends a status report (per app: newest backup age, offsite confirmation, last drill; no data or keys) to `ATLAS_HEARTBEAT_URL`. Problems go to `<URL>/fail` (healthchecks.io convention). Pointed at a dead-man's-switch service, this catches a server or timer that stops running, which the server cannot report itself. Optional HMAC signature (`ATLAS_HEARTBEAT_SECRET`). `atlas heartbeat status|send`. The dashboard shows whether it is set up.
- MySQL and MariaDB support (`database.type: mysql` or `mariadb`). Dumps use `--single-transaction` with routines, triggers and events, and read passwords from the container's own environment. The manifest counts rows per table from the dump's INSERT statements (single-line MySQL and multi-line MariaDB formats) and rejects dumps missing the `-- Dump completed` footer. Restore drills run on the production container's image and verify every table; production restores are supported.
- Test-restore containers are checked for readiness over TCP, so a database's temporary init server is never mistaken for the real one.
- File and Docker volume backups. Configure `files.volumes`, `files.paths` and `files.exclude` per app; Atlas writes `<app>-files-<timestamp>.tar.gz` with a manifest (file count, bytes, digest over every file's SHA-256), runs it daily by default (`files.every_hours`), and sends it through the same encryption, offsite confirmation and retention gate as database dumps. Apps without a database are supported.
- The nightly drill verifies files archives by reading every file and comparing with the manifest. `atlas restore files <app> --to=DIR` restores into a new directory and never overwrites live data.
- Dashboard shows a separate "Files and volumes" chain per app; an app is rated by the weaker of its database and files. New `/api/files` endpoint; `/api/status` reports which apps have a database.
- Restore drills that prove backups work. Each backup now writes `<archive>.manifest.json` with its tables and exact row counts, read from the dump's COPY blocks. `atlas restore drill` (and the daily `atlas-drill.timer`, 03:30 UTC) restores the newest backup into a throwaway container, checks every table's row count against the manifest, and records `<archive>.drill.json`. Failures alert via Discord/Slack and show in the dashboard as "Restore failed".
- Test restores use the production container's Postgres image (override with `database.restore_image`) instead of always `postgres:16-alpine`.
- End-to-end drill tests against real PostgreSQL; the CI matrix (14, 15, 16) now actually exercises each version.

### Security
- `bin/atlas` no longer passes arguments through `eval`; app names containing shell syntax (for example `$(...)`) could previously execute commands.

### Changed
- Dashboard rebuilt from scratch in React + TypeScript (`dashboard/web`, built to `dashboard/dist`). It shows each app's chain of custody (dumped, checksummed, encrypted, offsite-confirmed, restore-tested) and a plain-language recovery verdict. The Bootstrap page and the unused Ecme template are removed.
- `/api/backups` now reports `synced` (the `.synced` durability marker) and `modified_epoch` for each backup.
- CLI version is read from the new `VERSION` file (previously hardcoded as 1.0.0).
- Dashboard reads apps only from config and discovered backup directories; hardcoded app names and placeholder "healthy" containers are removed.
- Dashboard resolves the off-site provider from `ATLAS_S3_PROVIDER` or the endpoint instead of always reporting Cloudflare R2.
- Dashboard private-key scan is cached (default 10 minutes, `ATLAS_KEY_SCAN_TTL`) and skips files over 64 KB.
- `scripts/test-offsite-backup.sh` now requires an app name.

### Removed
- `infra/nginx/production/`: live nginx configs for our own sites. They were never read from the repo (the server uses its own copies in `/etc/nginx`). Generic `nginx.conf`, snippets and the app template remain.

### Fixed
- When `pg_dump` or `mysqldump`/`mariadb-dump` fails, `backup.sh` now reports the tool's own error (for example `database "x" does not exist`) instead of only "decompressed SQL stream is empty".
- `atlas-backup.service` wrote `exit $rc`, which systemd expands itself (to empty) before bash runs, so a failed backup followed by a successful sync exited 0 and systemd recorded success. Shell variables in unit files are now written `$$rc`, with a test that keeps them escaped.
- Dashboard reported every database container without a Docker healthcheck as "not found / stopped" on newer Docker versions (Go template error on `.State.Health`). It now reads `docker inspect` JSON.
- `backup.sh` and `sync-offsite.sh` used lock directories in `/tmp`. A crash, `kill -9` or OOM left the directory behind and silently blocked every later backup or sync. They now use kernel locks (`flock`) on `/run/atlas/*.lock`, which the kernel releases when the process dies, as the README always described. Leftover `/tmp/atlas_*.lock.d` directories are ignored.
- Timers no longer declare `Requires=` on their service, which made every timer start or restart (including each deploy) run an extra backup or drill immediately.
- `atlas-backup.service` ran offsite sync only if every app's backup succeeded, so one stopped container blocked all apps from reaching offsite storage. Sync now always runs, and the service still reports failure.
- Backup manifests detect truncated dumps (a COPY block without its terminator) and fail the backup.
- `tests/test-systemd.sh` and `tests/test-notifications-dashboard.sh` are now executable, so `make test` passes locally.

## [1.0.0] - 2026-08-29
### Added
- Unified `atlas` CLI supporting `init`, `doctor`, `backup`, `restore`, `crypto`, and `config`.
- Asymmetric Age encryption envelope for zero-trust off-site replication.
- Ephemeral PostgreSQL restore verification drill engine.
- Declarative `atlas.yml` schema parser with container name regex enforcement.
- Infrastructure Doctor with exposed port scanning and resource pressure diagnostics.
- Comprehensive CI test matrix supporting PostgreSQL 14, 15, and 16.
