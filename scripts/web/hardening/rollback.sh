#!/usr/bin/env bash
# rollback.sh — restore backups created by vps-security hardening scripts
#
# Each hardening script backs up files before modifying them. This script
# restores those backups on demand. Only restores files; does not reverse
# package installations or cron changes.
#
# Usage:
#   bash scripts/web/hardening/rollback.sh [--script 01|02|04|05|all] [--dry-run]
#
# Backups created by each script:
#   01: /etc/ssh/sshd_config.bak
#   02: /etc/apache2/conf-available/security.conf.bak
#       /etc/apache2/conf-available/security-headers.conf.bak
#   04: /etc/msmtprc.bak
#   05: /etc/logwatch/conf/logwatch.conf.bak
set -euo pipefail

DRYRUN=false
TARGET="all"
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRYRUN=true
    [[ "$arg" == "--script" ]] && shift && TARGET="${1:-all}"
done
# Simple positional parse
for i in "$@"; do
    case "$i" in
        --script=*) TARGET="${i#*=}" ;;
        --script)   ;;
        --dry-run)  ;;
        *)          if [[ "$i" =~ ^(01|02|04|05|all)$ ]]; then TARGET="$i"; fi ;;
    esac
done

if [[ -t 1 ]]; then
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" RESET="\033[0m"
else
    GREEN="" YELLOW="" RED="" RESET=""
fi

restored=0
skipped=0
errors=0

restore_file() {
    local bak="$1"
    local orig="${bak%.bak}"
    if [[ ! -f "$bak" ]]; then
        printf "  ${YELLOW}[SKIP]${RESET} No backup found: %s\n" "$bak"
        ((skipped++))
        return 0
    fi
    if $DRYRUN; then
        printf "  [dry-run] Would restore: %s -> %s\n" "$bak" "$orig"
        ((restored++))
        return 0
    fi
    if cp "$bak" "$orig"; then
        printf "  ${GREEN}[OK]${RESET} Restored: %s\n" "$orig"
        ((restored++))
    else
        printf "  ${RED}[FAIL]${RESET} Could not restore: %s\n" "$orig"
        ((errors++))
    fi
}

reload_ssh() {
    if ! $DRYRUN; then
        if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
            printf "  ${GREEN}[OK]${RESET} SSH reloaded\n"
        else
            printf "  ${YELLOW}[WARN]${RESET} SSH reload failed — test manually\n"
        fi
    else
        echo "  [dry-run] Would reload: ssh"
    fi
}

reload_apache() {
    if ! $DRYRUN; then
        if apache2ctl configtest 2>/dev/null && systemctl reload apache2 2>/dev/null; then
            printf "  ${GREEN}[OK]${RESET} Apache reloaded\n"
        else
            printf "  ${YELLOW}[WARN]${RESET} Apache reload failed — check config\n"
        fi
    else
        echo "  [dry-run] Would reload: apache2"
    fi
}

echo "========================================="
echo "  vps-security Rollback"
echo "  Target: script ${TARGET}"
echo "  Host:   $(hostname -f)"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]] && ! $DRYRUN; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# --- Script 01: SSH ---
if [[ "$TARGET" == "01" || "$TARGET" == "all" ]]; then
    echo "[ Script 01 — SSH config ]"
    restore_file /etc/ssh/sshd_config.bak
    if [[ -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; then
        if $DRYRUN; then
            echo "  [dry-run] Would remove: /etc/ssh/sshd_config.d/99-hardening.conf"
        else
            rm /etc/ssh/sshd_config.d/99-hardening.conf
            printf "  ${GREEN}[OK]${RESET} Removed: /etc/ssh/sshd_config.d/99-hardening.conf\n"
        fi
    fi
    reload_ssh
    echo ""
fi

# --- Script 02: Apache ---
if [[ "$TARGET" == "02" || "$TARGET" == "all" ]]; then
    echo "[ Script 02 — Apache config ]"
    restore_file /etc/apache2/conf-available/security.conf.bak
    restore_file /etc/apache2/conf-available/security-headers.conf.bak
    reload_apache
    echo ""
fi

# --- Script 04: msmtp ---
if [[ "$TARGET" == "04" || "$TARGET" == "all" ]]; then
    echo "[ Script 04 — msmtp config ]"
    restore_file /etc/msmtprc.bak
    echo ""
fi

# --- Script 05: Logwatch ---
if [[ "$TARGET" == "05" || "$TARGET" == "all" ]]; then
    echo "[ Script 05 — Logwatch config ]"
    restore_file /etc/logwatch/conf/logwatch.conf.bak
    echo ""
fi

# --- Summary ---
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
    echo "  ${restored} file(s) would be restored"
else
    printf "  Restored: %d  Skipped: %d  Errors: %d\n" "$restored" "$skipped" "$errors"
    if [[ "$errors" -gt 0 ]]; then
        printf "  ${RED}Errors occurred — review output above.${RESET}\n"
    fi
fi
echo "========================================="

[[ "$errors" -eq 0 ]]
