#!/usr/bin/env bash
# verify.sh — post-run artifact and state checker
#
# Confirms that each hardening script's specific changes took effect.
# Organized per-script, so you can see exactly which script's work succeeded.
# Read-only — makes no changes.
#
# Distinct from audit.sh, which checks overall security posture by category.
# verify.sh checks: "did the scripts do what they said they did?"
#
# Usage:
#   bash scripts/audit/verify.sh
#   bash scripts/audit/verify.sh --brief   (only show failures and warnings)
#
# Exit codes:
#   0 — all checks pass
#   1 — one or more failures
set -uo pipefail

# --- Args ---
BRIEF=false
for arg in "$@"; do [[ "$arg" == "--brief" ]] && BRIEF=true; done

# --- Config discovery ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    for loc in \
        "$SCRIPT_DIR/../../config.env" \
        "$SCRIPT_DIR/../config.env" \
        /etc/vps-security/config.env; do
        if [[ -f "$loc" ]]; then CONFIG_FILE="$loc"; break; fi
    done
fi
if [[ -n "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

SSH_PORT="${SSH_PORT:-22}"
ADMIN_USER="${ADMIN_USER:-}"

# --- Output ---
PASS=0; FAIL=0; WARN=0; SKIP=0
RESULTS=()

if [[ -t 1 ]]; then
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" DIM="\033[2m" RESET="\033[0m"
else
    GREEN="" YELLOW="" RED="" DIM="" RESET=""
fi

check() {
    local status="$1" name="$2" detail="${3:-}"
    RESULTS+=("${status}|${name}|${detail}")
    case "$status" in
        PASS) ((PASS++)) ;;
        FAIL) ((FAIL++)) ;;
        WARN) ((WARN++)) ;;
        SKIP) ((SKIP++)) ;;
    esac

    if $BRIEF && [[ "$status" == "PASS" ]]; then return; fi

    case "$status" in
        PASS) printf "  ${GREEN}[PASS]${RESET} %s\n" "$name" ;;
        FAIL) printf "  ${RED}[FAIL]${RESET} %s" "$name"
              [[ -n "$detail" ]] && printf " — %s" "$detail"
              printf "\n" ;;
        WARN) printf "  ${YELLOW}[WARN]${RESET} %s" "$name"
              [[ -n "$detail" ]] && printf " — %s" "$detail"
              printf "\n" ;;
        SKIP) $BRIEF || printf "  ${DIM}[SKIP]${RESET} %s — %s\n" "$name" "$detail" ;;
    esac
}

section() {
    echo ""
    echo "[ $1 ]"
}

# ============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "WARNING: Some checks require root. Run as root for full results." >&2
fi

echo "========================================="
echo "  vps-security Post-Run Verification"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="

# ============================================================================
# Script 01 — Firewall, fail2ban, SSH, sysctl
# ============================================================================
section "Script 01 — Firewall / fail2ban / SSH / sysctl"

# fail2ban installed and running
if command -v fail2ban-client &>/dev/null; then
    check PASS "fail2ban installed"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        check PASS "fail2ban service running"
    else
        check FAIL "fail2ban service running" "systemctl reports fail2ban not active"
    fi

    if [[ -f /etc/fail2ban/jail.local ]]; then
        check PASS "/etc/fail2ban/jail.local exists"
        for jail in apache-auth apache-badbots apache-noscript; do
            if grep -q "^\[${jail}\]" /etc/fail2ban/jail.local; then
                check PASS "jail.local has [${jail}]"
            else
                check FAIL "jail.local has [${jail}]" "Re-run 01-immediate-hardening.sh"
            fi
        done
    else
        check FAIL "/etc/fail2ban/jail.local exists" "File not found — script 01 may not have run"
    fi
else
    check FAIL "fail2ban installed" "Not found — run 01-immediate-hardening.sh"
fi

# UFW
if command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        check PASS "UFW active"
        if ufw status | grep -q "^${SSH_PORT}/tcp"; then
            check PASS "UFW rule: SSH port ${SSH_PORT}/tcp"
        else
            check FAIL "UFW rule: SSH port ${SSH_PORT}/tcp" "Rule not found"
        fi
        if ufw status | grep -q "^80/tcp"; then
            check PASS "UFW rule: 80/tcp (HTTP)"
        else
            check WARN "UFW rule: 80/tcp (HTTP)" "Not present — intentional?"
        fi
        if ufw status | grep -q "^443/tcp"; then
            check PASS "UFW rule: 443/tcp (HTTPS)"
        else
            check WARN "UFW rule: 443/tcp (HTTPS)" "Not present — intentional?"
        fi
    else
        check FAIL "UFW active" "UFW not active — run 01-immediate-hardening.sh"
    fi
