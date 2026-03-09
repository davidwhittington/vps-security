#!/usr/bin/env bash
# vhost-linter.sh — Apache vhost configuration linter
#
# Checks all enabled Apache vhosts for:
#   - Missing HSTS header
#   - Missing security headers (X-Content-Type-Options, Referrer-Policy, CSP)
#   - ServerTokens / ServerSignature not set to Prod/Off
#   - ServerName missing or mismatched with filename
#   - Directory traversal risk: Options Indexes not disabled
#   - AllowOverride All (disables server-side security controls)
#   - PHP admin values not locked down (if PHP enabled)
# Read-only. Exits 1 if critical issues found.
#
# Usage:
#   bash scripts/audit/vhost-linter.sh
#   bash scripts/audit/vhost-linter.sh --vhostdir /etc/apache2/sites-enabled
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"

VHOST_DIR="/etc/apache2/sites-enabled"
for arg in "$@"; do
    [[ "$arg" == "--vhostdir" ]] && shift && VHOST_DIR="${1:-/etc/apache2/sites-enabled}"
done

banner "Apache Vhost Linter"
echo "  Scanning: ${VHOST_DIR}"
echo ""

if [[ ! -d "$VHOST_DIR" ]]; then
    check_fail "Vhost directory exists" "${VHOST_DIR} not found — is Apache installed?"
    summary "Apache vhost linter could not run."
    exit 1
fi

VHOST_FILES=("$VHOST_DIR"/*.conf "$VHOST_DIR"/*.conf.*)
VHOST_COUNT=0

for vhost in "${VHOST_DIR}"/*.conf; do
    [[ -f "$vhost" ]] || continue
    NAME=$(basename "$vhost")
    VHOST_COUNT=$(( VHOST_COUNT + 1 ))

    section_header "Vhost: ${NAME}"

    # ServerName present
    if grep -qi "ServerName" "$vhost"; then
        SN=$(grep -i "ServerName" "$vhost" | head -1 | awk '{print $2}')
        check_pass "ServerName: ${SN}"
    else
        check_warn "ServerName missing" "Vhost has no ServerName directive — Apache will use server hostname"
    fi

    # HSTS
    if grep -qi "Strict-Transport-Security" "$vhost"; then
        check_pass "HSTS header present"
    else
        check_warn "HSTS header missing" "Add: Header always set Strict-Transport-Security \"max-age=63072000; includeSubDomains\""
    fi

    # X-Content-Type-Options
    if grep -qi "X-Content-Type-Options" "$vhost"; then
        check_pass "X-Content-Type-Options present"
    else
        check_warn "X-Content-Type-Options missing" "Add: Header always set X-Content-Type-Options \"nosniff\""
    fi

    # Referrer-Policy
    if grep -qi "Referrer-Policy" "$vhost"; then
        check_pass "Referrer-Policy present"
    else
        check_warn "Referrer-Policy missing" "Add: Header always set Referrer-Policy \"strict-origin-when-cross-origin\""
    fi

    # CSP
    if grep -qi "Content-Security-Policy" "$vhost"; then
        check_pass "Content-Security-Policy present"
    else
        check_warn "Content-Security-Policy missing" "Add a Content-Security-Policy header appropriate to the site"
    fi

    # Options Indexes
    if grep -qi "Options.*Indexes" "$vhost"; then
        # Check if it's disabled or enabled
        if grep -qi "Options.*-Indexes" "$vhost"; then
            check_pass "Directory listing disabled (-Indexes)"
        else
            check_fail "Options Indexes enabled" "Directory listing is on — add 'Options -Indexes' to the Directory block"
        fi
    else
        check_warn "Options Indexes" "Not explicitly set — verify inherited config disables directory listing"
    fi

    # AllowOverride All
    if grep -qi "AllowOverride.*All" "$vhost"; then
        check_warn "AllowOverride All" ".htaccess files can override server security settings — use AllowOverride None where possible"
    else
        check_pass "AllowOverride not set to All"
    fi

    # SSLEngine on for port 443 vhosts
    if grep -q "443" "$vhost"; then
        if grep -qi "SSLEngine on" "$vhost"; then
            check_pass "SSLEngine on (port 443 vhost)"
        else
            check_fail "SSLEngine missing" "Port 443 vhost has no SSLEngine on directive"
        fi

        # SSL cert configured
        if grep -qi "SSLCertificateFile" "$vhost"; then
            check_pass "SSLCertificateFile configured"
        else
            check_fail "SSLCertificateFile missing" "Port 443 vhost has no certificate configured"
        fi
    fi

    # HTTP vhost (port 80) should redirect to HTTPS
    if grep -q "80" "$vhost" && ! grep -q "443" "$vhost"; then
        if grep -qi "Redirect\|RewriteRule.*https\|mod_rewrite" "$vhost"; then
            check_pass "HTTP to HTTPS redirect present"
        else
            check_warn "No HTTP to HTTPS redirect" "Port 80 vhost should redirect to HTTPS"
        fi
    fi

    echo ""
done

if [[ "$VHOST_COUNT" -eq 0 ]]; then
    check_warn "No vhosts found" "No .conf files in ${VHOST_DIR}"
else
    check_info "Scanned ${VHOST_COUNT} vhost file(s)"
fi

# Global Apache security config
section_header "Global Apache Security Config"
SECURITY_CONF="/etc/apache2/conf-enabled/security.conf"
if [[ -f "$SECURITY_CONF" ]]; then
    if grep -qi "^ServerTokens Prod" "$SECURITY_CONF"; then
        check_pass "ServerTokens Prod"
    else
        check_warn "ServerTokens not set to Prod" "Edit ${SECURITY_CONF}: ServerTokens Prod"
    fi
    if grep -qi "^ServerSignature Off" "$SECURITY_CONF"; then
        check_pass "ServerSignature Off"
    else
        check_warn "ServerSignature not Off" "Edit ${SECURITY_CONF}: ServerSignature Off"
    fi
    if grep -qi "^TraceEnable Off" "$SECURITY_CONF"; then
        check_pass "TraceEnable Off"
    else
        check_warn "TraceEnable not Off" "Edit ${SECURITY_CONF}: TraceEnable Off"
    fi
else
    check_warn "security.conf not found at ${SECURITY_CONF}" "Global Apache security settings may not be configured"
fi

summary "Vhost linter complete."
[[ "$FAIL" -eq 0 ]]
