# Atlas Production Template (V1)

Atlas is a lightweight, application-agnostic production infrastructure framework for Linux Virtual Private Servers (VPS). It provides standardized workflows for **deployment**, **health monitoring**, **automated backups**, **safe database restores**, **TLS termination**, and **system diagnostics** without introducing unnecessary complexity.

---

## Design Principles

* **Infrastructure Shell, Not Application Code:** Applications plug into Atlas. Atlas contains zero application business logic or hardcoded app names.
* **Boring Technology Over Complexity:** Built entirely with Bash, Docker Compose, Nginx, and declarative YAML (via PyYAML). No Kubernetes, Terraform, Ansible, or complex cloud orchestrators.
* **Realistic Single-Host Operational Model:** Clearly acknowledges single-host Docker Compose constraints. Application updates operate via fast in-place container recreation (incurring a brief restart window during image swap), rather than claiming multi-replica zero-downtime rolling updates.
* **Secure by Default:** Non-root containers, strictly internal database/cache networking, TLS 1.2/1.3 enforcement, hardened SSH, and zero hardcoded credentials.
* **Recoverability First:** Automated checksummed backups with SQL stream content validation and isolated test-restore verification before any change.
* **Observable & Diagnostic:** Single-command diagnostic inspection (`./bin/doctor`) with clear `PASS`/`WARN`/`FAIL` reporting.

---

## Directory Structure

```text
atlas-production-template/
├── README.md                      # Architecture & overview
├── OPERATIONS.md                  # Daily operational runbook
├── DEPLOYMENT.md                  # Application onboarding & deployment guide
├── BACKUP.md                      # Backup system architecture & policies
├── RECOVERY.md                    # Disaster recovery & test restore procedures
├── SECURITY.md                    # VPS & container hardening standard
├── TROUBLESHOOTING.md              # Common failure modes & diagnostic playbooks
├── Makefile                       # Operator convenience commands
├── .env.example                   # Environment variable template
├── .gitignore                     # Secret & artifact exclusion rules
│
├── config/
│   ├── apps.example.yml           # Declarative application registry
│   └── backup.example.yml         # Global backup & retention settings
│
├── scripts/
│   ├── lib/
│   │   ├── common.sh              # Shared shell logging, validation & config helpers
│   │   └── yaml_parser.py         # PyYAML configuration query engine
│   ├── deploy.sh                  # Application deployment & update engine
│   ├── rollback.sh                # Git/Compose rollback engine
│   ├── backup.sh                  # Database dump, gzip, content check & sha256 engine
│   ├── restore.sh                 # Safe test & production restore engine (ON_ERROR_STOP=1)
│   ├── health-check.sh            # HTTP/HTTPS & container health probe
│   ├── setup-ssl.sh               # Automated Let's Encrypt Certbot wrapper
│   └── setup-server.sh            # Idempotent server bootstrap verification
│
├── bin/
│   └── doctor                     # Read-only production diagnostic CLI
│
├── infra/
│   └── nginx/
│       ├── nginx.conf             # Production Nginx gateway base config with catch-all drop
│       ├── snippets/
│       │   ├── proxy-params.conf  # Reverse proxy headers & WebSocket support
│       │   ├── ssl-params.conf    # TLS 1.2/1.3 ciphers & OCSP stapling
│       │   └── security-headers.conf # HSTS, X-Frame, MIME security headers
│       └── templates/
│           └── app.conf.template  # Virtual host template for new applications
│
├── docker/
│   ├── postgres.example.yml       # Hardened PostgreSQL 16 Compose service
│   ├── redis.example.yml          # Hardened Redis 7 Compose service
│   └── nginx.example.yml          # Containerized Nginx gateway service
│
└── tests/
    ├── run-all.sh                 # Comprehensive automated test runner
    ├── test-doctor.sh             # Diagnostic tool test suite
    ├── test-backup.sh             # Backup engine test suite
    ├── test-health-check.sh       # Health probe test suite
    ├── test-yaml.sh               # PyYAML edge-case parsing test suite
    └── test-adversarial.sh        # Adversarial & failure-path test suite
```

---

## Operational Distinction Matrix

| Action | What it Does | What it Does NOT Do |
|---|---|---|
| **Deployment (`deploy.sh`)** | Pulls latest Git branch, validates Compose syntax, rebuilds and restarts containers in-place, verifies health probe. | Does not perform multi-replica zero-downtime rolling updates; does not automatically roll back if post-deploy health check fails. |
| **Rollback (`rollback.sh`)** | Reverts application Git working tree to target commit/tag and recreates containers. | Does not automatically revert database schema migrations or persistent volume changes. |
| **Database Restore (`restore.sh`)** | Safely tests restore in an ephemeral container (default) or restores to production with `-v ON_ERROR_STOP=1 --single-transaction`. | Does not restore code or container configurations. |
| **Disaster Recovery (`RECOVERY.md`)** | End-to-end playbook for rebuilding the entire host from zero on a fresh VPS. | N/A |

---

## Quickstart

### 1. Check Host Readiness
Run the Atlas Doctor diagnostic tool:
```bash
./bin/doctor
# or
make doctor
```

### 2. Register an Application
Copy the example registry configuration and define your application:
```bash
cp config/apps.example.yml config/apps.yml
```

### 3. Deploy the Application
```bash
./scripts/deploy.sh --app=myapp
# or
make deploy APP=myapp
```

### 4. Create an Automated Database Backup
```bash
./scripts/backup.sh --app=myapp
# or
make backup APP=myapp
```

### 5. Verify Backup in an Isolated Container
```bash
./scripts/restore.sh --app=myapp --target=test
```
