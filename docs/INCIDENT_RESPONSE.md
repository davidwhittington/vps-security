# Incident Response Playbook

Operational guide for handling security incidents on servers managed with linux-security.

---

## Status

| Item | Detail |
|---|---|
| Applies to | Servers running linux-security hardening stack |
| Last updated | 2026-03-09 |

---

## Severity Levels

| Level | Description | Response Time |
|---|---|---|
| **P1 — Critical** | Active compromise, data exfiltration, ransomware, root backdoor | Immediate |
| **P2 — High** | Unauthorized access attempt succeeding, webshell found, unexplained root process | < 1 hour |
| **P3 — Medium** | AIDE/rkhunter alert, suspicious cron, brute-force spike | < 4 hours |
| **P4 — Low** | Failed auth spike, unexpected port open, minor config drift | Next business day |

---

## First Response

Regardless of severity, do these steps before anything else:

```bash
# 1. Capture current state before taking any action
uptime
w
last -20
ps aux --sort=-%cpu | head -20
ss -tlnp
netstat -an | grep ESTABLISHED
lsof -i
```

```bash
# 2. Check auth logs for recent access
grep "Accepted\|Failed" /var/log/auth.log | tail -50
grep "session opened" /var/log/auth.log | tail -20
```

```bash
# 3. Check what's running as root (that shouldn't be)
ps aux | grep "^root" | grep -v -E "PID|sshd|cron|apache|agetty|systemd|kernel"
```

```bash
# 4. Check for recent file modifications in critical directories
find /etc /usr/bin /usr/sbin /bin /sbin -newer /etc/passwd -type f 2>/dev/null | head -20
find /var/www -newer /etc/passwd -type f 2>/dev/null | head -20
```

---

## Scenario Playbooks

### Brute-Force SSH Attack

**Indicators:** fail2ban alert email, high rate of "Failed password" in auth.log

```bash
# Check fail2ban status
fail2ban-client status sshd
fail2ban-client status recidive

# View top attacking IPs
grep "Failed password" /var/log/auth.log | awk '{print $11}' | sort | uniq -c | sort -rn | head -20

# Manually ban an IP
fail2ban-client set sshd banip <IP>

# Check if the attack resulted in any successful logins
grep "Accepted" /var/log/auth.log | grep -v "your-known-ip"
```

**Resolution:** If no successful logins, fail2ban handled it. Consider tightening `MaxAuthTries` or moving SSH to a non-standard port.

---

### Webshell / PHP Backdoor

**Indicators:** ClamAV alert, rkhunter alert, unusual web traffic, unexpected PHP processes

```bash
# Scan web roots for known webshell signatures (ClamAV)
clamscan -r --infected /var/www 2>/dev/null

# Find recently modified PHP files
find /var/www -name "*.php" -newer /var/www -mtime -7 -type f | head -20

# Look for obfuscated PHP eval patterns
grep -rl "eval.*base64_decode\|eval.*gzinflate\|eval.*str_rot13" /var/www --include="*.php" 2>/dev/null

# Check for PHP files in unexpected locations
find /var/www -name "*.php" -type f | xargs ls -la | sort -k6,7 | head -20

# Run the web root permission audit
bash scripts/web/audit/web-root-perms.sh
```

**Containment:**
1. Identify the file(s) and quarantine immediately: `mv <file> /var/lib/clamav-quarantine/`
2. Identify how it was uploaded (check Apache access logs for the upload request)
3. Patch the upload vulnerability
4. Change all database passwords the site uses
5. Audit the site's code for further compromise

```bash
# Check Apache access logs for the upload event
grep "POST" /var/log/apache2/access.log | grep -E "\.php|upload" | tail -50
```

---

### Unauthorized Root Access

**Indicators:** Unknown entry in `last`, AIDE alert on /etc/sudoers or /root, unfamiliar process running as root

```bash
# Who has root access?
getent passwd | awk -F: '$3 == 0 {print}'
cat /etc/sudoers
grep -r "NOPASSWD\|ALL" /etc/sudoers.d/

# Check SSH authorized_keys for unexpected keys
cat /root/.ssh/authorized_keys
for user in $(cut -d: -f1 /etc/passwd); do
    home=$(getent passwd "$user" | cut -d: -f6)
    if [[ -f "${home}/.ssh/authorized_keys" ]]; then
        echo "=== $user ==="; cat "${home}/.ssh/authorized_keys"
    fi
done

# Check for new cron jobs
crontab -l 2>/dev/null
ls -la /etc/cron.d/ /var/spool/cron/crontabs/
```

