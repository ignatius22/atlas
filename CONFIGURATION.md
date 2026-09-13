# Configuration Reference

Atlas uses declarative YAML configurations (`config/apps.yml` or `atlas.yml`) alongside a secure root-only environment file (`/opt/atlas/.env`, mode `0600`).

---

## 1. Declarative Application Registry (`config/apps.yml`)

```yaml
version: "1"

settings:
  backup_dir: "/var/backups"          # Base directory for local backups
  default_retention_days: 14          # Days before verified local backups are pruned
  compression_level: 9                # gzip compression level (1-9)
  storage_provider: "auto"            # rclone, s3, r2, or auto

applications:
  <app-identifier>:
    name: "Display Name"
    directory: "/var/www/app"
    compose_file: "docker-compose.yml"
    domains:
      - "app.example.com"
    services:
      web:
        container: "app_frontend"
        healthcheck: "http://127.0.0.1:3000/health"
    database:
      type: "postgres"
      container: "app_postgres"       # Must match ^[a-zA-Z0-9_-]+$
      backup: true
      retention_days: 14
      user: "postgres"
      database: "app_prod"
```

---

## 2. Environment Configuration (`/opt/atlas/.env`)

All secrets, credentials, webhooks, and tokens must reside only in `/opt/atlas/.env` (`chmod 600`, owned by `root:root`).

### Failure & Alerting Notifications (Discord & Slack)
Atlas provides automated alerting hooks for system operators:
```dotenv
# Webhook destinations
ATLAS_DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
ATLAS_SLACK_WEBHOOK=https://hooks.slack.com/services/...

# Keep success notifications disabled by default (default: false)
ATLAS_NOTIFY_SUCCESS=false

# Repeated failure threshold (default: 2 consecutive failures)
ATLAS_SCHEDULER_ALERT_THRESHOLD=2
```

**Dispatched Alert Events:**
* **Database Backup Failure**: Dump errors, missing database containers, non-zero pipe exits.
* **Cloudflare R2 Sync Failure**: Network dropouts, authentication rejections, or verification gate timeouts after 3 bounded retry attempts.
* **Restore-Drill Failure**: Disposable test container start failures or SQL schema stream corruption.
* **Repeated Scheduler Failure**: Multiple consecutive automated snapshot failures detected by systemd or Doctor.

**Security Guarantee:** Webhook URLs, private keys, and passwords are automatically sanitized and are never printed to terminal logs, journald, the Web UI, or Git.

### Web Dashboard Configuration
```dotenv
# Secret token required for dashboard actions and startup
ATLAS_DASHBOARD_TOKEN=your_secure_random_64_character_token_here

# Local host binding (default: 127.0.0.1)
ATLAS_DASHBOARD_HOST=127.0.0.1
ATLAS_DASHBOARD_PORT=8888
```

> **Security Requirement:** The Atlas dashboard must bind to `127.0.0.1` by default and refuses to start without `ATLAS_DASHBOARD_TOKEN`. Do not expose the dashboard publicly until a domain, Nginx reverse proxy (with TLS), and an authentication strategy are configured.
