# Atlas Production Troubleshooting & Diagnostic Guide

When troubleshooting production issues on an Atlas host, always start with:
```bash
./bin/doctor
```

---

## 1. Diagnostic Decision Tree

```text
Problem Detected
  │
  ├── 502 / 504 Bad Gateway
  │     ├── Check Nginx error log: tail -50 /var/log/nginx/error.log
  │     ├── Check container state: docker ps -a
  │     └── Verify upstream port: curl -I http://127.0.0.1:<upstream_port>
  │
  ├── Disk Space Full / Build Failures
  │     ├── Check disk usage: df -h
  │     ├── Check docker space: docker system df
  │     └── Prune build cache: docker builder prune -a -f
  │
  ├── Memory Thrashing / High Swap
  │     ├── Check top consumers: ps aux --sort=-%mem | head -15
  │     └── Inspect container stats: docker stats --no-stream
  │
  └── Database Connection Refused
        ├── Check container logs: docker logs <db_container> --tail=50
        └── Check health: docker inspect --format '{{.State.Health.Status}}' <db_container>
```

---

## 2. Common Failure Modes & Fixes

### Issue 1: `502 Bad Gateway` on Application Domain
* **Cause:** The backend container is stopped, crashing on startup, or listening on a different port than configured in Nginx.
* **Resolution:**
  1. Inspect container status: `docker ps | grep <app>`
  2. Check application logs for startup crashes:
     ```bash
     docker compose -f /var/www/<app>/docker-compose.yml logs --tail=100
     ```
  3. Verify the upstream port in `/etc/nginx/sites-enabled/<app>.conf` matches the container's published port.

---

### Issue 2: Docker Build Fails with `no space left on device`
* **Cause:** Docker build cache and obsolete intermediate layers have exhausted the root partition.
* **Resolution:**
  ```bash
  # Prune all unused build cache
  docker builder prune -a -f

  # Vacuum archived journal logs
  journalctl --vacuum-size=200M

  # Verify recovered space
  df -h /
  ```

---

### Issue 3: SSL Certificate Renewal Fails (Certbot)
* **Cause:** Nginx is not routing ACME HTTP-01 challenge requests (`/.well-known/acme-challenge/`) to `/var/www/certbot`, or DNS has changed.
* **Resolution:**
  1. Verify ACME challenge directory exists: `mkdir -p /var/www/certbot`
  2. Verify Nginx contains the ACME location block:
     ```nginx
     location /.well-known/acme-challenge/ {
         root /var/www/certbot;
     }
     ```
  3. Test ACME challenge manually:
     ```bash
     echo "test" > /var/www/certbot/test.txt
     curl -I http://example.com/.well-known/acme-challenge/test.txt
     ```

---

### Issue 4: High Swap Usage & Server Sluggishness
* **Cause:** Memory leaks or unconstrained containers consuming all available RAM, forcing the kernel to swap pages to disk.
* **Resolution:**
  1. Identify the largest memory consumers:
     ```bash
     ps aux --sort=-%mem | head -10
     docker stats --no-stream
     ```
  2. Add memory limits to the misbehaving container in `docker-compose.yml`:
     ```yaml
     deploy:
       resources:
         limits:
           memory: 512M
     ```
  3. Restart the container stack: `docker compose up -d`
