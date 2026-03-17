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
| **Apache intrusion prevention** | fail2ban Apache jails active (badbots, botsearch, scanners) — see below |
| **Admin user** | Non-root sudo user with SSH key; direct root login disabled after setup |
| **Apache tokens** | `ServerTokens Prod` + `ServerSignature Off` |
| **Apache headers** | `mod_headers` enabled; security headers applied (see below) |
| **TLS** | Valid certs on all vhosts; auto-renewal verified |
| **Updates** | Unattended security upgrades active; pending updates < 30 days |
| **Proxy IP resolution** | If behind Cloudflare or any reverse proxy, `mod_remoteip` enabled — see below |

---

## Recommended — Should Have

- SSH on a non-standard port (reduces automated scan noise significantly)
- `Options -Indexes` on all vhosts — never serve directory listings
- Block `.git` and `.svn` access in Apache — prevents source code exposure if a vhost root overlaps with a repo
- Harden sysctl: disable ICMP redirects, enable martian packet logging
- `mod_status` disabled or restricted to `localhost` only
- Separate non-root admin per server (not a shared username across servers)
- Tune monitoring alert thresholds to account for normal background scanner traffic once Apache jails are active

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

SSH jail only (baseline). Web-server profile also requires the Apache jails below.

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

## fail2ban — Apache Jails (Web-Server Profile)

Internet-facing Apache servers receive continuous automated probing for WordPress, Laravel, `.env` files, `.git` directories, backup files, and other common vulnerability targets. Without Apache jails, these bursts pass silently and skew monitoring metrics.

Three jails are required on all web-server profile hosts:

```ini
# Add to /etc/fail2ban/jail.local
# IMPORTANT: backend = auto is required — Apache logs to files, not the systemd journal.
# Without it, fail2ban watches the journal and never sees Apache traffic.

[apache-badbots]
enabled  = true
backend  = auto
port     = http,https
filter   = apache-badbots
logpath  = /var/log/apache2/*-access.log
           /var/log/apache2/other_vhosts_access.log
maxretry = 2
bantime  = 86400

[apache-botsearch]
enabled  = true
backend  = auto
port     = http,https
filter   = apache-botsearch
logpath  = /var/log/apache2/*-error.log
           /var/log/apache2/error.log
maxretry = 2
bantime  = 86400

[apache-scanners]
enabled  = true
backend  = auto
port     = http,https
filter   = apache-scanners
logpath  = /var/log/apache2/*-access.log
           /var/log/apache2/other_vhosts_access.log
maxretry = 5
findtime = 60
bantime  = 86400
```

**`apache-scanners`** requires a custom filter at `/etc/fail2ban/filter.d/apache-scanners.conf`. The filter handles both `combined` (IP first) and `vhost_combined` (vhost:port then IP) log formats:

```ini
# /etc/fail2ban/filter.d/apache-scanners.conf
[INCLUDES]
before = apache-common.conf

[Definition]
failregex = ^(?:\S+ )?<HOST> - - \[.*?\] "(?:GET|POST|HEAD) (?:/\.env|/\.git/|/wp-admin/setup-config\.php|/wp-login\.php|/xmlrpc\.php|//xmlrpc\.php|/backup\.sql|/dump\.sql|/database\.sql|/db\.sql|/debug\.log|/phpinfo(?:\s|/)|/_profiler/|/storage/logs/|/shell\.php|/cmd\.php|/wordpress/wp-admin/|//(?:wp|wordpress|web|blog|cms|test|shop|site|sito|2019|wp1|wp2)/wp-includes/wlwmanifest\.xml|//wp-includes/wlwmanifest\.xml) HTTP/[0-9.]+" 4[0-9][0-9]

ignoreregex =

datepattern = ^[^\[]*\[({DATE})
              {^LN-BEG}
```

**Verify jails are watching files (not journal):**

```bash
fail2ban-client status apache-scanners
# The output should show "File list:" — if it shows "Journal matches:" the backend is wrong.
```

---

## mod_remoteip — Cloudflare and Reverse Proxy IP Resolution

