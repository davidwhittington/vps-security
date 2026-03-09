#!/usr/bin/env bash
# 04-clamav-setup.sh — ClamAV installation and weekly web-root scan
#
# Installs ClamAV, updates virus definitions, creates a weekly scan
# script targeting /var/www, and schedules it via cron.
# Sends an email report when threats are detected.
# Run as root on the target server.
set -euo pipefail

# --- Dry-run support ---
DRYRUN=false
CONFIRM=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRYRUN=true
    [[ "$arg" == "--confirm" ]] && CONFIRM=true
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        echo "04-clamav-setup.sh — install ClamAV antivirus with daily web root scan"
        echo
        echo "Usage:"
        echo "  bash scripts/web/hardening/04-clamav-setup.sh [--dry-run] [--confirm]"
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

if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "ERROR: ADMIN_EMAIL is not set in config.env." >&2
    exit 1
fi

# --- Banner ---
echo "========================================="
echo "  ClamAV Setup"
echo "  Email:  $ADMIN_EMAIL"
echo "  Host:   $SERVER_HOSTNAME"
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

# --- 1/4: Install ---
echo "[1/4] Installing ClamAV..."
if ! $DRYRUN; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clamav clamav-daemon
else
    echo "  [dry-run] Would install: clamav clamav-daemon"
fi
echo "  -> ClamAV installed."

# --- 2/4: Update definitions ---
echo ""
echo "[2/4] Updating virus definitions (this may take a minute)..."
if ! $DRYRUN; then
    systemctl stop clamav-freshclam 2>/dev/null || true
    freshclam --quiet 2>/dev/null || echo "  WARNING: freshclam update had errors — definitions may be outdated"
    systemctl start clamav-freshclam 2>/dev/null || true
else
    echo "  [dry-run] Would run: freshclam (virus database update)"
fi
echo "  -> Virus definitions updated."

# --- 3/4: Scan script ---
echo ""
echo "[3/4] Creating weekly web-root scan script..."
if ! $DRYRUN; then
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/clamav-webroots-scan.sh << SCRIPTEOF
#!/usr/bin/env bash
# ClamAV weekly web-root scan — managed by vps-security
set -uo pipefail

EMAIL="${ADMIN_EMAIL}"
HOSTNAME=\$(hostname -f)
SCAN_DIR="/var/www"
LOG_FILE="/var/log/clamav-webroots-scan.log"
QUARANTINE_DIR="/var/lib/clamav-quarantine"

mkdir -p "\$QUARANTINE_DIR"
chmod 700 "\$QUARANTINE_DIR"

echo "=== ClamAV scan started: \$(date) ===" >> "\$LOG_FILE"

# Run scan — move infected files to quarantine
RESULT=\$(clamscan -r "\$SCAN_DIR" \
    --move="\$QUARANTINE_DIR" \
    --infected \
    --no-summary \
    2>/dev/null) || true

SUMMARY=\$(clamscan -r "\$SCAN_DIR" \
    --infected \
    --no-summary \
    2>/dev/null | tail -10) || true

INFECTED_COUNT=\$(echo "\$RESULT" | grep -c "FOUND" || true)

echo "\$RESULT" >> "\$LOG_FILE"
echo "=== Scan complete: \$(date) ===" >> "\$LOG_FILE"

if [[ "\$INFECTED_COUNT" -gt 0 ]]; then
    {
        echo "ClamAV THREAT DETECTED on \$HOSTNAME"
        echo "Date: \$(date)"
        echo "Infected files found: \$INFECTED_COUNT"
        echo ""
        echo "=== Infected files (moved to \$QUARANTINE_DIR) ==="
        echo "\$RESULT"
        echo ""
        echo "Investigate quarantined files:"
        echo "  ls -la \$QUARANTINE_DIR"
        echo "  clamscan --no-summary \$QUARANTINE_DIR"
    } | mail -s "[\$HOSTNAME] ClamAV ALERT: \${INFECTED_COUNT} threat(s) detected" "\$EMAIL"
    echo "Alert sent to \$EMAIL"
else
    echo "Scan clean — no threats found. Next check in 7 days."
fi
SCRIPTEOF
    chmod +x /usr/local/sbin/clamav-webroots-scan.sh
else
    echo "  [dry-run] Would write /usr/local/sbin/clamav-webroots-scan.sh"
    echo "    - Scans /var/www recursively"
    echo "    - Moves infected files to /var/lib/clamav-quarantine"
    echo "    - Emails $ADMIN_EMAIL on detection"
fi
echo "  -> Scan script created."

# --- 4/4: Weekly cron ---
echo ""
echo "[4/4] Scheduling weekly ClamAV scan (Saturdays at 2 AM)..."
CRON_LINE="0 2 * * 6 /usr/local/sbin/clamav-webroots-scan.sh >> /var/log/clamav-webroots-scan.log 2>&1"
if ! $DRYRUN; then
    (crontab -l 2>/dev/null | grep -v "clamav-webroots-scan"; echo "$CRON_LINE") | crontab -
else
    echo "  [dry-run] Would add cron: $CRON_LINE"
fi
echo "  -> Cron scheduled: Saturdays at 2:00 AM."

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  ClamAV setup complete!"
    echo ""
    echo "  Schedule:   Saturdays at 2:00 AM"
    echo "  Scan root:  /var/www"
    echo "  Quarantine: /var/lib/clamav-quarantine"
    echo "  Log:        /var/log/clamav-webroots-scan.log"
    echo "  Email:      $ADMIN_EMAIL"
    echo ""
    echo "  Test now:   /usr/local/sbin/clamav-webroots-scan.sh"
fi
echo "========================================="
