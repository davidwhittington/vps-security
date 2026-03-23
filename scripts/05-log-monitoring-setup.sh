#!/usr/bin/env bash
# 05-log-monitoring-setup.sh
# Installs and configures Logwatch + GoAccess for security log monitoring
# Run as root on the target server
set -euo pipefail

EMAIL="davidwhittington@icloud.com"
MAIL_FROM="george@jetsons.io"

echo "========================================="
echo "  Log Monitoring Setup"
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

echo "[1/5] Installing logwatch, goaccess, apache2-utils..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq logwatch goaccess apache2-utils

echo ""
echo "[2/5] Configuring Logwatch..."
mkdir -p /etc/logwatch/conf

cat > /etc/logwatch/conf/logwatch.conf << EOF
Output = mail
MailTo = $EMAIL
MailFrom = $MAIL_FROM
Detail = High
Range = yesterday
Service = All
Format = html
mailer = "/usr/bin/msmtp"
EOF
echo "  -> Logwatch configured (daily email via cron.daily)."

echo ""
echo "[3/5] Creating GoAccess daily report script..."
mkdir -p /var/www/html/reports /usr/local/sbin

cat > /usr/local/sbin/goaccess-daily-report.sh << 'SCRIPTEOF'
#!/usr/bin/env bash
set -uo pipefail

REPORT_DIR="/var/www/html/reports"

LOGS=$(ls /var/log/apache2/*-access.log /var/log/apache2/access.log /var/log/apache2/other_vhosts_access.log 2>/dev/null | head -20)

if [[ -z "$LOGS" ]]; then
    echo "No access logs found"
    exit 0
fi

cat $LOGS | goaccess \
    --log-format=COMBINED \
    --no-global-config \
    --output="$REPORT_DIR/traffic-report.html" \
    --html-report-title="server1.ipvegan.com - Traffic Report" \
    2>/dev/null

echo "Report generated: $REPORT_DIR/traffic-report.html"
SCRIPTEOF

chmod +x /usr/local/sbin/goaccess-daily-report.sh

GOACCESS_CRON="0 4 * * * /usr/local/sbin/goaccess-daily-report.sh >> /var/log/goaccess-cron.log 2>&1"
(crontab -l 2>/dev/null | grep -v "goaccess-daily-report"; echo "$GOACCESS_CRON") | crontab -
echo "  -> GoAccess daily cron added (4 AM UTC)."

echo ""
echo "[4/5] Securing reports directory with HTTP basic auth..."
REPORT_PASS=$(openssl rand -base64 12)
htpasswd -cb /etc/apache2/.htpasswd-reports admin "$REPORT_PASS" 2>/dev/null

cat > /var/www/html/reports/.htaccess << 'HTEOF'
AuthType Basic
AuthName "Server Reports"
AuthUserFile /etc/apache2/.htpasswd-reports
Require valid-user
HTEOF

echo "  -> Username: admin"
echo "  -> Password: $REPORT_PASS"

echo ""
echo "[5/5] Generating initial GoAccess report..."
/usr/local/sbin/goaccess-daily-report.sh

echo ""
echo "========================================="
echo "  Log monitoring setup complete!"
echo "========================================="
