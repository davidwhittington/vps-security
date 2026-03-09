#!/usr/bin/env bash
# lib/output.sh — shared console output utilities for linux-security scripts
#
# Usage (from any script):
#   LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib"
#   # shellcheck source=/dev/null
#   source "${LIB_DIR}/output.sh"
#
# Provides: check_pass, check_fail, check_warn, check_info, banner, section_header, summary
# Sets: FAIL (counter, incremented by check_fail)

# Colors — auto-disabled when not a TTY
if [[ -t 1 ]]; then
    COL_GREEN="\033[0;32m"
    COL_YELLOW="\033[0;33m"
    COL_RED="\033[0;31m"
    COL_BOLD="\033[1m"
    COL_RESET="\033[0m"
else
    COL_GREEN="" COL_YELLOW="" COL_RED="" COL_BOLD="" COL_RESET=""
fi

# Failure counter — reset to 0 on source; scripts should check "$FAIL" at end
FAIL=0

check_pass() { printf "  ${COL_GREEN}[PASS]${COL_RESET} %s\n" "$1"; }
check_warn() { printf "  ${COL_YELLOW}[WARN]${COL_RESET} %s — %s\n" "$1" "$2"; }
check_fail() { printf "  ${COL_RED}[FAIL]${COL_RESET} %s — %s\n" "$1" "$2"; ((FAIL++)); }
check_info() { printf "       %s\n" "$1"; }

banner() {
    local title="$1"
    echo "========================================="
    printf "  %s\n" "$title"
    echo "  Host: $(hostname -f)"
    echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
    echo "========================================="
    echo ""
}

section_header() {
    echo ""
    echo "[ $1 ]"
}

summary() {
    local ok_msg="${1:-All checks passed.}"
    echo ""
    echo "========================================="
    if [[ "$FAIL" -eq 0 ]]; then
        printf "  ${COL_GREEN}%s${COL_RESET}\n" "$ok_msg"
    else
        printf "  ${COL_RED}%d issue(s) found — review output above.${COL_RESET}\n" "$FAIL"
    fi
    echo "========================================="
}
