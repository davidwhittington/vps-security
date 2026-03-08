#!/usr/bin/env bash
# 03-setup-admin-user.sh
# Sets up the 'david' user as a proper admin with sudo access
# Run as root on the target server
set -euo pipefail

echo "========================================="
echo "  Admin User Setup Script"
echo "========================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

USERNAME="david"

echo "[1/4] Updating shell for $USERNAME..."
usermod -s /bin/bash "$USERNAME"
echo "  -> Shell set to /bin/bash."

echo ""
echo "[2/4] Adding $USERNAME to sudo group..."
usermod -aG sudo "$USERNAME"
echo "  -> Added to sudo group."

echo ""
echo "[3/4] Setting up SSH keys..."
HOMEDIR=$(eval echo "~$USERNAME")
mkdir -p "$HOMEDIR/.ssh"

if [[ -f /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "$HOMEDIR/.ssh/authorized_keys"
    echo "  -> Copied root's authorized_keys."
else
    echo "  WARNING: No root authorized_keys to copy. Add keys manually."
fi

chown -R "$USERNAME":"$USERNAME" "$HOMEDIR/.ssh"
chmod 700 "$HOMEDIR/.ssh"
chmod 600 "$HOMEDIR/.ssh/authorized_keys" 2>/dev/null || true
echo "  -> SSH directory permissions set."

echo ""
echo "[4/4] Cleaning up cloud-init sudoers..."
if [[ -f /etc/sudoers.d/90-cloud-init-users ]]; then
    rm /etc/sudoers.d/90-cloud-init-users
    echo "  -> Removed cloud-init NOPASSWD sudoers rule."
else
    echo "  -> No cloud-init sudoers rule found."
fi

echo ""
echo "========================================="
echo "  Admin user setup complete!"
echo ""
echo "  Test: ssh $USERNAME@$(hostname -f)"
echo "  Then: sudo -v"
echo ""
echo "  After confirming access, update SSH:"
echo "    PermitRootLogin no"
echo "========================================="
