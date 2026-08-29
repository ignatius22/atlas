#!/usr/bin/env python3
"""
Atlas V1 — Strict Declarative Configuration & Schema Parser
"""

import sys
import os
import re
import json

vendor_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor")
if os.path.isdir(vendor_dir) and vendor_dir not in sys.path:
    sys.path.insert(0, vendor_dir)

try:
    import yaml
except ImportError:
    sys.stderr.write("[ERROR] PyYAML is required but not installed.\n")
    sys.exit(2)

CONTAINER_REGEX = re.compile(r"^[a-zA-Z0-9_-]+$")

def load_yaml(filepath):
    if not os.path.exists(filepath):
        sys.stderr.write(f"[ERROR] Config file not found: {filepath}\n")
        sys.exit(2)
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
            return data or {}
    except Exception as e:
        sys.stderr.write(f"[ERROR] Malformed YAML in {filepath}: {e}\n")
        sys.exit(2)

def get_apps_dict(data):
    if "applications" in data and isinstance(data["applications"], dict):
        return data["applications"]
    if "apps" in data and isinstance(data["apps"], dict):
        return data["apps"]
    return {}

def validate_config(filepath):
    data = load_yaml(filepath)
    if not isinstance(data, dict):
        sys.stderr.write("[ERROR] Top-level configuration must be a YAML mapping.\n")
        sys.exit(1)

    apps = get_apps_dict(data)
    if not apps:
        sys.stderr.write("[ERROR] No applications defined under 'applications'.\n")
        sys.exit(1)

    for app_id, app in apps.items():
        if not CONTAINER_REGEX.match(app_id):
            sys.stderr.write(f"[ERROR] Invalid application identifier '{app_id}'. Must match ^[a-zA-Z0-9_-]+$\n")
            sys.exit(1)

        db = app.get("database")
        if db and isinstance(db, dict):
            container = db.get("container")
            if container and not CONTAINER_REGEX.match(container):
                sys.stderr.write(f"[ERROR] App '{app_id}' database container '{container}' is invalid. Must match ^[a-zA-Z0-9_-]+$\n")
                sys.exit(1)

    return True

def main():
    if len(sys.argv) < 3:
        sys.stderr.write("Usage: yaml_parser.py <config.yml> <command> [args...]\n")
        sys.exit(2)

    filepath = sys.argv[1]
    cmd = sys.argv[2]
    data = load_yaml(filepath)
    apps = get_apps_dict(data)

    if cmd == "validate":
        validate_config(filepath)
        print("OK")
        sys.exit(0)
    elif cmd == "list_apps":
        print(" ".join(apps.keys()))
        sys.exit(0)
    elif cmd == "get_db_apps":
        db_apps = [k for k, v in apps.items() if isinstance(v, dict) and v.get("database", {}).get("backup") is True]
        print(" ".join(db_apps))
        sys.exit(0)
    elif cmd == "get_db_container":
        app_id = sys.argv[3] if len(sys.argv) > 3 else ""
        print(apps.get(app_id, {}).get("database", {}).get("container", ""))
        sys.exit(0)
    elif cmd == "get_db_user":
        app_id = sys.argv[3] if len(sys.argv) > 3 else ""
        print(apps.get(app_id, {}).get("database", {}).get("user", "postgres"))
        sys.exit(0)
    elif cmd == "get_db_name":
        app_id = sys.argv[3] if len(sys.argv) > 3 else ""
        print(apps.get(app_id, {}).get("database", {}).get("database", ""))
        sys.exit(0)
    elif cmd == "get_retention":
        app_id = sys.argv[3] if len(sys.argv) > 3 else ""
        ret = apps.get(app_id, {}).get("database", {}).get("retention_days")
        if not ret:
            ret = data.get("settings", {}).get("default_retention_days", 14)
        print(ret)
        sys.exit(0)
    elif cmd == "to_json":
        print(json.dumps(data))
        sys.exit(0)
    else:
        sys.stderr.write(f"[ERROR] Unknown command: {cmd}\n")
        sys.exit(2)

if __name__ == "__main__":
    main()
