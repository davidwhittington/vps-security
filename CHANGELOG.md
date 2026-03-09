# Changelog

All notable changes to linux-security are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [1.0.0] — 2026-03-09

### Added
- `profiles/baseline.conf` — script manifest for core-only hardening; runs on any Ubuntu/Debian server with no Apache dependency
- `profiles/web-server.conf` — script manifest for full stack hardening; core + Apache/PHP/MySQL (default, back-compatible with v0.x)
- `config.web.env` — web-server-specific configuration file; separates `CSP_FRAME_ANCESTORS`, `CERT_WARN_DAYS`, and `WEB_ROOTS_DIR` from the core `config.env`
- `docs/MIGRATION.md` — maps old script numbers and paths to their new locations for users upgrading from v0.x

### Changed
- Repo renamed `vps-security` → `linux-security`; GitHub redirects old clone URLs automatically
- `scripts/hardening/` split into `scripts/core/hardening/` (8 scripts + ssh-key-rotate) and `scripts/web/hardening/` (10 scripts + rollback)
- `scripts/audit/` split into `scripts/core/audit/` (12 scripts) and `scripts/web/audit/` (5 scripts); `audit.sh` remains at `scripts/audit/audit.sh` as a profile-aware dispatcher
- All scripts renumbered within their new layer (core: 01–08, web: 01–10); see `docs/MIGRATION.md` for the full mapping
- `bootstrap.sh` — added `--profile baseline|web-server` flag; default is `web-server` (back-compat); reads script list from `profiles/<name>.conf` instead of a hardcoded array; also loads `config.web.env` for web-server profile
- `scripts/audit/audit.sh` — added `--profile baseline|web-server` flag; baseline profile skips Apache and TLS certificate sections; profile shown in console output, JSON, and reports
- Config path in all scripts updated: `../../config.env` → `../../../config.env` (3-level depth from `scripts/{core,web}/{hardening,audit}/`)
- All system-wide install paths updated: `/etc/vps-security/` → `/etc/linux-security/`
- Web hardening scripts now load `config.web.env` in addition to `config.env` for web-specific variables

---

## [0.9.0] — 2026-03-09

