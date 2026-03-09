#!/usr/bin/env bash
# web-roots-writable.sh — world-writable file and directory scanner for web roots
#
# Scans /var/www for world-writable files and directories.
# Any found are a security risk — web processes should not be able to
# write files that the web server can then serve or execute.
# Read-only. Exits 1 if any world-writable paths are found.
#
# Usage:
#   bash scripts/audit/web-roots-writable.sh
#   bash scripts/audit/web-roots-writable.sh /custom/webroot
set -uo pipefail

WEB_ROOT="${1:-/var/www}"

if [[ -t 1 ]]; then
    GREEN="\033[0;32m" RED="\033[0;31m" RESET="\033[0m"
else
    GREEN="" RED="" RESET=""
fi

echo "========================================="
echo "  World-Writable File Scanner"
echo "  Root: $WEB_ROOT"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

if [[ ! -d "$WEB_ROOT" ]]; then
    echo "ERROR: $WEB_ROOT not found." >&2
    exit 1
fi

FOUND=0

echo "Scanning for world-writable files..."
while IFS= read -r path; do
    printf "  ${RED}[WRITABLE FILE]${RESET}  %s\n" "$path"
    ((FOUND++))
done < <(find "$WEB_ROOT" -type f -perm -002 2>/dev/null)

echo ""
echo "Scanning for world-writable directories..."
while IFS= read -r path; do
    printf "  ${RED}[WRITABLE DIR]${RESET}   %s\n" "$path"
    ((FOUND++))
done < <(find "$WEB_ROOT" -type d -perm -002 2>/dev/null)

echo ""
if [[ "$FOUND" -eq 0 ]]; then
    printf "  ${GREEN}No world-writable paths found under %s.${RESET}\n" "$WEB_ROOT"
else
    printf "  ${RED}%d world-writable path(s) found.${RESET}\n" "$FOUND"
    echo ""
    echo "  Fix with:"
    echo "    chmod o-w <path>"
    echo ""
    echo "  Or to fix all at once (review first):"
    echo "    find $WEB_ROOT -perm -002 -exec chmod o-w {} +"
fi
echo "========================================="

[[ "$FOUND" -eq 0 ]]
