# vps-security

A production-ready hardening toolkit for Ubuntu/Debian VPS servers running Apache. Five focused scripts address the most common critical vulnerabilities on freshly provisioned servers: firewall, SSH hardening, intrusion prevention, Apache security headers, automatic updates, and log monitoring.

Each script is idempotent, validates preconditions before making changes, supports `--dry-run`, and backs up any files it modifies.

**Tested on:** Ubuntu 24.04 LTS (Noble Numbat) · Apache 2.4

---

## Background

This toolkit came out of necessity. Managing a growing number of projects across multiple VPS providers made it clear that ad-hoc server setup wasn't sustainable. Every new deployment meant repeating the same hardening steps from memory, with inconsistent results and no audit trail.

The goal was a standardized, repeatable baseline: cookie-cutter deployments that stand up a secure server quickly, while staying flexible enough to handle the custom, one-off requirements that come with running a variety of distinct projects. Each server has its own quirks. Different domain configurations, monitoring needs, access patterns. The toolkit is structured to handle both the common baseline and those edge cases without diverging into a tangle of server-specific scripts.

---

## Status

| Component | Status |
|---|---|
| Hardening scripts (01–05) | Complete |
| `config.env` central configuration | Complete |
| `bootstrap.sh` single-command provisioner | Complete |
| `scripts/audit/audit.sh` baseline checker | Complete |
| `scripts/audit/` extended audit tools | Planned (Phase 1) |
| Nginx support | Planned (Phase 2) |
| Multi-server fleet tooling | Planned (Phase 2) |