else
    check FAIL "UFW installed" "ufw command not found"
fi

# SSH config
if [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]]; then
    if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config.d/50-cloud-init.conf; then
        check PASS "/etc/ssh/sshd_config.d/50-cloud-init.conf: PasswordAuthentication no"
    else
        check FAIL "/etc/ssh/sshd_config.d/50-cloud-init.conf: PasswordAuthentication no" "Value not set"
    fi
else
    check FAIL "/etc/ssh/sshd_config.d/50-cloud-init.conf exists" "File not found — script 01 may not have run"
fi

if [[ -f /etc/sysctl.d/99-hardening.conf ]]; then
    check PASS "/etc/sysctl.d/99-hardening.conf exists"
    if sysctl net.ipv4.conf.all.accept_redirects 2>/dev/null | grep -q "= 0"; then
        check PASS "sysctl: ICMP redirects disabled"
    else
        check WARN "sysctl: ICMP redirects disabled" "Value not applied — try: sysctl --system"
    fi
    if sysctl net.ipv4.conf.all.log_martians 2>/dev/null | grep -q "= 1"; then
        check PASS "sysctl: martian logging enabled"
    else
        check WARN "sysctl: martian logging enabled" "Value not applied — try: sysctl --system"
    fi
else
    check FAIL "/etc/sysctl.d/99-hardening.conf exists" "File not found — script 01 may not have run"
fi

# ============================================================================
# Script 02 — Apache hardening
# ============================================================================
section "Script 02 — Apache security headers"

if command -v apache2 &>/dev/null && systemctl is-active --quiet apache2 2>/dev/null; then
    check PASS "Apache running"

    if apache2ctl -M 2>/dev/null | grep -q "headers_module"; then
        check PASS "mod_headers loaded"
    else
        check FAIL "mod_headers loaded" "Run: a2enmod headers && systemctl reload apache2"
    fi

    SECCONF="/etc/apache2/conf-enabled/security.conf"
    if [[ -f "$SECCONF" ]]; then
        check PASS "$SECCONF exists"
        if grep -q "ServerTokens Prod" "$SECCONF"; then
            check PASS "security.conf: ServerTokens Prod"
        else
            check FAIL "security.conf: ServerTokens Prod" "Not found in $SECCONF"
        fi
        if grep -q "Strict-Transport-Security" "$SECCONF"; then
            check PASS "security.conf: HSTS header set"
        else
            check FAIL "security.conf: HSTS header set" "Not found in $SECCONF"
        fi
        if grep -q "Content-Security-Policy" "$SECCONF"; then
            check PASS "security.conf: CSP header set"
        else
            check FAIL "security.conf: CSP header set" "Not found in $SECCONF"
        fi
        if grep -q 'RedirectMatch 404 /\\\.git' "$SECCONF"; then
            check PASS "security.conf: .git access blocked"
        else
            check WARN "security.conf: .git access blocked" "RedirectMatch rule not found"
        fi
    else
        check FAIL "$SECCONF exists" "File not found — run 02-apache-hardening.sh"
    fi

    if apache2ctl -M 2>/dev/null | grep -q "status_module"; then
        check FAIL "mod_status disabled" "status_module is still loaded"
    else
        check PASS "mod_status disabled"
    fi
else
    check SKIP "Script 02 checks" "Apache not running or not installed"
fi

# ============================================================================
# Script 03 — Admin user
# ============================================================================
section "Script 03 — Admin user"

if [[ -z "$ADMIN_USER" ]]; then
    check SKIP "Script 03 checks" "ADMIN_USER not set in config.env"
elif ! id "$ADMIN_USER" &>/dev/null; then
    check FAIL "User '$ADMIN_USER' exists" "User not found on system"
