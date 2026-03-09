#!/usr/bin/env bash
# 08-apache-dos-mitigation.sh — mod_reqtimeout (Slowloris) and mod_evasive (HTTP flood)
#
# Installs and configures two complementary Apache DoS mitigations:
#   mod_reqtimeout  — kills slow HTTP connections (Slowloris mitigation)
#   mod_evasive     — rate-limits repeated requests from the same IP
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
    echo "  WARNING: config.env not found — using defaults."
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

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SERVER_HOSTNAME=$(hostname -f)

# --- Banner ---
echo "========================================="
echo "  Apache DoS Mitigation Setup"
echo "  mod_reqtimeout (Slowloris) + mod_evasive (HTTP flood)"
echo "  Host: $SERVER_HOSTNAME"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# --- 1/4: Install mod_evasive ---
echo "[1/4] Installing libapache2-mod-evasive..."
if ! $DRYRUN; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libapache2-mod-evasive
else
    echo "  [dry-run] Would install: libapache2-mod-evasive"
fi
echo "  -> libapache2-mod-evasive installed."

# --- 2/4: Enable modules ---
echo ""
echo "[2/4] Enabling Apache modules..."
cmd a2enmod reqtimeout
cmd a2enmod evasive
echo "  -> mod_reqtimeout and mod_evasive enabled."

# --- 3/4: Configure mod_reqtimeout (Slowloris) ---
echo ""
echo "[3/4] Configuring mod_reqtimeout (Slowloris mitigation)..."
if ! $DRYRUN; then
    cat > /etc/apache2/conf-available/reqtimeout-hardening.conf << 'RTEOF'
# linux-security: mod_reqtimeout — Slowloris mitigation
# Managed by 13-apache-dos-mitigation.sh

<IfModule reqtimeout_module>
    # Require HTTP headers within 20s (min) — 40s with data flowing
    RequestReadTimeout header=20-40,minrate=500

    # Require HTTP body within 10s — 60s with data flowing at 500 B/s
    RequestReadTimeout body=10,minrate=500
</IfModule>
RTEOF
    a2enconf reqtimeout-hardening
else
    echo "  [dry-run] Would write /etc/apache2/conf-available/reqtimeout-hardening.conf"
    echo "    - header timeout: 20-40s at min 500 B/s"
    echo "    - body timeout: 10-60s at min 500 B/s"
fi
echo "  -> mod_reqtimeout configured."

# --- 4/4: Configure mod_evasive (HTTP flood) ---
echo ""
echo "[4/4] Configuring mod_evasive (HTTP flood mitigation)..."
if ! $DRYRUN; then
    mkdir -p /var/log/mod_evasive

    cat > /etc/apache2/conf-available/evasive-hardening.conf << EVASEOF
# linux-security: mod_evasive — HTTP flood rate limiting
# Managed by 13-apache-dos-mitigation.sh

<IfModule evasive20_module>
    # Block if same page requested more than 5x per page interval (2s)
    DOSPageCount        5
    DOSPageInterval     2

    # Block if more than 50 requests to any site resource per interval (1s)
    DOSSiteCount        50
    DOSSiteInterval     1

    # Block duration in seconds (default 10)
    DOSBlockingPeriod   30

    # Log blocked IPs
    DOSLogDir           /var/log/mod_evasive

    # Email notification (requires mail configured)
    ${ADMIN_EMAIL:+DOSEmailNotify    ${ADMIN_EMAIL}}

    # Whitelist localhost
    DOSWhitelist        127.0.0.1
</IfModule>
EVASEOF
    a2enconf evasive-hardening
else
    echo "  [dry-run] Would write /etc/apache2/conf-available/evasive-hardening.conf"
    echo "    - DOSPageCount 5 / DOSSiteCount 50"
    echo "    - DOSBlockingPeriod 30s"
    if [[ -n "$ADMIN_EMAIL" ]]; then
        echo "    - DOSEmailNotify: $ADMIN_EMAIL"
    fi
fi
echo "  -> mod_evasive configured."

# Reload Apache
cmd apache2ctl configtest
cmd systemctl reload apache2

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Apache DoS mitigation complete!"
    echo ""
    echo "  mod_reqtimeout: /etc/apache2/conf-available/reqtimeout-hardening.conf"
    echo "  mod_evasive:    /etc/apache2/conf-available/evasive-hardening.conf"
    echo "  Block log:      /var/log/mod_evasive/"
    echo ""
    echo "  Monitor:  tail -f /var/log/mod_evasive/*"
fi
echo "========================================="
