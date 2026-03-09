#!/usr/bin/env bash
# unattended-upgrades-check.sh — automatic security update status checker
#
# Verifies unattended-upgrades is installed, active, and has run recently.
# Reports last run date, any errors, and held-back packages.
# Read-only. Exits 1 if unattended-upgrades is not active.
#
# Usage:
#   bash scripts/audit/unattended-upgrades-check.sh
set -uo pipefail

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
echo "  Unattended-Upgrades Check"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

# --- Installed ---
if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
    check_pass "unattended-upgrades package installed"
else
    check_fail "unattended-upgrades installed" "Not installed — run: apt install unattended-upgrades"
    exit 1
fi

# --- Service active ---
if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    check_pass "unattended-upgrades service active"
elif systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
    check_warn "unattended-upgrades service" "Enabled but not currently active"
else
    check_fail "unattended-upgrades service" "Not active — run: systemctl enable --now unattended-upgrades"
fi

# --- Last run ---
LOG_DIR="/var/log/unattended-upgrades"
if [[ -d "$LOG_DIR" ]]; then
    LATEST_LOG=$(ls -t "${LOG_DIR}"/unattended-upgrades.log* 2>/dev/null | head -1)
    if [[ -n "$LATEST_LOG" ]]; then
        LAST_MOD=$(stat -c %Y "$LATEST_LOG" 2>/dev/null || stat -f %m "$LATEST_LOG" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        AGE_DAYS=$(( (NOW - LAST_MOD) / 86400 ))

        if [[ "$AGE_DAYS" -le 2 ]]; then
            check_pass "Last run: ${AGE_DAYS} day(s) ago"
        elif [[ "$AGE_DAYS" -le 7 ]]; then
            check_warn "Last run" "${AGE_DAYS} days ago — expected daily"
        else
            check_fail "Last run" "${AGE_DAYS} days ago — may not be running"
        fi

        # Check for errors in last run
        if grep -qi "error\|failed" "$LATEST_LOG" 2>/dev/null; then
            check_warn "Last run had errors" "Check $LATEST_LOG"
        else
            check_pass "No errors in last run log"
        fi
    else
        check_warn "Last run" "No log files found in $LOG_DIR"
    fi
else
    check_warn "Log directory" "$LOG_DIR not found"
fi

# --- Held packages ---
echo ""
echo "[ Held-back packages ]"
HELD=$(apt-mark showhold 2>/dev/null)
if [[ -z "$HELD" ]]; then
    check_pass "No held-back packages"
else
    check_warn "Held packages" "These will not be auto-updated:"
    echo "$HELD" | sed 's/^/    /'
fi

# --- Config ---
echo ""
echo "[ Configuration ]"
UA_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
if [[ -f "$UA_CONF" ]]; then
    check_pass "$UA_CONF exists"
    if grep -q 'Unattended-Upgrade::Allowed-Origins' "$UA_CONF" 2>/dev/null; then
        check_pass "Allowed-Origins configured"
    else
        check_warn "Allowed-Origins" "Not found in $UA_CONF — default may apply"
    fi
else
    check_warn "$UA_CONF" "Config file not found — using package defaults"
fi

# --- Summary ---
echo ""
echo "========================================="
if [[ "$FAIL" -eq 0 ]]; then
    printf "  ${GREEN}Unattended-upgrades is configured correctly.${RESET}\n"
else
    printf "  ${RED}%d issue(s) found.${RESET}\n" "$FAIL"
fi
echo "========================================="

[[ "$FAIL" -eq 0 ]]
