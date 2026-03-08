# Architecture

How the toolkit fits together — for contributors and operators extending or adapting it.

---

## Overview

vps-security is organized around three concerns:

1. **Configuration** — one file (`config.env`) holds all environment-specific values
2. **Hardening** — five sequential scripts apply controls to a live server
3. **Verification** — the audit script checks that controls are active after the fact

These are intentionally decoupled. Config is separate from scripts. Audit is read-only and separate from hardening. The whole stack can be previewed with `--dry-run` before anything touches a server.

---

## Directory Layout

```
vps-security/
├── config.env                   # User configuration (fill in before running)
├── bootstrap.sh                 # Orchestrator: sources config, runs 01–05 in order
│
├── scripts/
│   ├── hardening/               # Numbered scripts, run in sequence
│   │   ├── 01-immediate-hardening.sh
│   │   ├── 02-apache-hardening.sh
│   │   ├── 03-setup-admin-user.sh
│   │   ├── 04-monthly-updates-setup.sh
│   │   └── 05-log-monitoring-setup.sh
│   └── audit/
│       └── audit.sh             # Read-only baseline checker
│
├── docs/                        # Operator and contributor documentation
│   ├── architecture.md          # This file
│   ├── customization.md         # config.env variable reference
│   ├── security/README.md       # Security baseline and policy
│   ├── TEMPLATE.md              # Audit report template
│   └── VPS_HARDENING_GUIDE.html # Standalone offline reference
│
├── config/                      # Config snippets and templates (planned)
├── logs/                        # Per-run bootstrap logs (gitignored)
└── private/                     # Git submodule — server-specific data (not public)
```

---

## Config Discovery

Every script and `bootstrap.sh` uses the same discovery chain at startup. The first match wins:

```
1. $CONFIG_FILE environment variable (explicit override)
2. <script-dir>/../../config.env  (repo root when running from scripts/hardening/)
3. <script-dir>/../config.env     (repo root when running from scripts/)
4. /etc/vps-security/config.env   (system-wide install)
5. (none found) — use per-variable defaults, print a warning
```

This means scripts work correctly whether run via `bootstrap.sh` (which exports `CONFIG_FILE`), run directly from the repo, or installed system-wide. No path is hardcoded.

To point scripts at a config file in your private submodule:

```bash
export CONFIG_FILE=/path/to/private/config.env.local
bash bootstrap.sh
```

Each variable has a safe default or aborts with a clear error if required and unset:

| Variable | Default | Behavior if unset |
|---|---|---|
| `SSH_PORT` | `22` | Uses default |
| `ADMIN_USER` | _(none)_ | Script 03 aborts |
| `ADMIN_EMAIL` | _(none)_ | Scripts 04, 05 abort |
| `MAIL_FROM` | `server@<hostname>` | Uses default |
| `SMTP_HOST` | `smtp.gmail.com` | Uses default |
| `SMTP_PORT` | `587` | Uses default |
| `SMTP_USER` | _(none)_ | Skips auth block in msmtp config |
| `CSP_FRAME_ANCESTORS` | `'self'` | Uses default |

---

## Script Execution Order and Dependencies

The five hardening scripts are numbered because order matters:

```
01  →  02  →  03  →  04  →  05
```

| Script | Installs / Configures | Dependency |
|---|---|---|
| `01` | fail2ban, UFW, SSH config, sysctl | Requires SSH key in `/root/.ssh/authorized_keys` |
| `02` | Apache security headers, mod_headers, security.conf | Requires Apache running |
| `03` | Admin user sudo + SSH keys, removes cloud-init sudoers | User must exist; SSH keys should be in place (01 must have run) |
| `04` | msmtp, monthly upgrade cron | fail2ban must be installed (01) for the report to query it |
| `05` | Logwatch, GoAccess, reports .htaccess | Apache must be running (02 should have run); msmtp installed (04) |

Running scripts out of order won't break the server, but report output in 04 and 05 will be incomplete if fail2ban or Apache hardening hasn't run yet.

---

## bootstrap.sh Orchestration

`bootstrap.sh` is a thin orchestrator, not a monolith. It:

1. Requires `config.env` to be found (aborts if not — unlike standalone scripts which warn and continue)
2. Exports `CONFIG_FILE` so child scripts skip their own discovery
3. Runs each script with `bash`, capturing stdout/stderr to both console and a per-script log file
4. Stops the chain on the first non-zero exit
5. Prints a summary of pass/fail counts and the log directory location

Log files are written to `logs/` at the repo root:

```
logs/
└── 20260308-153042/
    ├── bootstrap.log                  (full combined output)
    ├── 20260308-153042-01-immediate-hardening.log
    ├── 20260308-153042-02-apache-hardening.log
    └── ...
```

The `logs/` directory is gitignored. It is appropriate to copy logs to the private submodule after a run for an audit trail.

`--dry-run` is passed through to every child script. The entire stack can be previewed without a single change to the server.

---

## audit.sh Design

`audit.sh` is strictly read-only. It uses only inspection commands (`ufw status`, `sshd -T`, `fail2ban-client status`, `curl -sI`, `apt list`, `certbot certificates`) and makes no changes.

**Check categories and what they verify:**

| Category | Checks |
|---|---|
| Firewall | UFW active; SSH, HTTP, HTTPS ports open; no unexpected rules |
| SSH | `PasswordAuthentication no`; `PermitRootLogin` restricted; `X11Forwarding no` |
| fail2ban | Service running; `sshd` jail active; Apache jails (`apache-auth`, `apache-badbots`, `apache-noscript`) active |
| Apache | Service running; `ServerTokens Prod`; presence of HSTS, X-Content-Type-Options, Referrer-Policy, CSP headers; `mod_status` disabled |
| Updates | Pending package count; `unattended-upgrades` active |
| Certificates | Cert expiry via `certbot certificates`; flags anything expiring within 30 days |

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | All checks passed (no FAILs; WARNs are allowed) |
| `1` | One or more FAILs |

**Output modes:**

- Default: color-coded PASS / WARN / FAIL lines with summary counts
- `--json`: machine-readable JSON with host, timestamp, summary, and per-check results — suitable for storing in the private submodule as a timestamped snapshot

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
| `scripts/audit/` | Additional read-only checkers (open ports, SUID baseline, services diff, SSH config, firewall rules) — each a standalone script, runnable individually or composed |
| `scripts/hardening-nginx/` | Nginx equivalents of the Apache hardening scripts |
| `config/` | Reusable config snippets: example `jail.local`, `sysctl.conf`, Apache vhost templates with security headers pre-applied |

When adding a new hardening script:

1. Follow the numbered convention if it belongs in the main sequence, or add it unnumbered if it is optional/standalone
2. Source `config.env` using the standard discovery block (copy from any existing script)
3. Implement `--dry-run` using the `cmd()` pattern above
4. Add a pre-flight check for any precondition that could leave the server in a bad state
5. Back up any file before overwriting it
6. Update `README.md` (script list), `CHANGELOG.md`, and close the relevant issue
