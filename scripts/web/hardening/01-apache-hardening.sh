#!/usr/bin/env bash
# 01-apache-hardening.sh
# Apache: security headers, CSP, ServerTokens, mod_status, .git/.svn blocking
# Run as root on the target server.
set -euo pipefail

# --- Dry-run support ---
DRYRUN=false
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRYRUN=true; done

cmd() {
    if $DRYRUN; then echo "  [dry-run] $*"; return 0; fi
    "$@"
}

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
    echo "  -> Config loaded: $CONFIG_FILE"
else
    echo "  WARNING: config.env not found — using defaults. See docs/customization.md"
fi

# --- Web config discovery (config.web.env) ---
WEB_CONFIG_FILE="${WEB_CONFIG_FILE:-}"
if [[ -z "$WEB_CONFIG_FILE" ]]; then
    for loc in \
        "$SCRIPT_DIR/../../../config.web.env" \
        /etc/linux-security/config.web.env; do
        if [[ -f "$loc" ]]; then WEB_CONFIG_FILE="$loc"; break; fi
    done
fi
if [[ -n "$WEB_CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$WEB_CONFIG_FILE"
fi

CSP_FRAME_ANCESTORS="${CSP_FRAME_ANCESTORS:-'self'}"

# --- Banner ---
echo "========================================="
echo "  Apache Hardening"
echo "  Host: $(hostname -f)"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# --- 1/4: mod_headers ---
echo "[1/4] Enabling mod_headers..."
cmd a2enmod headers
echo "  -> mod_headers enabled."

# --- 2/4: security.conf ---
echo ""
echo "[2/4] Updating security.conf..."
SECCONF="/etc/apache2/conf-enabled/security.conf"

if ! $DRYRUN; then
    [[ -f "$SECCONF" ]] && cp "$SECCONF" "${SECCONF}.bak"

    cat > "$SECCONF" << SECEOF
# Hardened security configuration — managed by vps-security

# Hide server version details
ServerTokens Prod
ServerSignature Off

# Disable TRACE method
TraceEnable Off

# Block access to version control directories
RedirectMatch 404 /\.git
RedirectMatch 404 /\.svn

# Security headers
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-XSS-Protection "0"
    Header always set Content-Security-Policy "frame-ancestors ${CSP_FRAME_ANCESTORS}"
</IfModule>
SECEOF
    echo "  -> security.conf updated (backup: ${SECCONF}.bak)."
else
    echo "  [dry-run] Would write $SECCONF"
    echo "    - ServerTokens Prod / ServerSignature Off"
    echo "    - HSTS, X-Content-Type-Options, Referrer-Policy, Permissions-Policy"
    echo "    - CSP frame-ancestors: ${CSP_FRAME_ANCESTORS}"
    echo "    - Block .git / .svn"
fi

# --- 3/4: mod_status ---
echo ""
echo "[3/4] Disabling mod_status..."
cmd a2dismod status 2>/dev/null || echo "  -> mod_status already disabled."

# --- 4/4: Test and reload ---
echo ""
echo "[4/4] Testing and reloading Apache..."
if ! $DRYRUN; then
    if apache2ctl configtest 2>&1; then
        systemctl reload apache2
        echo "  -> Apache reloaded successfully."
    else
        echo "ERROR: Apache config test failed. Restoring backup." >&2
        [[ -f "${SECCONF}.bak" ]] && cp "${SECCONF}.bak" "$SECCONF"
        exit 1
    fi
else
    echo "  [dry-run] Would run: apache2ctl configtest && systemctl reload apache2"
fi

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Apache hardening complete!"
fi
echo "========================================="
