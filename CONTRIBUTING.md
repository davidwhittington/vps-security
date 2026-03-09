# Contributing

Contributions are welcome. This document covers the conventions, style requirements, and process for adding or modifying scripts.

---

## Script Style Guide

All scripts in `scripts/hardening/` and `scripts/audit/` must follow these conventions.

### Shebang and error handling

```bash
#!/usr/bin/env bash
set -euo pipefail
```

`set -euo pipefail` is required on every script. Do not use `set -e` alone.

### Dry-run support (hardening scripts)

Every script that modifies the system must support `--dry-run`:

```bash
DRYRUN=false
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRYRUN=true; done

cmd() {
    if $DRYRUN; then echo "  [dry-run] $*"; return 0; fi
    "$@"
}
```

Use `cmd` for commands that change system state. For heredoc file writes, use an explicit `if ! $DRYRUN; then ... else echo "[dry-run] ..."; fi` block.

### Config discovery

Every script must auto-discover `config.env` using the standard chain:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    for loc in \
        "$SCRIPT_DIR/../../config.env" \
        "$SCRIPT_DIR/../config.env" \
        /etc/linux-security/config.env; do
        if [[ -f "$loc" ]]; then CONFIG_FILE="$loc"; break; fi
    done
fi
if [[ -n "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi
```

Never hardcode email addresses, usernames, domains, or ports. All site-specific values must come from config.env variables with sensible defaults.

### Output formatting

**Hardening scripts:** numbered steps `[1/N]`, banner at start, summary at end.

**Audit scripts:** source `lib/output.sh` and use `check_pass`, `check_warn`, `check_fail`, `banner`, `section_header`, and `summary`.

```bash
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"
```

### Idempotency

Every script must be safe to run multiple times. Specifically:

- File writes should overwrite, not append
- Service enables/restarts should be `systemctl enable --now`, not conditional
- Cron additions must de-duplicate: `(crontab -l 2>/dev/null | grep -v "script-name"; echo "$CRON_LINE") | crontab -`
- Package installs must use `apt-get install -y` (idempotent by nature)

### Root check

All hardening scripts must abort if not run as root:

```bash
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi
```

### Backups before modification

Any script that modifies an existing config file must back it up first:

```bash
cp /etc/some/config /etc/some/config.bak
```

### Exit codes

- Hardening scripts: exit 0 on success, exit 1 on fatal error
- Audit scripts: exit 0 if all checks pass, exit 1 if any FAIL (WARNs do not fail)

---

## Adding a New Script

### Hardening script

1. Name it `NN-descriptive-name.sh` with the next available number
2. Place it in `scripts/hardening/`
3. Follow all conventions above
4. Add `--dry-run` support throughout
5. Add a CHANGELOG entry under `[Unreleased]`
6. Update the script inventory in `README.md` and `index.html` (gh-pages branch)
7. Add a corresponding verify step in `scripts/core/audit/verify.sh`

### Audit script

1. Name it `descriptive-name.sh`
2. Place it in `scripts/audit/`
3. Source `lib/output.sh` — do not duplicate color/check functions
4. Must be read-only (no system modifications)
5. Must exit 1 on FAIL, exit 0 on PASS (WARNs are informational)
6. Add a CHANGELOG entry
7. Update the script inventory in `README.md` and `index.html`

---

## Commit and PR Process

1. Fork the repo and create a branch from `main`
2. Run `bash -n scripts/hardening/your-script.sh` (syntax check) before submitting
3. Install shellcheck and run `shellcheck scripts/hardening/your-script.sh`
4. Test with `--dry-run` before testing a live run
5. Open a PR with:
   - What the script does
   - Which issue it closes
   - Dry-run output snippet
   - Live test result (redact any personal data)

---

## Shellcheck

All scripts are checked by CI on push and PR (`.github/workflows/lint.yml`). Fix all `warning` and `error` level findings before submitting. `info` level findings are acceptable but preferred to be resolved.

---

## Changelog

Every PR that adds or changes a script must update `CHANGELOG.md` under `## [Unreleased]`. Follow [Keep a Changelog v1.0.0](https://keepachangelog.com/en/1.0.0/).

Use `Added` for new scripts/features, `Changed` for modifications, `Fixed` for bug fixes.
