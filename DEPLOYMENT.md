# Atlas Application Onboarding & Deployment Guide

This guide walks through onboarding a new application to Atlas Production Template and executing reliable application updates.

---

## 1. Deployment Model & Realistic Constraints

> [!IMPORTANT]
> **Single-Host Docker Compose Deployment Reality:**
> Atlas V1 utilizes Docker Compose for container management on single-host virtual private servers.
> * Application updates execute via in-place container recreation (`docker compose up -d --build`).
> * During container recreation, an application incurs a brief service restart interruption (typically 1 to 5 seconds depending on framework boot time).
> * Single-host Compose does **NOT** provide multi-replica zero-downtime rolling deployments (which requires clustered load balancing like Nomad or Swarm with health-gated routing).
> * If a build or deployment fails, Atlas halts execution and reports error status without automatically rolling back to ensure the operator can inspect logs.

---

## 2. Onboarding a New Application

### Step 1: Create Application Directory & Clone Repository
```bash
sudo mkdir -p /var/www/my-new-app
sudo chown -R deploy:deploy /var/www/my-new-app
cd /var/www/my-new-app
git clone https://github.com/org/my-new-app.git .
```

### Step 2: Configure Environment Variables
Create a local `.env` file on the production host with strict permissions:
```bash
cp .env.example .env
chmod 600 .env
# Populate with production credentials
```

### Step 3: Configure Docker Compose
Ensure your `docker-compose.yml` (or `docker-compose.prod.yml`) adheres to Atlas standards:
1. **Network Isolation:** Service containers communicate over a private bridge network.
2. **No Exposed Database/Cache Ports:** Do NOT publish database ports (`5432:5432`) or Redis ports (`6379:6379`) to the public host interface.
3. **Healthchecks:** Provide explicit `healthcheck` definitions for databases and API services.
4. **Resource Constraints:** Define memory and CPU limits per container.

### Step 4: Register in `config/apps.yml`
Add an entry to `config/apps.yml`:
```yaml
apps:
  my-new-app:
    name: "My New Application"
    directory: "/var/www/my-new-app"
    compose_file: "docker-compose.yml"
    domains:
      - "app.example.com"
    services:
      web:
        container: "my_new_app_web"
        port: 3000
        healthcheck: "http://127.0.0.1:3000/health"
    database:
      type: "postgres"
      container: "my_new_app_postgres"
      backup: true
      retention_days: 14
    deployment:
      strategy: "compose"
      branch: "main"
      auto_pull: true
```

### Step 5: Configure Nginx Virtual Host
1. Copy the virtual host template:
   ```bash
   sudo cp infra/nginx/templates/app.conf.template /etc/nginx/sites-available/my-new-app.conf
   ```
2. Edit `/etc/nginx/sites-available/my-new-app.conf`:
   * Replace `{{DOMAIN_NAMES}}` with `app.example.com`
   * Replace `{{PRIMARY_DOMAIN}}` with `app.example.com`
   * Replace `{{UPSTREAM_WEB}}` with `127.0.0.1:3000` (or container network alias)
3. Obtain SSL certificate:
   ```bash
   ./scripts/setup-ssl.sh -d app.example.com -m admin@example.com
   ```
4. Enable virtual host:
   ```bash
   sudo ln -s /etc/nginx/sites-available/my-new-app.conf /etc/nginx/sites-enabled/
   sudo nginx -t && sudo nginx -s reload
   ```

---

## 3. Deploying Application Updates

To deploy an update for any registered application:

```bash
./scripts/deploy.sh --app=my-new-app
# or
make deploy APP=my-new-app
```

### What `deploy.sh` Does:
1. **Validates App Identifier:** Rejects path traversal and illegal shell characters.
2. **Validates Registry:** Confirms the application is declared in `config/apps.yml`.
3. **Validates Directory:** Verifies `/var/www/my-new-app` exists and is a valid Git repository.
4. **Pulls Updates:** Checks out the configured branch (`main`) and pulls latest commits.
5. **Validates Compose Syntax:** Executes `docker compose config -q` before modifying containers.
6. **Executes Pre-Deploy Hook:** Runs validated executable script hooks (never `eval`).
7. **Rebuilds & Restarts:** Rebuilds images and updates containers in-place (`docker compose up -d --build --remove-orphans`).
8. **Automated Health Check:** Executes `scripts/health-check.sh` against the container and HTTP endpoints.
9. **Executes Post-Deploy Hook:** Runs post-deployment notifications or cleanup script.

---

## 4. Rollback Procedures

If a deployment fails health checks or introduces an unexpected bug:

### Rollback to Previous Commit
```bash
./scripts/rollback.sh --app=my-new-app
# or
make rollback APP=my-new-app
```

### Rollback to Specific Release Tag or SHA
```bash
./scripts/rollback.sh --app=my-new-app --target=v1.1.0
```

> [!WARNING]
> **Stateful Rollback Notice:** Reverting Git commits and rebuilding containers restores code and container state. If database schema migrations were applied, you must restore the pre-deployment database backup using `./scripts/restore.sh`.
