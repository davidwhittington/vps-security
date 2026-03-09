#!/usr/bin/env bash
# apparmor-check.sh — AppArmor enforcement status and profile audit
#
# Checks whether AppArmor is active and lists all loaded profiles,
# flagging any in complain or unconfined mode.
# Read-only. Exits 1 if AppArmor is not active.
#
# Usage:
#   bash scripts/audit/apparmor-check.sh
set -uo pipefail

if [[ -t 1 ]]; then
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" RESET="\033[0m"
else
    GREEN="" YELLOW="" RED="" RESET=""
fi

echo "========================================="
echo "  AppArmor Status Check"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

# Check AppArmor is available
if ! command -v aa-status &>/dev/null && ! command -v apparmor_status &>/dev/null; then
    echo "  AppArmor tools not found. Install with: apt install apparmor-utils"
    exit 1
fi

AA_CMD="aa-status"
command -v aa-status &>/dev/null || AA_CMD="apparmor_status"

# Check kernel module loaded
if ! cat /sys/module/apparmor/parameters/enabled 2>/dev/null | grep -q "Y"; then
    printf "  ${RED}[FAIL]${RESET} AppArmor kernel module not enabled.\n"
    echo ""
    echo "  Enable AppArmor:"
    echo "    apt install apparmor apparmor-utils"
    echo "    update-grub && reboot"
    exit 1
fi

printf "  ${GREEN}[PASS]${RESET} AppArmor kernel module active.\n"
echo ""

# Parse aa-status output
AA_OUT=$($AA_CMD 2>/dev/null || true)

if [[ -z "$AA_OUT" ]]; then
    printf "  ${YELLOW}[WARN]${RESET} Could not read AppArmor status (try running as root).\n"
    exit 0
fi

# Counts
enforced=$(echo "$AA_OUT" | grep -c "enforce" || true)
complain=$(echo "$AA_OUT" | grep -c "complain" || true)

printf "  Profiles in enforce mode:  %d\n" "$enforced"
printf "  Profiles in complain mode: %d\n" "$complain"
echo ""

if [[ "$complain" -gt 0 ]]; then
    printf "  ${YELLOW}[WARN]${RESET} Profiles in complain mode (not enforcing):\n"
    echo "$AA_OUT" | grep "complain" | sed 's/^/    /'
    echo ""
    echo "  To enforce a profile:"
    echo "    aa-enforce <profile-name>"
fi

echo ""
echo "Full status:"
echo "$AA_OUT" | head -20
echo ""
echo "========================================="
[[ "$complain" -eq 0 ]]
