#!/usr/bin/env bash
# bootstrap.sh — linux-security provisioner
#
# Sources config.env (and config.web.env for the web-server profile), runs all
# hardening scripts listed in the selected profile, and logs each run.
# Exits non-zero if any script fails. Run as root.
set -euo pipefail

usage() {
    cat <<EOF
Usage: bootstrap.sh [OPTIONS]

Run all hardening scripts for the selected profile. Must be run as root.

Options:
  --profile PROFILE   Profile to run (default: web-server)
                        baseline    — core hardening only; works on any Ubuntu/Debian server
                        web-server  — core + Apache, PHP, MySQL, certbot hardening
  --dry-run           Preview every change without applying anything
  --confirm           Skip the interactive confirmation prompt
  --help, -h          Show this help

Profiles are defined in profiles/*.conf — plain text lists of scripts to run in order.
Config is read from config.env or /etc/linux-security/config.env.

Examples:
  bash bootstrap.sh                                # full web-server stack (default)
  bash bootstrap.sh --profile baseline             # core hardening only
  bash bootstrap.sh --profile baseline --dry-run   # preview baseline changes
  bash bootstrap.sh --profile web-server           # explicit full stack
EOF
}

# --- Args ---
DRYRUN=false
CONFIRM=false
PROFILE="web-server"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRYRUN=true ;;
        --confirm)  CONFIRM=true ;;
        --profile)  PROFILE="${2:-web-server}"; shift ;;
        --help|-h)  usage; exit 0 ;;
        *)          echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_FILE="${LOG_DIR}/bootstrap-${TIMESTAMP}.log"

# --- Validate profile ---
PROFILE_FILE="${SCRIPT_DIR}/profiles/${PROFILE}.conf"
if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "ERROR: Unknown profile '${PROFILE}'." >&2
    echo "  Available profiles: $(ls "$SCRIPT_DIR/profiles/" | sed 's/\.conf$//' | tr '\n' ' ')" >&2
    exit 1
fi

# --- Config discovery ---
CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    for loc in \
        "$SCRIPT_DIR/config.env" \
        /etc/linux-security/config.env; do
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

# --- Web config discovery (for web-server profile) ---
if [[ "$PROFILE" == "web-server" ]]; then
    WEB_CONFIG_FILE="${WEB_CONFIG_FILE:-}"
    if [[ -z "$WEB_CONFIG_FILE" ]]; then
        for loc in \
            "$SCRIPT_DIR/config.web.env" \
            /etc/linux-security/config.web.env; do
            if [[ -f "$loc" ]]; then WEB_CONFIG_FILE="$loc"; break; fi
        done
    fi
    if [[ -n "$WEB_CONFIG_FILE" ]]; then
        export WEB_CONFIG_FILE
        # shellcheck source=/dev/null
        source "$WEB_CONFIG_FILE"
    fi
fi

# --- Pre-flight ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: bootstrap.sh must be run as root." >&2
    exit 1
fi

require_confirm() {
    $CONFIRM && return
    $DRYRUN && return
    echo ""
    printf "  Type AGREE to continue or Ctrl+C to abort: "
    read -r _CONFIRM_REPLY
    [[ "$_CONFIRM_REPLY" == "AGREE" ]] || { echo "Aborted."; exit 0; }
}

require_confirm
CONFIRM=true   # prompt already given (or skipped); sub-scripts should not re-prompt

mkdir -p "$LOG_DIR"

# --- Load profile manifest ---
mapfile -t SCRIPTS < <(grep -v '^\s*#' "$PROFILE_FILE" | grep -v '^\s*$')

# --- Banner ---
echo "========================================="
echo "  linux-security Bootstrap"
echo "  Profile: ${PROFILE}"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
if $DRYRUN; then
    echo "  MODE: DRY RUN — no changes will be made"
fi
echo "  Log:  $LOG_FILE"
echo "========================================="
echo ""

PASS=0
FAIL=0

run_script() {
    local script="$1"
    local name
    name=$(basename "$script")
    local script_log="${LOG_DIR}/${TIMESTAMP}-${name%.sh}.log"

    echo "--- Running: ${script} ---"

    local args=()
    $DRYRUN && args+=("--dry-run")
    $CONFIRM && args+=("--confirm")

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

# Run all scripts in profile order, stop on first failure
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
echo "  Profile:       ${PROFILE}"
echo "  Scripts run:   ${#SCRIPTS[@]}"
echo "  Passed:        $PASS"
echo "  Failed:        $FAIL"
echo "  Full log:      $LOG_FILE"
if ! $DRYRUN && [[ "$FAIL" -eq 0 ]]; then
    echo ""
    echo "  Running post-run verification..."
    echo ""
    bash "${SCRIPT_DIR}/scripts/core/audit/verify.sh" --brief 2>&1 | tee -a "$LOG_FILE" || true
    echo ""
    echo "  Full audit: bash scripts/audit/audit.sh --profile ${PROFILE}"
    echo "  IMPORTANT: test SSH in a new terminal before"
    echo "  closing this session."
fi
echo "========================================="

[[ "$FAIL" -eq 0 ]]
