# vps-security

Hardening scripts, security baselines, and a knowledge base guide for Ubuntu/Debian VPS servers.

Designed as a reusable toolkit — scripts are generic and configurable; server-specific audit reports and inventory live in the private submodule.

## Structure

```
vps-security/
├── docs/
│   ├── security/
│   │   └── README.md               # Security baseline and requirements
│   ├── TEMPLATE.md                 # Audit report template
│   └── VPS_HARDENING_GUIDE.html    # Standalone HTML knowledge base
├── scripts/
│   ├── hardening/
│   │   ├── 01-immediate-hardening.sh     # Firewall, SSH lockdown, fail2ban
│   │   ├── 02-apache-hardening.sh        # Apache security headers, CSP
│   │   ├── 03-setup-admin-user.sh        # Non-root admin user setup
│   │   ├── 04-monthly-updates-setup.sh   # Unattended upgrades configuration
│   │   └── 05-log-monitoring-setup.sh    # Log rotation and monitoring
│   └── audit/                            # Audit scripts (coming soon)
├── config/                               # Config snippets and templates
└── private/                              # Submodule: vps-security-private (not public)
```

## Quick Start

Run scripts in order on a freshly provisioned Ubuntu/Debian VPS:

```bash
chmod +x scripts/hardening/*.sh

bash scripts/hardening/01-immediate-hardening.sh   # Firewall, SSH, fail2ban
bash scripts/hardening/02-apache-hardening.sh      # Apache headers + TLS hardening
bash scripts/hardening/03-setup-admin-user.sh      # Create non-root admin
bash scripts/hardening/04-monthly-updates-setup.sh # Unattended upgrades
bash scripts/hardening/05-log-monitoring-setup.sh  # Log rotation + monitoring
```

> Review each script before running. Adjust SSH port, allowed IPs, and domain names for your environment.

## Hardening Coverage

- UFW firewall (allow SSH/80/443, deny all else)
- SSH: key-only auth, no root login, no X11 forwarding, rate limiting
- fail2ban: SSH, Apache, and web application jails
- Apache: security headers, CSP, `ServerTokens Prod`, TLS hardening
- Unattended security upgrades
- Log monitoring and rotation

## Auditing a Server

1. Copy `docs/TEMPLATE.md` to `private/servers/<hostname>/AUDIT_REPORT.md`
2. Work through each finding category against your server
3. Use the checklist at the bottom to track remediation

See `docs/security/README.md` for the full security baseline.

## Private Submodule

Server-specific data (audit reports with real IPs, inventory, network topology) lives in a private companion repo added as a submodule:

```bash
# Initialize after cloning (requires access to the private repo)
git submodule update --init --recursive
```

If you're using this as a template for your own infrastructure, create your own private companion repo:

```bash
gh repo create my-vps-private --private
git submodule add https://github.com/<you>/my-vps-private private/
```
