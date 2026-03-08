#!/usr/bin/env bash
# 05-log-monitoring-setup.sh
# Logwatch daily email digest + GoAccess daily traffic report (password-protected).
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
    echo "  WARNING: config.env not found — using defaults. See docs/customization.md"
fi

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
MAIL_FROM="${MAIL_FROM:-server@$(hostname -f)}"
SERVER_HOSTNAME=$(hostname -f)

if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "ERROR: ADMIN_EMAIL is not set in config.env." >&2
    exit 1
fi

# --- Banner ---
echo "========================================="
echo "  Log Monitoring Setup"
echo "  Email: $ADMIN_EMAIL"
echo "  Host:  $SERVER_HOSTNAME"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# --- 1/5: Install tools ---
echo "[1/5] Installing logwatch, goaccess, apache2-utils..."
if ! $DRYRUN; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq logwatch goaccess apache2-utils
else
    echo "  [dry-run] Would install: logwatch goaccess apache2-utils"
fi

# --- 2/5: Logwatch ---
echo ""
echo "[2/5] Configuring Logwatch..."
if ! $DRYRUN; then
    mkdir -p /etc/logwatch/conf
    cat > /etc/logwatch/conf/logwatch.conf << LWEOF
Output   = mail
MailTo   = ${ADMIN_EMAIL}
MailFrom = ${MAIL_FROM}
Detail   = High
Range    = yesterday
Service  = All
Format   = html
mailer   = "/usr/bin/msmtp"
LWEOF
else
    echo "  [dry-run] Would write /etc/logwatch/conf/logwatch.conf"
    echo "    - MailTo: $ADMIN_EMAIL / MailFrom: $MAIL_FROM"
fi
echo "  -> Logwatch configured (daily digest via cron.daily)."

# --- 3/5: GoAccess report script ---
echo ""
echo "[3/5] Creating GoAccess daily report script..."
if ! $DRYRUN; then
    mkdir -p /var/www/html/reports /usr/local/sbin
    cat > /usr/local/sbin/goaccess-daily-report.sh << SCRIPTEOF
#!/usr/bin/env bash
# GoAccess daily traffic report — managed by vps-security
set -uo pipefail

REPORT_DIR="/var/www/html/reports"
REPORT_TITLE="${SERVER_HOSTNAME} - Traffic Report"

LOGS=\$(ls /var/log/apache2/*-access.log /var/log/apache2/access.log /var/log/apache2/other_vhosts_access.log 2>/dev/null | head -20)

if [[ -z "\$LOGS" ]]; then
    echo "No Apache access logs found."
    exit 0
fi

# shellcheck disable=SC2086
cat \$LOGS | goaccess \
    --log-format=COMBINED \
    --no-global-config \
    --output="\$REPORT_DIR/traffic-report.html" \
    --html-report-title="\$REPORT_TITLE" \
    2>/dev/null

echo "Report generated: \$REPORT_DIR/traffic-report.html"
SCRIPTEOF
    chmod +x /usr/local/sbin/goaccess-daily-report.sh
    GOACCESS_CRON="0 4 * * * /usr/local/sbin/goaccess-daily-report.sh >> /var/log/goaccess-cron.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "goaccess-daily-report"; echo "$GOACCESS_CRON") | crontab -
else
    echo "  [dry-run] Would write /usr/local/sbin/goaccess-daily-report.sh"
    echo "  [dry-run] Would add GoAccess cron at 4 AM daily"
fi
echo "  -> GoAccess daily cron scheduled (4 AM)."

# --- 4/5: Secure reports directory ---
echo ""
echo "[4/5] Securing reports directory with HTTP Basic Auth..."
REPORT_PASS=$(openssl rand -base64 12)
if ! $DRYRUN; then
    htpasswd -cb /etc/apache2/.htpasswd-reports admin "$REPORT_PASS" 2>/dev/null
    cat > /var/www/html/reports/.htaccess << 'HTEOF'
AuthType Basic
AuthName "Server Reports"
AuthUserFile /etc/apache2/.htpasswd-reports
Require valid-user
HTEOF
    echo "  -> Username: admin"
    echo "  -> Password: $REPORT_PASS"
else
    echo "  [dry-run] Would create /etc/apache2/.htpasswd-reports"
    echo "  [dry-run] Would write /var/www/html/reports/.htaccess"
fi

# --- 5/5: Initial report ---
echo ""
echo "[5/5] Generating initial GoAccess report..."
if ! $DRYRUN; then
    /usr/local/sbin/goaccess-daily-report.sh
else
    echo "  [dry-run] Would run /usr/local/sbin/goaccess-daily-report.sh"
fi

# --- Done ---
echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Log monitoring setup complete!"
    echo ""
    echo "  Logwatch: daily digest to $ADMIN_EMAIL"
    echo "  GoAccess: 4 AM daily, /var/www/html/reports/"
    echo ""
    echo "  Test delivery:"
    echo "    /usr/local/sbin/goaccess-daily-report.sh"
fi
echo "========================================="
