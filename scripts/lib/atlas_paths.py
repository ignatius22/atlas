#!/usr/bin/env python3
"""Where Atlas keeps local backups. The one place that decides it.

Every script that reads or writes archives (backup, sync, drill, restore,
heartbeat, dashboard, doctor) must use this, so they can never disagree. When
they did, a changed storage_dir meant backups were written to one directory
while sync and drills looked in /var/backups, found nothing, and reported
success.

Precedence, first match wins:
  1. ATLAS_BACKUP_DIR           explicit override (tests, one-off runs)
  2. ATLAS_BACKUP_STORAGE_DIR   the setting in /opt/atlas/.env
  3. backup.storage_dir         in config/backup.yml
  4. /var/backups

Shell usage:  python3 -I scripts/lib/atlas_paths.py backup-dir
Python usage: from atlas_paths import backup_dir; backup_dir(env)
"""
import os
import sys

DEFAULT_BACKUP_DIR = "/var/backups"
ATLAS_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class ConfigError(ValueError):
    pass


def _storage_dir_from_yaml(root):
    explicit = os.environ.get("ATLAS_BACKUP_CONFIG_FILE")
    candidates = [explicit] if explicit else []
    candidates += [os.path.join(root, "config", "backup.yml"), os.path.join(root, "config", "backup.yaml")]
    for path in candidates:
        if not path or not os.path.isfile(path):
            continue
        vendor = os.path.join(root, "scripts", "lib", "vendor")
        if vendor not in sys.path:
            sys.path.append(vendor)
        import yaml
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
        value = (data.get("backup") or {}).get("storage_dir") if isinstance(data, dict) else None
        return str(value) if value not in (None, "", "null") else None
    return None


def backup_dir(env=None, root=ATLAS_ROOT):
    """Return the absolute local backup directory, or raise ConfigError."""
    env = os.environ if env is None else env
    value = (env.get("ATLAS_BACKUP_DIR") or env.get("ATLAS_BACKUP_STORAGE_DIR")
             or _storage_dir_from_yaml(root) or DEFAULT_BACKUP_DIR)
    value = value.strip().strip("'\"")
    if not os.path.isabs(value) or ".." in value.split(os.sep):
        raise ConfigError(f"Backup directory must be an absolute path without '..': {value!r}")
    return os.path.normpath(value)


def main(argv):
    if len(argv) != 2 or argv[1] != "backup-dir":
        sys.stderr.write("usage: atlas_paths.py backup-dir\n")
        return 2
    try:
        print(backup_dir())
    except Exception as exc:  # bad value, unreadable or malformed backup.yml
        sys.stderr.write(f"{exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