**Containment:**
1. If active session: `pkill -u <username>` to kill their sessions
2. Lock the account: `passwd -l <username>`
3. Remove unauthorized SSH keys immediately
4. Rotate your own SSH keys: `bash scripts/core/hardening/ssh-key-rotate.sh --show`
5. Consider changing SSH port temporarily

---

### AIDE File Integrity Alert

**Indicators:** Email from aide-weekly-check.sh showing file changes

```bash
# Review what changed
aide --check 2>/dev/null | head -100

# Compare against known-good: check git for the original
# For system files, compare against dpkg's known state
dpkg --verify 2>/dev/null | head -20

# Check if the change is from a legitimate package update
grep "$(date +%Y-%m-%d)" /var/log/dpkg.log | head -20
```

**Resolution:**
- If changes are from a package upgrade: `aide --update && cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db`
- If changes are unexplained: treat as P2, investigate file by file

---

### Suspicious Process or Network Connection

```bash
# Identify process by connection
ss -tlnp
lsof -i -n -P | grep ESTABLISHED

# Get full details of a suspicious PID
ls -la /proc/<PID>/exe
cat /proc/<PID>/cmdline | tr '\0' ' '
cat /proc/<PID>/status

# Check what files it has open
lsof -p <PID>

# Kill if confirmed malicious
kill -9 <PID>
```

---

### Disk Space Exhaustion

```bash
# Find what's filling disk
df -h
du -sh /var/log/* | sort -rh | head -20
du -sh /var/www/* | sort -rh | head -10
du -sh /tmp/* | sort -rh | head -10

# Rotate logs immediately
logrotate -f /etc/logrotate.conf

# Check for large files
find / -type f -size +100M 2>/dev/null | sort -k5 -rn | head -10
```

---

## Containment Options

Escalating containment actions — use the minimum required:

```bash
# Block a specific IP at firewall level
ufw deny from <IP> to any comment "incident-response"

# Block all new connections (emergency — will disrupt service)
ufw default deny incoming
ufw default deny outgoing
ufw allow out 22  # keep SSH if you need it

# Isolate a specific Apache vhost (disable it)
a2dissite <site>.conf && systemctl reload apache2

# Suspend a user account
passwd -l <username>
usermod --expiredate 1 <username>

# Kill all processes for a user
pkill -KILL -u <username>
```

---

## Evidence Collection

Collect before making changes — evidence is volatile:

```bash
# Snapshot running processes
ps auxf > /root/ir-$(date +%Y%m%d)/processes.txt

# Network connections
ss -tlnp > /root/ir-$(date +%Y%m%d)/network.txt
netstat -an >> /root/ir-$(date +%Y%m%d)/network.txt

# Open files
lsof > /root/ir-$(date +%Y%m%d)/lsof.txt

# Auth logs
cp /var/log/auth.log /root/ir-$(date +%Y%m%d)/
cp /var/log/syslog /root/ir-$(date +%Y%m%d)/

# Apache logs
cp /var/log/apache2/access.log /root/ir-$(date +%Y%m%d)/
cp /var/log/apache2/error.log /root/ir-$(date +%Y%m%d)/

# Cron state
crontab -l > /root/ir-$(date +%Y%m%d)/crontab.txt
ls -la /etc/cron.d/ >> /root/ir-$(date +%Y%m%d)/crontab.txt
```

---

## Post-Incident

After resolving:

1. **Root cause analysis** — how did it happen, what allowed it
2. **Patch the vulnerability** — don't just clean up, fix the entry point
3. **Rotate credentials** — all passwords and SSH keys that may have been exposed
4. **Re-baseline** — update AIDE, rkhunter, and services baseline after cleaning
5. **Run full audit** — `bash scripts/audit/audit.sh --report html`
6. **Document** — add finding to private submodule audit report

```bash
# Re-baseline after incident is resolved
rkhunter --propupd
aide --update && cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
bash scripts/core/audit/services-check.sh --update
bash scripts/core/audit/suid-check.sh --update

# Run full audit
bash scripts/audit/audit.sh --report html --output /root/post-incident-audit.html
```

---

## Related

- [RUNBOOK.md](RUNBOOK.md) — day-to-day operational procedures
- [UPGRADE.md](UPGRADE.md) — applying script updates to live servers
- [docs/security/README.md](security/README.md) — security baseline and audit cadence
