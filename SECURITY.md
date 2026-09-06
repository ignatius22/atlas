# Atlas Production Security Standard & Hardening Guide

Atlas enforces a strict, defense-in-depth security model across the host OS, network ingress, containers, and credential management.

---

## 1. Core Security Principles

1. **Zero Public Database/Cache Exposure:** Database (PostgreSQL 5432) and cache (Redis 6379) ports MUST NEVER be published to `0.0.0.0` on the host. All service communication occurs over private Docker bridge networks.
2. **Key-Only SSH:** Password authentication is disabled on SSH. Only authorized cryptographic keys are permitted.
3. **No Hardcoded Secrets:** Credentials, API keys, and JWT secrets must never appear in `docker-compose.yml`, Git repositories, or scripts. All secrets live in `.env` files with `chmod 600` permissions.
4. **Non-Root Containers:** Containers should drop root privileges where possible (e.g. `USER node` in Node.js applications).
5. **Modern TLS Standards:** TLS 1.0 and 1.1 are disabled. Public traffic is encrypted with TLS 1.2 and TLS 1.3 with Perfect Forward Secrecy (PFS).

---

## 2. Host Hardening Checklist

### SSH Configuration (`/etc/ssh/sshd_config`)
```text
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
UsePAM yes
```
Validate syntax and reload:
```bash
sshd -t && systemctl reload ssh
```

### Firewall Configuration (UFW)
Only open necessary public ingress ports:
```bash
# Default policies
ufw default deny incoming
ufw default allow outgoing

# Ingress rules
ufw allow 22/tcp comment 'OpenSSH'
ufw allow 80/tcp comment 'HTTP ACME & Redirect'
ufw allow 443/tcp comment 'HTTPS TLS Gateway'

# Enable firewall
ufw enable
```

---

## 3. Container Hardening Standard

### Example Secure Service Definition (`docker-compose.prod.yml`)
```yaml
services:
  api:
    image: myapp_api:latest
    user: "1000:1000" # Run as unprivileged non-root user
    restart: always
    read_only: false
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
    networks:
      - internal_app_network

  database:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - internal_app_network
    # DO NOT EXPOSE PORTS TO HOST!
```

---

## 4. Secret Sanitization & Git Hygiene

* Always verify that `.gitignore` contains `.env`, `.env.*`, and `*.sql.gz`.
* Never use fallback defaults for secrets in `docker-compose.yml` (e.g. avoid `${JWT_SECRET:-default_secret}`).
* If secrets were committed to a repository in the past, consider them compromised and rotate them immediately.
