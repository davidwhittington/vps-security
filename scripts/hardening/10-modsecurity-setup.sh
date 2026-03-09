#!/usr/bin/env bash
# 10-modsecurity-setup.sh — ModSecurity with OWASP Core Rule Set
#
# Installs mod_security2 for Apache, downloads and configures the OWASP CRS,
# and sets ModSecurity to DetectionOnly mode initially (safe default).
# Run as root on the target server.
#
# After installation, review /var/log/apache2/modsec_audit.log for false
# positives before switching to enforcement mode.
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
        "$SCRIPT_DIR/../../config.env" \
        "$SCRIPT_DIR/../config.env" \
        /etc/vps-security/config.env; do
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

SERVER_HOSTNAME=$(hostname -f)

# --- Banner ---
echo "========================================="
echo "  ModSecurity + OWASP CRS Setup"
echo "  Mode: DetectionOnly (safe default)"
echo "  Host: $SERVER_HOSTNAME"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if ! command -v apache2 &>/dev/null && ! apachectl -v &>/dev/null 2>&1; then
    echo "ERROR: Apache2 not found. Install Apache before running this script." >&2
    exit 1
fi

# --- 1/5: Install ---
echo "[1/5] Installing libapache2-mod-security2..."
if ! $DRYRUN; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libapache2-mod-security2
else
    echo "  [dry-run] Would install: libapache2-mod-security2"
fi
echo "  -> mod_security2 installed."

# --- 2/5: Enable module ---
echo ""
echo "[2/5] Enabling mod_security and mod_unique_id..."
cmd a2enmod security2
cmd a2enmod unique_id
echo "  -> Apache modules enabled."

# --- 3/5: Base configuration ---
echo ""
echo "[3/5] Configuring ModSecurity base config..."
if ! $DRYRUN; then
    # Use the recommended config as the base
    if [[ -f /etc/modsecurity/modsecurity.conf-recommended ]]; then
        cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
    fi

    # Set to DetectionOnly — review logs before switching to On
    sed -i 's/^SecRuleEngine.*/SecRuleEngine DetectionOnly/' /etc/modsecurity/modsecurity.conf

    # Increase body inspection limits for typical web apps
    sed -i 's/^SecRequestBodyLimit.*/SecRequestBodyLimit 13107200/' /etc/modsecurity/modsecurity.conf
    sed -i 's/^SecRequestBodyNoFilesLimit.*/SecRequestBodyNoFilesLimit 131072/' /etc/modsecurity/modsecurity.conf

    # Write audit log to dedicated file
    sed -i 's|^SecAuditLog .*|SecAuditLog /var/log/apache2/modsec_audit.log|' /etc/modsecurity/modsecurity.conf
else
    echo "  [dry-run] Would configure /etc/modsecurity/modsecurity.conf:"
    echo "    - SecRuleEngine DetectionOnly"
    echo "    - SecAuditLog /var/log/apache2/modsec_audit.log"
fi
echo "  -> ModSecurity base config applied."

# --- 4/5: OWASP CRS ---
echo ""
echo "[4/5] Installing OWASP Core Rule Set..."
CRS_DIR="/etc/modsecurity/crs"
if ! $DRYRUN; then
    # Try package first (available in Ubuntu 22.04+)
    if apt-get install -y -qq modsecurity-crs 2>/dev/null; then
        CRS_INSTALLED_VIA="apt"
        # Locate where apt installed the CRS
        CRS_APT_DIR=$(dpkg -L modsecurity-crs 2>/dev/null | grep 'crs-setup.conf' | head -1 | xargs dirname 2>/dev/null || true)
        if [[ -n "$CRS_APT_DIR" ]]; then
            CRS_DIR="$CRS_APT_DIR"
        fi
    else
        # Fallback: download from GitHub releases
        echo "  apt package not found — downloading from GitHub..."
        CRS_INSTALLED_VIA="github"
        mkdir -p "$CRS_DIR"
        CRS_URL="https://github.com/coreruleset/coreruleset/archive/refs/tags/v4.0.0.tar.gz"
        curl -fsSL "$CRS_URL" | tar -xz -C "$CRS_DIR" --strip-components=1
    fi

    # Set up CRS config
    if [[ -f "${CRS_DIR}/crs-setup.conf.example" ]]; then
        cp "${CRS_DIR}/crs-setup.conf.example" "${CRS_DIR}/crs-setup.conf"
    fi

    # Write Apache include config pointing at CRS
    cat > /etc/apache2/conf-available/modsecurity-crs.conf << CRSEOF
# vps-security: OWASP CRS include — managed by vps-security
<IfModule security2_module>
    Include /etc/modsecurity/modsecurity.conf
    Include ${CRS_DIR}/crs-setup.conf
    Include ${CRS_DIR}/rules/*.conf
</IfModule>
CRSEOF
    a2enconf modsecurity-crs
else
    echo "  [dry-run] Would install OWASP CRS via apt or download"
    echo "  [dry-run] Would write /etc/apache2/conf-available/modsecurity-crs.conf"
fi
echo "  -> OWASP CRS installed."

# --- 5/5: Reload Apache ---
echo ""
echo "[5/5] Reloading Apache..."
cmd apache2ctl configtest
cmd systemctl reload apache2

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  ModSecurity + OWASP CRS setup complete!"
    echo ""
    echo "  Mode:       DetectionOnly (no blocking yet)"
    echo "  Audit log:  /var/log/apache2/modsec_audit.log"
    echo "  CRS rules:  ${CRS_DIR}/rules/"
    echo ""
    echo "  After reviewing logs for false positives, enable enforcement:"
    echo "    sed -i 's/DetectionOnly/On/' /etc/modsecurity/modsecurity.conf"
    echo "    systemctl reload apache2"
    echo ""
    echo "  Monitor:    tail -f /var/log/apache2/modsec_audit.log"
fi
echo "========================================="
