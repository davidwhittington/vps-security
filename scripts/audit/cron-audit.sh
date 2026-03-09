#!/usr/bin/env bash
# cron-audit.sh — scheduled job inventory and validator
#
# Enumerates all cron jobs across system and user crontabs, /etc/cron.d/,
# and cron.daily/weekly/monthly. Flags any root-owned jobs that execute
# scripts in world-writable directories.
# Read-only. Exits 1 if dangerous cron configurations are found.
#
# Usage:
#   bash scripts/audit/cron-audit.sh
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"

banner "Cron Job Audit"

if [[ $EUID -ne 0 ]]; then
    echo "  NOTE: Run as root to see all user crontabs."
    echo ""
fi

print_cron_file() {
    local label="$1" file="$2"
    local contents
    contents=$(grep -v '^#' "$file" 2>/dev/null | grep -v '^$' || true)
    if [[ -n "$contents" ]]; then
        echo "  [$label]"
        echo "$contents" | sed 's/^/    /'
        echo ""
    fi
}

# --- System crontab ---
section_header "/etc/crontab"
print_cron_file "/etc/crontab" /etc/crontab

# --- /etc/cron.d/ ---
section_header "/etc/cron.d/"
if [[ -d /etc/cron.d ]]; then
    for f in /etc/cron.d/*; do
        [[ -f "$f" ]] && print_cron_file "$f" "$f"
    done
fi

# --- Periodic directories ---
section_header "cron.daily / cron.weekly / cron.monthly"
for dir in /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.hourly; do
    if [[ -d "$dir" ]]; then
        scripts=$(find "$dir" -maxdepth 1 -type f -executable 2>/dev/null | sort)
        if [[ -n "$scripts" ]]; then
            echo "  [${dir}]"
            echo "$scripts" | sed 's/^/    /'
            echo ""
        fi
    fi
done

# --- Root crontab ---
section_header "root crontab"
ROOT_CRON=$(crontab -l 2>/dev/null || true)
if [[ -n "$ROOT_CRON" ]]; then
    echo "$ROOT_CRON" | grep -v '^#' | grep -v '^$' | sed 's/^/  /' || true
    echo ""
else
    echo "  (empty)"
    echo ""
fi

# --- User crontabs ---
section_header "User crontabs"
if [[ $EUID -eq 0 ]] && [[ -d /var/spool/cron/crontabs ]]; then
    for f in /var/spool/cron/crontabs/*; do
        [[ -f "$f" ]] && print_cron_file "$(basename "$f")" "$f"
    done
else
    echo "  Skipped (requires root)"
    echo ""
fi

# --- Safety checks ---
section_header "Safety Checks"

# Check for cron jobs executing scripts in world-writable directories
ALL_CRON_SCRIPTS=$(
    { crontab -l 2>/dev/null; cat /etc/crontab 2>/dev/null;
      cat /etc/cron.d/* 2>/dev/null; } \
    | grep -v '^#' | grep -oE '/[^ ]+\.(sh|py|pl|rb)' | sort -u || true
)

RISKY=0
while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    dir=$(dirname "$script")
    if [[ -d "$dir" ]] && [[ -w "$dir" ]] && [[ "$(stat -c %a "$dir" 2>/dev/null || true)" =~ [2367] ]]; then
        check_fail "Cron script in world-writable dir: ${script}" \
            "Any user can replace this script — privilege escalation risk"
        ((RISKY++))
    fi
done <<< "$ALL_CRON_SCRIPTS"

if [[ "$RISKY" -eq 0 ]]; then
    check_pass "No cron scripts found in world-writable directories"
fi

# Check cron.d files are not world-writable
if [[ -d /etc/cron.d ]]; then
    WW_CROND=$(find /etc/cron.d -maxdepth 1 -perm -002 -type f 2>/dev/null || true)
    if [[ -n "$WW_CROND" ]]; then
        check_fail "World-writable files in /etc/cron.d" "$(echo "$WW_CROND" | head -5)"
    else
        check_pass "/etc/cron.d files not world-writable"
    fi
fi

summary "Cron audit complete."
[[ "$FAIL" -eq 0 ]]
