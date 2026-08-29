# Atlas Commercial Strategy & Product Hypothesis

> **Note:** This document outlines commercial hypotheses for potential future exploration. These are not commitments, but design boundaries to ensure the open-source core remains clean, unencumbered, and fully functional.

---

## 1. The Open-Source Core (Atlas Community)
The free open-source core will **never be crippled** and includes everything needed for single-host production operations:
- Full CLI (`init`, `config`, `doctor`, `backup`, `restore`, `crypto`).
- PostgreSQL atomic backup generation & gzip compression.
- Client-side asymmetric Age envelope encryption.
- Multi-provider off-site replication (S3, Cloudflare R2, MinIO).
- Ephemeral disaster-recovery verification drills.
- Infrastructure Doctor health and port diagnostic suite.

---

## 2. Potential Future Expansion (Atlas Pro / Fleet)
For engineering teams managing multiple nodes across diverse clouds:

### Value Proposition:
> *"I run multiple servers across Hetzner, DigitalOcean, and AWS, and I want a centralized control plane that continuously monitors backup health and proves disaster-recovery readiness across my entire fleet."*

### Hypotheses to Validate:
1. **Centralized Fleet Dashboard:** Unified web interface displaying RPO/RTO status across 50+ VPS nodes.
2. **Automated Cross-Region Failover:** Orchestrated DNS failover via Cloudflare API when a primary host fails health checks.
3. **Compliance & Audit Reporting:** Automated weekly PDF disaster-recovery audit certificates for SOC2 / ISO27001 compliance.
4. **Team RBAC & SSO:** Integration with Google Workspace, Okta, and GitHub Teams for role-based restore authorizations.
