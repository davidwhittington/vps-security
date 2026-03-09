# Architecture

How the toolkit fits together — for contributors and operators extending or adapting it.

---

## Overview

linux-security is organized around four concerns:

1. **Configuration** — two files (`config.env` and `config.web.env`) hold all environment-specific values
2. **Profiles** — a profile file selects which scripts run for a given server type
3. **Hardening** — sequential scripts apply controls to a live server, split between core (any server) and web (Apache/PHP/MySQL addendum)
4. **Verification** — the audit script checks that controls are active after the fact

These are intentionally decoupled. Config is separate from scripts. Audit is read-only and separate from hardening. The entire stack can be previewed with `--dry-run` before anything touches a server.

---

## Directory Layout

```
linux-security/
├── config.env                   # Core configuration (fill in before running)
├── config.web.env               # Web-layer configuration (web-server profile only)
├── bootstrap.sh                 # Orchestrator: reads profile, sources config, runs scripts
│
├── profiles/
│   ├── baseline.conf            # Core-only script list (any Ubuntu/Debian server)
│   └── web-server.conf          # Core + web script list (Apache/PHP/MySQL servers)
│
├── scripts/
│   ├── core/
│   │   ├── hardening/           # Core hardening scripts, run in sequence
│   │   │   ├── 01-immediate-hardening.sh
│   │   │   ├── 02-setup-admin-user.sh
│   │   │   ├── 03-monthly-updates-setup.sh
│   │   │   ├── 04-rkhunter-setup.sh
│   │   │   ├── 05-auditd-setup.sh
│   │   │   ├── 06-fail2ban-recidive.sh
│   │   │   ├── 07-aide-setup.sh
│   │   │   ├── 08-disk-alert-setup.sh
│   │   │   └── ssh-key-rotate.sh
│   │   └── audit/               # Standalone read-only checkers (core)
│   │       ├── verify.sh
│   │       ├── firewall-check.sh
│   │       ├── ssh-audit.sh
│   │       ├── ports-check.sh
│   │       └── ...
│   │
│   ├── web/
│   │   ├── hardening/           # Web-layer hardening scripts
│   │   │   ├── 01-apache-hardening.sh
│   │   │   ├── 02-log-monitoring-setup.sh
│   │   │   ├── 03-cert-monitor-setup.sh
│   │   │   ├── 04-clamav-setup.sh
│   │   │   ├── 05-modsecurity-setup.sh
│   │   │   ├── 06-vhost-hardener.sh
│   │   │   ├── 07-apache-tls-hardening.sh
│   │   │   ├── 08-apache-dos-mitigation.sh
│   │   │   ├── 09-php-hardening.sh
│   │   │   ├── 10-mysql-hardening.sh
│   │   │   └── rollback.sh
│   │   └── audit/               # Standalone read-only checkers (web)
│   │       ├── headers-check.sh
│   │       ├── vhost-linter.sh
│   │       ├── web-root-perms.sh
│   │       └── ...
│   │
│   └── audit/
│       └── audit.sh             # Profile-aware baseline checker (dispatches to core + web checkers)
│
├── lib/                         # Shared shell libraries (output helpers, etc.)
├── docs/                        # Operator and contributor documentation
│   ├── architecture.md          # This file
│   ├── customization.md         # config.env and config.web.env variable reference
│   ├── security/README.md       # Security baseline and policy
│   ├── TEMPLATE.md              # Audit report template
│   └── VPS_HARDENING_GUIDE.html # Standalone offline reference
│
├── config/                      # Config snippets and templates (planned)
├── logs/                        # Per-run bootstrap logs (gitignored)
└── private/                     # Git submodule — server-specific data (not public)
```

---

## Profiles

Profiles live in `profiles/` and are plain text files listing one script path per line. `bootstrap.sh` reads the selected profile and runs each script in order.

| Profile | File | What it runs |
|---|---|---|
| `baseline` | `profiles/baseline.conf` | `scripts/core/hardening/` scripts only — no Apache dependency |
| `web-server` | `profiles/web-server.conf` | Core scripts interleaved with `scripts/web/hardening/` scripts |

`web-server` is the default when `--profile` is omitted, preserving back-compatibility with earlier versions.

The profile selection also controls which config file is loaded: `bootstrap.sh` sources `config.web.env` only for the `web-server` profile. It also controls which audit checks run: `audit.sh` skips web-layer checks when `--profile baseline` is passed.

---

## Config Discovery

Every script and `bootstrap.sh` uses the same discovery chain at startup. The first match wins:

