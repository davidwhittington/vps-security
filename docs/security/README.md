# Security Baseline

Minimum security requirements for any VPS managed with this toolkit.

## Required

- **Firewall:** UFW active — allow 22 (or custom SSH port), 80, 443 only; deny all else
- **SSH:** Key-only auth (`PasswordAuthentication no`), no root login (`PermitRootLogin prohibit-password` or `no`), no X11 forwarding
- **Intrusion prevention:** fail2ban installed and active for SSH and Apache jails
- **Admin user:** Non-root sudo user with SSH key access; root SSH login disabled
- **Apache:** `ServerTokens Prod`, `ServerSignature Off`, `mod_headers` enabled, security headers set
- **TLS:** Valid certs on all vhosts, auto-renewal verified (`certbot renew --dry-run`)
- **Updates:** Unattended security upgrades active; no more than 30 days of pending updates

## Recommended

- SSH on a non-standard port (reduces automated scan noise)
- `Options -Indexes` on all vhosts (disable directory listing)
- Block `.git` and `.svn` access in Apache
- Harden sysctl: disable ICMP redirects, enable martian logging
- `mod_status` disabled or restricted to localhost

## Security Headers (Apache)

Minimum headers for all vhosts:

```apache
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
```

## Audit Cadence

- **Initial:** Run `scripts/audit/` on every new server before going live
- **Monthly:** Review logs, check for pending updates, verify fail2ban is active
- **Quarterly:** Re-run full security audit, review open ports, check cert expiry
- **Annually:** Review and update hardening scripts against current best practices
