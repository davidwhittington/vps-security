#!/usr/bin/env bash
# 12-apache-tls-hardening.sh — Apache TLS cipher suite hardening
#
# Restricts Apache SSL to TLS 1.2+ with modern cipher suites only,
# enables OCSP stapling, and enforces server cipher order.
# Applies globally via /etc/apache2/conf-available/ssl-hardening.conf.
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
    echo "  WARNING: config.env not found — using defaults."
fi

SERVER_HOSTNAME=$(hostname -f)

# --- Banner ---
echo "========================================="
echo "  Apache TLS Hardening"
echo "  Host: $SERVER_HOSTNAME"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if ! command -v apache2 &>/dev/null && ! apachectl -v &>/dev/null 2>&1; then
    echo "ERROR: Apache2 not found." >&2
    exit 1
fi

# --- 1/3: Enable ssl and socache_shmcb modules ---
echo "[1/3] Enabling required Apache modules..."
cmd a2enmod ssl
cmd a2enmod socache_shmcb
echo "  -> SSL modules enabled."

# --- 2/3: Write TLS hardening config ---
echo ""
echo "[2/3] Writing /etc/apache2/conf-available/ssl-hardening.conf..."
if ! $DRYRUN; then
    cat > /etc/apache2/conf-available/ssl-hardening.conf << 'SSLEOF'
# vps-security: Apache TLS cipher suite hardening
# Managed by 12-apache-tls-hardening.sh

# TLS 1.2 and 1.3 only — drop SSLv3, TLS 1.0, TLS 1.1
SSLProtocol             all -SSLv3 -TLSv1 -TLSv1.1

# Modern cipher suites — forward secrecy, no RC4, no 3DES, no export ciphers
# Prefer ECDHE > DHE, prefer AES-GCM/ChaCha20, exclude SHA1-based MACs
SSLCipherSuite          ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:\
ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:\
ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:\
DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256

# Server chooses cipher, not client — enforce our ordered preference
SSLHonorCipherOrder     on

# Disable SSL compression (CRIME attack mitigation)
SSLCompression          off

# Disable TLS session tickets (improves forward secrecy)
SSLSessionTickets       off

# OCSP Stapling — reduces TLS handshake latency and improves privacy
SSLUseStapling          on
SSLStaplingCache        shmcb:/var/run/apache2/stapling-cache(512000)
SSLStaplingResponderTimeout 5
SSLStaplingReturnResponderErrors off

# Disable insecure renegotiation
SSLInsecureRenegotiation off
SSLEOF
else
    echo "  [dry-run] Would write /etc/apache2/conf-available/ssl-hardening.conf:"
    echo "    - SSLProtocol: TLS 1.2 + 1.3 only"
    echo "    - Modern ECDHE/DHE cipher suites with GCM + ChaCha20"
    echo "    - SSLHonorCipherOrder on"
    echo "    - SSLCompression off, SSLSessionTickets off"
    echo "    - OCSP Stapling enabled"
fi
echo "  -> TLS hardening config written."

# --- 3/3: Enable and reload ---
echo ""
echo "[3/3] Enabling conf and reloading Apache..."
cmd a2enconf ssl-hardening
cmd apache2ctl configtest
cmd systemctl reload apache2
echo "  -> Apache reloaded with TLS hardening."

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Apache TLS hardening complete!"
    echo ""
    echo "  Config:  /etc/apache2/conf-available/ssl-hardening.conf"
    echo "  Enabled: /etc/apache2/conf-enabled/ssl-hardening.conf"
    echo ""
    echo "  Verify:  openssl s_client -connect localhost:443 -tls1_1"
    echo "           (should fail — TLS 1.1 rejected)"
    echo "  Test:    curl -sI https://$(hostname -f)/ | grep -i server"
fi
echo "========================================="
