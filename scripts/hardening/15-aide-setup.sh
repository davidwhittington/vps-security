#!/usr/bin/env bash
# 15-aide-setup.sh — AIDE file integrity monitoring setup
#
# Installs and configures AIDE (Advanced Intrusion Detection Environment):
#   - Installs aide
#   - Writes a focused AIDE config covering critical system paths
#   - Initializes the AIDE database
#   - Schedules weekly Sunday 4 AM check with email alert on changes
#   - Backs up any existing AIDE config before modifying
#
# Usage:
#   bash scripts/hardening/15-aide-setup.sh
#   bash scripts/hardening/15-aide-setup.sh --dry-run
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

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
fi

ADMIN_EMAIL="${ADMIN_EMAIL:-root}"
STEPS=4

echo "========================================="
echo "  AIDE File Integrity Monitoring"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

# [1/4] Install AIDE
echo "[1/${STEPS}] Installing AIDE..."
cmd apt-get install -y aide aide-common
echo "  Done."

# [2/4] Write AIDE config
echo "[2/${STEPS}] Writing AIDE configuration..."

AIDE_CONF="/etc/aide/aide.conf.d/99-vps-security.conf"
cmd mkdir -p /etc/aide/aide.conf.d

if ! $DRYRUN; then
    # Backup existing main config if present
    if [[ -f /etc/aide/aide.conf ]]; then
        cp /etc/aide/aide.conf /etc/aide/aide.conf.bak
    fi

    cat > "$AIDE_CONF" << 'EOF'
# vps-security AIDE configuration
# Monitors critical system files for unauthorized changes.
# Attributes checked: p=permissions, i=inode, n=link count, u=uid, g=gid,
#                     s=size, m=mtime, c=ctime, md5=MD5, sha256=SHA-256

# Define check groups
NORMAL = p+i+n+u+g+s+m+c+md5+sha256
PERMS  = p+i+n+u+g

# Critical system binaries and libraries
/bin            NORMAL
/sbin           NORMAL
/usr/bin        NORMAL
/usr/sbin       NORMAL
/lib            NORMAL
/lib64          NORMAL
/usr/lib        NORMAL

# Configuration files
/etc            NORMAL
!/etc/mtab
!/etc/aide
!/etc/aide.conf.d
!/etc/random-seed
!/etc/.pwd.lock

# Bootloader and kernel
/boot           NORMAL

# SSH configuration (high-value target)
/etc/ssh        NORMAL

# Sudoers
/etc/sudoers    NORMAL
/etc/sudoers.d  NORMAL

# PAM configuration
/etc/pam.d      NORMAL

# Cron directories
/etc/cron.d     NORMAL
/etc/crontab    NORMAL
/etc/cron.daily    NORMAL
/etc/cron.weekly   NORMAL
/etc/cron.monthly  NORMAL

# Web server config (but not web roots — too many legitimate changes)
/etc/apache2    NORMAL

# Fail2ban config
/etc/fail2ban   NORMAL

# vps-security scripts installed to sbin
/usr/local/sbin NORMAL

# Explicitly ignore high-churn paths
!/var
!/tmp
!/proc
!/sys
!/run
!/dev
EOF
    echo "  Written: ${AIDE_CONF}"
else
    echo "  [dry-run] Would write: ${AIDE_CONF}"
fi

# [3/4] Initialize AIDE database
echo "[3/${STEPS}] Initializing AIDE database (this may take several minutes)..."
AIDE_DB="/var/lib/aide/aide.db"
AIDE_DB_NEW="/var/lib/aide/aide.db.new"

if $DRYRUN; then
    echo "  [dry-run] Would run: aideinit --yes"
    echo "  [dry-run] Would run: cp ${AIDE_DB_NEW} ${AIDE_DB}"
else
    mkdir -p /var/lib/aide
    if aideinit --yes 2>/dev/null; then
        if [[ -f "$AIDE_DB_NEW" ]]; then
            cp "$AIDE_DB_NEW" "$AIDE_DB"
            echo "  Database initialized: ${AIDE_DB}"
        else
            echo "  WARNING: aideinit ran but ${AIDE_DB_NEW} not found — check aide logs."
        fi
    else
        echo "  WARNING: aideinit exited non-zero — database may not be initialized."
        echo "  Run manually: aideinit --yes && cp ${AIDE_DB_NEW} ${AIDE_DB}"
    fi
fi

# [4/4] Schedule weekly check cron
echo "[4/${STEPS}] Scheduling weekly AIDE integrity check..."

AIDE_CHECK_SCRIPT="/usr/local/sbin/aide-weekly-check.sh"

if ! $DRYRUN; then
    cat > "$AIDE_CHECK_SCRIPT" << SCRIPT
#!/usr/bin/env bash
# aide-weekly-check.sh — weekly AIDE file integrity check with email alert
set -uo pipefail

ADMIN_EMAIL="${ADMIN_EMAIL}"
HOSTNAME="\$(hostname -f)"
DATE="\$(date '+%Y-%m-%d %H:%M %Z')"
LOG="/var/log/aide/aide-check-\$(date '+%Y%m%d').log"

mkdir -p /var/log/aide

# Run check; exit code 0=clean, 1=differences found, 2=error
aide --check > "\$LOG" 2>&1
EXIT_CODE=\$?

if [[ \$EXIT_CODE -eq 0 ]]; then
    echo "AIDE integrity check passed on \${HOSTNAME} at \${DATE}" | \
        mail -s "[OK] AIDE integrity check: \${HOSTNAME}" "\${ADMIN_EMAIL}" 2>/dev/null || true
elif [[ \$EXIT_CODE -eq 1 ]]; then
    {
        echo "AIDE detected file integrity changes on \${HOSTNAME} at \${DATE}."
        echo ""
        echo "Review the changes below carefully. If unexpected, investigate immediately."
        echo "========================================="
        cat "\$LOG"
    } | mail -s "[ALERT] AIDE integrity changes: \${HOSTNAME}" "\${ADMIN_EMAIL}" 2>/dev/null || true
else
    echo "AIDE check error (exit code \${EXIT_CODE}) on \${HOSTNAME} at \${DATE}. Check \${LOG}." | \
        mail -s "[ERROR] AIDE check failed: \${HOSTNAME}" "\${ADMIN_EMAIL}" 2>/dev/null || true
fi
SCRIPT
    chmod 700 "$AIDE_CHECK_SCRIPT"
    echo "  Written: ${AIDE_CHECK_SCRIPT}"
else
    echo "  [dry-run] Would write: ${AIDE_CHECK_SCRIPT}"
fi

CRON_LINE="0 4 * * 0 root ${AIDE_CHECK_SCRIPT}"
if $DRYRUN; then
    echo "  [dry-run] Would add to /etc/cron.d/aide-check: ${CRON_LINE}"
else
    echo "# vps-security: weekly AIDE integrity check (Sunday 4AM)" > /etc/cron.d/aide-check
    echo "$CRON_LINE" >> /etc/cron.d/aide-check
    chmod 644 /etc/cron.d/aide-check
    echo "  Cron scheduled: Sunday 4 AM"
fi

echo ""
echo "========================================="
echo "  AIDE setup complete."
echo ""
echo "  Database: /var/lib/aide/aide.db"
echo "  Config:   ${AIDE_CONF}"
echo "  Check:    ${AIDE_CHECK_SCRIPT}"
echo "  Cron:     Sunday 4 AM -> alerts to ${ADMIN_EMAIL}"
echo ""
echo "  Manual check: aide --check"
echo "  Update DB:    aide --update && cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
echo "========================================="
