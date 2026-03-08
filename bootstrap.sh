#!/usr/bin/env bash
# bootstrap.sh — vps-security full-stack provisioner
#
# Sources config.env, runs all hardening scripts in order, logs each run.
# Exits non-zero if any script fails.
#
# Usage:
#   bash bootstrap.sh              # Full hardening run
#   bash bootstrap.sh --dry-run    # Preview all changes, make none
set -euo pipefail

# --- Args ---
DRYRUN=false
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRYRUN=true; done

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_FILE="${LOG_DIR}/bootstrap-${TIMESTAMP}.log"

# --- Config discovery ---
CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    for loc in \
        "$SCRIPT_DIR/config.env" \
        /etc/vps-security/config.env; do
        if [[ -f "$loc" ]]; then CONFIG_FILE="$loc"; break; fi
    done
fi

if [[ -n "$CONFIG_FILE" ]]; then
    export CONFIG_FILE
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "ERROR: config.env not found." >&2
    echo "  Copy config.env to the repo root and fill in your values." >&2
    echo "  See docs/customization.md for details." >&2
    exit 1
fi

# --- Pre-flight ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: bootstrap.sh must be run as root." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

# --- Banner ---
echo "========================================="
echo "  vps-security Bootstrap"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
if $DRYRUN; then
    echo "  MODE: DRY RUN — no changes will be made"
fi
echo "  Log:  $LOG_FILE"
echo "========================================="
echo ""

SCRIPTS=(
    "scripts/hardening/01-immediate-hardening.sh"
    "scripts/hardening/02-apache-hardening.sh"
    "scripts/hardening/03-setup-admin-user.sh"
    "scripts/hardening/04-monthly-updates-setup.sh"
    "scripts/hardening/05-log-monitoring-setup.sh"
)

PASS=0
FAIL=0

run_script() {
    local script="$1"
    local name
    name=$(basename "$script")
    local script_log="${LOG_DIR}/${TIMESTAMP}-${name%.sh}.log"

    echo "--- Running: $name ---"

    local args=()
    $DRYRUN && args+=("--dry-run")

    if bash "${SCRIPT_DIR}/${script}" "${args[@]}" 2>&1 | tee "$script_log"; then
        echo "  [OK] $name"
        ((PASS++))
    else
        echo "  [FAILED] $name — see $script_log"
        ((FAIL++))
        return 1
    fi
    echo ""
}

# Run all scripts, stop on first failure
for script in "${SCRIPTS[@]}"; do
    run_script "$script"
done | tee "$LOG_FILE"

# --- Summary ---
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Bootstrap complete!"
fi
echo ""
echo "  Scripts run:   ${#SCRIPTS[@]}"
echo "  Passed:        $PASS"
echo "  Failed:        $FAIL"
echo "  Full log:      $LOG_FILE"
if ! $DRYRUN && [[ "$FAIL" -eq 0 ]]; then
    echo ""
    echo "  Running post-run verification..."
    echo ""
    bash "${SCRIPT_DIR}/scripts/audit/verify.sh" --brief 2>&1 | tee -a "$LOG_FILE" || true
    echo ""
    echo "  Full audit: bash scripts/audit/audit.sh"
    echo "  IMPORTANT: test SSH in a new terminal before"
    echo "  closing this session."
fi
echo "========================================="

[[ "$FAIL" -eq 0 ]]
