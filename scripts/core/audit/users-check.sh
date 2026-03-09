#!/usr/bin/env bash
# users-check.sh — privileged user and login shell audit
#
# Lists all users with login shells, checks for unexpected UID-0 accounts,
# NOPASSWD sudoers rules, and accounts with empty passwords.
# Read-only. Exits 1 if unexpected privileged accounts or NOPASSWD rules found.
#
# Usage:
#   bash scripts/core/audit/users-check.sh
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"

banner "Privileged User Audit"

if [[ $EUID -ne 0 ]]; then
    echo "  NOTE: Run as root for full results (shadow file checks require root)."
    echo ""
fi

# --- UID 0 accounts ---
section_header "UID 0 Accounts (root-equivalent)"
UID0_USERS=$(awk -F: '$3 == 0 {print $1}' /etc/passwd)
UID0_COUNT=$(echo "$UID0_USERS" | grep -c . || true)

if [[ "$UID0_COUNT" -eq 1 ]] && echo "$UID0_USERS" | grep -q "^root$"; then
    check_pass "Only root has UID 0"
else
    for u in $UID0_USERS; do
        if [[ "$u" != "root" ]]; then
            check_fail "Unexpected UID-0 account: ${u}" "Non-root account with UID 0 is a critical security risk"
        else
            check_pass "root UID 0 (expected)"
        fi
    done
fi

# --- Login shell users ---
section_header "Users with Login Shells"
SHELL_USERS=$(awk -F: '$7 !~ /nologin|false|sync/ && $7 != "" {print $1 " (" $7 ")"}' /etc/passwd)
echo "$SHELL_USERS" | sed 's/^/  /'
echo ""

# --- sudo group members ---
section_header "Sudo Group Members"
if getent group sudo &>/dev/null; then
    SUDO_MEMBERS=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^$' || true)
    if [[ -n "$SUDO_MEMBERS" ]]; then
        echo "$SUDO_MEMBERS" | sed 's/^/  /'
    else
        check_pass "No users in sudo group (root-only access)"
    fi
else
    echo "  sudo group not found"
fi
echo ""

# --- sudoers NOPASSWD check ---
section_header "NOPASSWD Sudoers Rules"
NOPASSWD_RULES=""

if [[ -f /etc/sudoers ]] && grep -q "NOPASSWD" /etc/sudoers 2>/dev/null; then
    NOPASSWD_RULES+=$(grep "NOPASSWD" /etc/sudoers | grep -v "^#" || true)
fi

if [[ -d /etc/sudoers.d ]]; then
    while IFS= read -r -d '' f; do
        if grep -q "NOPASSWD" "$f" 2>/dev/null; then
            NOPASSWD_RULES+=$(grep "NOPASSWD" "$f" | grep -v "^#" || true)
        fi
    done < <(find /etc/sudoers.d -type f -print0 2>/dev/null)
fi

if [[ -n "$NOPASSWD_RULES" ]]; then
    check_fail "NOPASSWD sudoers rules found" "Passwordless sudo is a privilege escalation risk"
    echo "$NOPASSWD_RULES" | sed 's/^/    /'
    echo ""
    check_info "Review and remove NOPASSWD entries unless explicitly required (e.g., automation users)"
else
    check_pass "No NOPASSWD sudoers rules"
fi

# --- Empty passwords ---
section_header "Empty Passwords"
if [[ $EUID -eq 0 ]] && [[ -f /etc/shadow ]]; then
    EMPTY_PW=$(awk -F: '$2 == "" {print $1}' /etc/shadow || true)
    if [[ -n "$EMPTY_PW" ]]; then
        check_fail "Accounts with empty passwords" "These accounts can be accessed without a password"
        echo "$EMPTY_PW" | sed 's/^/    /'
    else
        check_pass "No accounts with empty passwords"
    fi
else
    echo "  Skipped (requires root)"
fi

# --- Locked accounts with active SSH keys ---
section_header "Locked Accounts with Authorized Keys"
if [[ $EUID -eq 0 ]]; then
    while IFS=: read -r username _ uid _ _ homedir _; do
        if [[ "$uid" -ge 1000 ]] && [[ -f "${homedir}/.ssh/authorized_keys" ]]; then
            pw_status=$(passwd -S "$username" 2>/dev/null | awk '{print $2}' || true)
            if [[ "$pw_status" == "L" ]]; then
                check_fail "Locked account with SSH keys: ${username}" \
                    "Account is locked but has authorized_keys — can still SSH in"
            fi
        fi
    done < /etc/passwd
    if [[ "$FAIL" -eq 0 ]]; then
        check_pass "No locked accounts with active SSH authorized_keys"
    fi
else
    echo "  Skipped (requires root)"
fi

summary "User audit complete."
[[ "$FAIL" -eq 0 ]]
