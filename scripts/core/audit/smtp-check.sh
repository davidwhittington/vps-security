#!/usr/bin/env bash
# smtp-check.sh — SMTP relay health check
#
# Verifies msmtp is installed and configured, checks the msmtp log for
# recent errors, tests TCP connectivity to the configured SMTP server,
# and optionally sends a test email with --send.
# Read-only by default. Exits 1 if relay is not reachable or misconfigured.
#
# Usage:
#   bash scripts/core/audit/smtp-check.sh
#   bash scripts/core/audit/smtp-check.sh --send        # send a test email
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"

SEND=false
for arg in "$@"; do [[ "$arg" == "--send" ]] && SEND=true; done

# --- Config discovery ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    for loc in \
        "$SCRIPT_DIR/../../../config.env" \
        "$SCRIPT_DIR/../../config.env" \
        /etc/linux-security/config.env; do
        if [[ -f "$loc" ]]; then CONFIG_FILE="$loc"; break; fi
    done
fi
if [[ -n "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"

banner "SMTP Relay Health Check"

# --- msmtp installed ---
section_header "Installation"
if command -v msmtp &>/dev/null; then
    MSMTP_VER=$(msmtp --version 2>/dev/null | head -1 || true)
    check_pass "msmtp installed (${MSMTP_VER})"
else
    check_fail "msmtp installed" "msmtp not found — run 04-monthly-updates-setup.sh"
    summary "msmtp is not installed."
    exit 1
fi

# --- Config file ---
section_header "Configuration"
MSMTP_CONF=""
for f in /etc/msmtprc /root/.msmtprc /etc/msmtp/msmtprc; do
    [[ -f "$f" ]] && { MSMTP_CONF="$f"; break; }
done

if [[ -n "$MSMTP_CONF" ]]; then
    check_pass "msmtp config: ${MSMTP_CONF}"
    # Show non-sensitive config lines
    echo ""
    echo "  Config (passwords redacted):"
    grep -v -i "password\|pass " "$MSMTP_CONF" 2>/dev/null | sed 's/^/    /' || true
    echo ""
else
    check_fail "msmtp config" "No config file found at /etc/msmtprc or /root/.msmtprc"
fi

# --- SMTP connectivity ---
section_header "Connectivity"
if [[ -n "$SMTP_HOST" ]]; then
    echo "  Testing ${SMTP_HOST}:${SMTP_PORT}..."
    if timeout 10 bash -c "echo >/dev/tcp/${SMTP_HOST}/${SMTP_PORT}" 2>/dev/null; then
        check_pass "TCP reachable: ${SMTP_HOST}:${SMTP_PORT}"
    else
        check_fail "TCP connection to ${SMTP_HOST}:${SMTP_PORT}" \
            "Cannot connect — check SMTP_HOST/SMTP_PORT in config.env and firewall rules"
    fi
else
    check_fail "SMTP_HOST not configured" "Set SMTP_HOST in config.env and re-run 04-monthly-updates-setup.sh"
fi

# --- Recent log errors ---
section_header "Recent Log Errors"
MSMTP_LOG="/var/log/msmtp.log"
if [[ -f "$MSMTP_LOG" ]]; then
    RECENT_ERRORS=$(tail -100 "$MSMTP_LOG" 2>/dev/null | grep -i "error\|failed\|refused" | tail -5 || true)
    if [[ -n "$RECENT_ERRORS" ]]; then
        check_fail "Recent msmtp errors in log" "Check ${MSMTP_LOG}"
        echo "$RECENT_ERRORS" | sed 's/^/    /'
        echo ""
    else
        LAST_LINE=$(tail -1 "$MSMTP_LOG" 2>/dev/null || true)
        check_pass "No recent errors in ${MSMTP_LOG}"
        [[ -n "$LAST_LINE" ]] && check_info "Last log entry: ${LAST_LINE}"
    fi
else
    echo "  No log file at ${MSMTP_LOG} (no emails sent yet, or logging disabled)"
fi

# --- Test send ---
if $SEND; then
    section_header "Test Email"
    if [[ -z "$ADMIN_EMAIL" ]]; then
        check_fail "Test send" "ADMIN_EMAIL not set in config.env"
    else
        echo "  Sending test email to ${ADMIN_EMAIL}..."
        if echo "vps-security smtp-check.sh test — $(date)" \
            | mail -s "[$(hostname -f)] SMTP test" "$ADMIN_EMAIL" 2>/dev/null; then
            check_pass "Test email sent to ${ADMIN_EMAIL}"
        else
            check_fail "Test email send failed" "Check msmtp config and credentials"
        fi
    fi
fi

summary "SMTP health check complete."
[[ "$FAIL" -eq 0 ]]
