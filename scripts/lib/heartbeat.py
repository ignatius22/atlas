#!/usr/bin/env python3
"""
Atlas heartbeat: an external watchdog for this server.

Builds a status report from what is on disk (no backup data, no keys) and
sends it to ATLAS_HEARTBEAT_URL. Pointed at a dead-man's-switch service
(healthchecks.io, Uptime Kuma push, Better Stack heartbeats, or Atlas Cloud),
you are alerted when:

  * a run finds a problem: the report goes to the failure URL, and
  * nothing arrives at all: the server, its timers or Atlas itself died.

A server cannot report its own death; this is the part that can.

Environment:
  ATLAS_HEARTBEAT_URL         success ping URL (required to send)
  ATLAS_HEARTBEAT_FAIL_URL    failure ping URL (default: <URL>/fail, the healthchecks.io convention)
  ATLAS_HEARTBEAT_SECRET      optional; adds X-Atlas-Signature: sha256=<hmac of body>
  ATLAS_BACKUP_DIR            default /var/backups
  ATLAS_CONFIG_FILE           apps.yml to report on (default: <atlas>/config/apps.yml).
                              Only configured apps are reported; old folders in the
                              backup directory are ignored. Without a config, every
                              folder there is reported.

Commands:
  report [--event NAME] [--exit-code N]   print the report JSON
  send   [--event NAME] [--exit-code N]   build and send; never fails the caller
"""

import glob
import hashlib
import hmac
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

FORMAT = 1
BACKUP_LATE_HOURS = 7     # 6-hour schedule + slack
FILES_LATE_HOURS = 26     # daily files backups + slack
DRILL_STALE_HOURS = 48    # daily drill + a day of slack


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _newest(paths):
    return max(paths, key=os.path.getmtime) if paths else None


def _archive_state(path, now):
    if not path:
        return None
    manifest = _read_json(f"{path}.manifest.json") or {}
    drill = _read_json(f"{path}.drill.json")
    return {
        "archive": os.path.basename(path),
        "age_hours": round((now - os.path.getmtime(path)) / 3600, 1),
        "bytes": os.path.getsize(path),
        "offsite_confirmed": os.path.exists(f"{path}.synced"),
        "tables": manifest.get("table_count"),
        "rows": manifest.get("total_rows"),
        "files": manifest.get("files"),
    }, drill


def _latest_drill(paths):
    best = None
    for p in paths:
        d = _read_json(f"{p}.drill.json")
        if d and d.get("checked_at") and (best is None or d["checked_at"] > best["checked_at"]):
            best = d
    return best