else
    check PASS "User '$ADMIN_USER' exists"

    shell=$(getent passwd "$ADMIN_USER" | cut -d: -f7)
    if [[ "$shell" == "/bin/bash" ]]; then
        check PASS "$ADMIN_USER shell: /bin/bash"
    else
        check FAIL "$ADMIN_USER shell: /bin/bash" "Current shell: ${shell:-unknown}"
    fi

    if groups "$ADMIN_USER" 2>/dev/null | grep -qw sudo; then
        check PASS "$ADMIN_USER in sudo group"
    else
        check FAIL "$ADMIN_USER in sudo group" "Not in sudo group"
    fi

    HOMEDIR=$(eval echo "~$ADMIN_USER")
    if [[ -f "$HOMEDIR/.ssh/authorized_keys" ]] && [[ -s "$HOMEDIR/.ssh/authorized_keys" ]]; then
        check PASS "$ADMIN_USER has SSH authorized_keys"
    else
        check WARN "$ADMIN_USER has SSH authorized_keys" "File missing or empty — add SSH keys manually"
    fi

    if [[ -f /etc/sudoers.d/90-cloud-init-users ]]; then
        check WARN "cloud-init NOPASSWD sudoers removed" "File still present — run 03-setup-admin-user.sh or remove manually"
    else
        check PASS "cloud-init NOPASSWD sudoers removed"
    fi
fi

# ============================================================================
# Script 04 — Monthly updates
# ============================================================================
section "Script 04 — Monthly updates"

if command -v msmtp &>/dev/null; then
    check PASS "msmtp installed"
else
    check FAIL "msmtp installed" "Not found — run 04-monthly-updates-setup.sh"
fi

if [[ -f /etc/msmtprc ]]; then
    check PASS "/etc/msmtprc exists"
else
    check FAIL "/etc/msmtprc exists" "File not found — run 04-monthly-updates-setup.sh"
fi

if [[ -x /usr/local/sbin/monthly-apt-report.sh ]]; then
    check PASS "/usr/local/sbin/monthly-apt-report.sh exists and is executable"
else
    check FAIL "/usr/local/sbin/monthly-apt-report.sh exists and is executable" "Run 04-monthly-updates-setup.sh"
fi

if crontab -l 2>/dev/null | grep -q "monthly-apt-report"; then
    check PASS "Monthly update cron job present"
else
    check FAIL "Monthly update cron job present" "Not found in root crontab — run 04-monthly-updates-setup.sh"
fi

# ============================================================================
# Script 05 — Log monitoring
# ============================================================================
section "Script 05 — Log monitoring"

if command -v logwatch &>/dev/null; then
    check PASS "logwatch installed"
else
    check FAIL "logwatch installed" "Not found — run 05-log-monitoring-setup.sh"
fi

if [[ -f /etc/logwatch/conf/logwatch.conf ]]; then
    check PASS "/etc/logwatch/conf/logwatch.conf exists"
else
    check FAIL "/etc/logwatch/conf/logwatch.conf exists" "Run 05-log-monitoring-setup.sh"
fi

if command -v goaccess &>/dev/null; then
    check PASS "goaccess installed"
else
    check FAIL "goaccess installed" "Not found — run 05-log-monitoring-setup.sh"
fi

if [[ -x /usr/local/sbin/goaccess-daily-report.sh ]]; then
    check PASS "/usr/local/sbin/goaccess-daily-report.sh exists and is executable"
else
    check FAIL "/usr/local/sbin/goaccess-daily-report.sh exists and is executable" "Run 05-log-monitoring-setup.sh"
fi

if crontab -l 2>/dev/null | grep -q "goaccess-daily-report"; then
    check PASS "GoAccess daily cron job present"
else
    check FAIL "GoAccess daily cron job present" "Not found in root crontab — run 05-log-monitoring-setup.sh"
fi

if [[ -f /var/www/html/reports/.htaccess ]]; then
    check PASS "Reports directory protected (.htaccess exists)"
else
    check WARN "Reports directory protected (.htaccess exists)" "Run 05-log-monitoring-setup.sh"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================="
printf "  ${GREEN}PASS: %-3d${RESET}  ${RED}FAIL: %-3d${RESET}  ${YELLOW}WARN: %-3d${RESET}  ${DIM}SKIP: %d${RESET}\n" \
    "$PASS" "$FAIL" "$WARN" "$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "  Re-run the relevant hardening scripts to"
    echo "  resolve failures, then run verify.sh again."
fi
echo "========================================="

[[ "$FAIL" -eq 0 ]]
