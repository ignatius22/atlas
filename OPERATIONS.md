# Atlas Production Operations Runbook

This document serves as the primary day-to-day operational guide for maintaining an Atlas production host.

---

## 1. Daily Health Audits

Run the Atlas Doctor at the start of any shift or maintenance window:
```bash
./bin/doctor
```
Review the output for:
* **Disk Space:** Ensure `/` usage is below 75%.
* **Memory & Swap:** Verify memory availability is > 1.5 GB and swap is not thrashing.
* **Unhealthy Containers:** Investigate any container flagged with `unhealthy`.
* **Backup Freshness:** Confirm backups for all registered databases are less than 24 hours old.

---

## 2. Service Management

### Inspecting Running Services
```bash
# List all running containers and health status
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Inspect logs of a specific service
docker compose -f /var/www/<app>/docker-compose.yml logs -f --tail=100 <service_name>
```

### Restarting a Specific Service Safely
```bash
# Restart a single application stack without touching other apps
cd /var/www/<app>
docker compose restart <service_name>

# Verify health immediately after restart
/path/to/atlas/scripts/health-check.sh --app=<app>
```

---

## 3. Storage & Disk Maintenance

### Safe Build Cache Cleanup
Over time, continuous Docker builds accumulate build cache layers. Reclaim disk space safely with:
```bash
# Safely prune unused build cache (does NOT touch active images, containers, or volumes)
docker builder prune -a -f

# Prune dangling/untagged images
docker image prune -f
```

### System Journal Log Management
Vacuum system journal logs if `/var/log/journal` exceeds 500 MB:
```bash
journalctl --disk-usage
journalctl --vacuum-size=200M
```

---

## 4. Database Maintenance

### Manual Backup On Demand
Before executing any manual database migration or hotfix:
```bash
./scripts/backup.sh --app=<app>
```

### Inspecting Existing Backups
```bash
ls -lh /var/backups/<app>/
```

### Testing Backup Integrity
Always test backups in an isolated container:
```bash
./scripts/restore.sh --app=<app> --file=/var/backups/<app>/<app>-<timestamp>.sql.gz --target=test
```

---

## 5. Nginx Ingress Operations

### Testing Nginx Syntax
Before reloading Nginx after modifying any virtual host configuration:
```bash
nginx -t
```

### Reloading Nginx Without Dropping Connections
```bash
nginx -s reload
# or for containerized Nginx:
docker exec atlas_nginx_gateway nginx -s reload
```

---

## 6. Standard Cron Schedule

On an Atlas production host, configure crontab as follows:
```cron
# Atlas Automated Application Backups
0 0 * * * /path/to/atlas/scripts/backup.sh --app=app1 >> /var/log/atlas/backup-app1.log 2>&1
0 1 * * * /path/to/atlas/scripts/backup.sh --app=app2 >> /var/log/atlas/backup-app2.log 2>&1
0 2 * * * /path/to/atlas/scripts/backup.sh --app=app3 >> /var/log/atlas/backup-app3.log 2>&1

# Weekly Docker Build Cache & Dangling Image Cleanup (Sunday at 03:00)
0 3 * * 0 docker builder prune -a -f >> /var/log/atlas/docker-prune.log 2>&1
```