See the [open issues](https://github.com/davidwhittington/vps-security/issues) for the full phased roadmap.

---

## What It Hardens

| Area | Coverage |
|---|---|
| **Firewall** | UFW — deny all inbound, allow SSH / 80 / 443 |
| **SSH** | Key-only auth, no root password login, no X11 forwarding |
| **Intrusion Prevention** | fail2ban with SSH + Apache jails, 3 strikes / 1 hour ban |
| **Kernel Network** | ICMP redirect blocking, martian packet logging |
| **Apache** | `ServerTokens Prod`, `ServerSignature Off`, security headers, HSTS, CSP, block `.git`/`.svn`, disable `mod_status` |
| **Admin User** | Non-root sudo user with SSH key access |
| **Automatic Updates** | `unattended-upgrades` + monthly full upgrade with email report |
| **Log Monitoring** | Logwatch daily digest + GoAccess traffic reports (password-protected) |

---

## Prerequisites

- Ubuntu 22.04+ or Debian 12+
- Apache 2.4 installed and running
- Root access
- **SSH public key already in `/root/.ssh/authorized_keys`** before running script 01 — it disables password authentication and aborts if no key is present

---

## Quick Start

**1. Clone and configure**

```bash
git clone https://github.com/davidwhittington/vps-security.git
cd vps-security
cp config.env config.env.local   # or edit config.env directly
```

Edit `config.env` and set your values: admin username, email address, SMTP relay, SSH port, and CSP domains. See [docs/customization.md](docs/customization.md) for details on each variable.

**2. Run**

Option A — single command (recommended):

```bash
# As root on the target server
bash bootstrap.sh            # full run
bash bootstrap.sh --dry-run  # preview all changes first
```

Option B — run scripts individually in order:

```bash
chmod +x scripts/hardening/*.sh

bash scripts/hardening/01-immediate-hardening.sh   # Firewall · SSH · fail2ban · sysctl
bash scripts/hardening/02-apache-hardening.sh      # Apache headers · TLS · mod_status
bash scripts/hardening/03-setup-admin-user.sh      # Non-root admin with sudo + SSH keys
bash scripts/hardening/04-monthly-updates-setup.sh # Scheduled apt upgrades + email report
bash scripts/hardening/05-log-monitoring-setup.sh  # Logwatch + GoAccess traffic reports
```

**3. Verify**

```bash
bash scripts/audit/audit.sh
```

> **After running script 01:** Open a second terminal and verify SSH access before closing your current session. Password authentication will be disabled.

---

## Scripts

### `01-immediate-hardening.sh` — Critical Fixes

Addresses the highest-risk issues found on most freshly provisioned VPS instances.

- Installs and configures **fail2ban** with SSH jail (3 strikes, 1h ban) and Apache jails (`apache-auth`, `apache-badbots`, `apache-noscript`)
- Enables **UFW** with deny-all inbound policy; opens SSH port, 80, 443
- Disables **SSH password authentication** and root password login
- Disables **X11 forwarding**
- Hardens **kernel sysctl**: disables ICMP redirects, enables martian logging

Safe to re-run. Aborts if no SSH authorized key is found.

---

### `02-apache-hardening.sh` — Apache Security

Reduces information disclosure and adds browser security headers.

- Enables `mod_headers`
- Sets `ServerTokens Prod` and `ServerSignature Off` (hides version strings)
- Disables TRACE method
- Blocks access to `.git` and `.svn` directories
- Adds security headers: `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, `Strict-Transport-Security` (HSTS), `Content-Security-Policy`
- Disables `mod_status`
- Backs up existing `security.conf` before overwriting; restores on failure

CSP `frame-ancestors` is set from `$CSP_FRAME_ANCESTORS` in `config.env`.

---

### `03-setup-admin-user.sh` — Admin User

Promotes an existing user to sudo admin and removes the cloud-init NOPASSWD sudoers rule.

- Sets login shell to `/bin/bash`
- Adds user to `sudo` group
- Copies root's `authorized_keys` so SSH access works immediately
- Removes `/etc/sudoers.d/90-cloud-init-users` (overly permissive cloud-init rule)

Admin username is set from `$ADMIN_USER` in `config.env`. The user must exist on the server before running.

After verifying SSH access and `sudo -v` work, set `PermitRootLogin no` in `/etc/ssh/sshd_config`.

---

### `04-monthly-updates-setup.sh` — Scheduled Updates

Sets up a monthly full system update with an emailed report.

- Installs and configures `msmtp` with your SMTP relay settings
- Creates `/usr/local/sbin/monthly-apt-report.sh` — runs `apt upgrade`, checks kernel version, disk usage, uptime, fail2ban status, and cert expiry
- Schedules a cron job at 3:00 AM on the 1st of each month
- Emails the full report on completion

Email address and SMTP settings read from `config.env`. Test delivery with `/usr/local/sbin/monthly-apt-report.sh`.

---

### `05-log-monitoring-setup.sh` — Log Monitoring

Installs daily log digest and traffic reporting.

- Installs **Logwatch** — configures a daily HTML email digest of all services
- Installs **GoAccess** — generates a daily HTML traffic report from Apache access logs
- Password-protects the reports directory with HTTP Basic Auth (auto-generates a password, printed at the end)
- Schedules GoAccess at 4:00 AM daily

Email and from-address read from `config.env`. Reports are served from `/var/www/html/reports/`.

---

## Repository Structure

```
vps-security/
├── config.env                   # Configuration — fill this in before running anything
├── bootstrap.sh                 # Single-command provisioner (runs all scripts in order)
├── docs/
│   ├── security/
│   │   └── README.md            # Security baseline, requirements, audit cadence
│   ├── customization.md         # What to change in config.env and why
│   ├── TEMPLATE.md              # Blank audit report template
│   └── VPS_HARDENING_GUIDE.html # Standalone HTML knowledge base (offline reference)
├── scripts/
│   ├── hardening/               # The five hardening scripts (01–05, run in order)
│   └── audit/
│       └── audit.sh             # Baseline checker (read-only, pass/fail output)
├── logs/                        # Per-run bootstrap logs (gitignored)
├── config/                      # Config snippets and templates (planned)
└── private/                     # Git submodule — server-specific data (not public)
```

---

## Auditing a Server

Run the built-in checker after hardening to verify every control is active:

```bash
bash scripts/audit/audit.sh
```

For a full manual audit, use the template:

1. Copy `docs/TEMPLATE.md` to your private repo as `private/servers/<hostname>/AUDIT_REPORT.md`
2. Work through each finding category against your server
3. Use the checklist at the bottom to track remediation progress

See [docs/security/README.md](docs/security/README.md) for the full security baseline.

---

## Using This as a Template

This repo is structured to keep generic, reusable scripts public and server-specific data private. The `private/` directory is a separate private git submodule holding actual audit reports, inventory, and network data.

To adopt this pattern for your own infrastructure:

```bash
# Fork or clone this repo
gh repo fork davidwhittington/vps-security

# Create your own private companion repo
gh repo create my-vps-private --private

# Add it as a submodule
git submodule add https://github.com/<you>/my-vps-private private/
git commit -m "Add private submodule"
```

---

## Docs

- [Customization Guide](docs/customization.md) — config.env variables explained
- [Security Baseline](docs/security/README.md) — requirements, headers, audit cadence
- [Audit Report Template](docs/TEMPLATE.md) — blank template for documenting findings
- [VPS Hardening Guide](docs/VPS_HARDENING_GUIDE.html) — standalone offline reference
- [Changelog](CHANGELOG.md) — version history

---

## License

MIT — use freely, adapt for your own infrastructure.
