# Upgrade Guide

How to apply updated linux-security scripts to an already-hardened server.

---

## Status

| Item | Detail |
|---|---|
| Applies to | Servers previously provisioned with linux-security |
| Last updated | 2026-03-09 |

---

## Overview

linux-security scripts are idempotent — safe to re-run on a server that already has them applied. The general process is:

1. Pull the latest version
2. Review the CHANGELOG for breaking changes
3. Dry-run the updated scripts
4. Apply changes script by script or via bootstrap

---

## Step-by-Step

### 1. Pull latest changes

```bash
cd linux-security
git pull origin main
```

### 2. Review the CHANGELOG

Check `CHANGELOG.md` for any breaking changes or manual migration steps before running anything.

```bash
git log --oneline HEAD@{1}..HEAD
cat CHANGELOG.md | head -60
```

### 3. Update config.env if needed

New versions may add new config variables. Compare your config against the example:

```bash
diff config.env config.env.example
```

Copy any new variables you need into your live config.

### 4. Dry-run first

Always dry-run before applying to a live server:

```bash
export CONFIG_FILE=/etc/linux-security/config.env
bash bootstrap.sh --dry-run
```

Or for a specific script:

```bash
bash scripts/core/hardening/01-immediate-hardening.sh --dry-run
```

### 5. Apply changes

**Option A — Re-run bootstrap (applies everything):**

```bash
export CONFIG_FILE=/etc/linux-security/config.env
bash bootstrap.sh
```

**Option B — Apply only changed scripts:**

If the CHANGELOG shows only scripts 05 and 06 changed:

```bash
export CONFIG_FILE=/etc/linux-security/config.env
bash scripts/web/hardening/02-log-monitoring-setup.sh
bash scripts/web/hardening/03-cert-monitor-setup.sh
```

### 6. Verify

After applying, run verify and audit to confirm everything is in order:

```bash
bash scripts/core/audit/verify.sh
bash scripts/audit/audit.sh
```

---

## Adding New Scripts

New scripts added to `scripts/hardening/` in a version upgrade are not run automatically by re-running `bootstrap.sh` if they are numbered higher than what was previously installed. Run them explicitly:

```bash
bash scripts/web/hardening/07-apache-tls-hardening.sh
bash scripts/web/hardening/08-apache-dos-mitigation.sh
```

Or re-run `bootstrap.sh` — it runs all scripts in order and is safe to run multiple times.

---

## Handling Config Changes

If a script's behavior has changed in a way that requires updated config.env values:

1. Add the new variable to `/etc/linux-security/config.env` on the target server
2. Re-run the affected script

Example — adding `CERT_WARN_DAYS` in a new version:

```bash
echo 'CERT_WARN_DAYS=21' >> /etc/linux-security/config.env
bash scripts/web/hardening/03-cert-monitor-setup.sh
```

---

## Rolling Back

If an upgrade causes problems, use `rollback.sh` to restore the previous config backups:

```bash
# Rollback all scripts
bash scripts/web/hardening/rollback.sh

# Rollback a specific script
bash scripts/web/hardening/rollback.sh --script 02
```

Rollback only restores `.bak` config files. It does not downgrade packages or remove cron jobs added by the new version.

---

## applied-versions.yml

If you are tracking applied versions in the private submodule (see issue #53), update it after each upgrade:

```yaml
# private/servers/server1.example.com/applied-versions.yml
server: server1.example.com
last_updated: 2026-03-09
vps_security_version: "0.8.0"
scripts_applied:
  - 01-immediate-hardening.sh
  - 02-apache-hardening.sh
  # ...
```

---

## Related

- [RUNBOOK.md](RUNBOOK.md) — day-to-day operational procedures
- [CHANGELOG](../CHANGELOG.md) — full version history
- [Architecture](architecture.md) — script execution model