```
1. $CONFIG_FILE environment variable (explicit override)
2. <script-dir>/../../../config.env  (repo root when running from scripts/core/hardening/)
3. <script-dir>/../../config.env     (repo root when running from scripts/audit/)
4. /etc/linux-security/config.env   (system-wide install)
5. (none found) — use per-variable defaults, print a warning
```

Web scripts follow the same pattern for `config.web.env`, using `$WEB_CONFIG_FILE` as the override variable.

This means scripts work correctly whether run via `bootstrap.sh` (which exports `CONFIG_FILE`), run directly from the repo, or installed system-wide. No path is hardcoded.

To point scripts at a config file in your private submodule:

```bash
export CONFIG_FILE=/path/to/private/config.env.local
bash bootstrap.sh
```

Each variable has a safe default or aborts with a clear error if required and unset:

| Variable | Config file | Default | Behavior if unset |
|---|---|---|---|
| `SSH_PORT` | `config.env` | `22` | Uses default |
| `ADMIN_USER` | `config.env` | _(none)_ | Script 02 aborts |
| `ADMIN_EMAIL` | `config.env` | _(none)_ | Scripts abort |
| `MAIL_FROM` | `config.env` | `server@<hostname>` | Uses default |
| `SMTP_HOST` | `config.env` | `smtp.gmail.com` | Uses default |
| `SMTP_PORT` | `config.env` | `587` | Uses default |
| `SMTP_USER` | `config.env` | _(none)_ | Skips auth block in msmtp config |
| `CSP_FRAME_ANCESTORS` | `config.web.env` | `'self'` | Uses default |
| `CERT_WARN_DAYS` | `config.web.env` | `30` | Uses default |
| `WEB_ROOTS_DIR` | `config.web.env` | `/var/www` | Uses default |

---

## Script Execution Order and Dependencies

Scripts within each layer are numbered because order matters. The profile file determines the interleaving between core and web scripts.

**Baseline profile (core only):**

```
core/01  →  core/02  →  core/03  →  core/04  →  core/05  →  core/06  →  core/07  →  core/08
```

**Web-server profile (core + web interleaved):**

```
core/01  →  core/02  →  core/03  →  web/01  →  web/02  →  web/03  →  core/04  →  ...  →  web/09  →  web/10  →  core/08
```

| Script | Layer | Installs / Configures | Dependency |
|---|---|---|---|
| `core/01` | core | fail2ban, UFW, SSH config, sysctl | Requires SSH key in `/root/.ssh/authorized_keys` |
| `core/02` | core | Admin user sudo + SSH keys, removes cloud-init sudoers | User must exist; 01 must have run |
| `core/03` | core | msmtp, monthly upgrade cron | fail2ban must be installed (01) for reports to query it |
| `web/01` | web | Apache security headers, mod_headers, security.conf | Requires Apache running |
| `web/02` | web | Logwatch, GoAccess, reports .htaccess | Apache running (web/01); msmtp installed (core/03) |
| `web/03` | web | Cert expiry monitor cron + email alert | msmtp installed (core/03); certbot present |
| `core/04` | core | rkhunter rootkit scanner | _(none)_ |
| `core/05` | core | auditd syscall auditing | _(none)_ |
| `web/04–10` | web | ClamAV, ModSecurity, vhost hardening, TLS, DoS mitigation, PHP, MySQL | Apache running; relevant software installed |
| `core/06` | core | fail2ban recidive jail | fail2ban installed (01) |
| `core/07` | core | AIDE filesystem integrity | _(none)_ |
| `core/08` | core | Disk usage alert cron | msmtp installed (core/03) |

Running scripts out of order won't break the server, but report output will be incomplete if dependencies haven't run yet.

---

## bootstrap.sh Orchestration

`bootstrap.sh` is a thin orchestrator, not a monolith. It:

1. Validates the `--profile` argument and reads the corresponding profile file
2. Requires `config.env` to be found (aborts if not — unlike standalone scripts which warn and continue)
3. Exports `CONFIG_FILE` so child scripts skip their own discovery
4. For the `web-server` profile, also locates and exports `WEB_CONFIG_FILE`
5. Runs each script listed in the profile with `bash`, capturing stdout/stderr to both console and a per-script log file
6. Stops the chain on the first non-zero exit
7. Prints a summary of pass/fail counts and the log directory location

Log files are written to `logs/` at the repo root:

```
logs/
└── 20260308-153042/
    ├── bootstrap.log                         (full combined output)
    ├── 20260308-153042-01-immediate-hardening.log
    ├── 20260308-153042-web-01-apache-hardening.log
    └── ...
```

