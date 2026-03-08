#!/usr/bin/env bash
# audit.sh — vps-security baseline checker
#
# Read-only. Checks all security controls against the baseline in docs/security/README.md.
# Exits 0 if all checks pass, 1 if any fail.
#
# Usage:
#   bash scripts/audit/audit.sh
#   bash scripts/audit/audit.sh --json    (machine-readable output)
set -uo pipefail

# --- Args ---
JSON=false
for arg in "$@"; do [[ "$arg" == "--json" ]] && JSON=true; done

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

# --- Output helpers ---
PASS=0
FAIL=0
WARN=0
RESULTS=()

check() {
    local name="$1" status="$2" detail="$3"
    RESULTS+=("${status}|${name}|${detail}")
    case "$status" in
        PASS) ((PASS++)) ;;
        FAIL) ((FAIL++)) ;;
        WARN) ((WARN++)) ;;
    esac
}

# Colors (disabled if not a terminal or JSON mode)
if $JSON || [[ ! -t 1 ]]; then
    GREEN="" YELLOW="" RED="" RESET=""
else
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" RESET="\033[0m"
fi

print_result() {
    local status="$1" name="$2" detail="$3"
    case "$status" in
        PASS) printf "${GREEN}  [PASS]${RESET} %s\n" "$name" ;;
        WARN) printf "${YELLOW}  [WARN]${RESET} %s — %s\n" "$name" "$detail" ;;
        FAIL) printf "${RED}  [FAIL]${RESET} %s — %s\n" "$name" "$detail" ;;
    esac
}

# ============================================================================
# CHECKS
# ============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "WARNING: Some checks require root. Run as root for full results." >&2
fi

# --- UFW ---
echo ""
echo "[ Firewall ]"

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    check "UFW active" "PASS" ""

    if ufw status | grep -q "^${SSH_PORT}/tcp.*ALLOW"; then
        check "UFW allows SSH (port ${SSH_PORT})" "PASS" ""
    else
        check "UFW allows SSH (port ${SSH_PORT})" "FAIL" "Port ${SSH_PORT}/tcp not found in UFW rules"
    fi

    if ufw status | grep -q "^80/tcp.*ALLOW"; then
        check "UFW allows HTTP (80)" "PASS" ""
    else
        check "UFW allows HTTP (80)" "WARN" "Port 80/tcp not in UFW rules — intended?"
    fi

    if ufw status | grep -q "^443/tcp.*ALLOW"; then
        check "UFW allows HTTPS (443)" "PASS" ""
    else
        check "UFW allows HTTPS (443)" "WARN" "Port 443/tcp not in UFW rules — intended?"
    fi
else
    check "UFW active" "FAIL" "UFW is not installed or not active"
fi

# --- SSH ---
echo ""
echo "[ SSH ]"

if command -v sshd &>/dev/null; then
    SSHD_T=$(sshd -T 2>/dev/null || true)

    pw_auth=$(echo "$SSHD_T" | grep "^passwordauthentication " | awk '{print $2}')
    if [[ "$pw_auth" == "no" ]]; then
        check "SSH PasswordAuthentication no" "PASS" ""
    else
        check "SSH PasswordAuthentication no" "FAIL" "Currently: ${pw_auth:-unknown}"
    fi

    root_login=$(echo "$SSHD_T" | grep "^permitrootlogin " | awk '{print $2}')
    if [[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]]; then
        check "SSH PermitRootLogin restricted" "PASS" "(${root_login})"
    else
        check "SSH PermitRootLogin restricted" "FAIL" "Currently: ${root_login:-unknown}"
    fi

    x11=$(echo "$SSHD_T" | grep "^x11forwarding " | awk '{print $2}')
    if [[ "$x11" == "no" ]]; then
        check "SSH X11Forwarding no" "PASS" ""
    else
        check "SSH X11Forwarding no" "WARN" "X11 forwarding is enabled (unnecessary on headless server)"
    fi
else
    check "SSH daemon" "WARN" "sshd not found or not accessible"
fi

# --- fail2ban ---
echo ""
echo "[ fail2ban ]"

if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
    check "fail2ban running" "PASS" ""

    if fail2ban-client status sshd &>/dev/null; then
        check "fail2ban SSH jail active" "PASS" ""
    else
        check "fail2ban SSH jail active" "FAIL" "sshd jail not found or not active"
    fi

    for jail in apache-auth apache-badbots apache-noscript; do
        if fail2ban-client status "$jail" &>/dev/null; then
            check "fail2ban ${jail} jail" "PASS" ""
        else
            check "fail2ban ${jail} jail" "WARN" "Jail not active — run 01-immediate-hardening.sh to add Apache jails"
        fi
    done
