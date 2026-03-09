#!/usr/bin/env bash
# preflight-check.sh — dependency pre-flight check
#
# Verifies all tools required by vps-security are present and that
# the server environment is compatible before running bootstrap.sh.
# Read-only. Exits 1 if any required dependency is missing.
#
# Usage:
#   bash scripts/core/audit/preflight-check.sh
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

banner "Pre-flight Check"

# --- OS compatibility ---
section_header "Operating System"
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-unknown}"

    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        check_pass "OS: ${OS_NAME}"
    else
        check_fail "OS: ${OS_NAME}" "linux-security targets Ubuntu 22.04/24.04 and Debian 12. Other distros may work but are untested."
    fi

    if [[ "$OS_ID" == "ubuntu" && "${OS_VER:-0}" < "22.04" ]]; then
        check_fail "Ubuntu version ${OS_VER}" "Ubuntu 22.04+ required (24.04 recommended)"
    fi
else
    check_warn "OS detection" "/etc/os-release not found"
fi

# --- Root / privilege ---
section_header "Privileges"
if [[ $EUID -eq 0 ]]; then
    check_pass "Running as root"
else
    check_fail "Running as root" "vps-security hardening scripts require root — run as root or with sudo"
fi

# --- SSH safety ---
section_header "SSH Safety"
if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
    KEY_COUNT=$(grep -c "^ssh-" /root/.ssh/authorized_keys 2>/dev/null || true)
    check_pass "SSH authorized_keys present (${KEY_COUNT} key(s))"
else
    check_fail "SSH authorized_keys" "No keys in /root/.ssh/authorized_keys — add your public key before hardening SSH or you will be locked out"
fi

# --- Required system tools ---
section_header "Required Tools"
REQUIRED_CMDS=(apt-get systemctl curl openssl hostname)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        check_pass "Command: ${cmd}"
    else
        check_fail "Command: ${cmd}" "Not found — required by vps-security"
    fi
done

# --- Script 01 dependencies ---
section_header "Script 01 — Firewall & SSH"
for pkg in ufw fail2ban; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        check_pass "${pkg} installed"
    else
        check_warn "${pkg} not installed" "Will be installed by 01-immediate-hardening.sh"
    fi
done

# --- Script 02 dependencies ---
section_header "Script 02 — Apache"
if command -v apache2 &>/dev/null || dpkg -l apache2 2>/dev/null | grep -q "^ii"; then
    check_pass "apache2 installed"
else
    check_warn "apache2 not installed" "Install before running 02-apache-hardening.sh: apt-get install apache2"
fi

# --- Script 04 dependencies ---
section_header "Script 04 — Email / SMTP"
for pkg in msmtp mailutils; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        check_pass "${pkg} installed"
    else
        check_warn "${pkg} not installed" "Will be installed by 04-monthly-updates-setup.sh"
    fi
done

# --- Script 05 dependencies ---
section_header "Script 05 — Log Monitoring"
for pkg in logwatch goaccess apache2-utils; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        check_pass "${pkg} installed"
    else
        check_warn "${pkg} not installed" "Will be installed by 05-log-monitoring-setup.sh"
    fi
done

# --- Script 06 / certbot ---
section_header "Script 06 — TLS Certificates"
CERTBOT_CMD=$(command -v certbot 2>/dev/null)
[[ -z "$CERTBOT_CMD" && -x /snap/bin/certbot ]] && CERTBOT_CMD=/snap/bin/certbot
if [[ -n "$CERTBOT_CMD" ]]; then
    check_pass "certbot found: ${CERTBOT_CMD}"
else
    if [[ "${OS_ID:-}" == "debian" ]]; then
        check_warn "certbot not found" "Install: apt-get install -y certbot python3-certbot-apache"
    else
        check_warn "certbot not found" "Install: snap install --classic certbot  OR  apt-get install -y certbot"
    fi
fi

# --- config.env ---
section_header "Configuration"
if [[ -n "$CONFIG_FILE" ]]; then
    check_pass "config.env loaded: ${CONFIG_FILE}"
else
    check_warn "config.env not found" "Copy config.env.example to config.env and fill in your values before running bootstrap.sh"
fi

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
if [[ -n "$ADMIN_EMAIL" ]]; then
    check_pass "ADMIN_EMAIL set: ${ADMIN_EMAIL}"
else
    check_fail "ADMIN_EMAIL not set" "Required for email alerts — set in config.env"
fi

# --- Network connectivity ---
section_header "Network"
# Use distro-specific mirror, fall back to Cloudflare DNS as a neutral target
_CONN_TARGET="https://cloudflare.com"
[[ "${OS_ID:-}" == "ubuntu" ]] && _CONN_TARGET="https://archive.ubuntu.com"
[[ "${OS_ID:-}" == "debian" ]] && _CONN_TARGET="https://deb.debian.org"
if curl -s --max-time 5 "$_CONN_TARGET" &>/dev/null; then
    check_pass "Internet connectivity (${_CONN_TARGET} reachable)"
else
    check_warn "Internet connectivity" "Cannot reach ${_CONN_TARGET} — apt-get installs may fail"
fi

summary "Pre-flight check complete."
[[ "$FAIL" -eq 0 ]]
