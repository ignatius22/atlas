# Atlas Product Plan

_As of 20 Oct 2026 · Ignatius Sani_

## Summary

Atlas becomes **the backup tool that proves your restores work**: a free open-source agent for Docker VPS hosts, plus a paid hosted service that watches every server, runs restore drills on a schedule, and tells you the moment recovery is at risk.

The bet: indie hackers, small SaaS teams and agencies running apps on Hetzner, DigitalOcean or Contabo will pay a small monthly fee for certainty, not for storage. Existing tools sell "we copy your data somewhere." Atlas sells "we prove you can get it back, and we never hold your keys."

## Where Atlas is today

Atlas v1.1 is a working Bash + Python toolkit that already runs production backups for our own apps; all 9 test suites pass (about 150 assertions).

**What already works and is genuinely good:**

- Every 6 hours a systemd timer (with catch-up after reboots) dumps each app's Postgres, gzips it, and writes a SHA-256 checksum and manifest.
- Archives are encrypted with `age` to a public key, so the private key never sits on the server.
- Uploads to R2/S3 are retried and then verified against the remote listing before a `.synced` marker is written.
- Local backups are never deleted unless that marker exists. This durability gate is the core idea worth selling.
- Test restores run in an isolated container; Discord and Slack alerts fire on failure.

**Gaps between what we claim and what the code does:**

| Claim | Reality | Fix |
| --- | --- | --- |
| "Atlas verifies backups can be restored" | Restore drills only run by hand; nothing schedules them | Scheduled drills via a second systemd timer |
| Schema and row-count validation | Test restore only checks the SQL ran without errors | Compare table list and row counts to a snapshot taken at dump time |
| MariaDB support | `backup.sh` rejects anything but Postgres | Add MySQL/MariaDB adapter |
| Application-agnostic | No volume or file backups; our app names and nginx configs are hardcoded in the repo | Volume backups; strip personal infra and defaults |
| Multi-provider | Dashboard hardcodes "Cloudflare" | Provider from config |
| "Zero shell interpretation" | `bin/atlas` passes args through `eval` | Replace with arrays |

Smaller issues: the CLI reports v1.0.0 while docs say v1.1.0, two test files lack the executable bit, `/api/status` scans `/root`, `/home` and `/etc` on every call, failed deploys don't roll back, and there are two competing dashboards.

## The problem and who pays

People running apps on their own VPS rarely lose data because they skipped backups; they lose it because the backup silently stopped working months earlier. The cron job died, credentials expired, the bucket filled up, or the dump was never restorable. They find out on the worst day.

**Who we sell to, in order:**

1. **Indie hackers and solo founders** with 1–5 paying apps on Hetzner, DigitalOcean or Contabo using Docker Compose, Coolify or Dokploy. Pain: "if my DB dies I lose my customers and I'm not sure my backups work." Budget: $5–20/month.
2. **Small agencies and freelancers** hosting 5–50 client apps. Pain: they carry the liability and want proof to show clients. Budget: $30–150/month, and they can bill it to clients.
3. **Small SaaS teams (2–20 engineers)** avoiding managed databases to save cost. Pain: a customer or auditor asks "what's your disaster recovery plan?" Budget: $50–300/month.

**Who we don't target first:** enterprises with Kubernetes and managed RDS (they already have PITR and vendors), and hobbyists with no revenue at stake.

**The job to be done:** "Tell me, without me checking, that I could rebuild every app from yesterday if this server vanished right now — and show me the evidence."

## Competitive landscape

The market splits into hosted backup services that copy data on a schedule and free self-hosted tools you have to babysit. None of them makes automatic restore verification on a plain VPS the headline product.

