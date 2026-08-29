# Contributing to Atlas

Thank you for your interest in contributing to Atlas! Atlas is an open-source project designed to provide production-grade backup automation, client-side encryption, and disaster-recovery verification for Dockerized workloads.

---

## 🛠️ Development Setup

### Prerequisites
- Linux or macOS (Ubuntu 22.04 / 24.04 recommended)
- Docker Engine 24+
- Python 3.9+ with PyYAML
- `age` and `rclone` (or `aws-cli`)

### Running the Test Suite
Before submitting any pull request, verify that all unit and chaos disaster-recovery verification tests pass:

```bash
chmod +x tests/run-all.sh
./tests/run-all.sh
```

---

## 📋 Contribution Guidelines

1. **Keep the Core Lightweight:** Do not add heavy dependencies, frameworks, or cloud-specific lock-ins.
2. **Prioritize Zero-Trust & Fail-Safe Defaults:** Every backup, encryption, and restore path must validate inputs against strict regular expressions and never leak private cryptographic keys.
3. **Preserve Compatibility:** Atlas is designed to work seamlessly on vanilla Linux VPS environments.

---

## 🔒 Reporting Security Vulnerabilities
Please do **not** open public GitHub issues for security vulnerabilities. Review our [Security Policy](SECURITY.md) for confidential disclosure instructions.
