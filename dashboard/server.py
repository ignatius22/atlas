#!/usr/bin/env python3
"""
Atlas V1.1 Production Web Dashboard - Hardened Backend Server
Zero-dependency HTTP server utilizing Python 3 standard library.
Binds to 127.0.0.1 by default for secure access via SSH port forward or reverse proxy.
"""

import os
import sys
import re
import json
import time
import hmac
import shutil
import subprocess
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
PUBLIC_DIR = Path(__file__).resolve().parent / "public"
ENV_FILE = BASE_DIR / ".env"
APPS_FILE = BASE_DIR / "config" / "apps.yml"

PORT = int(os.environ.get("ATLAS_DASHBOARD_PORT", 8888))
HOST = os.environ.get("ATLAS_DASHBOARD_HOST", "127.0.0.1")

def load_env():
    """Safely parse .env file without executing shell code."""
    env = {}
    if ENV_FILE.exists():
        try:
            with open(ENV_FILE, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip("'\"")
                        env[k] = v
        except Exception:
            pass
    return env

def run_cmd(args, timeout=30, env=None):
    """
    Run subprocess safely without shell=True.
    Accepts list of arguments and returns exit code, stdout, and stderr.
    """
    if isinstance(args, str):
        args = [args]
    try:
        res = subprocess.run(
            args,
            shell=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(BASE_DIR),
            env=env
        )
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)

def validate_app_name(app_val, allow_all=True):
    """
    Validate application identifier against strict alphanumeric allowlist.
    Rejects any shell metacharacters or unexpected structures.
    """
    if app_val is None:
        return False, None, "Missing app parameter"
    if not isinstance(app_val, str):
        return False, None, "Application parameter must be a string"
    app_str = app_val.strip()
    if not app_str:
        return False, None, "Application parameter cannot be empty"
    if app_str == "--all":
        if allow_all:
            return True, "--all", ""
        else:
            return False, None, "--all is not permitted for this action"
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$", app_str):
        return False, None, "Invalid application identifier format. Only alphanumeric, dashes, and underscores allowed."
    return True, app_str, ""

def get_system_summary():
    """Retrieve comprehensive system metrics and database container statuses."""
    env = load_env()
    
    # Disk Usage
    disk = shutil.disk_usage("/var/backups" if os.path.exists("/var/backups") else "/")
    disk_total_gb = round(disk.total / (1024 ** 3), 1)
    disk_used_gb = round(disk.used / (1024 ** 3), 1)
    disk_free_gb = round(disk.free / (1024 ** 3), 1)
    disk_pct = round((disk.used / disk.total) * 100, 1) if disk.total > 0 else 0

    # Containers Status
    containers = []
    target_containers = ["catalogflow_postgres", "sand2keys-db", "wdni_prod_postgres"]
    fmt = '{"id":"{{.Id}}","status":"{{.State.Status}}","started":"{{.State.StartedAt}}","health":"{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}"}'
    for name in target_containers:
        code, out, _ = run_cmd(["docker", "inspect", name, "--format", fmt], timeout=10)
        if code == 0 and out.strip():
            try:
                data = json.loads(out.strip())
                data["name"] = name
                data["id_short"] = data["id"][:12] if "id" in data and data["id"] else ""
                containers.append(data)
            except Exception:
                containers.append({"name": name, "status": "unknown", "health": "unknown", "started": ""})
        else:
            containers.append({"name": name, "status": "not found / stopped", "health": "down", "started": ""})

    # Zero-Knowledge Key Scan (Pure Python traversal, zero shell execution)
    key_count = 0
    scan_dirs = ["/opt/atlas", "/root", "/home", "/etc", "/var/backups"]
    for sdir in scan_dirs:
        p = Path(sdir)
        if p.exists():
            try:
                for root, dirs, files in os.walk(str(p)):
                    dirs[:] = [d for d in dirs if d not in {".git", "tests", "docs", "node_modules", "__pycache__"}]
                    for fname in files:
                        if fname in {"production-preflight", "notify.sh", "restore-offsite.sh", "server.py", "README.md"} or fname.endswith(".pyc"):
                            continue
                        fpath = os.path.join(root, fname)
                        try:
                            with open(fpath, "r", encoding="utf-8", errors="ignore") as f_obj:
                                if "AGE-SECRET-KEY" in f_obj.read():
                                    key_count += 1
                        except Exception:
                            pass
            except Exception:
                pass

    # Recipient Info
    recipient = env.get("ATLAS_AGE_RECIPIENT", "")
    has_recipient = recipient.startswith("age1") and len(recipient) == 62
    masked_recipient = f"{recipient[:10]}...{recipient[-6:]}" if has_recipient else "Not Configured"

    # Cloud R2 Config
    bucket = env.get("ATLAS_S3_BUCKET", "atlas-production-backups")
    endpoint = env.get("ATLAS_S3_ENDPOINT", "")
    has_r2 = bool(endpoint and env.get("ATLAS_S3_ACCESS_KEY"))

    # Scheduler check: test systemd timer first, then crontab fallback
    has_systemd_timer = False
    systemd_code, systemd_out, _ = run_cmd(["systemctl", "is-active", "atlas-backup.timer"], timeout=5)
    if systemd_code == 0 and "active" in systemd_out.lower():
        has_systemd_timer = True

    _, cron_out, _ = run_cmd(["crontab", "-l"], timeout=5)
    has_cron = ("0 */6" in cron_out or "0 0,6,12,18" in cron_out) and "backup.sh --all" in cron_out

    scheduler_type = "systemd" if has_systemd_timer else ("cron" if has_cron else "none")
    scheduler_active = has_systemd_timer or has_cron

    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": os.uname().nodename,
        "os": " ".join(os.uname()[:3]),
        "disk": {
            "total_gb": disk_total_gb,
            "used_gb": disk_used_gb,
            "free_gb": disk_free_gb,
            "percent": disk_pct
        },
        "containers": containers,
        "security": {
            "private_keys_on_vps": key_count,
            "zero_knowledge_intact": (key_count == 0),
            "recipient_configured": has_recipient,
            "recipient_masked": masked_recipient
        },
        "offsite": {
            "provider": "Cloudflare R2",
            "bucket": bucket,
            "configured": has_r2
        },
        "scheduler": {
            "type": scheduler_type,
            "active": scheduler_active,
            "rpo": "6 Hours" if scheduler_active else "Unscheduled"
        },
        "cron": {
            "active": scheduler_active,
            "rpo": "6 Hours" if scheduler_active else "24 Hours (Legacy)"
        }
    }

