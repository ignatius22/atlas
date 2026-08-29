# Security Policy

The Atlas maintainers take the security of backup automation, encryption, and infrastructure disaster-recovery seriously.

---

## 🛡️ Supported Versions

| Version | Supported          |
| :------ | :----------------- |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

---

## 🔒 Security Architecture Guarantees

1. **Client-Side Envelope Encryption:** All off-site backups are encrypted locally using asymmetric Age (X25519) keys prior to cloud transport.
2. **Input Sanitization:** All container and application identifiers are strictly sanitized (`^[a-zA-Z0-9_-]+$`) to prevent shell and command injection vulnerabilities.
3. **Safe Ephemeral Workspaces:** All decryption and restore drills use restricted permissions (`umask 077` and `chmod 0700`) and automatic cleanup traps on process exit.
4. **Zero Telemetry:** Atlas contains zero telemetry, analytics, or background phone-home mechanisms.

---

## 🚨 Reporting a Vulnerability

If you discover a security issue or vulnerability in Atlas:
- **Do NOT open a public GitHub issue.**
- Email the security maintainers at **security@atlasinfra.dev**.
- Provide a proof-of-concept, description of the vulnerability, and affected components.
- We will acknowledge receipt within 48 hours and work with you on a coordinated disclosure timeline.
