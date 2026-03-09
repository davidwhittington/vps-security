#!/usr/bin/env bash
# 04-rkhunter-setup.sh — rkhunter installation and clean baseline
#
# Installs rkhunter, performs initial property update (baseline),
# configures email alerts, and schedules a weekly cron scan.
# Run as root on the target server after the system is in a known-good state.
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

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SERVER_HOSTNAME=$(hostname -f)

if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "ERROR: ADMIN_EMAIL is not set in config.env." >&2
    exit 1
fi

# --- Banner ---
echo "========================================="
echo "  rkhunter Setup"
echo "  Email:  $ADMIN_EMAIL"
echo "  Host:   $SERVER_HOSTNAME"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# --- 1/4: Install ---
echo "[1/4] Installing rkhunter..."
if ! $DRYRUN; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rkhunter
else
    echo "  [dry-run] Would install: rkhunter"
fi
echo "  -> rkhunter installed."

# --- 2/4: Configure ---
echo ""
echo "[2/4] Configuring rkhunter..."
if ! $DRYRUN; then
    # Set email for reports
    sed -i "s|^#*MAIL-ON-WARNING=.*|MAIL-ON-WARNING=\"${ADMIN_EMAIL}\"|" /etc/rkhunter.conf
    sed -i "s|^#*MAIL_CMD=.*|MAIL_CMD=mail|" /etc/rkhunter.conf

    # Allow package manager updates to not trigger false positives
    sed -i 's|^#*UPDATE_MIRRORS=.*|UPDATE_MIRRORS=1|' /etc/rkhunter.conf
    sed -i 's|^#*MIRRORS_MODE=.*|MIRRORS_MODE=0|' /etc/rkhunter.conf

    # Allow SSH root login (configured as prohibit-password, which rkhunter may warn about)
    # The SSH check in rkhunter looks for PermitRootLogin; our setting is correct
    sed -i 's|^#*ALLOW_SSH_ROOT_USER=.*|ALLOW_SSH_ROOT_USER=prohibit-password|' /etc/rkhunter.conf 2>/dev/null || true

    # Use SHA256 for file hashing
    sed -i 's|^#*HASH_CMD=.*|HASH_CMD=sha256sum|' /etc/rkhunter.conf 2>/dev/null || true
else
    echo "  [dry-run] Would configure /etc/rkhunter.conf:"
    echo "    - MAIL-ON-WARNING=$ADMIN_EMAIL"
    echo "    - UPDATE_MIRRORS=1"
    echo "    - ALLOW_SSH_ROOT_USER=prohibit-password"
    echo "    - HASH_CMD=sha256sum"
fi
echo "  -> rkhunter configured."

# --- 3/4: Baseline ---
echo ""
echo "[3/4] Running rkhunter database update and initial property check..."
if ! $DRYRUN; then
    # Update rkhunter database
    rkhunter --update --nocolors 2>/dev/null || true

    # Set baseline — captures current file hashes, so run ONLY on clean system
    echo "  Setting file property baseline (--propupd)..."
    rkhunter --propupd --nocolors 2>/dev/null
    echo "  -> Baseline set. Run 'rkhunter --check' to verify against baseline."
else
    echo "  [dry-run] Would run: rkhunter --update"
    echo "  [dry-run] Would run: rkhunter --propupd (baseline fingerprint)"
fi

# --- 4/4: Weekly cron ---
echo ""
echo "[4/4] Scheduling weekly rkhunter scan (Sundays at 3 AM)..."
CRON_LINE="0 3 * * 0 /usr/bin/rkhunter --cronjob --update --quiet 2>&1 | mail -s \"[${SERVER_HOSTNAME}] rkhunter weekly report\" ${ADMIN_EMAIL}"
if ! $DRYRUN; then
    (crontab -l 2>/dev/null | grep -v "rkhunter"; echo "$CRON_LINE") | crontab -
else
    echo "  [dry-run] Would add cron: $CRON_LINE"
fi
echo "  -> Cron scheduled: Sundays at 3:00 AM."

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  rkhunter setup complete!"
    echo ""
    echo "  Baseline:   Set (run only on clean system)"
    echo "  Schedule:   Sundays at 3:00 AM"
    echo "  Email:      $ADMIN_EMAIL"
    echo ""
    echo "  Manual check:  rkhunter --check --nocolors"
    echo "  Re-baseline:   rkhunter --propupd"
fi
echo "========================================="
