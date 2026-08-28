#!/usr/bin/env python3
"""
Atlas V1.1 Production Web Dashboard - Backend Server
Zero-dependency HTTP server utilizing Python 3 standard library.
Binds to localhost:8080 by default for secure access via SSH port forward or reverse proxy.
"""

import os
import sys
import json
import time
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
        with open(ENV_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip("'\"")
                    env[k] = v
    return env

def run_cmd(cmd, timeout=30):
    """Run shell command safely and return exit code, stdout, and stderr."""
    try:
        res = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(BASE_DIR)
        )
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)

def get_system_summary():
    """Retrieve comprehensive system metrics and database container statuses."""
    env = load_env()
    
    # Disk Usage
    disk = shutil.disk_usage("/var/backups" if os.path.exists("/var/backups") else "/")
    disk_total_gb = round(disk.total / (1024 ** 3), 1)
    disk_used_gb = round(disk.used / (1024 ** 3), 1)
    disk_free_gb = round(disk.free / (1024 ** 3), 1)
    disk_pct = round((disk.used / disk.total) * 100, 1)

    # Containers Status
    containers = []
    target_containers = ["catalogflow_postgres", "sand2keys-db", "wdni_prod_postgres"]
    for name in target_containers:
        cmd = f'docker inspect "{name}" --format \'{{"id":"{{{{.Id}}}}","status":"{{{{.State.Status}}}}","started":"{{{{.State.StartedAt}}}}","health":"{{{{if .State.Health}}}}{{{{.State.Health.Status}}}}{{{{else}}}}n/a{{{{end}}}}"}}\''
        code, out, _ = run_cmd(cmd)
        if code == 0 and out.strip():
            try:
                data = json.loads(out.strip())
                data["name"] = name
                data["id_short"] = data["id"][:12]
                containers.append(data)
            except Exception:
                containers.append({"name": name, "status": "unknown", "health": "unknown", "started": ""})
        else:
            containers.append({"name": name, "status": "not found / stopped", "health": "down", "started": ""})

    # Zero-Knowledge Key Scan
    key_cmd = (
        'find /opt/atlas /root /home /etc /var/backups -maxdepth 4 -type f '
        '! -path "*/tests/*" ! -path "*/docs/*" ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/__pycache__/*" '
        '! -name "production-preflight" ! -name "notify.sh" ! -name "restore-offsite.sh" ! -name "server.py" ! -name "README.md" ! -name "*.pyc" '
        '-exec grep -l "AGE-SECRET-KEY" {} + 2>/dev/null | wc -l || echo "0"'
    )
    _, key_out, _ = run_cmd(key_cmd)
    key_count = int(key_out.strip() or 0)

    # Recipient Info
    recipient = env.get("ATLAS_AGE_RECIPIENT", "")
    has_recipient = recipient.startswith("age1") and len(recipient) == 62
    masked_recipient = f"{recipient[:10]}...{recipient[-6:]}" if has_recipient else "Not Configured"

    # Cloud R2 Config
    bucket = env.get("ATLAS_S3_BUCKET", "atlas-production-backups")
    endpoint = env.get("ATLAS_S3_ENDPOINT", "")
    has_r2 = bool(endpoint and env.get("ATLAS_S3_ACCESS_KEY"))

    # Crontab check
    _, cron_out, _ = run_cmd("crontab -l")
    has_cron = "0 */6" in cron_out and "backup.sh --all" in cron_out

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
        "cron": {
            "active": has_cron,
            "rpo": "6 Hours" if has_cron else "24 Hours (Legacy)"
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
    """Query Cloudflare R2 bucket objects via rclone."""
    env = load_env()
    bucket = env.get("ATLAS_S3_BUCKET", "atlas-production-backups")
    endpoint = env.get("ATLAS_S3_ENDPOINT", "")
    key_id = env.get("ATLAS_S3_ACCESS_KEY", "")
    secret_key = env.get("ATLAS_S3_SECRET_KEY", "")

    if not endpoint or not key_id:
        return {"configured": False, "objects": [], "error": "Cloud credentials not configured in .env"}

    cmd = (
        f'export RCLONE_S3_PROVIDER=Cloudflare; '
        f'export RCLONE_S3_ENDPOINT="{endpoint}"; '
        f'export RCLONE_S3_ACCESS_KEY_ID="{key_id}"; '
        f'export RCLONE_S3_SECRET_ACCESS_KEY="{secret_key}"; '
        f'export RCLONE_S3_NO_CHECK_BUCKET=true; '
        f'rclone lsf ":s3:{bucket}/atlas-backups/" --recursive --s3-no-check-bucket'
    )
    code, out, err = run_cmd(cmd, timeout=15)
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

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/status":
            self.send_json(get_system_summary())
        elif parsed.path == "/api/backups":
            self.send_json(get_backups_list())
        elif parsed.path == "/api/offsite":
            self.send_json(get_remote_objects())
        elif parsed.path == "/api/preflight":
            code, out, _ = run_cmd(f"{BASE_DIR}/bin/production-preflight --json", timeout=20)
            try:
                data = json.loads(out.strip())
                self.send_json(data)
            except Exception:
                self.send_json({"error": "Preflight JSON unavailable", "raw": out}, status=500)
        elif parsed.path == "/api/doctor":
            code, out, err = run_cmd(f"{BASE_DIR}/bin/doctor", timeout=20)
            self.send_json({"exit_code": code, "output": out + err})
        else:
            # Fallback to static files
            super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            req_data = json.loads(body)
        except Exception:
            req_data = {}

        if parsed.path == "/api/actions/backup":
            app = req_data.get("app", "--all")
            flag = f"--app {app}" if app != "--all" else "--all"
            code, out, err = run_cmd(f"{BASE_DIR}/scripts/backup.sh {flag}", timeout=60)
            self.send_json({"action": "backup", "exit_code": code, "output": out + err})

        elif parsed.path == "/api/actions/sync":
            app = req_data.get("app", "--all")
            flag = f"--app {app}" if app != "--all" else "--all"
            code, out, err = run_cmd(f"{BASE_DIR}/scripts/sync-offsite.sh {flag}", timeout=60)
            self.send_json({"action": "sync", "exit_code": code, "output": out + err})

        elif parsed.path == "/api/actions/restore-test":
            app = req_data.get("app", "catalogflow")
            cmd = f"{BASE_DIR}/scripts/restore.sh --app {app} --latest --target-env disposable-test"
            code, out, err = run_cmd(cmd, timeout=120)
            self.send_json({"action": "restore-test", "app": app, "exit_code": code, "output": out + err})
        else:
            self.send_json({"error": "Not Found"}, status=404)

    def send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

def main():
    if not PUBLIC_DIR.exists():
        PUBLIC_DIR.mkdir(parents=True, exist_ok=True)
    server_address = (HOST, PORT)
    httpd = HTTPServer(server_address, AtlasDashboardHandler)
    print(f"==================================================")
    print(f" Atlas V1.1 Production Web Dashboard")
    print(f" Listening on: http://{HOST}:{PORT}")
    print(f" Press Ctrl+C to terminate.")
    print(f"==================================================")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping dashboard server...")
        httpd.server_close()

if __name__ == "__main__":
    main()
