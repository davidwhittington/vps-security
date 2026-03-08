# Changelog

All notable changes to vps-security are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.5.0] — 2026-03-08

### Added
- `scripts/audit/verify.sh` — post-run artifact and state checker organized per-script; confirms each hardening script's specific changes took effect (files written, services running, cron jobs present, user configuration); `--brief` flag suppresses passing checks; exits 1 on any failure
- `.github/workflows/lint.yml` — CI pipeline running `shellcheck` (warning severity) and `bash -n` syntax check across all `.sh` files on push and PR

### Changed
- `bootstrap.sh`: runs `verify.sh --brief` automatically after a successful full hardening run, before the final summary

---

## [0.4.0] — 2026-03-08

### Added
- `config.env` — central configuration file; all user-specific variables (SSH port, admin user, email, SMTP settings, CSP domains) now live in one place; scripts auto-discover it at repo root or `/etc/vps-security/config.env` with per-variable defaults as fallback
- `bootstrap.sh` — single-command provisioner; sources `config.env`, runs all five hardening scripts in order with per-script log files under `logs/`, aborts on first failure, supports `--dry-run`
- `scripts/audit/audit.sh` — read-only baseline checker; validates UFW rules, SSH config, fail2ban jails (SSH + Apache), Apache security headers, pending updates, and TLS cert expiry; color-coded PASS/WARN/FAIL output; exits 1 on any FAIL; `--json` flag for machine-readable output

### Changed
- All five hardening scripts now auto-discover and source `config.env`; hardcoded values (username, email, SSH port, CSP domains) replaced with config variables
- All five hardening scripts now support `--dry-run` — prints every change that would be made without touching the system
- `01-immediate-hardening.sh`: banner no longer hardcodes hostname (uses `hostname -f`); SSH port reads from `$SSH_PORT`
- `02-apache-hardening.sh`: CSP `frame-ancestors` reads from `$CSP_FRAME_ANCESTORS`
- `03-setup-admin-user.sh`: admin username reads from `$ADMIN_USER`; aborts with a clear error if unset or user does not exist
- `04-monthly-updates-setup.sh`: email and SMTP settings read from config; msmtp configured with auth block when `SMTP_USER` is set
- `05-log-monitoring-setup.sh`: email/from-address read from config; GoAccess report title uses live hostname

### Fixed
- `01-immediate-hardening.sh`: added `apache-auth`, `apache-badbots` (24h ban, 1-strike), and `apache-noscript` fail2ban jails — Apache jails were previously absent despite Apache being the primary attack surface

---

## [0.3.0] — 2026-03-08

### Changed
- Rewrote README with full script breakdowns, prerequisites, quick start, per-script customization callouts, and private submodule usage pattern for adopters
- Expanded `docs/security/README.md` — added requirement table, fail2ban minimum config block, quick verification commands, and audit cadence table
- Expanded `docs/TEMPLATE.md` — added remediation plan section, fuller finding categories, and comprehensive hardening checklist organized by area

### Added
- `docs/customization.md` — per-script guide to every hardcoded variable (username, email, SMTP relay, SSH port, CSP domains) with copy-paste examples

---

## [0.2.0] — 2026-03-08

### Changed
- Restructured repo layout to align with mac-deploy conventions — scripts moved to `scripts/hardening/`, HTML guide moved to `docs/`
- Moved `AUDIT_REPORT.md` (contains real server IPs and hostnames) out of the public repo and into the private submodule
- Rewrote README for public audience — removed server-specific references, added private submodule adoption pattern
- Updated `.gitignore` — added `*.log` and `audit-*.txt` patterns

### Added
- `docs/security/README.md` — security baseline requirements, security headers block, and audit cadence
- `docs/TEMPLATE.md` — blank audit report template with finding categories and hardening checklist
- `private/` — git submodule pointing to `vps-security-private` (private companion repo for server-specific data)
- `scripts/audit/` and `config/` directories for future expansion

### Removed
- `AUDIT_REPORT.md` from public repo — relocated to `private/servers/server1.ipvegan.com/`

---

## [0.1.0] — 2026-03-04

### Added
- `scripts/hardening/01-immediate-hardening.sh` — installs fail2ban, enables UFW (22/80/443), disables SSH password auth and root login, disables X11 forwarding, hardens sysctl (ICMP redirects, martian logging); aborts safely if no SSH key is present
- `scripts/hardening/02-apache-hardening.sh` — enables `mod_headers`, sets `ServerTokens Prod` / `ServerSignature Off`, disables TRACE, blocks `.git`/`.svn` access, applies full security header suite (HSTS, CSP, X-Content-Type-Options, Referrer-Policy, Permissions-Policy), disables `mod_status`; backs up and restores `security.conf` on failure
- `scripts/hardening/03-setup-admin-user.sh` — promotes existing user to sudo, sets bash shell, copies root SSH keys, removes cloud-init NOPASSWD sudoers rule
- `scripts/hardening/04-monthly-updates-setup.sh` — installs msmtp + mailutils, creates `/usr/local/sbin/monthly-apt-report.sh` (apt upgrade, kernel check, disk, uptime, fail2ban status, cert expiry), schedules cron at 3 AM on the 1st of each month
- `scripts/hardening/05-log-monitoring-setup.sh` — installs Logwatch (daily HTML email digest) and GoAccess (daily traffic report), password-protects reports directory via HTTP Basic Auth, schedules GoAccess at 4 AM daily
- `docs/VPS_HARDENING_GUIDE.html` — standalone offline reference covering all hardening areas
- `AUDIT_REPORT.md` — full security audit of initial server state with findings at CRITICAL / HIGH / MEDIUM / LOW / INFO severity and a prioritized remediation plan

### Fixed
- SSH service reload uses correct service name (`ssh` not `sshd`) on Ubuntu 24.04
- Apache CSP uses `frame-ancestors` instead of `X-Frame-Options` to support cross-domain iframe embedding within the same infrastructure
