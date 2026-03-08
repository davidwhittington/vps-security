#!/usr/bin/env bash
# 03-setup-admin-user.sh
# Promotes an existing user to sudo admin, copies SSH keys, removes cloud-init sudoers.
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

ADMIN_USER="${ADMIN_USER:-}"
if [[ -z "$ADMIN_USER" ]]; then
    echo "ERROR: ADMIN_USER is not set in config.env." >&2
    echo "  Set ADMIN_USER=youruser and re-run." >&2
    exit 1
fi

# --- Banner ---
echo "========================================="
echo "  Admin User Setup"
echo "  User: $ADMIN_USER"
echo "  Host: $(hostname -f)"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if ! id "$ADMIN_USER" &>/dev/null; then
    echo "ERROR: User '$ADMIN_USER' does not exist. Create it first:" >&2
    echo "  adduser $ADMIN_USER" >&2
    exit 1
fi

# --- 1/4: Shell ---
echo "[1/4] Setting login shell to /bin/bash..."
cmd usermod -s /bin/bash "$ADMIN_USER"
echo "  -> Shell set."

# --- 2/4: sudo ---
echo ""
echo "[2/4] Adding $ADMIN_USER to sudo group..."
cmd usermod -aG sudo "$ADMIN_USER"
echo "  -> Added to sudo group."

# --- 3/4: SSH keys ---
echo ""
echo "[3/4] Setting up SSH keys..."
HOMEDIR=$(eval echo "~$ADMIN_USER")
if ! $DRYRUN; then
    mkdir -p "$HOMEDIR/.ssh"
    if [[ -f /root/.ssh/authorized_keys ]]; then
        cp /root/.ssh/authorized_keys "$HOMEDIR/.ssh/authorized_keys"
        echo "  -> Copied root's authorized_keys."
    else
        echo "  WARNING: No root authorized_keys to copy. Add keys manually."
    fi
    chown -R "$ADMIN_USER":"$ADMIN_USER" "$HOMEDIR/.ssh"
    chmod 700 "$HOMEDIR/.ssh"
    chmod 600 "$HOMEDIR/.ssh/authorized_keys" 2>/dev/null || true
else
    echo "  [dry-run] Would create $HOMEDIR/.ssh"
    echo "  [dry-run] Would copy /root/.ssh/authorized_keys"
    echo "  [dry-run] Would set ownership and permissions"
fi
echo "  -> SSH directory configured."

# --- 4/4: cloud-init sudoers ---
echo ""
echo "[4/4] Removing cloud-init NOPASSWD sudoers rule..."
if [[ -f /etc/sudoers.d/90-cloud-init-users ]]; then
    cmd rm /etc/sudoers.d/90-cloud-init-users
    echo "  -> Removed cloud-init NOPASSWD rule."
else
    echo "  -> No cloud-init sudoers rule found."
fi

# --- Done ---
echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Admin user setup complete!"
    echo ""
    echo "  Test SSH:  ssh $ADMIN_USER@$(hostname -f)"
    echo "  Test sudo: sudo -v"
    echo ""
    echo "  Once confirmed, set PermitRootLogin no in sshd_config."
fi
echo "========================================="
