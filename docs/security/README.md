# Security Baseline

Minimum security requirements for any VPS managed with this toolkit. Use this as a checklist before considering a server production-ready.

---

## Required — Non-Negotiable

| Control | Requirement |
|---|---|
| **Firewall** | UFW active — default deny inbound, allow SSH port + 80 + 443 only |
| **SSH auth** | Key-only (`PasswordAuthentication no`) |
| **SSH root** | `PermitRootLogin prohibit-password` or `no` |
| **SSH X11** | `X11Forwarding no` |
| **Intrusion prevention** | fail2ban running with SSH jail active |
| **Admin user** | Non-root sudo user with SSH key; direct root login disabled after setup |
| **Apache tokens** | `ServerTokens Prod` + `ServerSignature Off` |
| **Apache headers** | `mod_headers` enabled; security headers applied (see below) |
| **TLS** | Valid certs on all vhosts; auto-renewal verified |
| **Updates** | Unattended security upgrades active; pending updates < 30 days |

---

## Recommended — Should Have

- SSH on a non-standard port (reduces automated scan noise significantly)
- `Options -Indexes` on all vhosts — never serve directory listings
- Block `.git` and `.svn` access in Apache — prevents source code exposure if a vhost root overlaps with a repo
- Harden sysctl: disable ICMP redirects, enable martian packet logging
- `mod_status` disabled or restricted to `localhost` only
- Separate non-root admin per server (not a shared username across servers)

---

## Security Headers

Minimum set for all Apache vhosts. Applied globally in `security.conf` via `mod_headers`:

```apache
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-XSS-Protection "0"

    # CSP: adjust frame-ancestors to match your domain structure
    Header always set Content-Security-Policy "frame-ancestors 'self' yourdomain.com www.yourdomain.com"
</IfModule>
```

**Notes:**
- `X-XSS-Protection: 0` is intentional — modern browsers ignore it and it can introduce vulnerabilities in old ones; rely on CSP instead
- `HSTS` with `includeSubDomains` requires all subdomains to also serve HTTPS — verify this before deploying
- Adjust `frame-ancestors` to your actual domain list; use `'none'` if you don't use iframes

---

## fail2ban Minimum Configuration

```ini
[DEFAULT]
bantime  = 3600     # 1 hour
findtime = 600      # 10 minute window
maxretry = 3        # 3 failures triggers a ban
banaction = iptables-multiport

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
```

---

## Audit Cadence

| Frequency | What to Check |
|---|---|
| **Initial** | Full audit before going live — firewall, SSH config, Apache headers, open ports, pending updates |
| **Monthly** | Review auth.log and fail2ban status, verify no unexpected open ports, check for pending updates |
| **Quarterly** | Re-run a full audit pass, review cert expiry, check cron jobs are running, review Apache vhost configs |
| **Annually** | Update hardening scripts against current best practices, review and rotate SSH keys if needed |

---

## Quick Verification Commands

```bash
# Firewall status
ufw status verbose

# SSH config (check key lines)
sshd -T | grep -E "passwordauthentication|permitrootlogin|x11forwarding"

# fail2ban status
fail2ban-client status sshd

# Apache headers test (run from another machine)
curl -sI https://yourdomain.com | grep -iE "server|x-content|strict|referrer|x-frame|permissions|content-security"

# Pending updates
apt list --upgradable 2>/dev/null | wc -l

# Cert expiry
certbot certificates
```