The `logs/` directory is gitignored. It is appropriate to copy logs to the private submodule after a run for an audit trail.

`--dry-run` is passed through to every child script. The entire stack can be previewed without a single change to the server.

---

## audit.sh Design

`audit.sh` is strictly read-only. It is profile-aware: core checks always run; web checks (`headers-check.sh`, `vhost-linter.sh`, certificate checks) are skipped when `--profile baseline` is passed.

It uses only inspection commands (`ufw status`, `sshd -T`, `fail2ban-client status`, `curl -sI`, `apt list`, `certbot certificates`) and makes no changes.

**Check categories and what they verify:**

| Category | Profile | Checks |
|---|---|---|
| Firewall | core | UFW active; SSH, HTTP, HTTPS ports open; no unexpected rules |
| SSH | core | `PasswordAuthentication no`; `PermitRootLogin` restricted; `X11Forwarding no` |
| fail2ban | core | Service running; `sshd` jail active; recidive jail active |
| Updates | core | Pending package count; `unattended-upgrades` active |
| Apache | web | Service running; `ServerTokens Prod`; HSTS, X-Content-Type-Options, Referrer-Policy, CSP headers; `mod_status` disabled |
| fail2ban (Apache jails) | web | `apache-auth`, `apache-badbots`, `apache-noscript` jails active |
| Certificates | web | Cert expiry via `certbot certificates`; flags anything expiring within `CERT_WARN_DAYS` |

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | All checks passed (no FAILs; WARNs are allowed) |
| `1` | One or more FAILs |

**Output modes:**

- Default: color-coded PASS / WARN / FAIL lines with summary counts
- `--json`: machine-readable JSON with host, timestamp, summary, and per-check results — suitable for storing in the private submodule as a timestamped snapshot
- `--report` / `--report html`: formatted audit report in Markdown or HTML

---

## Public/Private Submodule Split

The public repo contains only generic, reusable content: scripts with no server-specific values, documentation, templates. Nothing that identifies a real server.

The `private/` directory is a separate private git repository added as a submodule. It holds everything server-specific:

```
private/
├── servers/
│   └── <hostname>/
│       ├── AUDIT_REPORT.md     # Findings with real IPs, ports, hostnames
│       └── notes.md            # Operational notes
├── inventory/                  # Hardware/VM inventory, IPs, provider accounts
└── network/                    # Topology, firewall rule rationale, port maps
```

Cloning the public repo does not pull the submodule. Only users with access to the private repo can initialize it:

```bash
git submodule update --init --recursive
```

This is the intended model for adopters: fork the public repo, create your own private companion repo, wire it up as a submodule at `private/`. Your server-specific data stays private; you still benefit from upstream improvements to the scripts.

---

## Dry-Run Pattern

Every hardening script implements `--dry-run` using the same pattern:

```bash
DRYRUN=false
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRYRUN=true; done

cmd() {
    if $DRYRUN; then echo "  [dry-run] $*"; return 0; fi
    "$@"
}
```

Executable commands (package installs, systemctl, ufw, sed) go through `cmd()`.

File writes (heredocs) use explicit `if ! $DRYRUN; then ... else echo "[dry-run] Would write <path>"; fi` blocks to keep the heredoc readable while still printing meaningful output in dry-run mode.

Scripts that require a value from config (like `ADMIN_USER`) still validate and abort in dry-run mode — you want to catch missing config before a live run, not during one.

---

## Extension Points

The repo is structured for growth. Planned directories and their intended purpose:

| Path | Purpose |
|---|---|
| `scripts/core/audit/` | Additional read-only checkers (open ports, SUID baseline, services diff, SSH config, firewall rules) — each a standalone script, runnable individually or composed |
| `scripts/web/audit/` | Web-layer checkers (header validation, vhost linting, web root permissions) |
| `config/` | Reusable config snippets: example `jail.local`, `sysctl.conf`, Apache vhost templates with security headers pre-applied |

When adding a new hardening script:

1. Decide the layer: `scripts/core/hardening/` for server-agnostic controls, `scripts/web/hardening/` for anything with an Apache/web dependency
2. Follow the numbered convention if it belongs in the main sequence, or add it unnumbered if it is optional/standalone
3. Source `config.env` (and `config.web.env` if needed) using the standard discovery block (copy from any existing script)
4. Implement `--dry-run` using the `cmd()` pattern above
5. Add a pre-flight check for any precondition that could leave the server in a bad state
6. Back up any file before overwriting it
7. Add the script path to the relevant profile file(s), then update `README.md`, `CHANGELOG.md`, and close the relevant issue
