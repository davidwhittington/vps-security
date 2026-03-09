#!/usr/bin/env bash
# 14-fail2ban-recidive.sh — fail2ban recidive jail (permanent bans for repeat offenders)
#
# Adds the recidive jail to fail2ban: any IP that gets banned 5+ times
# across any jail within 12 hours receives a 1-week ban.
# Also adds optional SSH login email notification via PAM.
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
    echo "  WARNING: config.env not found — using defaults."
fi

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SERVER_HOSTNAME=$(hostname -f)

# --- Banner ---
echo "========================================="
echo "  fail2ban Recidive Jail + SSH Login Alerts"
echo "  Host: $SERVER_HOSTNAME"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if ! command -v fail2ban-client &>/dev/null; then
    echo "ERROR: fail2ban not installed. Run 01-immediate-hardening.sh first." >&2
    exit 1
fi

# --- 1/3: Recidive jail ---
echo "[1/3] Configuring fail2ban recidive jail..."
if ! $DRYRUN; then
    cat > /etc/fail2ban/jail.d/recidive.conf << 'RECEOF'
# vps-security: recidive jail — permanent bans for repeat offenders
# Managed by 14-fail2ban-recidive.sh

[recidive]
enabled   = true
logpath   = /var/log/fail2ban.log
banaction = iptables-allports
bantime   = 604800    ; 1 week
findtime  = 43200     ; 12 hours
maxretry  = 5
filter    = recidive
RECEOF
else
    echo "  [dry-run] Would write /etc/fail2ban/jail.d/recidive.conf:"
    echo "    - bantime: 604800s (1 week)"
    echo "    - findtime: 43200s (12 hours)"
    echo "    - maxretry: 5 bans in any jail"
fi
echo "  -> Recidive jail configured."

# --- 2/3: SSH login email notification ---
echo ""
echo "[2/3] Configuring SSH login email notification..."
if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "  SKIP: ADMIN_EMAIL not set — skipping SSH login alerts"
else
    if ! $DRYRUN; then
        cat > /etc/ssh/sshrc << SSHEOF
#!/bin/sh
# SSH login notification — managed by vps-security
ALERT_EMAIL="${ADMIN_EMAIL}"
IP=\$(echo "\$SSH_CONNECTION" | awk '{print \$1}')
HOST=\$(hostname -f)
USER_NAME=\$(whoami)
echo "SSH login on \$HOST
User:    \$USER_NAME
From IP: \$IP
Date:    \$(date)
" | mail -s "[\$HOST] SSH login: \$USER_NAME from \$IP" "\$ALERT_EMAIL" 2>/dev/null || true
SSHEOF
        chmod 755 /etc/ssh/sshrc
    else
        echo "  [dry-run] Would write /etc/ssh/sshrc for SSH login alerts to $ADMIN_EMAIL"
    fi
    echo "  -> SSH login notification configured."
fi

# --- 3/3: Reload fail2ban ---
echo ""
echo "[3/3] Reloading fail2ban..."
cmd systemctl reload fail2ban
cmd fail2ban-client status recidive 2>/dev/null || \
    echo "  NOTE: recidive jail status check failed — it may take a moment to activate"
echo "  -> fail2ban reloaded."

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Recidive jail + SSH alerts setup complete!"
    echo ""
    echo "  Recidive: /etc/fail2ban/jail.d/recidive.conf"
    echo "  SSH alert: /etc/ssh/sshrc"
    echo ""
    echo "  Check status:  fail2ban-client status recidive"
    echo "  View bans:     fail2ban-client status recidive"
fi
echo "========================================="
