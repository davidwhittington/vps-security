# Customization Guide

The hardening scripts are designed to be run as-is on most Ubuntu/Debian Apache servers, but a handful of values should be updated for your environment before running.

---

## Script 01 — `01-immediate-hardening.sh`

**SSH Port**

By default, UFW allows SSH on port 22. If you run SSH on a non-standard port, update these lines:

```bash
# Change 22 to your SSH port
ufw allow 22/tcp comment 'SSH'
```

And in the fail2ban jail, change the port if needed:

```ini
[sshd]
port = 2222   # or whatever your SSH port is
```

No other changes are typically needed for script 01.

---

## Script 02 — `02-apache-hardening.sh`

**Content Security Policy (`frame-ancestors`)**

The CSP header controls which domains are allowed to embed your pages in iframes. The default value lists a set of example domains. Replace these with your own:

```bash
Header always set Content-Security-Policy "frame-ancestors 'self' yourdomain.com www.yourdomain.com"
```

If you don't use iframes at all, you can simplify this to:

```bash
Header always set Content-Security-Policy "frame-ancestors 'none'"
```

Or use `X-Frame-Options` instead:

```bash
Header always set X-Frame-Options "SAMEORIGIN"
```

---

## Script 03 — `03-setup-admin-user.sh`

**Admin username**

Change this variable at the top of the script:

```bash
USERNAME="your-username"   # line 17
```

The script will:
- Set the user's shell to `/bin/bash`
- Add them to the `sudo` group
- Copy `/root/.ssh/authorized_keys` to their home directory

Make sure this user already exists on the system, or create them first:

```bash
adduser your-username
```

---

## Script 04 — `04-monthly-updates-setup.sh`

**Email address**

Set your address at the top of the script (it appears in two places — the outer script and the embedded monthly report script):

```bash
EMAIL="you@example.com"   # line 7 and line 51
```

**SMTP configuration**

The script installs `msmtp` but includes a minimal placeholder config. You need to configure a working SMTP relay for email delivery. Edit the `msmtprc` block in the script:

```bash
# Example: using Gmail with an App Password
account default
host smtp.gmail.com
port 587
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
auth on
user you@gmail.com
password your-app-password
from you@gmail.com
```

Alternatively, use a transactional email service (Postmark, Mailgun, SendGrid) as the relay — they provide SMTP credentials that work directly with msmtp.

---

## Script 05 — `05-log-monitoring-setup.sh`

**Email addresses**

```bash
EMAIL="you@example.com"       # line 7 — where Logwatch reports are sent
MAIL_FROM="server@yourdomain.com"   # line 8 — the From address
```

**Reports URL**

The GoAccess traffic report is saved to `/var/www/html/reports/traffic-report.html`. To serve it at a custom path or restrict access further, edit the report directory and `.htaccess` block in the script.

The generated password for the reports directory is printed at the end of the script run — save it.

---

## General Notes

- **Run scripts in order** — each builds on the previous (e.g., fail2ban from 01 is used by 04 and 05)
- **Test SSH access after script 01** before closing your current session
- **Test email delivery** after setting up scripts 04 and 05 by running the report scripts manually:
  ```bash
  /usr/local/sbin/monthly-apt-report.sh
  /usr/local/sbin/goaccess-daily-report.sh
  ```
