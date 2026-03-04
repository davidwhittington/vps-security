#!/usr/bin/env bash
# 02-apache-hardening.sh
# Addresses HIGH findings: Apache info disclosure, security headers, mod_status
# Run as root on the target server
set -euo pipefail

echo "========================================="
echo "  Apache Hardening Script"
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

echo "[1/4] Enabling mod_headers..."
a2enmod headers
echo "  -> mod_headers enabled."

echo ""
echo "[2/4] Updating security.conf..."
cp /etc/apache2/conf-enabled/security.conf /etc/apache2/conf-enabled/security.conf.bak

cat > /etc/apache2/conf-enabled/security.conf << 'SECEOF'
# Hardened security configuration

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
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-XSS-Protection "0"
</IfModule>
SECEOF
echo "  -> security.conf updated (backup: security.conf.bak)."

echo ""
echo "[3/4] Disabling mod_status..."
a2dismod status 2>/dev/null || echo "  -> mod_status already disabled."

echo ""
echo "[4/4] Testing and reloading Apache..."
if apache2ctl configtest 2>&1; then
    systemctl reload apache2
    echo "  -> Apache reloaded successfully."
else
    echo "ERROR: Apache config test failed! Restoring backup."
    cp /etc/apache2/conf-enabled/security.conf.bak /etc/apache2/conf-enabled/security.conf
    exit 1
fi

echo ""
echo "========================================="
echo "  Apache hardening complete!"
echo "========================================="
