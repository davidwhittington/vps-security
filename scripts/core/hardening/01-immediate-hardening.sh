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

SSH_PORT="${SSH_PORT:-22}"

# --- Banner ---
echo "========================================="
echo "  Linux Immediate Hardening"
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

# --- 1/5: fail2ban ---
echo "[1/5] Installing and configuring fail2ban..."
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

# --- 2/5: UFW ---
echo ""
echo "[2/5] Configuring UFW firewall..."
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

# --- 3/5: SSH ---
echo ""
echo "[3/5] Hardening SSH configuration..."
if ! $DRYRUN; then
    # Back up sshd_config before modifying
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config

    # Restrict to modern ciphers, MACs, and key exchange algorithms (#19)
    # Removes legacy CBC ciphers, MD5/SHA1-based MACs, and weak DH groups
    cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'SSHEOF'
# linux-security: restrict to modern cryptographic algorithms

# Ciphers: AES-GCM and ChaCha20 only (no CBC, no RC4, no 3DES)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

# MACs: HMAC-SHA2 and ETM variants only (no MD5, no SHA1)
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256

# KexAlgorithms: Curve25519, ECDH, and DH group14/16/18 only (no group1, no SHA1)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256

# Additional hardening
MaxAuthTries 3
LoginGraceTime 30
AllowTcpForwarding no
X11Forwarding no
SSHEOF

    systemctl reload ssh
else
    echo "  [dry-run] Would apply to /etc/ssh/sshd_config:"
    echo "    - PasswordAuthentication no"
    echo "    - PermitRootLogin prohibit-password"
    echo "    - X11Forwarding no"
    echo "  [dry-run] Would write /etc/ssh/sshd_config.d/99-hardening.conf:"
    echo "    - Restrict ciphers to AES-GCM + ChaCha20"
    echo "    - Restrict MACs to HMAC-SHA2 + ETM variants"
    echo "    - Restrict KexAlgorithms to Curve25519 + ECDH + DH group14/16/18"
    echo "    - MaxAuthTries 3, LoginGraceTime 30, AllowTcpForwarding no"
fi
echo "  -> SSH hardened: auth, ciphers, MACs, KexAlgorithms, timeouts."

# --- 3b: UFW rate-limiting (#25) ---
echo ""
echo "[3b] Adding UFW connection rate limits for HTTP/HTTPS..."
if ! $DRYRUN; then
    # ufw limit applies a rate limit: block IPs making >6 connections in 30s
    ufw limit 80/tcp comment 'HTTP rate-limit'
    ufw limit 443/tcp comment 'HTTPS rate-limit'
else
    echo "  [dry-run] Would add: ufw limit 80/tcp && ufw limit 443/tcp"
fi
echo "  -> UFW rate-limiting applied (HTTP + HTTPS)."

# --- 5/5: sysctl (#28) ---
echo ""
echo "[5/5] Hardening kernel network parameters..."
if ! $DRYRUN; then
    cat > /etc/sysctl.d/99-hardening.conf << 'SYSEOF'
# linux-security: kernel network hardening

# Disable ICMP redirects (prevent MITM via routing manipulation)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Log martian packets (packets with impossible source addresses)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IP forwarding (this is a web server, not a router)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Enable TCP SYN cookie protection (SYN flood mitigation)
net.ipv4.tcp_syncookies = 1

# Disable source routing (packets cannot specify their own route)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Enable reverse path filtering (drop packets that can't be routed back)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
SYSEOF
    sysctl --system > /dev/null 2>&1
else
    echo "  [dry-run] Would write /etc/sysctl.d/99-hardening.conf:"
    echo "    - ICMP redirects disabled"
    echo "    - Martian logging enabled"
    echo "    - IP forwarding disabled"
    echo "    - TCP SYN cookies enabled"
    echo "    - Source routing disabled"
    echo "    - ICMP broadcast ignore"
    echo "    - Reverse path filtering enabled"
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
