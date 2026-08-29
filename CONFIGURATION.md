# Configuration Reference (`atlas.yml`)

The primary declarative configuration file is `atlas.yml`.

## Schema Reference

```yaml
version: "1"

settings:
  backup_dir: "/var/backups"          # Base directory for local backups
  default_retention_days: 14          # Days before local backups are pruned
  compression_level: 9                # gzip compression level (1-9)
  storage_provider: "s3"              # s3, r2, rclone, or local-mock
  notification_webhook: ""            # Optional Slack/Discord alert webhook

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