| Alternative | Type | Price (monthly) | What it does well | Where it falls short for our buyer |
| --- | --- | --- | --- | --- |
| [SimpleBackups](https://simplebackups.com/pricing) | Hosted SaaS | Free (1 job, daily) · $49 Lite (5 jobs) · $99 Plus · $299 Max | Polished UI, many databases, storage included | $49 is the first useful tier; pricing page does not mention restore testing; vendor connects to your servers |
| [SnapShooter](https://snapshooter.com/pricing) (DigitalOcean) | Hosted SaaS | Free (1 job) · ~$14 Lite · $39 Startup · $79 Business · $199 Agency | Cheap entry, agency tier, DigitalOcean integration | Owned by a cloud vendor; focused on copying, not proving restores |
| [Ottomatik](https://www.capterra.com/p/252617/Ottomatik/) | Hosted SaaS | Listed from about [$10 to $109](https://www.g2.com/products/ottomatik/pricing) | MySQL, Postgres, MongoDB; many storage targets | No public restore-verification story |
| [Coolify](https://coolify.io/docs/knowledge-base/databases/backups) / Dokploy | Free self-hosted PaaS | Free | Scheduled dumps to S3 built into the platform people already use | No restore verification (its docs warn a backup only proves a file was created); no encryption mentioned; no volume backups |
| [Databasus](https://dev.co/devops/open-source/databasus), PG Back Web | Free self-hosted tools | Free | Web UI, PITR (Databasus), alerts, about 7.6k GitHub stars | You host and watch it yourself; nobody tells you when the tool itself dies |
| restic, Borg, pgBackRest | Free CLI tools | Free | Battle-tested engines | Raw building blocks; you write and monitor the glue |
| [AWS Backup restore testing](https://aws.amazon.com/blogs/aws/automatic-restore-testing-and-validation-is-now-available-in-aws-backup/) | Cloud-native | Usage-based | Proves the idea: automated restore tests, launched Nov 2023 | Only for AWS resources; useless on Hetzner or DigitalOcean droplets |

**What this tells us:** AWS built automated restore testing because enterprises demanded it, but VPS users have no equivalent. Hosted backup SaaS charges $39–99 for copying alone. That leaves a gap for a cheaper, verification-first product that runs where the data lives.

## Positioning and differentiation

**Positioning line:** *Atlas proves your VPS backups restore — every day, automatically, without ever holding your keys.*

```mermaid
quadrantChart
    title Nobody else offers verified restores where you keep the keys
    x-axis Copies data on a schedule --> Proves the backup restores
    y-axis Vendor handles your data --> You hold the keys
    quadrant-1 Verified and zero-knowledge
    quadrant-2 Self-hosted tools
    quadrant-3 Hosted backup services
    quadrant-4 Cloud-native verification
    Atlas: [0.72, 0.82]
    restic / Borg / pgBackRest: [0.12, 0.85]
    Coolify / Dokploy backups: [0.15, 0.72]
    Databasus: [0.42, 0.62]
    SimpleBackups: [0.15, 0.35]
    SnapShooter: [0.15, 0.25]
    Ottomatik: [0.15, 0.15]
    AWS Backup (AWS only): [0.75, 0.3]
```

Positions are by zone, from each product's public docs; Databasus sits near the line because it lists restore verification but leaves you to host and watch it.

Four things separate us, and every roadmap item should strengthen one of them:

1. **Proof, not copies.** Scheduled restore drills that load each backup into a throwaway container and check it against what was dumped: tables, row counts, and an optional app-defined query ("latest order exists"). We report a **Recovery Score** per app, not just "last backup: OK".
2. **Zero-knowledge by design.** Data is encrypted on the customer's server with their public key. Our cloud receives only status and metadata, never data or keys. Hosted competitors connect to your servers and handle your dumps; we can say we cannot read your data, and prove it.
3. **Durability you can't accidentally break.** The `.synced` gate means local copies are never pruned until the offsite copy is confirmed. Competitors that "delete local after upload" can lose both.
4. **A watchdog outside the box.** Self-hosted tools die silently with the server they protect. Our cloud expects a heartbeat from every server and alerts when one goes quiet, which no free tool can do for itself.

**What we deliberately won't be:** a PaaS (Coolify and Dokploy win there — we integrate with them instead), a storage reseller (customers bring their own R2/S3/B2, keeping our margins clean), or an enterprise PITR platform.

## Product shape

Atlas ships as two parts: a free, Apache-2.0-licensed **agent** that does all the work on the server, and a paid **Atlas Cloud** that watches, schedules and reports across servers. The free agent is complete for one server; Cloud is what you pay for once you can't afford to check it yourself.

**Atlas Agent (open source):** a single install command; backs up Postgres, MySQL/MariaDB, MongoDB, Redis and Docker volumes; encrypts with `age`; syncs to any S3-compatible bucket with the durability gate; runs scheduled restore drills; local CLI, doctor and Discord/Slack/email alerts. Auto-detects databases in running Compose, Coolify and Dokploy stacks.

**Atlas Cloud (paid):** the agent sends signed heartbeats and run reports — status, sizes, checksums, drill results — never data.

| Capability | Agent (free) | Cloud (paid) |
| --- | --- | --- |
| Encrypted backups, offsite sync, durability gate | Yes | Yes |
| Scheduled restore drills with row-count checks | Yes | Yes, plus history and trends |
| Alerts | Local webhooks | Missed-heartbeat alerts from outside the server, email/SMS/Slack, escalation |
| Dashboard | One server, localhost | All servers and apps, Recovery Score per app |
| Reports | — | Monthly DR report PDF (RPO met, drills passed), shareable link for clients |
| Restore | CLI | Guided restore runbook, "restore to new server" walkthrough |
| Team | — | Members, roles, audit log |

The split keeps the community version honest — nothing is crippled — while charging for what only a service outside the server can provide.

## Pricing

We price per server, below the hosted competitors' first useful tier, because customers bring their own storage and our cost per server is tiny.

| Plan | Price (USD/month) | Servers | Includes |
| --- | --- | --- | --- |
| Community | $0 | Unlimited, self-managed | The full open-source agent |
| Solo | $9 | 1 | Cloud dashboard, heartbeat alerts, daily restore drills, 30-day history |
| Pro | $29 | 5 | Everything in Solo, monthly DR reports, email/SMS alerts, 1-year history |
| Agency | $99 | 25 | Everything in Pro, client-branded reports, per-client workspaces, team roles |
| Extra servers | $4 each | — | On Pro and Agency |

**Why these numbers:** Solo at $9 undercuts SnapShooter Lite (~$14) and SimpleBackups Lite ($49) while adding restore proof. Agency at $99 sits under SnapShooter Agency ($199) and is easy for an agency to pass on to clients at $10–20 per site. Annual billing at two months free. A 14-day trial without a card on Pro.

Regional pricing (Nigeria, India and other emerging markets) at about 50% off is worth testing once we have card payments through Paddle or Lemon Squeezy, which also handle VAT.

## Roadmap

We spend November making Atlas's existing promises true, then earn the right to charge through design partners before a public launch in April 2027.

| Phase | When | Scope | Gate to move on |
| --- | --- | --- | --- |
| **0 · Make the claims true** | Nov 2026 · 4 weeks | Scheduled restore drills with table and row-count checks; strip personal infra and hardcoded apps; remove `eval`; fix version; one dashboard; fix test permissions and the status-page key scan | Drills pass daily on our own servers for 2 weeks |
| **1 · Agent v2** | Dec 2026 – Jan 2027 | One-line installer; auto-detect Compose, Coolify, Dokploy stacks; MySQL/MariaDB, MongoDB, Redis and Docker volume backups; email alerts; signed heartbeat to a Cloud endpoint (opt-in) | 10 design partners running it in production |
| **2 · Atlas Cloud MVP** | Feb – Mar 2027 | Multi-server dashboard, Recovery Score, drill history; missed-heartbeat and failed-drill alerts from outside the server; billing via Paddle or Lemon Squeezy, Solo and Pro plans | 5 design partners pay; no data-loss bugs found |
| **3 · Launch and grow** | Apr 2027 onward | Show HN, r/selfhosted, Product Hunt; Coolify and Dokploy templates; monthly DR reports, agency workspaces, team roles; agent rewritten as a single Go binary | — |

Each gate must pass before the next phase starts; if a gate slips, the phase after it waits rather than shipping on a weaker foundation. Phase 0 is the work we can start immediately:

- [ ] Add `atlas-drill.timer` that restore-tests the newest backup of every app daily
- [ ] Record table names and row counts at dump time; compare them after each test restore
- [ ] Move our own nginx configs and app names out of the repo; read apps only from config
- [ ] Replace `eval` in `bin/atlas` with argument arrays; align the version to 1.2.0
- [ ] Choose one dashboard and delete the other; cache the key scan or narrow its paths
- [ ] Mark the two test files executable so `make test` passes locally

## Go-to-market

We win first customers where VPS self-hosters already gather, using our own production use as the proof.

1. **Design partners (10 people, free).** Hand-pick indie hackers and agencies running Coolify, Dokploy or plain Compose. Install Atlas with them, watch them use it, and convert them to paid at launch. Our own apps are customer zero.
2. **Content that ranks for fear.** Write posts on Medium, dev.to and the docs site: "Your Coolify backups aren't verified", "How I lost a database with a passing backup", "Restore-testing Postgres on a $5 VPS". Each ends with the one-line install.
3. **Integrations as distribution.** Publish a Coolify and Dokploy one-click template and a guide in their communities; their docs already admit backups are unverified.
4. **Launch.** Show HN and r/selfhosted for the open-source agent; Product Hunt and Indie Hackers for Cloud a few weeks later, each with a live demo dashboard.
5. **Agency outreach.** Direct messages to agencies hosting client sites, leading with the client-facing DR report.

The free agent is the top of the funnel; the in-product nudge is the moment the agent detects a second server or a missed drill.

## Metrics, risks and open questions

**North-star metric:** servers with a passing restore drill in the last 7 days.

| Milestone | Target |
| --- | --- |
| Agent installs (GitHub + telemetry opt-in) | 300 in the first 3 months after launch |
| Design partners converted to paid | 5 of 10 |
| Paying customers | 50 within 6 months of Cloud launch |
| Monthly recurring revenue | $1,000 within 6 months |
| Drill pass rate across fleet | Above 95%, with every failure alerted |

**Risks:**

- **Coolify or Dokploy add restore verification.** Mitigation: integrate with them early and own the cross-platform, zero-knowledge, external-watchdog angle they can't offer.
- **Bash at scale.** More engines and platforms will strain shell scripts. Mitigation: rewrite the agent as a single Go binary in Phase 3, keeping the same invariants and tests.
- **Trust.** A backup company with a data-loss bug is finished. Mitigation: keep the adversarial test suite, publish a security model, and get an external review before charging.
- **Solo-founder bandwidth.** This competes with a full-time job and other projects. Mitigation: ship the smallest Cloud (heartbeats, drill results, email alerts) before anything else.

**Open questions:**

- Agent stays Bash with a Go rewrite later, or start Go now?
- Do agencies really pay for client-facing DR reports? Ask in the first 10 design-partner calls.
- Brand: keep "Atlas" (crowded name) or rename before launch?
- Solo at $9, or free for one server and charge from Pro?

## Sources

Competitor prices were checked on 20 Oct 2026 and some vendor pages list inconsistent figures; confirm before publishing pricing.

- [SimpleBackups pricing](https://simplebackups.com/pricing)
- [SnapShooter pricing](https://snapshooter.com/pricing)
- [Ottomatik pricing on G2](https://www.g2.com/products/ottomatik/pricing) and [Ottomatik on Capterra](https://www.capterra.com/p/252617/Ottomatik/)
- [Coolify database backups docs](https://coolify.io/docs/knowledge-base/databases/backups)
- [Databasus overview](https://dev.co/devops/open-source/databasus)
- [AWS Backup restore testing announcement](https://aws.amazon.com/blogs/aws/automatic-restore-testing-and-validation-is-now-available-in-aws-backup/)
