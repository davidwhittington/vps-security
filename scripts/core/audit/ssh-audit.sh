#!/usr/bin/env bash
# ssh-audit.sh — SSH daemon configuration checker
#
# Inspects the live sshd configuration via 'sshd -T' and checks all key
# hardening parameters against expected values. Also flags weak ciphers,
# MACs, and key exchange algorithms if present.
# Read-only. Exits 1 if any required value is wrong.
#
# Usage:
#   bash scripts/core/audit/ssh-audit.sh
set -uo pipefail

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

SSH_PORT="${SSH_PORT:-22}"

# --- Output ---
if [[ -t 1 ]]; then
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" RESET="\033[0m"
else
    GREEN="" YELLOW="" RED="" RESET=""
fi

FAIL=0; WARN=0; PASS=0

check() {
    local status="$1" label="$2" detail="${3:-}"
    case "$status" in
        PASS) ((PASS++)); printf "  ${GREEN}[PASS]${RESET} %s\n" "$label" ;;
        FAIL) ((FAIL++)); printf "  ${RED}[FAIL]${RESET} %s — %s\n" "$label" "$detail" ;;
        WARN) ((WARN++)); printf "  ${YELLOW}[WARN]${RESET} %s — %s\n" "$label" "$detail" ;;
    esac
}

echo "========================================="
echo "  SSH Configuration Audit"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

if ! command -v sshd &>/dev/null; then
    echo "ERROR: sshd not found." >&2
    exit 1
fi

SSHD_T=$(sshd -T 2>/dev/null)

if [[ -z "$SSHD_T" ]]; then
    echo "ERROR: Could not read sshd configuration (try running as root)." >&2
    exit 1
fi

# --- Auth ---
echo "[ Authentication ]"

val=$(echo "$SSHD_T" | grep "^passwordauthentication " | awk '{print $2}')
[[ "$val" == "no" ]] && check PASS "PasswordAuthentication no" || check FAIL "PasswordAuthentication no" "Currently: ${val:-unset}"

val=$(echo "$SSHD_T" | grep "^permitrootlogin " | awk '{print $2}')
[[ "$val" == "no" || "$val" == "prohibit-password" ]] \
    && check PASS "PermitRootLogin: ${val}" \
    || check FAIL "PermitRootLogin restricted" "Currently: ${val:-unset}"

val=$(echo "$SSHD_T" | grep "^pubkeyauthentication " | awk '{print $2}')
[[ "$val" == "yes" ]] && check PASS "PubkeyAuthentication yes" || check WARN "PubkeyAuthentication yes" "Currently: ${val:-unset}"

val=$(echo "$SSHD_T" | grep "^permitemptypasswords " | awk '{print $2}')
[[ "$val" == "no" ]] && check PASS "PermitEmptyPasswords no" || check FAIL "PermitEmptyPasswords no" "Currently: ${val:-unset}"

# --- Port ---
echo ""
echo "[ Port ]"
val=$(echo "$SSHD_T" | grep "^port " | awk '{print $2}')
[[ "$val" == "$SSH_PORT" ]] \
    && check PASS "Port matches config (${SSH_PORT})" \
    || check WARN "Port mismatch" "sshd reports ${val:-unknown}, config.env SSH_PORT=${SSH_PORT}"

# --- Forwarding ---
echo ""
echo "[ Forwarding ]"

val=$(echo "$SSHD_T" | grep "^x11forwarding " | awk '{print $2}')
[[ "$val" == "no" ]] && check PASS "X11Forwarding no" || check WARN "X11Forwarding no" "Currently: ${val:-unset}"

val=$(echo "$SSHD_T" | grep "^allowtcpforwarding " | awk '{print $2}')
[[ "$val" == "no" ]] && check PASS "AllowTcpForwarding no" || check WARN "AllowTcpForwarding no" "Currently: ${val:-unset} (consider disabling on web-only servers)"

val=$(echo "$SSHD_T" | grep "^agentforwarding " | awk '{print $2}')
[[ "$val" == "no" ]] && check PASS "AllowAgentForwarding no" || check WARN "AllowAgentForwarding no" "Currently: ${val:-unset}"

# --- Timeouts ---
echo ""
echo "[ Timeouts ]"

val=$(echo "$SSHD_T" | grep "^logingracetime " | awk '{print $2}')
if [[ -n "$val" ]] && [[ "$val" -le 60 ]]; then
    check PASS "LoginGraceTime: ${val}s"
else
    check WARN "LoginGraceTime" "Currently ${val:-unset} — recommend 30-60s"
fi

val=$(echo "$SSHD_T" | grep "^maxauthtries " | awk '{print $2}')
if [[ -n "$val" ]] && [[ "$val" -le 4 ]]; then
    check PASS "MaxAuthTries: ${val}"
else
    check WARN "MaxAuthTries" "Currently ${val:-unset} — recommend 3-4"
fi

# --- Ciphers / MACs / KEx ---
echo ""
echo "[ Ciphers / MACs / KexAlgorithms ]"

WEAK_CIPHERS="3des-cbc aes128-cbc aes192-cbc aes256-cbc arcfour blowfish-cbc cast128-cbc"
WEAK_MACS="hmac-md5 hmac-md5-96 hmac-sha1-96 umac-64 hmac-ripemd160"
WEAK_KEX="diffie-hellman-group1-sha1 diffie-hellman-group14-sha1 diffie-hellman-group-exchange-sha1"

ciphers=$(echo "$SSHD_T" | grep "^ciphers " | sed 's/^ciphers //')
macs=$(echo "$SSHD_T" | grep "^macs " | sed 's/^macs //')
kex=$(echo "$SSHD_T" | grep "^kexalgorithms " | sed 's/^kexalgorithms //')

cipher_weak=()
for wc in $WEAK_CIPHERS; do
    echo "$ciphers" | grep -q "$wc" && cipher_weak+=("$wc")
done
if [[ "${#cipher_weak[@]}" -eq 0 ]]; then
    check PASS "No weak ciphers detected"
else
    check WARN "Weak ciphers present" "${cipher_weak[*]}"
fi

mac_weak=()
for wm in $WEAK_MACS; do
    echo "$macs" | grep -q "$wm" && mac_weak+=("$wm")
done
if [[ "${#mac_weak[@]}" -eq 0 ]]; then
    check PASS "No weak MACs detected"
else
    check WARN "Weak MACs present" "${mac_weak[*]}"
fi

kex_weak=()
for wk in $WEAK_KEX; do
    echo "$kex" | grep -q "$wk" && kex_weak+=("$wk")
done
if [[ "${#kex_weak[@]}" -eq 0 ]]; then
    check PASS "No weak KexAlgorithms detected"
else
    check WARN "Weak KexAlgorithms present" "${kex_weak[*]}"
fi

# --- Summary ---
echo ""
echo "========================================="
printf "  ${GREEN}PASS: %d${RESET}  ${YELLOW}WARN: %d${RESET}  ${RED}FAIL: %d${RESET}\n" "$PASS" "$WARN" "$FAIL"
if [[ "$WARN" -gt 0 ]]; then
    echo ""
    echo "  Run 01-immediate-hardening.sh or issue #19 (cipher hardening)"
    echo "  to address warnings."
fi
echo "========================================="

[[ "$FAIL" -eq 0 ]]
