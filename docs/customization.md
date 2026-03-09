# Customization Guide

All user-specific values live in `config.env` at the repo root. Fill it in once before running anything. The scripts auto-discover it and fall back to per-variable defaults if it is not found.

---

## config.env Reference

### `SSH_PORT`

The port SSH listens on. Default: `22`.

Update this if you run SSH on a non-standard port. The value propagates automatically to the UFW rule and the fail2ban jail created by `01-immediate-hardening.sh`.

```bash
SSH_PORT=2222
```

---

### `ADMIN_USER`

The username to set up as a sudo admin in `03-setup-admin-user.sh`. No default — the script aborts if this is unset.

The user must already exist on the server before running script 03. Create it first if needed:

```bash
adduser youruser
```

```bash
ADMIN_USER="youruser"
```

---

### `ADMIN_EMAIL`

Where to send reports and alerts. Used by `04-monthly-updates-setup.sh` (monthly upgrade report) and `05-log-monitoring-setup.sh` (Logwatch digest). No default — scripts abort if unset.

```bash
ADMIN_EMAIL="you@example.com"
```

---

### `MAIL_FROM`

The From address on outgoing server emails. Used by `05-log-monitoring-setup.sh` for the Logwatch configuration. Defaults to `server@<hostname>` if not set.

```bash
MAIL_FROM="server@yourdomain.com"
```

---

### `SMTP_HOST` / `SMTP_PORT`

SMTP relay host and port for `msmtp`. Used by `04-monthly-updates-setup.sh`.

Common values:

| Provider | Host | Port |
|---|---|---|
| Gmail | `smtp.gmail.com` | `587` |
| Postmark | `smtp.postmarkapp.com` | `587` |
| Mailgun | `smtp.mailgun.org` | `587` |
| SendGrid | `smtp.sendgrid.net` | `587` |

```bash
SMTP_HOST="smtp.gmail.com"
SMTP_PORT=587
```

---

### `SMTP_USER` / `SMTP_PASS`

SMTP authentication credentials. Leave empty to attempt unauthenticated relay, which rarely works from VPS providers.

For Gmail, use an [App Password](https://support.google.com/accounts/answer/185833) rather than your account password.

```bash
SMTP_USER="you@gmail.com"
SMTP_PASS="your-app-password"
```

---

### `CSP_FRAME_ANCESTORS`

Controls which domains may embed your pages in iframes. Used by `02-apache-hardening.sh` to set the `Content-Security-Policy` header's `frame-ancestors` directive.

Common configurations:

```bash
# Block all embedding
CSP_FRAME_ANCESTORS="'none'"

# Same-origin only
CSP_FRAME_ANCESTORS="'self'"

# Same-origin + specific trusted domains
CSP_FRAME_ANCESTORS="'self' yourdomain.com www.yourdomain.com app.yourdomain.com"
```

---

## Testing Before Applying

Every hardening script and `bootstrap.sh` supports `--dry-run`:

```bash
bash bootstrap.sh --dry-run
```

This prints every change that would be made without touching the system. Run it after editing `config.env` to verify the values look correct before committing to a live run.

---

## Testing Email Delivery

After running scripts 04 and 05, verify email delivery manually:

```bash
/usr/local/sbin/monthly-apt-report.sh
/usr/local/sbin/goaccess-daily-report.sh
```

If mail does not arrive, check `/var/log/msmtp.log` and verify your SMTP credentials and relay configuration.

---

## Per-server Overrides (config.env.local)

When managing multiple servers, each server may need a slightly different configuration (different email, different SSH port, or different SMTP relay). The recommended pattern is to use `config.env` as the shared base and a server-specific `config.env.local` for overrides.

### Structure

```
private/
  servers/
    server1.example.com/
      config.env.local    # server-specific overrides
    server2.example.com/
      config.env.local
```

### How it works

Export `CONFIG_FILE` to point at your base config, then source the override file on top:

```bash
export CONFIG_FILE=/etc/vps-security/config.env
source /etc/vps-security/config.env.local   # optional override
bash bootstrap.sh
```

Or combine them in your deployment workflow:

```bash
# Merge base + override into a single file for the target server
cat config.env private/servers/server2.example.com/config.env.local \
    > /tmp/server2-config.env

ssh root@server2 "CONFIG_FILE=/tmp/server2-config.env bash -s" < bootstrap.sh
```

### Example config.env.local

```bash
# server2.example.com overrides
SSH_PORT=2222
ADMIN_EMAIL=ops-server2@example.com
SMTP_HOST=smtp.mailgun.org
SMTP_PORT=587
SMTP_USER=postmaster@mg.example.com
SMTP_PASS=your-mailgun-api-key
```

The private submodule is the right home for these files — they contain real server details and credentials that must not be in the public repo.

---

## Debian 12 (Bookworm) Notes

The hardening scripts are developed and tested on Ubuntu 24.04 LTS. Most steps are compatible with Debian 12, with the following differences:

| Area | Ubuntu 24.04 | Debian 12 |
|---|---|---|
| Certbot | `snap install certbot` | `apt install certbot` |
| SSH service name | `ssh` | `ssh` (same) |
| fail2ban filter paths | `/var/log/auth.log` | `/var/log/auth.log` (same) |
| AppArmor | Pre-installed | Pre-installed (may differ in profile set) |
| snap packages | Available | Not available by default |

If running on Debian 12, install certbot via apt rather than snap:

```bash
apt install certbot python3-certbot-apache
```

Then update the certbot path check in `06-cert-monitor-setup.sh` if needed:

```bash
CERTBOT="$(command -v certbot)"
```

All other scripts run without modification on Debian 12. Testing on Debian 12 is tracked in [issue #9](https://github.com/davidwhittington/vps-security/issues/9).
