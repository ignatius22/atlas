# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: on the repository page, open **Security**, then **Report a vulnerability**. Do not open a public issue. We aim to reply within 3 working days and will credit you in the changelog unless you would rather we didn't.

## What Atlas protects, and how

Atlas runs as root on your server, because it needs `docker exec` into your database containers and read access to your volumes. It is built so that the server is never the only thing standing between an attacker and your backups.

| Risk | What Atlas does |
| --- | --- |
| Someone takes over the server and reads your offsite backups | Archives are encrypted on the server with your age **public** key before upload. The private key is never on the server, so a compromised server cannot decrypt anything in the bucket. |
| Someone takes over the server and deletes your offsite backups | Atlas never deletes from the bucket, so its credentials only need write access. Use a key without delete permission, and turn on versioning or object lock in the bucket. |
| A failed upload leads to local copies being pruned | A local archive is deleted only after its encrypted copy has been confirmed in the bucket (the `.synced` marker). |
| A backup looks fine but cannot be restored | Daily restore drills restore every backup in a throwaway container and compare row counts with what was dumped. |
| Database passwords leak into logs or process lists | Passwords are read inside each container from the image's own variables and passed through the environment or a private config file, never on a command line. Atlas does not store them. |
| The dashboard becomes a way in | It binds to `127.0.0.1` only. Reading needs no token; every action requires `ATLAS_DASHBOARD_TOKEN`, compared in constant time. Actions run fixed commands with argument lists (no shell), and app names are checked against `^[a-zA-Z0-9_-]+$`. |
| Malicious input in `apps.yml` or arguments | App and container names are checked against strict patterns everywhere they are used, and the CLI never passes arguments through `eval`. `tests/test-adversarial.sh` covers injection and path traversal. |
| A restore overwrites good data by mistake | Drills never touch production. A production restore takes a safety backup first and needs a typed confirmation. Files are restored into a new directory, never over live data. |
| A restore extracts files outside its target | Files archives are checked before extraction; absolute paths, `..` and links pointing outside the target are refused. |

## What you are responsible for

- **Keep the private key and a copy of `.env` off the server**, for example in a password manager. See [RECOVERY.md](RECOVERY.md).
- **Keep `/opt/atlas/.env` at mode 600.** It holds the bucket credentials and dashboard token. The installer sets this.
- **Do not publish the dashboard port.** Reach it through an SSH tunnel.
- **Keep the host patched**, and SSH key-only. `atlas doctor` checks, read-only, whether SSH allows passwords or root logins and whether the firewall is on. Never publish database ports to the internet.

## Supported versions

Security fixes go into the latest release. Upgrade by running the installer again; it keeps your settings.
