# Runbook

Operational runbook for common events on linux-security-managed servers.

---

## Status

| Item | Detail |
|---|---|
| Phase | 1 — Active Development |
| Applies to | Any server provisioned with linux-security |
| Last updated | 2026-03-08 |

---

## Contents

1. [Initial Provisioning](#initial-provisioning)
2. [Certificate Renewal](#certificate-renewal)
3. [SSH Key Rotation](#ssh-key-rotation)
4. [Fail2ban — Unban an IP](#fail2ban-unban-an-ip)
5. [Apache Reload / Restart](#apache-reload--restart)
6. [Monthly Update Report Not Arriving](#monthly-update-report-not-arriving)
7. [Disk Space Alert](#disk-space-alert)
8. [Audit Failed — Investigating](#audit-failed--investigating)
9. [Re-running a Single Hardening Script](#re-running-a-single-hardening-script)
10. [Rolling Back a Script](#rolling-back-a-script)
11. [Adding a New Domain](#adding-a-new-domain)
12. [Server Rebuild](#server-rebuild)

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
# List active bans
fail2ban-client status sshd
fail2ban-client status apache-auth

# Unban a specific IP
fail2ban-client set sshd unbanip <ip>
fail2ban-client set apache-auth unbanip <ip>

# Unban from all jails
for jail in $(fail2ban-client status | awk '/Jail list/{print $NF}' | tr ',' ' '); do
    fail2ban-client set "$jail" unbanip <ip> 2>/dev/null || true
done
```

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
- [CHANGELOG](../CHANGELOG.md) — version history
