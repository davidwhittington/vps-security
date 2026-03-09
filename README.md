# linux-security

A layered hardening toolkit for Ubuntu/Debian servers. Two profiles: `baseline` (any server) and `web-server` (Apache/PHP/MySQL addendum). One config file, one command.

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
| Core hardening scripts (01–08) | Complete |
| Web hardening scripts (01–10) | Complete |
| `config.env` / `config.web.env` configuration | Complete |
| `bootstrap.sh` with `--profile` support | Complete |
| `scripts/audit/audit.sh` baseline checker | Complete |
| `scripts/core/audit/` extended audit tools | Complete |
| `scripts/web/audit/` web audit tools | Complete |
| Nginx support | Planned (Phase 2) |
| Multi-server fleet tooling | Planned (Phase 2) |

See the [open issues](https://github.com/davidwhittington/linux-security/issues) for the full phased roadmap.

---

## What It Hardens

| Area | Coverage |
|---|---|
| **Firewall** | UFW — deny all inbound, allow SSH / 80 / 443 |
| **SSH** | Key-only auth, no root password login, no X11 forwarding |
| **Intrusion Prevention** | fail2ban with SSH + Apache jails, 3 strikes / 1 hour ban; recidive jail for repeat offenders |
| **Kernel Network** | ICMP redirect blocking, martian packet logging |
| **Rootkit Detection** | rkhunter with scheduled scans |
| **Syscall Auditing** | auditd with baseline ruleset |
| **Filesystem Integrity** | AIDE — baseline snapshot + scheduled diff |
| **Apache** | `ServerTokens Prod`, `ServerSignature Off`, security headers, HSTS, CSP, block `.git`/`.svn`, disable `mod_status` (web-server profile) |
| **TLS** | Modern cipher suite, HSTS preload, cert expiry monitoring (web-server profile) |
| **Admin User** | Non-root sudo user with SSH key access |
| **Automatic Updates** | `unattended-upgrades` + monthly full upgrade with email report |
| **Log Monitoring** | Logwatch daily digest + GoAccess traffic reports, password-protected (web-server profile) |
| **Malware Scanning** | ClamAV with scheduled scans (web-server profile) |
| **WAF** | ModSecurity with OWASP Core Rule Set (web-server profile) |

---

## Prerequisites

- Ubuntu 22.04+ or Debian 12+
- Root access
- **SSH public key already in `/root/.ssh/authorized_keys`** before running — script `core/01` disables password authentication and aborts if no key is present

For the **web-server profile**, Apache 2.4 must be installed and running. PHP and MySQL/MariaDB hardening scripts are optional and will skip cleanly if those services are not present.

---

## Quick Start

**1. Clone and configure**

```bash
git clone https://github.com/davidwhittington/linux-security.git
cd linux-security
cp config.env config.env.local   # or edit config.env directly
```

Edit `config.env` and set your values: admin username, email address, SMTP relay, and SSH port.

For the web-server profile, also fill in `config.web.env` (CSP domains, cert warn threshold, web roots path).

See [docs/customization.md](docs/customization.md) for details on every variable.

**2. Run**

Option A — single command (recommended):

```bash
# As root on the target server
bash bootstrap.sh --profile baseline     # core controls only (any server)
bash bootstrap.sh --profile web-server   # core + Apache/PHP/MySQL hardening
bash bootstrap.sh --dry-run              # preview all changes first
bash bootstrap.sh --profile baseline --dry-run
```

Option B — run scripts individually in order:

```bash
# Core layer
bash scripts/core/hardening/01-immediate-hardening.sh   # Firewall · SSH · fail2ban · sysctl
bash scripts/core/hardening/02-setup-admin-user.sh      # Non-root admin with sudo + SSH keys
bash scripts/core/hardening/03-monthly-updates-setup.sh # Scheduled apt upgrades + email report

# Web layer (web-server profile only)
bash scripts/web/hardening/01-apache-hardening.sh       # Apache headers · TLS · mod_status
bash scripts/web/hardening/02-log-monitoring-setup.sh   # Logwatch + GoAccess traffic reports
bash scripts/web/hardening/03-cert-monitor-setup.sh     # Cert expiry monitoring
```

**3. Verify**

```bash
bash scripts/audit/audit.sh                      # web-server checks (default)
bash scripts/audit/audit.sh --profile baseline   # core checks only
```

> **After running `core/01`:** Open a second terminal and verify SSH access before closing your current session. Password authentication will be disabled.

---

## Scripts

### Core Layer

Available in both profiles. No Apache or web-server dependency.

---

#### `core/01-immediate-hardening.sh` — Critical Fixes

Addresses the highest-risk issues found on most freshly provisioned servers.

- Installs and configures **fail2ban** with SSH jail (3 strikes, 1h ban) and Apache jails
- Enables **UFW** with deny-all inbound policy; opens SSH port, 80, 443
- Disables **SSH password authentication** and root password login
- Disables **X11 forwarding**
- Hardens **kernel sysctl**: disables ICMP redirects, enables martian logging

Safe to re-run. Aborts if no SSH authorized key is found.

---

#### `core/02-setup-admin-user.sh` — Admin User

Promotes an existing user to sudo admin and removes the cloud-init NOPASSWD sudoers rule.

- Sets login shell to `/bin/bash`
- Adds user to `sudo` group
- Copies root's `authorized_keys` so SSH access works immediately
- Removes `/etc/sudoers.d/90-cloud-init-users`

Admin username is set from `$ADMIN_USER` in `config.env`. The user must exist before running.

After verifying SSH access and `sudo -v` work, set `PermitRootLogin no` in `/etc/ssh/sshd_config`.

---

#### `core/03-monthly-updates-setup.sh` — Scheduled Updates

Sets up a monthly full system update with an emailed report.

- Installs and configures `msmtp` with your SMTP relay settings
- Creates `/usr/local/sbin/monthly-apt-report.sh` — runs `apt upgrade`, checks kernel version, disk usage, uptime, fail2ban status, and cert expiry
- Schedules a cron job at 3:00 AM on the 1st of each month

Email address and SMTP settings read from `config.env`.

---

#### `core/04–08` — Defense in Depth

Additional hardening applied after the baseline is established:

| Script | Installs / Configures |
|---|---|
| `04-rkhunter-setup.sh` | rkhunter rootkit scanner with scheduled scans and email alerts |
| `05-auditd-setup.sh` | auditd syscall auditing with a baseline ruleset |
| `06-fail2ban-recidive.sh` | fail2ban recidive jail — escalating bans for repeat offenders |
| `07-aide-setup.sh` | AIDE filesystem integrity baseline and nightly diff |
| `08-disk-alert-setup.sh` | Disk usage cron — emails when any partition crosses threshold |

---

### Web Layer

Applied only with `--profile web-server`. Requires Apache 2.4 running.

---

#### `web/01-apache-hardening.sh` — Apache Security

Reduces information disclosure and adds browser security headers.

- Enables `mod_headers`
- Sets `ServerTokens Prod` and `ServerSignature Off`
- Disables TRACE method
- Blocks access to `.git` and `.svn` directories
- Adds security headers: `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, HSTS, CSP
- Disables `mod_status`
- Backs up existing `security.conf` before overwriting; restores on failure

CSP `frame-ancestors` is set from `$CSP_FRAME_ANCESTORS` in `config.web.env`.

---

#### `web/02-log-monitoring-setup.sh` — Log Monitoring

Installs daily log digest and traffic reporting.

- Installs **Logwatch** — configures a daily HTML email digest of all services
- Installs **GoAccess** — generates a daily HTML traffic report from Apache access logs
- Password-protects the reports directory with HTTP Basic Auth
- Schedules GoAccess at 4:00 AM daily

Reports are served from `/var/www/html/reports/`.

---

#### `web/03-cert-monitor-setup.sh` — Certificate Monitoring

Configures automated TLS cert expiry alerts.

- Installs a daily cron that checks cert expiry via `certbot certificates`
- Emails a warning when any cert is within `$CERT_WARN_DAYS` days of expiry (default: 30)

---

#### `web/04–10` — Extended Web Hardening

| Script | Installs / Configures |
|---|---|
| `04-clamav-setup.sh` | ClamAV with scheduled scans of web roots |
| `05-modsecurity-setup.sh` | ModSecurity WAF with OWASP Core Rule Set |
| `06-vhost-hardener.sh` | Per-vhost security headers and directory restrictions |
| `07-apache-tls-hardening.sh` | Modern cipher suite, HSTS preload, OCSP stapling |
| `08-apache-dos-mitigation.sh` | mod_evasive and mod_reqtimeout tuning |
| `09-php-hardening.sh` | PHP ini hardening (skips cleanly if PHP not installed) |
| `10-mysql-hardening.sh` | MySQL/MariaDB secure defaults (skips cleanly if not installed) |

---

## Repository Structure

```
linux-security/
├── config.env                   # Core configuration — fill in before running
├── config.web.env               # Web-layer configuration — needed for web-server profile
├── bootstrap.sh                 # Single-command provisioner
├── profiles/
│   ├── baseline.conf            # Core-only script list
│   └── web-server.conf          # Core + web script list
├── docs/
│   ├── security/
│   │   └── README.md            # Security baseline, requirements, audit cadence
│   ├── architecture.md          # How the toolkit fits together
│   ├── customization.md         # config.env and config.web.env variables explained
│   ├── TEMPLATE.md              # Blank audit report template
│   └── VPS_HARDENING_GUIDE.html # Standalone HTML knowledge base (offline reference)
├── scripts/
│   ├── core/
│   │   ├── hardening/           # Core hardening scripts (01–08)
│   │   └── audit/               # Core read-only checkers
│   ├── web/
│   │   ├── hardening/           # Web hardening scripts (01–10)
│   │   └── audit/               # Web read-only checkers
│   └── audit/
│       └── audit.sh             # Profile-aware baseline checker
├── lib/                         # Shared shell libraries
├── logs/                        # Per-run bootstrap logs (gitignored)
├── config/                      # Config snippets and templates (planned)
└── private/                     # Git submodule — server-specific data (not public)
```

---

## Auditing a Server

Run the built-in checker after hardening to verify every control is active:

```bash
bash scripts/audit/audit.sh                      # web-server checks (default)
bash scripts/audit/audit.sh --profile baseline   # core checks only
bash scripts/audit/audit.sh --json               # machine-readable output
bash scripts/audit/audit.sh --report html        # full HTML report
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
gh repo fork davidwhittington/linux-security

# Create your own private companion repo
gh repo create my-linux-private --private

# Add it as a submodule
git submodule add https://github.com/<you>/my-linux-private private/
git commit -m "Add private submodule"
```

---

## Docs

- [Customization Guide](docs/customization.md) — config.env and config.web.env variables explained
- [Architecture](docs/architecture.md) — how the toolkit fits together
- [Security Baseline](docs/security/README.md) — requirements, headers, audit cadence
- [Audit Report Template](docs/TEMPLATE.md) — blank template for documenting findings
- [VPS Hardening Guide](docs/VPS_HARDENING_GUIDE.html) — standalone offline reference
- [Changelog](CHANGELOG.md) — version history

---

## License

MIT — use freely, adapt for your own infrastructure.
