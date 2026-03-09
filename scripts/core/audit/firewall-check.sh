#!/usr/bin/env bash
# firewall-check.sh — UFW rules validator
#
# Verifies UFW is active, default policies are deny-incoming/allow-outgoing,
# required ports are open (SSH, HTTP, HTTPS), and rate limiting is applied.
# Read-only. Exits 1 if any FAIL.
#
# Usage:
#   bash scripts/core/audit/firewall-check.sh
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"

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

banner "UFW Firewall Check"

if [[ $EUID -ne 0 ]]; then
    echo "  NOTE: Some checks may be incomplete without root."
    echo ""
fi

if ! command -v ufw &>/dev/null; then
    check_fail "UFW installed" "ufw not found — install: apt-get install ufw"
    summary "UFW is not installed."
    exit 1
fi

# --- Active status ---
section_header "Status"
UFW_STATUS=$(ufw status verbose 2>/dev/null || true)

if echo "$UFW_STATUS" | grep -q "Status: active"; then
    check_pass "UFW active"
else
    check_fail "UFW active" "UFW is inactive — enable: ufw --force enable"
    summary "UFW is not active."
    exit 1
fi

# --- Default policies ---
section_header "Default Policies"
default_in=$(echo "$UFW_STATUS" | grep "Default:" | grep -o "deny (incoming)\|reject (incoming)" || true)
default_out=$(echo "$UFW_STATUS" | grep "Default:" | grep -o "allow (outgoing)" || true)

if [[ -n "$default_in" ]]; then
    check_pass "Default incoming: deny"
else
    check_fail "Default incoming policy" "Expected 'deny (incoming)' — run: ufw default deny incoming"
fi

if [[ -n "$default_out" ]]; then
    check_pass "Default outgoing: allow"
else
    check_fail "Default outgoing policy" "Expected 'allow (outgoing)' — run: ufw default allow outgoing"
fi

# --- Required ports ---
section_header "Required Rules"
UFW_RULES=$(ufw status numbered 2>/dev/null || true)

if echo "$UFW_RULES" | grep -q "${SSH_PORT}/tcp.*ALLOW"; then
    check_pass "SSH port ${SSH_PORT}/tcp allowed"
else
    check_fail "SSH port ${SSH_PORT}/tcp" "Not found in UFW rules — risk of lockout: ufw allow ${SSH_PORT}/tcp"
fi

if echo "$UFW_RULES" | grep -q "80/tcp.*ALLOW"; then
    check_pass "HTTP 80/tcp allowed"
else
    check_fail "HTTP 80/tcp" "Not found — add: ufw allow 80/tcp comment 'HTTP'"
fi

if echo "$UFW_RULES" | grep -q "443/tcp.*ALLOW"; then
    check_pass "HTTPS 443/tcp allowed"
else
    check_fail "HTTPS 443/tcp" "Not found — add: ufw allow 443/tcp comment 'HTTPS'"
fi

# --- Rate limiting ---
section_header "Rate Limiting"
if echo "$UFW_RULES" | grep -q "80/tcp.*LIMIT"; then
    check_pass "HTTP 80/tcp rate-limited"
else
    check_fail "HTTP 80/tcp rate limit" "Not set — add: ufw limit 80/tcp comment 'HTTP rate-limit'"
fi

if echo "$UFW_RULES" | grep -q "443/tcp.*LIMIT"; then
    check_pass "HTTPS 443/tcp rate-limited"
else
    check_fail "HTTPS 443/tcp rate limit" "Not set — add: ufw limit 443/tcp comment 'HTTPS rate-limit'"
fi

# --- All rules (informational) ---
echo ""
echo "[ Current Rules ]"
echo "$UFW_RULES" | grep -v "^Status" | sed 's/^/  /' || true

summary "UFW firewall check complete."
[[ "$FAIL" -eq 0 ]]