def get_backups_list():
    """List all local backup files across applications."""
    apps = ["catalogflow", "sand2keys", "wdni"]
    result = {}

    for app in apps:
        app_dir = Path(f"/var/backups/{app}")
        backups = []
        if app_dir.exists():
            for f in sorted(app_dir.glob(f"{app}-*.sql.gz"), reverse=True):
                sha_file = Path(f"{f}.sha256")
                age_file = Path(f"{f}.age")
                meta_file = Path(f"{f}.meta.json")

                sha = ""
                if sha_file.exists():
                    try:
                        sha = sha_file.read_text().split()[0]
                    except Exception:
                        pass

                meta = {}
                if meta_file.exists():
                    try:
                        meta = json.loads(meta_file.read_text())
                    except Exception:
                        pass

                backups.append({
                    "filename": f.name,
                    "size_bytes": f.stat().st_size,
                    "size_human": f"{round(f.stat().st_size / 1024, 1)} KB",
                    "modified": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(f.stat().st_mtime)),
                    "sha256": sha,
                    "sha256_short": sha[:12] + "..." if sha else "",
                    "has_age": age_file.exists(),
                    "age_size_bytes": age_file.stat().st_size if age_file.exists() else 0,
                    "metadata": meta
                })
        result[app] = backups
    return result

def get_remote_objects():
    """Query Cloudflare R2 bucket objects via rclone without shell interpolation."""
    env = load_env()
    bucket = env.get("ATLAS_S3_BUCKET", "atlas-production-backups")
    endpoint = env.get("ATLAS_S3_ENDPOINT", "")
    key_id = env.get("ATLAS_S3_ACCESS_KEY", "")
    secret_key = env.get("ATLAS_S3_SECRET_KEY", "")

    if not endpoint or not key_id:
        return {"configured": False, "objects": [], "error": "Cloud credentials not configured in .env"}

    env_vars = os.environ.copy()
    env_vars.update({
        "RCLONE_S3_PROVIDER": "Cloudflare",
        "RCLONE_S3_ENDPOINT": endpoint,
        "RCLONE_S3_ACCESS_KEY_ID": key_id,
        "RCLONE_S3_SECRET_ACCESS_KEY": secret_key,
        "RCLONE_S3_NO_CHECK_BUCKET": "true"
    })

    args = ["rclone", "lsf", f":s3:{bucket}/atlas-backups/", "--recursive", "--s3-no-check-bucket"]
    code, out, err = run_cmd(args, env=env_vars, timeout=15)
    if code != 0:
        return {"configured": True, "objects": [], "error": err.strip() or "R2 listing failed"}

    lines = [line.strip() for line in out.strip().split("\n") if line.strip() and not line.endswith("/")]
    return {
        "configured": True,
        "bucket": bucket,
        "total_objects": len(lines),
        "objects": lines
    }

class AtlasDashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(PUBLIC_DIR), **kwargs)

    def check_auth(self):
        """
        Verify X-Atlas-Token header for mutating actions.
        Uses constant-time comparison against configured ATLAS_DASHBOARD_TOKEN.
        """
        env = load_env()
        expected_token = os.environ.get("ATLAS_DASHBOARD_TOKEN") or env.get("ATLAS_DASHBOARD_TOKEN")
        if not expected_token:
            return False, "Server authentication token not configured. Set ATLAS_DASHBOARD_TOKEN in environment or .env."
        
        token = self.headers.get("X-Atlas-Token", "")
        if not token:
            return False, "Missing required X-Atlas-Token authentication header."
        
        if not hmac.compare_digest(token.strip(), expected_token.strip()):
            return False, "Invalid X-Atlas-Token."
        
        return True, ""

    def do_OPTIONS(self):
        """Handle preflight requests without wildcard CORS."""
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            self.send_json({"status": "ok", "service": "atlas-dashboard", "host": HOST, "port": PORT})
        elif parsed.path == "/api/status":
            self.send_json(get_system_summary())
        elif parsed.path == "/api/backups":
            self.send_json(get_backups_list())
        elif parsed.path == "/api/offsite":
            self.send_json(get_remote_objects())
        elif parsed.path == "/api/preflight":
            code, out, _ = run_cmd([str(BASE_DIR / "bin" / "production-preflight"), "--json"], timeout=20)
            try:
                data = json.loads(out.strip())
                self.send_json(data)
            except Exception:
                self.send_json({"error": "Preflight JSON unavailable", "raw": out}, status=500)
        elif parsed.path == "/api/doctor":
            code, out, err = run_cmd([str(BASE_DIR / "bin" / "doctor")], timeout=20)
            self.send_json({"exit_code": code, "output": (out + err).strip()})
        else:
            # Fallback to static files
            super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        content_length = int(self.headers.get("Content-Length", 0))
        
        if content_length > 1024 * 1024:  # 1MB max body limit
            self.send_json({"error": "Payload too large"}, status=413)
            return

        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            req_data = json.loads(body)
            if not isinstance(req_data, dict):
                self.send_json({"error": "Malformed JSON: body must be a JSON object"}, status=400)
                return
        except Exception:
            self.send_json({"error": "Malformed or invalid JSON payload"}, status=400)
            return

        # Enforce authentication for all mutating actions
        if parsed.path in {"/api/actions/backup", "/api/actions/sync", "/api/actions/restore-test"}:
            is_authed, auth_err = self.check_auth()
            if not is_authed:
                self.send_json({"error": auth_err}, status=401)
                return

        if parsed.path == "/api/actions/backup":
            raw_app = req_data.get("app", "--all")
            valid, app, err = validate_app_name(raw_app, allow_all=True)
            if not valid:
                self.send_json({"error": err}, status=400)
                return

            args = [str(BASE_DIR / "scripts" / "backup.sh")]
            if app != "--all":
                args.extend(["--app", app])
            else:
                args.append("--all")

            code, out, err = run_cmd(args, timeout=120)
            self.send_json({"action": "backup", "exit_code": code, "output": (out + err).strip()})

        elif parsed.path == "/api/actions/sync":
            raw_app = req_data.get("app", "--all")
            valid, app, err = validate_app_name(raw_app, allow_all=True)
            if not valid:
                self.send_json({"error": err}, status=400)
                return

            args = [str(BASE_DIR / "scripts" / "sync-offsite.sh")]
            if app != "--all":
                args.extend(["--app", app])
            else:
                args.append("--all")

            code, out, err = run_cmd(args, timeout=120)
            self.send_json({"action": "sync", "exit_code": code, "output": (out + err).strip()})

        elif parsed.path == "/api/actions/restore-test":
            raw_app = req_data.get("app")
            valid, app, err = validate_app_name(raw_app, allow_all=False)
            if not valid:
                self.send_json({"error": err or "Application name required for restore-test"}, status=400)
                return

            args = [str(BASE_DIR / "scripts" / "restore.sh"), "--app", app, "--target=test"]
            code, out, err = run_cmd(args, timeout=180)
            self.send_json({"action": "restore-test", "app": app, "exit_code": code, "output": (out + err).strip()})

        else:
            self.send_json({"error": "Not Found"}, status=404)

    def send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # Restrict CORS to same-origin
        self.end_headers()
        self.wfile.write(body)

def main():
    env = load_env()
    token = os.environ.get("ATLAS_DASHBOARD_TOKEN") or env.get("ATLAS_DASHBOARD_TOKEN")
    if not token or not token.strip():
        sys.stderr.write("CRITICAL ERROR: ATLAS_DASHBOARD_TOKEN is not configured in environment or .env.\n")
        sys.stderr.write("The Atlas Dashboard refuses to start without authentication configured.\n")
        sys.exit(1)

    if not PUBLIC_DIR.exists():
        PUBLIC_DIR.mkdir(parents=True, exist_ok=True)
    server_address = (HOST, PORT)
    httpd = HTTPServer(server_address, AtlasDashboardHandler)
    print(f"==================================================")
    print(f" Atlas V1.1 Production Web Dashboard")
    print(f" Listening on: http://{HOST}:{PORT}")
    print(f" Bound to localhost (127.0.0.1) for secure access.")
    print(f" Authentication enforced via ATLAS_DASHBOARD_TOKEN.")
    print(f" Press Ctrl+C to terminate.")
    print(f"==================================================")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping dashboard server...")
        httpd.server_close()

if __name__ == "__main__":
    main()
