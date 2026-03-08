#!/usr/bin/env bash
# 01-immediate-hardening.sh
# Firewall (UFW), SSH hardening, fail2ban (SSH + Apache jails), sysctl
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

SSH_PORT="${SSH_PORT:-22}"

# --- Banner ---
echo "========================================="
echo "  VPS Immediate Hardening"
echo "  Host: $(hostname -f)"
if $DRYRUN; then echo "  MODE: DRY RUN — no changes will be made"; fi
echo "========================================="
echo ""

# --- Pre-flight ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [[ ! -f /root/.ssh/authorized_keys ]] || [[ ! -s /root/.ssh/authorized_keys ]]; then
    echo "ERROR: No SSH authorized_keys found for root." >&2
    echo "  Add your public key first: ssh-copy-id root@$(hostname -f)" >&2
    exit 1
fi

# --- 1/4: fail2ban ---
echo "[1/4] Installing and configuring fail2ban..."
if ! $DRYRUN; then
    apt-get update -qq
    apt-get install -y -qq fail2ban
fi

if ! $DRYRUN; then
    cat > /etc/fail2ban/jail.local << JAILEOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
banaction = iptables-multiport

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3

[apache-auth]
enabled  = true
port     = http,https
filter   = apache-auth
logpath  = /var/log/apache2/*error.log
maxretry = 3

[apache-badbots]
enabled  = true
port     = http,https
filter   = apache-badbots
logpath  = /var/log/apache2/*access.log
bantime  = 86400
maxretry = 1

[apache-noscript]
enabled  = true
port     = http,https
filter   = apache-noscript
logpath  = /var/log/apache2/*access.log
maxretry = 3
JAILEOF
else
    echo "  [dry-run] Would write /etc/fail2ban/jail.local"
    echo "    - SSH jail on port ${SSH_PORT}"
    echo "    - apache-auth jail"
    echo "    - apache-badbots jail (1-strike, 24h ban)"
    echo "    - apache-noscript jail"
fi

cmd systemctl enable --now fail2ban
echo "  -> fail2ban configured (SSH + Apache jails)."

# --- 2/4: UFW ---
echo ""
echo "[2/4] Configuring UFW firewall..."
if ! $DRYRUN; then
    apt-get install -y -qq ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw --force enable
    echo "  -> UFW enabled. Rules:"
    ufw status numbered
else
    echo "  [dry-run] Would configure UFW:"
    echo "    - default deny incoming"
    echo "    - allow ${SSH_PORT}/tcp (SSH)"
    echo "    - allow 80/tcp (HTTP)"
    echo "    - allow 443/tcp (HTTPS)"
fi

# --- 3/4: SSH ---
echo ""
echo "[3/4] Hardening SSH configuration..."
if ! $DRYRUN; then
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config
    systemctl reload ssh
else
    echo "  [dry-run] Would apply to /etc/ssh/sshd_config:"
    echo "    - PasswordAuthentication no"
    echo "    - PermitRootLogin prohibit-password"
    echo "    - X11Forwarding no"
fi
echo "  -> SSH: password auth off, root key-only, X11 off."

# --- 4/4: sysctl ---
echo ""
echo "[4/4] Hardening kernel network parameters..."
if ! $DRYRUN; then
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
else
    echo "  [dry-run] Would write /etc/sysctl.d/99-hardening.conf (ICMP redirects, martian logging)"
fi
echo "  -> Kernel network parameters hardened."

# --- Done ---
echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  Immediate hardening complete!"
    echo ""
    echo "  IMPORTANT: Test SSH access in a new"
    echo "  terminal before closing this session."
fi
echo "========================================="
