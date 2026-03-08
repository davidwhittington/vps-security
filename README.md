# vps-security

A production-ready hardening toolkit for Ubuntu/Debian VPS servers running Apache. Five focused scripts that address the most common critical vulnerabilities on freshly provisioned servers — firewall, SSH hardening, intrusion prevention, Apache security headers, automatic updates, and log monitoring.

Designed to be **auditable, sequential, and safe** — each script is idempotent, validates preconditions before making changes, and backs up any files it modifies.

**Tested on:** Ubuntu 24.04 LTS (Noble Numbat) · Apache 2.4

---

## Background

This toolkit came out of necessity. Managing a growing number of projects across multiple VPS providers made it clear that ad-hoc server setup wasn't sustainable — every new deployment meant repeating the same hardening steps from memory, with inconsistent results and no audit trail.

The goal was a standardized, repeatable baseline: cookie-cutter deployments that could stand up a secure server quickly, while still being flexible enough to accommodate the custom, one-off requirements that inevitably come with running a variety of distinct projects. Each server has its own quirks — different domain configurations, monitoring needs, or access patterns — and the toolkit is structured to handle both the common baseline and those edge cases without diverging into a tangle of server-specific scripts.

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

- Ubuntu 22.04+ or Debian 12+ (other Debian-based distros may work)
- Apache 2.4 installed and running
- Root or sudo access
- **SSH public key already in `/root/.ssh/authorized_keys`** — Script 01 will abort if this is missing, as it disables password authentication

---

## Quick Start

Clone the repo on your local machine (or directly on the server) and run scripts in order:

```bash
git clone https://github.com/davidwhittington/vps-security.git
cd vps-security
chmod +x scripts/hardening/*.sh
```

> **Read each script before running.** See [docs/customization.md](docs/customization.md) for variables to update (username, email, domain names) before executing.

```bash
# Run as root on the target server

bash scripts/hardening/01-immediate-hardening.sh   # Firewall · SSH · fail2ban · sysctl
bash scripts/hardening/02-apache-hardening.sh      # Apache headers · TLS · mod_status
bash scripts/hardening/03-setup-admin-user.sh      # Non-root admin with sudo + SSH keys
bash scripts/hardening/04-monthly-updates-setup.sh # Scheduled apt upgrades + email report
bash scripts/hardening/05-log-monitoring-setup.sh  # Logwatch + GoAccess traffic reports
```

> **After running script 01:** Open a second terminal and verify SSH access before closing your current session. Password authentication will be disabled.

---

## Scripts

### `01-immediate-hardening.sh` — Critical Fixes

Addresses the highest-risk issues found on most freshly provisioned VPS instances.

- Installs and configures **fail2ban** (3 failed attempts = 1 hour ban)
- Enables **UFW** with deny-all inbound policy; opens ports 22, 80, 443
- Disables **SSH password authentication** and root password login
- Disables **X11 forwarding**
- Hardens **kernel sysctl**: disables ICMP redirects, enables martian logging

**Safe to re-run.** Aborts if no SSH authorized key is found.

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

**Customize:** Update the CSP `frame-ancestors` directive in the script to list your own domains. See [docs/customization.md](docs/customization.md).

---

### `03-setup-admin-user.sh` — Admin User

Creates a proper non-root admin user and removes the cloud-init NOPASSWD sudoers rule.

- Sets login shell to `/bin/bash`
- Adds user to `sudo` group
- Copies root's `authorized_keys` so SSH access works immediately
- Removes `/etc/sudoers.d/90-cloud-init-users` (the overly permissive cloud-init rule)

**Customize:** Change `USERNAME` at the top of the script before running.

After verifying the new user can SSH in and run `sudo -v`, update `/etc/ssh/sshd_config` to set `PermitRootLogin no`.

---

### `04-monthly-updates-setup.sh` — Scheduled Updates

Sets up a monthly full system update with an emailed report.

- Installs `msmtp` and `mailutils`
- Creates `/usr/local/sbin/monthly-apt-report.sh` — runs `apt upgrade`, checks kernel version, disk usage, uptime, fail2ban status, and cert expiry
- Schedules a cron job at 3:00 AM on the 1st of each month
- Emails the full report on completion

**Customize:** Set `EMAIL` and configure your SMTP relay in the script. See [docs/customization.md](docs/customization.md).

---

### `05-log-monitoring-setup.sh` — Log Monitoring

Installs daily log digest and traffic reporting.

- Installs **Logwatch** — configures daily HTML email digest of all services
- Installs **GoAccess** — generates a daily HTML traffic report from Apache access logs
- Password-protects the reports directory with HTTP Basic Auth (auto-generates a password, printed at the end)
- Schedules GoAccess at 4:00 AM daily

**Customize:** Set `EMAIL` and `MAIL_FROM` before running. Reports are served from `/var/www/html/reports/` — restrict access further if needed.

---

## Repository Structure

```
vps-security/
├── docs/
│   ├── security/
│   │   └── README.md            # Security baseline and audit cadence
│   ├── customization.md         # What to change before running the scripts
│   ├── TEMPLATE.md              # Blank audit report template
│   └── VPS_HARDENING_GUIDE.html # Standalone HTML knowledge base (offline reference)
├── scripts/
│   ├── hardening/               # The five hardening scripts (run in order)
│   └── audit/                   # Audit scripts (coming soon)
├── config/                      # Config snippets and templates (coming soon)
└── private/                     # Git submodule — server-specific data (not public)
```

---

## Auditing a Server

Use the included template to document findings before and after hardening:

1. Copy `docs/TEMPLATE.md` to your notes or private repo
2. Walk through each finding category against your server
3. Use the checklist at the end to track remediation progress

See [docs/security/README.md](docs/security/README.md) for the full security baseline this toolkit is built against.

---

## Using This as a Template for Your Infrastructure

This repo is structured to keep **generic, reusable scripts public** and **server-specific data private**. The `private/` directory is a separate private git submodule that holds actual audit reports, inventory, and network data.

To adopt this pattern for your own infrastructure:

```bash
# 1. Fork or clone this repo
gh repo fork davidwhittington/vps-security

# 2. Create your own private companion repo
gh repo create my-vps-private --private

# 3. Add it as a submodule
git submodule add https://github.com/<you>/my-vps-private private/
git commit -m "Add private submodule"
```

Store things like real audit reports with IPs and hostnames, SSH key lists, and network topology in `private/` — they stay out of the public repo automatically.

---

## Docs

- [Security Baseline](docs/security/README.md) — requirements, headers, audit cadence
- [Customization Guide](docs/customization.md) — what to change before running scripts
- [Audit Report Template](docs/TEMPLATE.md) — blank template for documenting findings
- [VPS Hardening Guide](docs/VPS_HARDENING_GUIDE.html) — standalone offline reference
- [Changelog](CHANGELOG.md) — version history

---

## License

MIT — use freely, adapt for your own infrastructure.
