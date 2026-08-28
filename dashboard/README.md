# Atlas V1.1 Production Web Dashboard

The **Atlas Web Dashboard** is a zero-dependency, real-time control center and visual explorer for Atlas production backups, zero-knowledge encryption, and Cloudflare R2 off-site replication.

---

## Features

* **Live Database & Container Health Cards:** Real-time metrics, status, and health checks for `catalogflow_postgres`, `sand2keys-db`, and `wdni_prod_postgres`.
* **Local Encrypted Backups Explorer:** Filter backups by application, view size, timestamp, SHA-256 checksums (with 1-click copy), and age encryption badges.
* **Cloudflare R2 Remote Explorer:** Real-time browser of encrypted objects in `atlas-production-backups` (`.age`, `.sha256`, `.meta.json`).
* **Interactive Disaster Recovery Controls:**
  * One-click manual backup trigger (`backup.sh --all`)
  * One-click Cloudflare R2 sync trigger (`sync-offsite.sh --all`)
  * One-click non-destructive disposable container restore drill (`restore.sh --target-env disposable-test`)
  * One-click production preflight diagnostic viewer
* **Security Matrix:** Verifies zero private keys on the host, displays public age recipient key, and confirms IP whitelisting.

---

## How to Run & Access the Dashboard

### 1. Launch on VPS

To start the dashboard manually on the VPS:
```bash
/opt/atlas/bin/atlas-dashboard 8888
```

To install as a background `systemd` service:
```bash
cp /opt/atlas/infra/atlas-dashboard.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now atlas-dashboard
systemctl status atlas-dashboard
```

---

### 2. Securely Access from Your Local Machine (SSH Port Forward)

Because the dashboard binds to `127.0.0.1` (localhost) for maximum security, you can access it from your local machine over an encrypted SSH tunnel:

```bash
# On your local machine / laptop:
ssh -N -L 8888:127.0.0.1:8888 root@153.75.251.207
```

Then open your browser and navigate to:
```text
http://localhost:8888
```

---

## Architecture & Security

* **Zero External Port Exposure:** The dashboard runs on `127.0.0.1:8888` and is not exposed to the public internet.
* **Zero Pip / NPM Dependencies:** The backend uses pure Python 3 standard library (`http.server`, `subprocess`, `json`, `pathlib`).
* **Zero Credential Exposure:** All tokens, secrets, and private keys are redacted from API responses and the UI.
