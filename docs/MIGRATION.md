# Migration Guide: vps-security → linux-security

This document maps old script paths and numbers to their new locations after the v1.0.0 refactor.

---

## What Changed

The repo was renamed from `vps-security` to `linux-security` and reorganized into two layers:

- `scripts/core/` — works on any Ubuntu/Debian server (no Apache dependency)
- `scripts/web/` — Apache, PHP, MySQL, certbot, web-specific tooling

A `--profile` flag was added to `bootstrap.sh` and `audit.sh`:
- `--profile baseline` — runs core scripts only
- `--profile web-server` — runs core + web scripts (default, back-compatible)

---

## Hardening Scripts

### Core hardening (`scripts/core/hardening/`)

| Old path | New path | Change |
|---|---|---|
| `scripts/hardening/01-immediate-hardening.sh` | `scripts/core/hardening/01-immediate-hardening.sh` | Number unchanged |
| `scripts/hardening/03-setup-admin-user.sh` | `scripts/core/hardening/02-setup-admin-user.sh` | Renumbered 03→02 |
| `scripts/hardening/04-monthly-updates-setup.sh` | `scripts/core/hardening/03-monthly-updates-setup.sh` | Renumbered 04→03 |
| `scripts/hardening/07-rkhunter-setup.sh` | `scripts/core/hardening/04-rkhunter-setup.sh` | Renumbered 07→04 |
| `scripts/hardening/08-auditd-setup.sh` | `scripts/core/hardening/05-auditd-setup.sh` | Renumbered 08→05 |
| `scripts/hardening/14-fail2ban-recidive.sh` | `scripts/core/hardening/06-fail2ban-recidive.sh` | Renumbered 14→06 |
| `scripts/hardening/15-aide-setup.sh` | `scripts/core/hardening/07-aide-setup.sh` | Renumbered 15→07 |
| `scripts/hardening/18-disk-alert-setup.sh` | `scripts/core/hardening/08-disk-alert-setup.sh` | Renumbered 18→08 |
| `scripts/hardening/ssh-key-rotate.sh` | `scripts/core/hardening/ssh-key-rotate.sh` | Moved, name unchanged |

### Web hardening (`scripts/web/hardening/`)

| Old path | New path | Change |
|---|---|---|
| `scripts/hardening/02-apache-hardening.sh` | `scripts/web/hardening/01-apache-hardening.sh` | Renumbered 02→01 |
| `scripts/hardening/05-log-monitoring-setup.sh` | `scripts/web/hardening/02-log-monitoring-setup.sh` | Renumbered 05→02 |
| `scripts/hardening/06-cert-monitor-setup.sh` | `scripts/web/hardening/03-cert-monitor-setup.sh` | Renumbered 06→03 |
| `scripts/hardening/09-clamav-setup.sh` | `scripts/web/hardening/04-clamav-setup.sh` | Renumbered 09→04 |
| `scripts/hardening/10-modsecurity-setup.sh` | `scripts/web/hardening/05-modsecurity-setup.sh` | Renumbered 10→05 |
| `scripts/hardening/11-vhost-hardener.sh` | `scripts/web/hardening/06-vhost-hardener.sh` | Renumbered 11→06 |
| `scripts/hardening/12-apache-tls-hardening.sh` | `scripts/web/hardening/07-apache-tls-hardening.sh` | Renumbered 12→07 |
| `scripts/hardening/13-apache-dos-mitigation.sh` | `scripts/web/hardening/08-apache-dos-mitigation.sh` | Renumbered 13→08 |
| `scripts/hardening/16-php-hardening.sh` | `scripts/web/hardening/09-php-hardening.sh` | Renumbered 16→09 |
| `scripts/hardening/17-mysql-hardening.sh` | `scripts/web/hardening/10-mysql-hardening.sh` | Renumbered 17→10 |
| `scripts/hardening/rollback.sh` | `scripts/web/hardening/rollback.sh` | Moved, name unchanged |

---

## Audit Scripts

### Core audit (`scripts/core/audit/`)

| Old path | New path |
|---|---|
| `scripts/audit/apparmor-check.sh` | `scripts/core/audit/apparmor-check.sh` |
| `scripts/audit/cron-audit.sh` | `scripts/core/audit/cron-audit.sh` |
| `scripts/audit/firewall-check.sh` | `scripts/core/audit/firewall-check.sh` |
| `scripts/audit/memory-check.sh` | `scripts/core/audit/memory-check.sh` |
| `scripts/audit/ports-check.sh` | `scripts/core/audit/ports-check.sh` |
| `scripts/audit/preflight-check.sh` | `scripts/core/audit/preflight-check.sh` |
| `scripts/audit/services-check.sh` | `scripts/core/audit/services-check.sh` |
| `scripts/audit/smtp-check.sh` | `scripts/core/audit/smtp-check.sh` |
| `scripts/audit/ssh-audit.sh` | `scripts/core/audit/ssh-audit.sh` |
| `scripts/audit/suid-check.sh` | `scripts/core/audit/suid-check.sh` |
| `scripts/audit/users-check.sh` | `scripts/core/audit/users-check.sh` |
| `scripts/audit/verify.sh` | `scripts/core/audit/verify.sh` |

### Web audit (`scripts/web/audit/`)

| Old path | New path |
|---|---|
| `scripts/audit/headers-check.sh` | `scripts/web/audit/headers-check.sh` |
| `scripts/audit/unattended-upgrades-check.sh` | `scripts/web/audit/unattended-upgrades-check.sh` |
| `scripts/audit/vhost-linter.sh` | `scripts/web/audit/vhost-linter.sh` |
| `scripts/audit/web-root-perms.sh` | `scripts/web/audit/web-root-perms.sh` |
| `scripts/audit/web-roots-writable.sh` | `scripts/web/audit/web-roots-writable.sh` |

### Dispatcher (unchanged location)

`scripts/audit/audit.sh` — now profile-aware. Same path, new `--profile` flag.

---

## Config

### config.env

Unchanged location. Removed the Apache section (CSP variables). Update your copy:

```bash
# Remove this block if present — moved to config.web.env
# CSP frame-ancestors
CSP_FRAME_ANCESTORS="'self'"
```

### config.web.env (new)

Web-server-specific variables extracted from `config.env`. Copy it to the repo root:

```bash
cp config.web.env config.web.env.local  # or edit in place
```

Variables moved here:
- `CSP_FRAME_ANCESTORS` (was in `config.env`)
- `CERT_WARN_DAYS` (was inline default in `06-cert-monitor-setup.sh`)
- `WEB_ROOTS_DIR` (new, optional)

---

## bootstrap.sh

Old usage still works — default profile is `web-server`:

```bash
bash bootstrap.sh              # same as before
bash bootstrap.sh --dry-run    # same as before
```

New usage:

```bash
bash bootstrap.sh --profile baseline    # core only
bash bootstrap.sh --profile web-server  # full stack (explicit)
```

---

## audit.sh

Old usage still works:

```bash
bash scripts/audit/audit.sh          # same as before (web-server profile)
bash scripts/audit/audit.sh --json   # same as before
bash scripts/audit/audit.sh --report html
```

New usage:

```bash
bash scripts/audit/audit.sh --profile baseline    # skip Apache/TLS sections
bash scripts/audit/audit.sh --profile web-server  # full audit (default)
```

---

## System-wide install path

If you installed config to `/etc/vps-security/config.env`, move it:

```bash
mkdir -p /etc/linux-security
cp /etc/vps-security/config.env /etc/linux-security/config.env
# copy config.web.env if using web-server profile
cp /path/to/config.web.env /etc/linux-security/config.web.env
```
