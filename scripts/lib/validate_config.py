#!/usr/bin/env python3
"""
Check config/apps.yml against what Atlas actually reads.

Usage: validate_config.py <apps.yml>

Prints one line per problem and exits 1 if there are errors. Warnings (keys
Atlas does not read, likely typos) do not fail the check.
"""

import os
import re
import sys

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))
import yaml  # noqa: E402

APP_NAME = re.compile(r"^[a-zA-Z0-9_-]+$")
CONTAINER = re.compile(r"^[a-zA-Z0-9_.-]+$")
IMAGE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$")
DB_TYPES = {"postgres", "postgresql", "mysql", "mariadb", "mongodb", "mongo"}
APP_KEYS = {"name", "directory", "compose_file", "domains", "services", "deployment", "database", "files"}
DB_KEYS = {"type", "container", "name", "user", "backup", "retention_days", "restore_image"}
FILES_KEYS = {"volumes", "paths", "exclude", "every_hours", "retention_days"}


def check(data):
    errors, warnings = [], []
    if not isinstance(data, dict) or not isinstance(data.get("apps"), dict):
        return ["top level must contain an 'apps:' mapping"], warnings
    if not data["apps"]:
        warnings.append("no apps configured yet; run: atlas discover --write")
    for name, app in data["apps"].items():
        where = f"apps.{name}"
        if not APP_NAME.match(str(name)):
            errors.append(f"{where}: app names may only use letters, digits, '-' and '_'")
        if not isinstance(app, dict):
            errors.append(f"{where}: must be a mapping")
            continue
        for key in sorted(set(app) - APP_KEYS):
            warnings.append(f"{where}.{key}: not read by Atlas (typo?)")

        db = app.get("database")
        if db is not None:
            if not isinstance(db, dict):
                errors.append(f"{where}.database: must be a mapping")
            else:
                for key in sorted(set(db) - DB_KEYS):
                    warnings.append(f"{where}.database.{key}: not read by Atlas (typo?)")
                if str(db.get("type", "postgres")).lower() not in DB_TYPES:
                    errors.append(f"{where}.database.type: '{db.get('type')}' is not one of postgres, mysql, mariadb, mongodb")
                if db.get("backup", True) is not False:
                    container = db.get("container")
                    if not container:
                        errors.append(f"{where}.database.container: required (the database container's name)")
                    elif not CONTAINER.match(str(container)):
                        errors.append(f"{where}.database.container: '{container}' is not a valid container name")
                if "restore_image" in db and not IMAGE.match(str(db["restore_image"])):
                    errors.append(f"{where}.database.restore_image: not a valid image reference")
                if "retention_days" in db and not (isinstance(db["retention_days"], int) and db["retention_days"] >= 0):
                    errors.append(f"{where}.database.retention_days: must be a whole number of days")

        files = app.get("files")
        if files is not None:
            if not isinstance(files, dict):
                errors.append(f"{where}.files: must be a mapping")
            else:
                for key in sorted(set(files) - FILES_KEYS):
                    warnings.append(f"{where}.files.{key}: not read by Atlas (typo?)")
                for key in ("volumes", "paths", "exclude"):
                    if key in files and not (isinstance(files[key], list) and all(isinstance(v, str) for v in files[key])):
                        errors.append(f"{where}.files.{key}: must be a list of strings")
                for path in files.get("paths") or []:
                    if isinstance(path, str) and not path.startswith("/"):
                        errors.append(f"{where}.files.paths: '{path}' must be an absolute path")
                if not (files.get("volumes") or files.get("paths")):
                    errors.append(f"{where}.files: list at least one volume or path")
                for key in ("every_hours", "retention_days"):
                    if key in files and not (isinstance(files[key], int) and files[key] >= 0):
                        errors.append(f"{where}.files.{key}: must be a whole number")

        if db is None and files is None:
            warnings.append(f"{where}: has neither a database nor files, so nothing is backed up")
    return errors, warnings


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except (OSError, yaml.YAMLError) as exc:
        print(f"error: cannot read {argv[1]}: {exc}")
        return 1
    errors, warnings = check(data)
    for line in errors:
        print(f"error: {line}")
    for line in warnings:
        print(f"warning: {line}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