If any vhosts are behind Cloudflare (or any other reverse proxy), Apache logs the proxy's IP rather than the real client IP. This breaks fail2ban — banning a Cloudflare IP would block all legitimate traffic through that proxy.

Enable `mod_remoteip` with the proxy's IP ranges trusted to restore real client IPs in all logs:

```bash
a2enmod remoteip
```

Create `/etc/apache2/conf-available/remoteip-cloudflare.conf`:

```apache
RemoteIPHeader X-Forwarded-For
# Cloudflare IPv4 ranges
RemoteIPTrustedProxy 173.245.48.0/20
RemoteIPTrustedProxy 103.21.244.0/22
RemoteIPTrustedProxy 103.22.200.0/22
RemoteIPTrustedProxy 103.31.4.0/22
RemoteIPTrustedProxy 141.101.64.0/18
RemoteIPTrustedProxy 108.162.192.0/18
RemoteIPTrustedProxy 190.93.240.0/20
RemoteIPTrustedProxy 188.114.96.0/20
RemoteIPTrustedProxy 197.234.240.0/22
RemoteIPTrustedProxy 198.41.128.0/17
RemoteIPTrustedProxy 162.158.0.0/15
RemoteIPTrustedProxy 104.16.0.0/13
RemoteIPTrustedProxy 104.24.0.0/14
RemoteIPTrustedProxy 172.64.0.0/13
RemoteIPTrustedProxy 131.0.72.0/22
# Cloudflare IPv6 ranges
RemoteIPTrustedProxy 2400:cb00::/32
RemoteIPTrustedProxy 2606:4700::/32
RemoteIPTrustedProxy 2803:f800::/32
RemoteIPTrustedProxy 2405:b500::/32
RemoteIPTrustedProxy 2405:8100::/32
RemoteIPTrustedProxy 2a06:98c0::/29
RemoteIPTrustedProxy 2c0f:f248::/32
```

Then enable and reload:

```bash
a2enconf remoteip-cloudflare
apache2ctl configtest && systemctl reload apache2
```

**Verify:** tail any vhost access log and confirm IPs are no longer all in Cloudflare ranges. For reference, Cloudflare IPv4 occupies `103.21.244.0/22`, `103.22.200.0/22`, `103.31.4.0/22`, `104.16.0.0/13`, `104.24.0.0/14`, `108.162.192.0/18`, `131.0.72.0/22`, `141.101.64.0/18`, `162.158.0.0/15`, `172.64.0.0/13`, `173.245.48.0/20`, `188.114.96.0/20`, `190.93.240.0/20`, `197.234.240.0/22`, `198.41.128.0/17`.

Keep Cloudflare IP ranges current — they publish the full list at `https://www.cloudflare.com/ips/`. Review annually or when adding new Cloudflare-fronted properties.

---

## Monitoring Alert Tuning (Netdata)

With Apache jails active, short scanner bursts that previously skewed bad-request percentages are suppressed at the firewall level. The Netdata `web_log_1m_bad_requests` default threshold (WARNING at 30%) can be too sensitive for servers receiving normal internet background noise.

Override at `/etc/netdata/health.d/web_log.conf`:

```ini
template: web_log_1m_bad_requests
      on: web_log.type_requests
   class: Errors
    type: Web Server
component: Web log
  lookup: sum -1m unaligned of bad
    calc: $this * 100 / $web_log_1m_requests
   units: %
   every: 10s
    warn: ($web_log_1m_requests > 120) ? ($this > (($status >= $WARNING)  ? ( 20 ) : ( 50 )) ) : ( 0 )
   delay: up 2m down 15m multiplier 1.5 max 1h
 summary: Web log bad requests
    info: Ratio of client error HTTP requests over the last minute (4xx except 401 and 429)
      to: webmaster
```

Key changes from default:
- WARNING threshold raised from 30% to 50% — scanner bursts below this are expected background noise handled by fail2ban
- Hysteresis drops to 20% once alerting — requires sustained improvement before clearing

Apply without restart:

```bash
netdatacli reload-health
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
