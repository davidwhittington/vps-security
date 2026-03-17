# Runbook

Operational runbook for common events on linux-security-managed servers.

---

## Status

| Item | Detail |
|---|---|
| Phase | 1 — Active Development |
| Applies to | Any server provisioned with linux-security |
| Last updated | 2026-03-17 |

---

## Contents

1. [Initial Provisioning](#initial-provisioning)
2. [Certificate Renewal](#certificate-renewal)
3. [Certbot Renewal Failures](#certbot-renewal-failures)
4. [SSH Key Rotation](#ssh-key-rotation)
5. [Fail2ban — Unban an IP](#fail2ban-unban-an-ip)
6. [Apache Reload / Restart](#apache-reload--restart)
7. [Monthly Update Report Not Arriving](#monthly-update-report-not-arriving)
8. [Disk Space Alert](#disk-space-alert)
9. [Netdata — Bad Request Alert](#netdata--bad-request-alert)
10. [Audit Failed — Investigating](#audit-failed--investigating)
11. [Re-running a Single Hardening Script](#re-running-a-single-hardening-script)
12. [Rolling Back a Script](#rolling-back-a-script)
13. [Adding a New Domain](#adding-a-new-domain)
14. [Server Rebuild](#server-rebuild)

---

## Initial Provisioning

```bash
# On your local machine — clone and configure
git clone https://github.com/davidwhittington/linux-security.git
cd linux-security
cp config.env.example config.env   # edit with your values
scp config.env root@<server>:/etc/linux-security/config.env

# On the server
export CONFIG_FILE=/etc/linux-security/config.env
bash bootstrap.sh
```

Bootstrap prompts once with "Type AGREE to continue" before running any scripts. All sub-scripts receive `--confirm` automatically and do not prompt again. For non-interactive use (CI, automation), pass `--confirm` to skip the prompt entirely:

```bash
bash bootstrap.sh --confirm
```

Verify the run:

```bash
bash scripts/core/audit/verify.sh
bash scripts/audit/audit.sh
```

---

## Certificate Renewal

Certificates auto-renew via certbot's built-in timer. On Ubuntu (snap install), use `certbot` or `/snap/bin/certbot`. On Debian 12 (apt install), `certbot` is in PATH directly.

```bash
# Check cert status
certbot certificates

# Test renewal
certbot renew --dry-run

# Force renew a specific domain
certbot renew --cert-name example.com --force-renewal

# Check timer status (Ubuntu/snap)
systemctl status snap.certbot.renew.timer

# Check timer status (Debian/apt)
systemctl status certbot.timer
```

If the weekly cert monitor fires an alert email:

```bash
# Run the check manually to see details
/usr/local/sbin/cert-expiry-check.sh

# Renew and reload Apache
certbot renew && systemctl reload apache2
```

---

## Certbot Renewal Failures

Auto-renewal runs silently when it works. When it fails, the cert monitor script sends an alert and certbot logs the error. Start here:

```bash
# View the last renewal attempt
cat /var/log/letsencrypt/letsencrypt.log | tail -50

# Or for snap installs, check the timer run output
journalctl -u snap.certbot.renew.service --since "7 days ago"
```

---

### ACME HTTP-01 Challenge Failure

**Symptoms:** `Connection refused`, `Timeout`, or `No valid IP addresses found`.

The ACME server makes an HTTP request to `http://<domain>/.well-known/acme-challenge/<token>` to verify domain ownership. This requires port 80 to be reachable from the internet.

```bash
# Check UFW allows port 80
ufw status | grep 80

# If missing, add it
ufw allow 80/tcp

# Verify Apache is listening on port 80
curl -I http://yourdomain.com/.well-known/acme-challenge/test 2>&1 | head -5
```

Also check that no `.htaccess` rule or Apache config is blocking `/.well-known/`:

```bash
apache2ctl -S
grep -r "well-known" /etc/apache2/
```

---

### Rate Limit Errors

**Symptoms:** `Error: too many certificates already issued for...`

Let's Encrypt enforces limits: 5 duplicate certificates per 7 days, 50 certificates per registered domain per week. Hitting this usually means running `--force-renewal` repeatedly during testing.

```bash
# Check current cert count at:
# https://crt.sh/?q=yourdomain.com

# Wait out the rate limit window (up to 7 days for duplicates)
# Use --dry-run to test without consuming quota
certbot renew --dry-run
```

Staging certificates don't count against rate limits and are useful for testing:

```bash
certbot certonly --staging -d yourdomain.com
```

---

### Plugin / Snap Conflicts

**Symptoms:** `certbot: command not found`, `The requested apache plugin does not appear to be installed`.

On Ubuntu with snap-installed certbot, the system certbot (apt) and snap certbot can conflict:

```bash
# Check which certbot is in use
which certbot
/snap/bin/certbot --version

# If both are installed, remove the apt version
apt remove certbot python3-certbot-apache

# Reinstall via snap
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot
```

---

### DNS Propagation Delays (DNS-01 Challenges)

**Symptoms:** `DNS problem: NXDOMAIN looking up TXT for _acme-challenge.<domain>`.

DNS-01 challenges require a TXT record to be visible from the ACME server. If you recently changed DNS providers or updated records, propagation can take minutes to hours.

```bash
# Check what the ACME server sees
dig TXT _acme-challenge.yourdomain.com @8.8.8.8

# Once the record resolves, retry renewal
certbot renew --cert-name yourdomain.com
```

---

### Cert Expired Before Recovery

If a cert has already expired (or is about to and renewal keeps failing), force a fresh issue:

```bash
certbot certonly --apache -d yourdomain.com -d www.yourdomain.com --force-renewal
systemctl reload apache2
```

Then investigate the root cause before the next renewal window (90-day certs renew at 60 days by default).

---

## SSH Key Rotation

1. Add the new public key to `/root/.ssh/authorized_keys` while still connected
2. Test login with the new key in a separate terminal before removing the old key
3. Remove the old key from `authorized_keys`
4. Update `private/servers/inventory.yml` with the rotation date

```bash
# Add a new key
echo "ssh-ed25519 AAAA... comment" >> /root/.ssh/authorized_keys

# Verify key is accepted (from another terminal)
ssh -i ~/.ssh/new_key root@<server>

# Remove old key
nano /root/.ssh/authorized_keys
```

---

## Fail2ban — Unban an IP

```bash
# List all active jails and their bans
fail2ban-client status
fail2ban-client status sshd
fail2ban-client status apache-badbots
fail2ban-client status apache-botsearch
fail2ban-client status apache-scanners

# Unban a specific IP from a specific jail
fail2ban-client set sshd unbanip <ip>
fail2ban-client set apache-scanners unbanip <ip>

# Unban from all jails at once
for jail in $(fail2ban-client status | awk '/Jail list/{print $NF}' | tr ',' ' '); do
    fail2ban-client set "$jail" unbanip <ip> 2>/dev/null || true
done
```

If Apache jails show 0 total failed and the File list is missing (showing "Journal matches" instead), the `backend = auto` directive is not set. See the security baseline for the correct jail configuration.

---

## Apache Reload / Restart

Always test config before reloading:

```bash
apache2ctl configtest && systemctl reload apache2
```

Full restart (drops active connections):

```bash
apache2ctl configtest && systemctl restart apache2
```

Check error log:

```bash
tail -50 /var/log/apache2/error.log
```

---

## Monthly Update Report Not Arriving

1. Check the cron ran:

```bash
grep "monthly-apt" /var/log/syslog | tail -5
cat /var/log/monthly-apt-cron.log
```

2. Test msmtp manually:

```bash
echo "Test from $(hostname -f)" | mail -s "msmtp test" "$ADMIN_EMAIL"
```

3. Check msmtp log:

```bash
cat /var/log/msmtp.log
```

4. Verify SMTP credentials in `/etc/linux-security/config.env`, then re-run script 04:

```bash
bash scripts/core/hardening/03-monthly-updates-setup.sh
```

---

## Disk Space Alert

```bash
# Check usage
df -h
du -sh /var/www/* | sort -rh | head -10
du -sh /var/log/* | sort -rh | head -10

# Force log rotation
logrotate -f /etc/logrotate.conf

# Clear old apt cache
apt-get clean
apt-get autoremove -y

# Check for large files
find / -xdev -size +100M -type f 2>/dev/null | sort -n
```

---

## Netdata — Bad Request Alert

**Alert:** `web_log_1m_bad_requests` WARNING on `web_log_apache_vhosts.requests_by_type`

This alert fires when the percentage of 4xx responses (excluding 401 and 429) exceeds the configured threshold over a 1-minute window. Short spikes (1-2 minutes, 30-70%) that then self-recover are almost always automated vulnerability scanners probing common paths (WordPress, `.env`, `.git/config`, xmlrpc, backup files). This is normal internet background noise.

**Triage — check what's causing it:**

```bash
# Top 4xx request paths in the last hour
grep " 40[^1] \| 40[^29] " /var/log/apache2/other_vhosts_access.log | \
  awk '{print $8}' | sort | uniq -c | sort -rn | head -20

# Which IPs are generating 404s right now
grep " 404 " /var/log/apache2/other_vhosts_access.log | \
  awk '{print $2}' | sort | uniq -c | sort -rn | head -10

# Check if fail2ban is catching and banning them
fail2ban-client status apache-scanners
fail2ban-client status apache-badbots
```

**If it's scanner traffic (expected pattern):**

Verify the Apache jails are running and watching files (not the journal):

```bash
fail2ban-client status apache-scanners
# Should show "File list:" — if it shows "Journal matches:" see the fix below
```

If jails are on the journal instead of files:

```bash
# Check /etc/fail2ban/jail.local — each Apache jail needs backend = auto
grep -A5 "apache-scanners" /etc/fail2ban/jail.local
# Add backend = auto if missing, then:
systemctl restart fail2ban
```

**If the alert is firing frequently despite jails being active:**

The alert threshold may need tuning. The default WARNING at 30% is often too sensitive for busy servers. Raise it to 50% (or adjust to your traffic profile):

```bash
# Edit or create override
nano /etc/netdata/health.d/web_log.conf
# Change the warn line threshold from 30 to 50

# Apply without restart
netdatacli reload-health
```

See `docs/security/README.md` for the full override configuration.

**If it's NOT scanner traffic (sustained, high volume, unknown paths):**

```bash
# Check for unusual patterns — non-scanner targets
grep " 40[^1] " /var/log/apache2/other_vhosts_access.log | \
  tail -200 | awk '{print $2, $8, $9}' | sort | uniq -c | sort -rn | head -30

# Check if mod_remoteip is showing real IPs (not Cloudflare ranges like 104.16-31.x.x)
tail -20 /var/log/apache2/other_vhosts_access.log | grep -v "Netdata\|127.0.0.1"

# If IPs look like Cloudflare proxies, mod_remoteip may not be configured
apache2ctl -M | grep remoteip
```

---

## Audit Failed — Investigating

Run the full audit to see all failures:

```bash
bash scripts/audit/audit.sh
```

For each FAIL category, run the specific audit script for more detail:

```bash
bash scripts/core/audit/ssh-audit.sh
bash scripts/core/audit/ports-check.sh
bash scripts/web/audit/headers-check.sh
bash scripts/web/audit/unattended-upgrades-check.sh
bash scripts/core/audit/apparmor-check.sh
```

---

## Re-running a Single Hardening Script

All scripts are idempotent — safe to re-run. Export config path first:

```bash
export CONFIG_FILE=/etc/linux-security/config.env

# Example: re-run Apache hardening
bash scripts/web/hardening/01-apache-hardening.sh

# Dry-run first to see what will change
bash scripts/web/hardening/01-apache-hardening.sh --dry-run
```

---

## Rolling Back a Script

```bash
# Rollback all scripts (restores .bak files)
bash scripts/web/hardening/rollback.sh

# Rollback a single script
bash scripts/web/hardening/rollback.sh --script 01   # SSH
bash scripts/web/hardening/rollback.sh --script 02   # Apache

# Dry-run rollback
bash scripts/web/hardening/rollback.sh --dry-run
```

Rollback only restores config file backups. It does not remove packages or cron jobs.

---

## Adding a New Domain

1. Point DNS to the server IP
2. Create an Apache vhost config in `/etc/apache2/sites-available/<domain>.conf`
3. Enable it and obtain a certificate:

```bash
a2ensite <domain>.conf
apache2ctl configtest && systemctl reload apache2

certbot --apache -d <domain> -d www.<domain>
```

4. Run the header checker to verify security posture:

```bash
bash scripts/web/audit/headers-check.sh
```

5. Add the domain to `private/servers/inventory.yml`

---

## Server Rebuild

For a full server rebuild from scratch:

1. Provision a new server with Ubuntu 24.04 LTS
2. Add your SSH public key during provisioning
3. Follow [Initial Provisioning](#initial-provisioning)
4. Restore site files from backups or re-clone GitHub repos to `/var/www/`
5. Run `bash scripts/audit/audit.sh` to verify posture
6. Point DNS to the new server IP
7. Run certbot for each domain

Refer to `private/servers/inventory.yml` for the full domain and configuration record.

---

## Related

- [Architecture](architecture.md) — system design and script flow
- [Customization](customization.md) — config.env variable reference
- [SSH Two-Factor Authentication](ssh-2fa.md) — optional TOTP setup for SSH
- [Glossary](GLOSSARY.md) — terminology reference
- [CHANGELOG](../CHANGELOG.md) — version history
