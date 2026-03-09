#!/usr/bin/env bash
# 03-monthly-updates-setup.sh
# Scheduled apt upgrade with emailed report via msmtp. Runs 1st of month, 3 AM.
# Run as root on the target server.
set -euo pipefail

# --- Dry-run support ---
DRYRUN=false
CONFIRM=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRYRUN=true
    [[ "$arg" == "--confirm" ]] && CONFIRM=true
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        echo "03-monthly-updates-setup.sh — schedule monthly unattended security updates and email reports"
        echo
        echo "Usage:"
        echo "  bash scripts/core/hardening/03-monthly-updates-setup.sh [--dry-run] [--confirm]"
        echo
        echo "Flags:"
        echo "  --dry-run   Preview all changes without applying anything"
        echo "  --confirm   Skip the interactive confirmation prompt"
        echo "  --help      Show this help and exit"
        exit 0
    fi
done

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

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SERVER_HOSTNAME=$(hostname -f)

if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "ERROR: ADMIN_EMAIL is not set in config.env." >&2
    exit 1
fi

# --- Banner ---
echo "========================================="
echo "  Monthly Update + Email Report Setup"
echo "  Email: $ADMIN_EMAIL"
echo "  Host:  $SERVER_HOSTNAME"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

require_confirm() {
    $CONFIRM && return
    $DRYRUN && return
    echo ""
    printf "  Type AGREE to continue or Ctrl+C to abort: "
    read -r _CONFIRM_REPLY
    [[ "$_CONFIRM_REPLY" == "AGREE" ]] || { echo "Aborted."; exit 0; }
}

require_confirm

# --- 1/3: Install mail tools ---
echo "[1/3] Installing msmtp and mailutils..."
if ! $DRYRUN; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq msmtp msmtp-mta mailutils
    cat > /etc/msmtprc << MSMTPEOF
account default
host ${SMTP_HOST}
port ${SMTP_PORT}
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
$(if [[ -n "$SMTP_USER" ]]; then
    echo "auth on"
    echo "user ${SMTP_USER}"
    echo "password ${SMTP_PASS}"
    echo "from ${SMTP_USER}"
fi)
MSMTPEOF
    chmod 600 /etc/msmtprc
else
    echo "  [dry-run] Would install msmtp, msmtp-mta, mailutils"
    echo "  [dry-run] Would write /etc/msmtprc (host: $SMTP_HOST:$SMTP_PORT)"
fi
echo "  -> Mail utilities configured."

# --- 2/3: Create monthly report script ---
echo ""
echo "[2/3] Creating monthly update script..."
if ! $DRYRUN; then
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/monthly-apt-report.sh << SCRIPTEOF
#!/usr/bin/env bash
# Monthly apt update/upgrade with email report — managed by vps-security
set -uo pipefail

EMAIL="${ADMIN_EMAIL}"
HOSTNAME=\$(hostname -f)
DATE=\$(date '+%Y-%m-%d %H:%M %Z')
LOGFILE="/var/log/monthly-apt-upgrade.log"

{
    echo "======================================"
    echo " Monthly System Update Report"
    echo " Host: \$HOSTNAME"
    echo " Date: \$DATE"
    echo "======================================"
    echo ""

    echo "--- Pre-update package status ---"
    apt update 2>&1
    echo ""

    UPGRADABLE=\$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
    echo "Packages to upgrade: \$UPGRADABLE"
    echo ""

    if [[ "\$UPGRADABLE" -gt 0 ]]; then
        echo "--- Upgrading packages ---"
        DEBIAN_FRONTEND=noninteractive apt upgrade -y 2>&1
        echo ""
        echo "--- Post-upgrade status ---"
        REMAINING=\$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
        echo "Remaining upgradable: \$REMAINING"
    else
        echo "System is already up to date."
    fi

    echo ""
    echo "--- Kernel ---"
    uname -r
    NEWEST_KERNEL=\$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
    RUNNING_KERNEL=\$(uname -r)
    if [[ "\$NEWEST_KERNEL" != "\$RUNNING_KERNEL" ]]; then
        echo "WARNING: Reboot needed — Running: \$RUNNING_KERNEL  Available: \$NEWEST_KERNEL"
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
    echo "--- Certificate Expiry ---"
    certbot certificates 2>/dev/null | grep -E "Certificate Name|Expiry Date" || echo "certbot not available"

    echo ""
    echo "======================================"
    echo " End of Report"
    echo "======================================"

} 2>&1 | tee "\$LOGFILE"

mail -s "[\$HOSTNAME] Monthly Update Report - \$(date '+%Y-%m-%d')" "\$EMAIL" < "\$LOGFILE"
SCRIPTEOF
    chmod +x /usr/local/sbin/monthly-apt-report.sh
else
    echo "  [dry-run] Would write /usr/local/sbin/monthly-apt-report.sh"
    echo "    - apt upgrade, kernel check, disk, uptime, fail2ban, cert expiry"
    echo "    - emails to $ADMIN_EMAIL"
fi
echo "  -> Report script created."

# --- 3/3: Cron ---
echo ""
echo "[3/3] Scheduling monthly cron job (3 AM on 1st of month)..."
CRON_LINE="0 3 1 * * /usr/local/sbin/monthly-apt-report.sh >> /var/log/monthly-apt-cron.log 2>&1"
if ! $DRYRUN; then
    (crontab -l 2>/dev/null | grep -v "monthly-apt-report"; echo "$CRON_LINE") | crontab -
else
    echo "  [dry-run] Would add cron: $CRON_LINE"
fi
echo "  -> Cron job scheduled."

# --- Done ---
echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Monthly update setup complete!"
    echo ""
    echo "  Schedule: 1st of month at 3:00 AM"
    echo "  Email:    $ADMIN_EMAIL"
    echo "  Log:      /var/log/monthly-apt-upgrade.log"
    echo ""
    echo "  Test delivery:"
    echo "    /usr/local/sbin/monthly-apt-report.sh"
fi
echo "========================================="