def load_configured_apps(config_path=None):
    """Apps that should have backups, from apps.yml: {name: expects_backups}. None if no config."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = config_path or os.environ.get("ATLAS_CONFIG_FILE") or os.path.join(root, "config", "apps.yml")
    if not os.path.isfile(path):
        return None
    sys.path.append(os.path.join(root, "scripts", "lib", "vendor"))
    try:
        import yaml

        with open(path, encoding="utf-8") as fh:
            apps = (yaml.safe_load(fh) or {}).get("apps") or {}
    except Exception:  # an unreadable config must not stop the heartbeat
        return None
    if not isinstance(apps, dict):
        return None
    configured = {}
    for name, app in apps.items():
        app = app if isinstance(app, dict) else {}
        db = app.get("database") if isinstance(app.get("database"), dict) else None
        has_db = bool(db) and db.get("backup", True) is not False
        configured[str(name)] = has_db or bool(app.get("files"))
    return configured


def build_report(backup_dir, event, exit_code, now=None, configured=None):
    now = now or time.time()
    apps = []
    problems = []
    if configured is not None:
        names = sorted(configured)
    elif os.path.isdir(backup_dir):
        names = sorted(
            d for d in os.listdir(backup_dir)
            if os.path.isdir(os.path.join(backup_dir, d)) and d not in {"lost+found", "offsite-mock"}
        )
    else:
        names = []

    for app in names:
        base = os.path.join(backup_dir, app)
        db_paths = [p for p in glob.glob(os.path.join(base, f"{app}-*.sql.gz")) if "-files-" not in os.path.basename(p)]
        file_paths = glob.glob(os.path.join(base, f"{app}-files-*.tar.gz"))
        if not db_paths and not file_paths:
            if configured and configured.get(app):
                apps.append({"app": app, "database": None, "files": None})
                problems.append(f"{app}: configured but has no backups yet")
            continue
        entry = {"app": app}
        for kind, paths, late in (("database", db_paths, BACKUP_LATE_HOURS), ("files", file_paths, FILES_LATE_HOURS)):
            if not paths:
                continue
            newest = _newest(paths)
            state, _ = _archive_state(newest, now)
            confirmed = [p for p in paths if os.path.exists(f"{p}.synced")]
            last_confirmed = _newest(confirmed)
            state["last_offsite_age_hours"] = (
                round((now - os.path.getmtime(last_confirmed)) / 3600, 1) if last_confirmed else None
            )
            drill = _latest_drill(paths)
            state["drill"] = None if drill is None else {
                "passed": bool(drill.get("passed")),
                "age_hours": round((now - drill["checked_at"]) / 3600, 1),
                "reason": drill.get("reason") or "",
            }
            entry[kind] = state

            label = app if kind == "database" else f"{app} files"
            if state["age_hours"] > late:
                problems.append(f"{label}: newest backup is {state['age_hours']:.0f} h old")
            if last_confirmed is None:
                problems.append(f"{label}: no copy confirmed offsite")
            elif state["last_offsite_age_hours"] > late:
                problems.append(f"{label}: newest offsite copy is {state['last_offsite_age_hours']:.0f} h old")
            if drill is not None and not drill.get("passed"):
                problems.append(f"{label}: last restore drill failed ({drill.get('reason') or 'see logs'})")
            elif drill is not None and state["drill"]["age_hours"] > DRILL_STALE_HOURS:
                problems.append(f"{label}: last restore drill was {state['drill']['age_hours']:.0f} h ago")
        apps.append(entry)

    if exit_code not in (None, 0):
        problems.insert(0, f"{event or 'run'} exited with code {exit_code}")
    if not apps:
        problems.append("no backups found on this server")

    version = ""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    try:
        with open(os.path.join(root, "VERSION"), encoding="utf-8") as fh:
            version = fh.read().strip()
    except OSError:
        pass

    return {
        "format": FORMAT,
        "host": socket.gethostname(),
        "atlas_version": version,
        "event": event or "manual",
        "exit_code": exit_code,
        "sent_at": int(now),
        "status": "ok" if not problems else "fail",
        "problems": problems,
        "apps": apps,
    }


def send(report, url, fail_url, secret, timeout=10, attempts=3):
    body = json.dumps(report, separators=(",", ":")).encode("utf-8")
    target = url if report["status"] == "ok" else (fail_url or url.rstrip("/") + "/fail")
    headers = {"Content-Type": "application/json", "User-Agent": f"atlas-heartbeat/{report.get('atlas_version') or 'dev'}"}
    if secret:
        sig = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
        headers["X-Atlas-Signature"] = f"sha256={sig}"
    last_error = ""
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(target, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if 200 <= resp.status < 300:
                    return True, f"{report['status']} sent ({resp.status})"
                last_error = f"HTTP {resp.status}"
        except urllib.error.HTTPError as exc:
            last_error = f"HTTP {exc.code}"
        except (urllib.error.URLError, OSError) as exc:
            last_error = str(getattr(exc, "reason", exc))
        time.sleep(2 ** attempt)
    return False, f"heartbeat not delivered: {last_error}"


def main(argv):
    if len(argv) < 2 or argv[1] not in {"report", "send"}:
        sys.stderr.write(__doc__)
        return 2
    event, exit_code = None, None
    args = argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--event" and i + 1 < len(args):
            event = args[i + 1]
            i += 2
        elif args[i] == "--exit-code" and i + 1 < len(args):
            try:
                exit_code = int(args[i + 1])
            except ValueError:
                exit_code = 1
            i += 2
        else:
            sys.stderr.write(f"unknown argument {args[i]}\n")
            return 2

    report = build_report(os.environ.get("ATLAS_BACKUP_DIR", "/var/backups"), event, exit_code,
                          configured=load_configured_apps())
    if argv[1] == "report":
        print(json.dumps(report, indent=2))
        return 0

    url = os.environ.get("ATLAS_HEARTBEAT_URL", "").strip()
    if not url:
        print("heartbeat: ATLAS_HEARTBEAT_URL not set; skipped")
        return 0
    host = urllib.parse.urlparse(url).hostname or ""
    if not url.startswith(("https://", "http://")) or host in {"", "http", "https"} or "://" in url.split("://", 1)[1]:
        print(f"heartbeat: ATLAS_HEARTBEAT_URL looks wrong ({url}); expected e.g. https://hc-ping.com/<uuid>. Skipped.")
        return 0
    ok, message = send(
        report,
        url,
        os.environ.get("ATLAS_HEARTBEAT_FAIL_URL", "").strip() or None,
        os.environ.get("ATLAS_HEARTBEAT_SECRET", "").strip() or None,
    )
    print(f"heartbeat: {message}" + ("" if report["status"] == "ok" else f" — {'; '.join(report['problems'][:3])}"))
    # Never fail the backup or drill because the watchdog was unreachable.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