else
    check "fail2ban running" "FAIL" "fail2ban is not installed or not active"
fi

# --- Apache ---
echo ""
echo "[ Apache ]"

if command -v apache2 &>/dev/null && systemctl is-active --quiet apache2 2>/dev/null; then
    check "Apache running" "PASS" ""

    # Check headers via curl (localhost)
    if command -v curl &>/dev/null; then
        HEADERS=$(curl -sk -o /dev/null -D - http://localhost/ 2>/dev/null || true)

        server_hdr=$(echo "$HEADERS" | grep -i "^server:" | tr -d '\r')
        if echo "$server_hdr" | grep -q "Apache$"; then
            check "ServerTokens Prod (no version in Server header)" "PASS" ""
        else
            check "ServerTokens Prod (no version in Server header)" "WARN" "Server header: ${server_hdr:-not found}"
        fi

        for hdr in "strict-transport-security" "x-content-type-options" "referrer-policy" "content-security-policy"; do
            if echo "$HEADERS" | grep -qi "^${hdr}:"; then
                check "Apache header: ${hdr}" "PASS" ""
            else
                check "Apache header: ${hdr}" "FAIL" "Missing — run 02-apache-hardening.sh"
            fi
        done
    else
        check "Apache headers" "WARN" "curl not available — skipping header checks"
    fi

    # mod_status
    if apache2ctl -M 2>/dev/null | grep -q "status_module"; then
        check "mod_status disabled" "FAIL" "status_module is loaded — disable or restrict to localhost"
    else
        check "mod_status disabled" "PASS" ""
    fi
else
    check "Apache running" "WARN" "Apache not active or not installed"
fi

# --- Updates ---
echo ""
echo "[ System Updates ]"

if command -v apt &>/dev/null; then
    apt-get update -qq 2>/dev/null || true
    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c "\[upgradable" || true)
    if [[ "$UPGRADABLE" -eq 0 ]]; then
        check "No pending updates" "PASS" ""
    elif [[ "$UPGRADABLE" -lt 10 ]]; then
        check "Pending updates" "WARN" "${UPGRADABLE} packages upgradable"
    else
        check "Pending updates" "FAIL" "${UPGRADABLE} packages upgradable — run apt upgrade"
    fi

    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        check "unattended-upgrades active" "PASS" ""
    else
        check "unattended-upgrades active" "WARN" "Not active — automatic security updates may not be running"
    fi
fi

# --- Certificates ---
echo ""
echo "[ TLS Certificates ]"

if command -v certbot &>/dev/null; then
    CERT_OUTPUT=$(certbot certificates 2>/dev/null || true)
    EXPIRING=$(echo "$CERT_OUTPUT" | grep "VALID:" | grep -E "VALID: [0-9] days|VALID: [12][0-9] days" || true)
    EXPIRED=$(echo "$CERT_OUTPUT" | grep "INVALID\|EXPIRED" || true)

    if [[ -n "$EXPIRED" ]]; then
        check "TLS certificates valid" "FAIL" "Expired certificates found — renew immediately"
    elif [[ -n "$EXPIRING" ]]; then
        check "TLS certificates valid" "WARN" "Certs expiring within 30 days — verify auto-renewal"
    else
        check "TLS certificates valid" "PASS" ""
    fi
else
    check "TLS certificates" "WARN" "certbot not found — cannot check cert expiry"
fi

# ============================================================================
# OUTPUT
# ============================================================================

if $JSON; then
    echo "{"
    echo "  \"host\": \"$(hostname -f)\","
    echo "  \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"summary\": {\"pass\": $PASS, \"warn\": $WARN, \"fail\": $FAIL},"
    echo "  \"checks\": ["
    local_sep=""
    for result in "${RESULTS[@]}"; do
        IFS='|' read -r s n d <<< "$result"
        printf '%s    {"status": "%s", "name": "%s", "detail": "%s"}' "$local_sep" "$s" "$n" "$d"
        local_sep=$'\n'
    done
    echo ""
    echo "  ]"
    echo "}"
else
    echo ""
    echo "========================================="
    echo "  Audit Summary — $(hostname -f)"
    echo "  $(date '+%Y-%m-%d %H:%M %Z')"
    echo ""
    for result in "${RESULTS[@]}"; do
        IFS='|' read -r s n d <<< "$result"
        print_result "$s" "$n" "$d"
    done
    echo ""
    printf "  ${GREEN}PASS: %d${RESET}  ${YELLOW}WARN: %d${RESET}  ${RED}FAIL: %d${RESET}\n" "$PASS" "$WARN" "$FAIL"
    echo "========================================="
fi

[[ "$FAIL" -eq 0 ]]
