#!/usr/bin/env bash
# suid-check.sh — SUID/SGID binary baseline and drift detection
#
# Scans the filesystem for all SUID and SGID binaries, compares against
# a saved baseline, and flags any additions or removals.
# On first run (no baseline), saves the current state as the baseline.
# Read-only mode by default. Exits 1 if unexpected binaries are found.
#
# Usage:
#   bash scripts/core/audit/suid-check.sh              # compare against baseline
#   bash scripts/core/audit/suid-check.sh --update     # overwrite baseline with current state
#   bash scripts/core/audit/suid-check.sh --save       # alias for --update (first-run baseline)
set -uo pipefail

BASELINE_DIR="/var/lib/vps-security"
BASELINE_FILE="${BASELINE_DIR}/suid-baseline.txt"
UPDATE=false
for arg in "$@"; do
    [[ "$arg" == "--update" || "$arg" == "--save" ]] && UPDATE=true
done

if [[ -t 1 ]]; then
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" RESET="\033[0m"
else
    GREEN="" YELLOW="" RED="" RESET=""
fi

FAIL=0
check_pass() { printf "  ${GREEN}[PASS]${RESET} %s\n" "$1"; }
check_fail() { printf "  ${RED}[FAIL]${RESET} %s — %s\n" "$1" "$2"; ((FAIL++)); }
check_warn() { printf "  ${YELLOW}[WARN]${RESET} %s — %s\n" "$1" "$2"; }

echo "========================================="
echo "  SUID/SGID Binary Check"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "  NOTE: Running without root — some paths may be inaccessible."
    echo ""
fi

# --- Scan ---
echo "Scanning for SUID/SGID binaries (excludes /proc, /sys, /dev)..."
CURRENT=$(find / \
    \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune \
    -o \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null \
    | sort)

CURRENT_COUNT=$(echo "$CURRENT" | grep -c . || true)
echo "  Found: ${CURRENT_COUNT} SUID/SGID binaries"
echo ""

# --- First-run or update ---
if $UPDATE || [[ ! -f "$BASELINE_FILE" ]]; then
    if [[ ! -f "$BASELINE_FILE" ]]; then
        echo "No baseline found — saving current state as baseline."
    else
        echo "Updating baseline with current state."
    fi
    mkdir -p "$BASELINE_DIR"
    echo "$CURRENT" > "$BASELINE_FILE"
    echo "  Baseline saved: $BASELINE_FILE (${CURRENT_COUNT} entries)"
    echo ""
    echo "  Run this script again (without --update) to check for drift."
    echo "========================================="
    exit 0
fi

# --- Compare ---
BASELINE=$(cat "$BASELINE_FILE")
BASELINE_COUNT=$(echo "$BASELINE" | grep -c . || true)

ADDED=$(comm -23 <(echo "$CURRENT") <(echo "$BASELINE") | grep -v '^$' || true)
REMOVED=$(comm -13 <(echo "$CURRENT") <(echo "$BASELINE") | grep -v '^$' || true)

echo "[ Drift Analysis ]"
echo "  Baseline:  ${BASELINE_COUNT} binaries"
echo "  Current:   ${CURRENT_COUNT} binaries"
echo ""

if [[ -n "$REMOVED" ]]; then
    printf "  ${YELLOW}Removed since baseline (no longer SUID/SGID):${RESET}\n"
    echo "$REMOVED" | sed 's/^/    /'
    echo ""
fi

if [[ -n "$ADDED" ]]; then
    printf "  ${RED}Added since baseline (new SUID/SGID binaries):${RESET}\n"
    echo "$ADDED" | sed 's/^/    /'
    echo ""
    check_fail "SUID/SGID drift detected" "$(echo "$ADDED" | wc -l | tr -d ' ') new binary/binaries not in baseline"
    echo ""
    echo "  Investigate each new entry. If legitimate, run:"
    echo "    bash scripts/core/audit/suid-check.sh --update"
else
    check_pass "No new SUID/SGID binaries since baseline"
fi

# --- Current list ---
echo ""
echo "[ Current SUID/SGID Binaries ]"
echo "$CURRENT" | sed 's/^/  /'
echo ""

echo "========================================="
if [[ "$FAIL" -eq 0 ]]; then
    printf "  ${GREEN}No unexpected SUID/SGID drift detected.${RESET}\n"
else
    printf "  ${RED}%d issue(s) found — review new SUID/SGID binaries above.${RESET}\n" "$FAIL"
fi
echo "========================================="

[[ "$FAIL" -eq 0 ]]