### Added
- `scripts/audit/memory-check.sh` — RAM and swap health check; flags servers with < 512MB RAM, no swap on low-RAM systems, swap usage > 80%, memory pressure < 10% available, and OOM kill events in kernel log (#66)
- `scripts/audit/vhost-linter.sh` — Apache vhost config linter; checks each enabled vhost for missing security headers (HSTS, X-Content-Type-Options, Referrer-Policy, CSP), Options Indexes, AllowOverride All, SSL config on port 443 vhosts, and HTTP-to-HTTPS redirect; also checks global ServerTokens/ServerSignature/TraceEnable (#58)
- `scripts/audit/preflight-check.sh` — dependency pre-flight check; verifies OS compatibility (Ubuntu/Debian), root privilege, SSH authorized_keys presence, required commands, per-script package availability, config.env and ADMIN_EMAIL, and internet connectivity (#54)
- `scripts/audit/web-root-perms.sh` — web root file permission scanner; finds world-writable files/directories, unexpected ownership (not www-data or root), executable non-script files (webshell risk), PHP files with obfuscated eval() patterns, and sensitive files (.env, wp-config.php) with world-readable permissions; `--webroot` flag (#71)
- `scripts/hardening/15-aide-setup.sh` — AIDE file integrity monitoring; installs aide, writes a focused config covering critical system paths (/etc, /bin, /sbin, SSH, sudoers, cron, vps-security scripts), initializes database, schedules weekly Sunday 4 AM check with email alert on changes (#49)
- `scripts/hardening/16-php-hardening.sh` — PHP security baseline; auto-detects all installed PHP versions and SAPIs; applies: expose_php=Off, disable_functions (exec/system/passthru/etc.), allow_url_fopen=Off, allow_url_include=Off, display_errors=Off, secure session cookies (httponly/secure/samesite), upload limits; backs up each php.ini before modifying (#43)
- `scripts/hardening/17-mysql-hardening.sh` — MySQL/MariaDB security baseline; removes anonymous users, removes remote root login, drops test database, flushes privileges; writes `/etc/mysql/conf.d/security.cnf` with bind-address=127.0.0.1, local-infile=0, symbolic-links=0, skip-show-database; uses socket auth (#67)
- `scripts/hardening/18-disk-alert-setup.sh` — disk usage alerting cron; creates `/usr/local/sbin/disk-usage-check.sh` checking all filesystems (disk and inode usage) against configurable `DISK_WARN_PCT` threshold (default 80%); emails `ADMIN_EMAIL` on breach; daily 7 AM cron (#42)
- `scripts/hardening/ssh-key-rotate.sh` — SSH key rotation helper; `--show` displays current keys with fingerprints; `--add-key` validates and adds a new key; `--remove-line N` removes an old key by line number with lockout protection (refuses to remove last key); `--user` targets non-root users; backs up authorized_keys before every change (#47)
- `docs/INCIDENT_RESPONSE.md` — IR playbook; severity levels (P1-P4), first response commands, scenario playbooks (brute-force SSH, webshell, unauthorized root access, AIDE alert, suspicious process, disk exhaustion), containment options, evidence collection, post-incident re-baselining (#60)
- `docs/PROVIDER_NOTES.md` — per-provider gotchas and configuration notes; covers DigitalOcean, Hetzner, Vultr, Linode/Akamai, AWS EC2/Lightsail, OVH; cloud firewall interaction, console access, private networking, cloud-init quirks (#50)

---

## [0.8.0] — 2026-03-09

### Added
- `lib/output.sh` — shared console output library; `check_pass/fail/warn/info`, `banner`, `section_header`, `summary`; auto-disables color when not a TTY; new audit scripts source this rather than duplicating color logic (#55)
- `scripts/audit/firewall-check.sh` — UFW rules validator; active status, default deny-incoming, required port rules (SSH/HTTP/HTTPS), and rate-limiting on 80/443 (#38)
- `scripts/audit/users-check.sh` — privileged user audit; UID-0 accounts, login-shell users, sudo group membership, NOPASSWD sudoers rules, empty passwords, locked accounts with SSH keys (#62)
- `scripts/audit/services-check.sh` — systemd service baseline and drift detector; `--update` refreshes baseline (#52)
- `scripts/audit/cron-audit.sh` — full cron inventory (crontab, /etc/cron.d/, periodic dirs, user crontabs); flags root jobs executing scripts in world-writable directories (#56)
- `scripts/audit/smtp-check.sh` — SMTP relay health check; msmtp install, config, TCP reachability, log errors; `--send` flag sends a live test email (#44)
- `scripts/hardening/12-apache-tls-hardening.sh` — TLS 1.2+, modern ECDHE/DHE cipher suites, SSLHonorCipherOrder, OCSP stapling, no session tickets (#59)
- `scripts/hardening/13-apache-dos-mitigation.sh` — mod_reqtimeout (Slowloris) and mod_evasive (HTTP flood) with tuned defaults and optional email alert (#48, #45)
- `scripts/hardening/14-fail2ban-recidive.sh` — recidive jail (1-week ban after 5 bans in 12h) and SSH login email notification via /etc/ssh/sshrc (#40, #41)
- `CONTRIBUTING.md` — script style guide, dry-run requirements, idempotency rules, config convention, output standards, PR process, shellcheck requirements (#63)
- `docs/UPGRADE.md` — guide for re-applying updated scripts to existing servers; covers CHANGELOG review, dry-run, targeted re-runs, rollback, version tracking (#65)

### Changed
- `scripts/audit/audit.sh`: `--report [md|html]` generates a formatted audit report with FAIL/WARN/PASS sections and per-finding remediation suggestions; `--output <path>` sets the output file; remediation text added to all checks

---

## [0.7.0] — 2026-03-08

### Added
- `scripts/hardening/07-rkhunter-setup.sh` — installs rkhunter, configures email alerts, sets clean-system baseline (`--propupd`), and schedules weekly Sunday scan via cron (#16)
- `scripts/hardening/08-auditd-setup.sh` — installs auditd and audispd-plugins, writes CIS Benchmark-aligned ruleset covering identity changes, DAC permissions, SUID execution, mounts, deletions, sudo, kernel modules, and SSH key changes (#17)
- `scripts/hardening/09-clamav-setup.sh` — installs ClamAV, updates definitions via freshclam, creates weekly web-root scan script with quarantine and email alert on detection, schedules Saturday 2 AM cron (#24)
- `scripts/hardening/10-modsecurity-setup.sh` — installs mod_security2, configures OWASP CRS in DetectionOnly mode (safe default), writes Apache include, and creates audit log at `/var/log/apache2/modsec_audit.log` (#18)
- `scripts/hardening/11-vhost-hardener.sh` — writes `/etc/apache2/conf-available/vhost-hardening.conf` applying `Options -Indexes -FollowSymLinks`, `AllowOverride None`, and access rules blocking dotfiles, VCS directories, backup files, and env files across all web roots (#12)
- `scripts/hardening/rollback.sh` — restores `.bak` backups created by scripts 01, 02, 04, and 05; supports `--script <01|02|04|05|all>` and `--dry-run` (#8)
- `scripts/audit/suid-check.sh` — scans filesystem for SUID/SGID binaries, compares against saved baseline, flags new additions; `--update` flag refreshes the baseline; exits 1 on unexpected drift (#20)
- `docs/RUNBOOK.md` — operational runbook covering provisioning, cert renewal, SSH key rotation, fail2ban unban, disk space, audit failures, rollback, adding domains, and full server rebuild (#29)
- `private/servers/inventory.yml` — server inventory schema with all domains and configuration metadata for server1.ipvegan.com (#14)

### Changed
- `docs/customization.md`: added per-server `config.env.local` override pattern for multi-server deployments (#30); added Debian 12 compatibility notes with key differences from Ubuntu 24.04 (#9)

---

## [0.6.0] — 2026-03-08

### Added
- `scripts/hardening/06-cert-monitor-setup.sh` — weekly certbot certificate expiry monitor; creates `/usr/local/sbin/cert-expiry-check.sh` and schedules a Monday 8 AM cron; emails `ADMIN_EMAIL` when any cert expires within `CERT_WARN_DAYS` (default 30); reports expired and soon-to-expire certs separately (#13)
- `scripts/audit/ports-check.sh` — scans listening TCP ports via `ss -tlnp`; compares against `ALLOWED_PORTS` from config (SSH, 80, 443) and flags unexpected listeners; exits 1 on unexpected ports (#10)
- `scripts/audit/unattended-upgrades-check.sh` — verifies unattended-upgrades is installed, service active, last-run recency (from log mtime), errors in last run, held-back packages, and config file presence (#11)
- `scripts/audit/web-roots-writable.sh` — finds world-writable files and directories under `/var/www`; exits 1 if any are found (#21)
- `scripts/audit/headers-check.sh` — auto-detects domains from enabled Apache vhosts or `DOMAINS` in config; `curl -sI` checks each for HSTS, X-Content-Type-Options, Referrer-Policy, CSP, and bare `Server` header (#22)
- `scripts/audit/ssh-audit.sh` — runs `sshd -T` and checks all key hardening settings (PasswordAuthentication, PermitRootLogin, MaxAuthTries, X11Forwarding, AllowTcpForwarding, etc.); flags weak ciphers, MACs, and KexAlgorithms (#27)
- `scripts/audit/apparmor-check.sh` — checks AppArmor kernel module, runs `aa-status`, reports enforce vs complain profile counts, flags profiles not in enforce mode (#32)

### Changed
- `01-immediate-hardening.sh`: now backs up `sshd_config` before modification; writes `/etc/ssh/sshd_config.d/99-hardening.conf` restricting ciphers to AES-GCM/ChaCha20, MACs to HMAC-SHA2/ETM variants, and KexAlgorithms to Curve25519/ECDH/DH group14/16/18; adds `MaxAuthTries 3`, `LoginGraceTime 30`, `AllowTcpForwarding no` (#19); adds `ufw limit 80/tcp` and `ufw limit 443/tcp` rate-limiting (#25); extends `/etc/sysctl.d/99-hardening.conf` with IP forwarding disabled, TCP SYN cookies, source routing disabled, ICMP broadcast ignore, and reverse path filtering (#28)
- `05-log-monitoring-setup.sh`: adds step 5 writing `/etc/logrotate.d/vps-security` for monthly rotation (12-month retention, compressed) of toolkit log files (#26)

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
