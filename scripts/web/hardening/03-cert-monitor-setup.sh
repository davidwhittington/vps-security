#!/usr/bin/env bash
# 03-cert-monitor-setup.sh — TLS certificate expiry monitoring
#
# Sets up a weekly cron job that checks all certbot-managed certificates
# and sends an email alert if any expire within 30 days.
# Distinct from the monthly update report — alerts fire when certs need attention,
# not buried in a monthly digest.
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

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
WARN_DAYS="${CERT_WARN_DAYS:-30}"
SERVER_HOSTNAME=$(hostname -f)

if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "ERROR: ADMIN_EMAIL is not set in config.env." >&2
    exit 1
fi

# --- Banner ---
echo "========================================="
echo "  Certificate Expiry Monitor Setup"
echo "  Email:    $ADMIN_EMAIL"
echo "  Alert at: ${WARN_DAYS} days before expiry"
echo "  Host:     $SERVER_HOSTNAME"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

_CERTBOT_CMD=$(command -v certbot 2>/dev/null)
[[ -z "$_CERTBOT_CMD" && -x /snap/bin/certbot ]] && _CERTBOT_CMD=/snap/bin/certbot
if [[ -z "$_CERTBOT_CMD" ]]; then
    echo "WARNING: certbot not found. Install certbot before running this script." >&2
    echo "  Ubuntu: snap install --classic certbot" >&2
    echo "  Debian: apt-get install -y certbot python3-certbot-apache" >&2
fi

# --- Create monitor script ---
echo "[1/2] Creating certificate expiry monitor script..."
if ! $DRYRUN; then
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/cert-expiry-check.sh << SCRIPTEOF
#!/usr/bin/env bash
# Certificate expiry monitor — managed by vps-security
set -uo pipefail

EMAIL="${ADMIN_EMAIL}"
HOSTNAME=\$(hostname -f)
WARN_DAYS="${WARN_DAYS}"
CERTBOT=\$(command -v certbot 2>/dev/null)
[[ -z "\$CERTBOT" && -x /snap/bin/certbot ]] && CERTBOT=/snap/bin/certbot

if [[ -z "\$CERTBOT" || ! -x "\$CERTBOT" ]]; then
    echo "certbot not found" | mail -s "[\$HOSTNAME] Cert check failed" "\$EMAIL" || true
    exit 1
fi

# Get cert info
CERT_OUT=\$("\$CERTBOT" certificates 2>/dev/null || true)

# Find certs expiring within WARN_DAYS
EXPIRING=\$(echo "\$CERT_OUT" | awk '
    /Certificate Name:/ { name=\$3 }
    /VALID: / {
        match(\$0, /VALID: ([0-9]+) day/, arr)
        days = arr[1]
        if (days != "" && days+0 <= '"'"'\$WARN_DAYS'"'"') {
            print name " — " days " days remaining"
        }
    }
')

EXPIRED=\$(echo "\$CERT_OUT" | grep -i "INVALID\|EXPIRED" | head -5 || true)

if [[ -n "\$EXPIRED" ]] || [[ -n "\$EXPIRING" ]]; then
    {
        echo "Certificate expiry alert for \$HOSTNAME"
        echo "Date: \$(date)"
        echo ""
        if [[ -n "\$EXPIRED" ]]; then
            echo "=== EXPIRED ==="
            echo "\$EXPIRED"
            echo ""
        fi
        if [[ -n "\$EXPIRING" ]]; then
            echo "=== Expiring within \${WARN_DAYS} days ==="
            echo "\$EXPIRING"
            echo ""
        fi
        echo "Run: certbot renew --dry-run"
        echo "Then: certbot renew"
    } | mail -s "[\$HOSTNAME] CERT ALERT: certificates expiring soon" "\$EMAIL"
    echo "Alert sent to \$EMAIL"
else
    echo "All certificates valid. Next check in 7 days."
fi
SCRIPTEOF
    chmod +x /usr/local/sbin/cert-expiry-check.sh
else
    echo "  [dry-run] Would write /usr/local/sbin/cert-expiry-check.sh"
    echo "    - Checks all certbot certs weekly"
    echo "    - Emails $ADMIN_EMAIL if any expire within ${WARN_DAYS} days"
fi
echo "  -> Monitor script created."

# --- Schedule weekly cron ---
echo ""
echo "[2/2] Scheduling weekly certificate check (Mondays at 8 AM)..."
CRON_LINE="0 8 * * 1 /usr/local/sbin/cert-expiry-check.sh >> /var/log/cert-expiry-check.log 2>&1"
if ! $DRYRUN; then
    (crontab -l 2>/dev/null | grep -v "cert-expiry-check"; echo "$CRON_LINE") | crontab -
else
    echo "  [dry-run] Would add cron: $CRON_LINE"
fi
echo "  -> Cron scheduled: Mondays at 8:00 AM."

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Certificate monitor setup complete!"
    echo ""
    echo "  Schedule:  Mondays at 8:00 AM"
    echo "  Alert at:  ${WARN_DAYS} days before expiry"
    echo "  Email:     $ADMIN_EMAIL"
    echo "  Log:       /var/log/cert-expiry-check.log"
    echo ""
    echo "  Test now:  /usr/local/sbin/cert-expiry-check.sh"
fi
echo "========================================="
