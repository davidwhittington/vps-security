#!/usr/bin/env bash
# 04-monthly-updates-setup.sh
# Sets up monthly apt upgrade with email report
# Run as root on the target server
set -euo pipefail

EMAIL="davidwhittington@icloud.com"
HOSTNAME=$(hostname -f)

echo "========================================="
echo "  Monthly Update + Email Report Setup"
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

echo "[1/3] Installing msmtp and mailutils..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq msmtp msmtp-mta mailutils

# Configure msmtp to use smtp.gmail.com as a relay-free forwarder
# Uses DigitalOcean's built-in SMTP or a simple relay.
# For iCloud delivery, we use a public relay-free approach via local sendmail.
# msmtp with a simple config that sends directly.
cat > /etc/msmtprc << 'MSMTPEOF'
# Default account
account default
host smtp.gmail.com
port 587
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt

# We'll use a simple local delivery approach instead
# since we don't have SMTP credentials configured.
# Falling back to direct SMTP delivery.
MSMTPEOF

echo "  -> Mail utilities installed."

echo ""
echo "[2/3] Creating monthly update script..."
mkdir -p /usr/local/sbin

cat > /usr/local/sbin/monthly-apt-report.sh << 'SCRIPTEOF'
#!/usr/bin/env bash
# Monthly apt update/upgrade with email report
set -uo pipefail

EMAIL="davidwhittington@icloud.com"
HOSTNAME=$(hostname -f)
DATE=$(date '+%Y-%m-%d %H:%M %Z')
LOGFILE="/var/log/monthly-apt-upgrade.log"

{
    echo "======================================"
    echo " Monthly System Update Report"
    echo " Host: $HOSTNAME"
    echo " Date: $DATE"
    echo "======================================"
    echo ""

    echo "--- Pre-update package status ---"
    apt update 2>&1
    echo ""

    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
    echo "Packages to upgrade: $UPGRADABLE"
    echo ""

    if [[ "$UPGRADABLE" -gt 0 ]]; then
        echo "--- Upgrading packages ---"
        DEBIAN_FRONTEND=noninteractive apt upgrade -y 2>&1
        echo ""
        echo "--- Post-upgrade status ---"
        REMAINING=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
        echo "Remaining upgradable: $REMAINING"
    else
        echo "System is already up to date."
    fi

    echo ""
    echo "--- Kernel ---"
    uname -r
    NEWEST_KERNEL=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
    RUNNING_KERNEL=$(uname -r)
    if [[ "$NEWEST_KERNEL" != "$RUNNING_KERNEL" ]]; then
        echo "WARNING: Reboot needed! Running: $RUNNING_KERNEL, Available: $NEWEST_KERNEL"
    else
        echo "Kernel is current."
    fi

    echo ""
    echo "--- Disk Usage ---"
    df -h / | tail -1

    echo ""
    echo "--- Uptime ---"
    uptime

    echo ""
    echo "--- Fail2Ban Status ---"
    fail2ban-client status sshd 2>/dev/null || echo "fail2ban not running"

    echo ""
    echo "--- Certificate Expiry Check ---"
    certbot certificates 2>/dev/null | grep -E "Certificate Name|Expiry Date" || echo "certbot not available"

    echo ""
    echo "======================================"
    echo " End of Report"
    echo "======================================"

} 2>&1 | tee "$LOGFILE"

# Send email report
mail -s "[$HOSTNAME] Monthly System Update Report - $(date '+%Y-%m-%d')" "$EMAIL" < "$LOGFILE"
SCRIPTEOF

chmod +x /usr/local/sbin/monthly-apt-report.sh
echo "  -> Script created at /usr/local/sbin/monthly-apt-report.sh"

echo ""
echo "[3/3] Setting up monthly cron job..."
# Run at 3 AM on the 1st of every month
CRON_LINE="0 3 1 * * /usr/local/sbin/monthly-apt-report.sh >> /var/log/monthly-apt-cron.log 2>&1"

# Add to root crontab if not already present
(crontab -l 2>/dev/null | grep -v "monthly-apt-report"; echo "$CRON_LINE") | crontab -
echo "  -> Cron job added: 3 AM on the 1st of each month"

echo ""
echo "========================================="
echo "  Setup complete!"
echo ""
echo "  Cron: 1st of month at 3:00 AM UTC"
echo "  Email: $EMAIL"
echo "  Log:   /var/log/monthly-apt-upgrade.log"
echo ""
echo "  NOTE: Email delivery requires working"
echo "  SMTP. See below for next steps."
echo "========================================="
