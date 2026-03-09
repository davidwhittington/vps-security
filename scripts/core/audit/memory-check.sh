#!/usr/bin/env bash
# memory-check.sh — memory and swap health check
#
# Checks:
#   - Total RAM (warn if < 512MB, info if < 1GB)
#   - Swap configured and active
#   - Swap usage (warn if > 50%)
#   - Current memory pressure (MemAvailable < 10% of total)
#   - OOM kill events in kernel log
# Read-only. Exits 1 if critical issues found.
#
# Usage:
#   bash scripts/core/audit/memory-check.sh
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"

banner "Memory & Swap Check"

# --- RAM ---
section_header "System Memory"

if [[ ! -f /proc/meminfo ]]; then
    check_warn "Memory info" "/proc/meminfo not found — cannot read memory stats"
else
    MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    MEM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
    MEM_AVAIL_MB=$(( MEM_AVAIL_KB / 1024 ))

    if [[ "$MEM_TOTAL_MB" -lt 512 ]]; then
        check_fail "Total RAM: ${MEM_TOTAL_MB}MB" "Less than 512MB — system may be unstable; consider upgrading or adding swap"
    elif [[ "$MEM_TOTAL_MB" -lt 1024 ]]; then
        check_warn "Total RAM: ${MEM_TOTAL_MB}MB" "Less than 1GB — ensure adequate swap is configured"
    else
        check_pass "Total RAM: ${MEM_TOTAL_MB}MB"
    fi

    # Memory pressure check
    if [[ "$MEM_TOTAL_KB" -gt 0 ]]; then
        AVAIL_PCT=$(( MEM_AVAIL_KB * 100 / MEM_TOTAL_KB ))
        if [[ "$AVAIL_PCT" -lt 10 ]]; then
            check_fail "Available memory: ${MEM_AVAIL_MB}MB (${AVAIL_PCT}%)" "Less than 10% available — system is under memory pressure"
        elif [[ "$AVAIL_PCT" -lt 25 ]]; then
            check_warn "Available memory: ${MEM_AVAIL_MB}MB (${AVAIL_PCT}%)" "Less than 25% available"
        else
            check_pass "Available memory: ${MEM_AVAIL_MB}MB (${AVAIL_PCT}%)"
        fi
    fi
fi

# --- Swap ---
section_header "Swap"

SWAP_TOTAL_KB=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
SWAP_FREE_KB=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
SWAP_TOTAL_MB=$(( SWAP_TOTAL_KB / 1024 ))

if [[ "$SWAP_TOTAL_KB" -eq 0 ]]; then
    if [[ "${MEM_TOTAL_MB:-0}" -lt 2048 ]]; then
        check_fail "Swap configured" "No swap found — required on servers with < 2GB RAM"
        check_info "Fix: fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    else
        check_warn "Swap configured" "No swap — acceptable for servers with >= 2GB RAM but recommended"
    fi
else
    check_pass "Swap configured: ${SWAP_TOTAL_MB}MB"

    SWAP_USED_KB=$(( SWAP_TOTAL_KB - SWAP_FREE_KB ))
    SWAP_USED_PCT=$(( SWAP_USED_KB * 100 / SWAP_TOTAL_KB ))

    if [[ "$SWAP_USED_PCT" -gt 80 ]]; then
        check_fail "Swap usage: ${SWAP_USED_PCT}%" "Over 80% swap in use — investigate memory-hungry processes"
    elif [[ "$SWAP_USED_PCT" -gt 50 ]]; then
        check_warn "Swap usage: ${SWAP_USED_PCT}%" "Over half of swap is in use — monitor memory trends"
    else
        check_pass "Swap usage: ${SWAP_USED_PCT}%"
    fi

    # Swappiness
    SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
    if [[ "$SWAPPINESS" == "unknown" ]]; then
        check_warn "vm.swappiness" "Cannot read — /proc/sys/vm/swappiness not found"
    elif [[ "$SWAPPINESS" -gt 60 ]]; then
        check_warn "vm.swappiness: ${SWAPPINESS}" "Greater than 60 — kernel will swap aggressively; consider setting to 10 for servers"
        check_info "Fix: echo 'vm.swappiness=10' >> /etc/sysctl.d/99-hardening.conf && sysctl -p /etc/sysctl.d/99-hardening.conf"
    else
        check_pass "vm.swappiness: ${SWAPPINESS}"
    fi
fi

# --- OOM kills ---
section_header "OOM Kill History"
if command -v dmesg &>/dev/null; then
    OOM_EVENTS=$(dmesg --time-format reltime 2>/dev/null | grep -c "oom.kill" 2>/dev/null || \
                 dmesg 2>/dev/null | grep -c "oom.kill" || echo 0)
    if [[ "$OOM_EVENTS" -gt 0 ]]; then
        check_warn "OOM kill events in kernel log" "${OOM_EVENTS} event(s) since last boot — processes are being killed due to memory exhaustion"
        dmesg 2>/dev/null | grep "oom.kill" | tail -3 | sed 's/^/    /'
    else
        check_pass "No OOM kill events since last boot"
    fi
else
    check_warn "OOM check" "dmesg not available"
fi

summary "Memory check complete."
[[ "$FAIL" -eq 0 ]]
