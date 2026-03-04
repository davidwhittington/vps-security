#!/usr/bin/env bash
# 01-immediate-hardening.sh
# Addresses CRITICAL findings: firewall, fail2ban, SSH hardening
# Run as root on the target server
set -euo pipefail

echo "========================================="
echo "  VPS Immediate Hardening Script"
echo "  Target: server1.ipvegan.com"
echo "========================================="
echo ""

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# Ensure an SSH key exists before locking out password auth
if [[ ! -f /root/.ssh/authorized_keys ]] || [[ ! -s /root/.ssh/authorized_keys ]]; then
    echo "WARNING: No SSH authorized_keys found for root!"
    echo "Add your SSH public key before running this script."
    echo "  ssh-copy-id root@$(hostname -f)"
    exit 1
fi

echo "[1/4] Installing fail2ban..."
apt-get update -qq
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local << 'JAILEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = iptables-multiport

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
JAILEOF

systemctl enable --now fail2ban
echo "  -> fail2ban installed and running."

echo ""
echo "[2/4] Configuring UFW firewall..."
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
echo "  -> UFW enabled. Rules:"
ufw status numbered

echo ""
echo "[3/4] Hardening SSH configuration..."
# Disable password authentication
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/50-cloud-init.conf

# Disable root login (key-only via prohibit-password if you still need root SSH)
sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Disable X11 forwarding
sed -i 's/^X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config

systemctl reload sshd
echo "  -> SSH hardened: password auth disabled, root login key-only, X11 forwarding off."

echo ""
echo "[4/4] Hardening kernel network parameters..."
cat > /etc/sysctl.d/99-hardening.conf << 'SYSEOF'
# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
SYSEOF

sysctl --system > /dev/null 2>&1
echo "  -> Kernel network parameters hardened."

echo ""
echo "========================================="
echo "  Immediate hardening complete!"
echo ""
echo "  IMPORTANT: Test SSH access in a new"
echo "  terminal before closing this session."
echo "========================================="
