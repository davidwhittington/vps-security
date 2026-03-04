# VPS Security Audit Report

**Target:** `159.198.64.231` (`server1.ipvegan.com`)
**OS:** Ubuntu 24.04.3 LTS (Noble Numbat)
**Kernel:** 6.8.0-90-generic
**Web Server:** Apache 2.4.58
**Audit Date:** 2026-03-04
**Uptime:** 35 days

---

## Executive Summary

The server is **actively under brute-force attack** with no intrusion prevention system in place. The most critical issues are: **no firewall is enabled**, **fail2ban is not installed**, and **SSH allows root login with password authentication**. These three issues together mean any attacker can endlessly attempt root password guesses with zero rate limiting or blocking.

Apache is configured with reasonable TLS (via Certbot) but exposes server version information, lacks security headers, and has the `mod_status` module loaded. Several virtual hosts lack explicit directory security directives.

**Overall Risk Posture: HIGH** — The server requires immediate hardening, particularly around SSH, firewall, and intrusion detection.

---

## Findings

### CRITICAL

#### C1. No Firewall Active
- **UFW Status:** Inactive
- **iptables:** All chains set to ACCEPT with zero rules
- **Impact:** Every service on the server is directly exposed to the internet with no packet filtering whatsoever.

#### C2. No Fail2Ban / Intrusion Prevention
- **fail2ban** is not installed.
- **Active brute-force attacks observed** in `/var/log/auth.log` — multiple IPs hammering SSH (e.g., `45.148.10.151`, `119.18.52.5`, `176.120.22.47`, `80.94.92.63`) with dozens of failed root login attempts in the last hour alone.
- **Impact:** Attackers can attempt unlimited password guesses against SSH with no blocking mechanism.

#### C3. SSH Root Login with Password Enabled
- `PermitRootLogin yes` in `/etc/ssh/sshd_config`
- `PasswordAuthentication yes` (also enforced by `/etc/ssh/sshd_config.d/50-cloud-init.conf`)
- **Impact:** Combined with C1 and C2, this is the most dangerous configuration — remote attackers can brute-force the root password directly.

### HIGH

#### H1. SSH Password Authentication Enabled
- Password authentication is enabled globally, not restricted to key-only.
- **Recommendation:** Disable password auth and enforce key-based authentication.

#### H2. Apache Server Information Disclosure
- `ServerTokens OS` — exposes OS type in HTTP headers (e.g., `Apache/2.4.58 (Ubuntu)`)
- `ServerSignature On` — displays server version on error pages
- **Impact:** Gives attackers exact version info for targeted exploits.

#### H3. No Security Headers
- `mod_headers` is **not enabled**
- Missing headers: `X-Content-Type-Options`, `X-Frame-Options`, `Content-Security-Policy`, `Strict-Transport-Security` (HSTS), `Referrer-Policy`, `Permissions-Policy`
- **Impact:** Sites are vulnerable to clickjacking, MIME-sniffing attacks, and lack HSTS protection.

#### H4. mod_status Loaded
- The `status_module` is loaded, which can expose server operational details at `/server-status` if accessible.
- **Recommendation:** Disable or restrict to localhost only.

#### H5. Version Control Directories Not Blocked
- `.git` / `.svn` directory access is commented out in `security.conf`:
  ```
  #RedirectMatch 404 /\.git
  #RedirectMatch 404 /\.svn
  ```
- **Impact:** If any `.git` directory exists in a web root, the entire source code and history could be downloaded.

#### H6. Ubuntu User Has Passwordless Sudo
- `/etc/sudoers.d/90-cloud-init-users`: `ubuntu ALL=(ALL) NOPASSWD:ALL`
- The `ubuntu` user does not appear to have a login shell (not in passwd with shell), but this rule is overly permissive.

### MEDIUM

#### M1. X11 Forwarding Enabled
- `X11Forwarding yes` in sshd_config — unnecessary on a headless server.

#### M2. ICMP Redirects Accepted
- `net.ipv4.conf.all.accept_redirects = 1` (should be 0)
- `net.ipv4.conf.all.send_redirects = 1` (should be 0)
- `net.ipv6.conf.all.accept_redirects = 1` (should be 0)
- `net.ipv4.conf.all.log_martians = 0` (should be 1)
- **Impact:** Potential for MITM via ICMP redirect attacks; spoofed packets not logged.

#### M3. Pending System Updates
- **29+ packages** awaiting upgrade, including `systemd`, `linux-firmware`, `libldap`, `util-linux` components.
- Unattended-upgrades is configured and active, which is good, but the pending backlog should be cleared.

#### M4. Some Virtual Hosts Lack Directory Restrictions
- Several vhosts (e.g., `6kdave`, `shabezo`, `commodorecaverns`, `cosmicllama`, `theatariclub`) have no explicit `<Directory>` block with `Options -Indexes`.
- Only `beta.ipvegan.com` and `docs.ipvegan.com` explicitly set `Options -Indexes`.
- **Impact:** Directory listing may be enabled for sites that rely on Apache's global defaults.

#### M5. TLS Certificates Expiring in 34-38 Days
- Certbot auto-renewal timer is active (`snap.certbot.renew.timer`), which should handle renewals.
- Several certificates (marielly.net at 34 days, commodorecaverns.com at 36 days, etc.) will need renewal soon.
- **Recommendation:** Verify auto-renewal works: `certbot renew --dry-run`

#### M6. Default SSH Port
- SSH is running on default port 22, making it an easy target for automated scanners.
- Moving to a non-standard port reduces noise (security through obscurity, not a fix alone).

### LOW

#### L1. No Dedicated Admin User
- `david` user exists with `/bin/sh` shell but is not in sudoers.
- Server administration appears to be done as `root` directly.
- **Recommendation:** Create a proper admin user with sudo access; disable direct root login.

#### L2. Duplicate SSL VirtualHost for davidwhittington.com
- Port 443 is defined in both `davidwhittington.conf` and `davidwhittington-le-ssl.conf`, which could cause configuration conflicts.

### INFO

#### I1. Good: TLS Configuration
- Certbot's `options-ssl-apache.conf` enforces TLS 1.2+ with strong ciphers (ECDHE + AES-GCM/CHACHA20).
- All sites use Let's Encrypt with ECDSA keys.

#### I2. Good: Unattended Upgrades Active
- `unattended-upgrades` is installed and configured for automatic security updates.

#### I3. Good: No World-Writable Files in Web Roots
- No world-writable files found under `/var/www/`.

#### I4. Good: Standard SUID Binaries Only
- All SUID/SGID binaries are standard system utilities within snap packages. No suspicious SUID binaries.

#### I5. Good: IP Forwarding Disabled
- `net.ipv4.ip_forward = 0` — correct for a non-router.

#### I6. Good: SYN Cookies Enabled
- `net.ipv4.tcp_syncookies = 1` — protects against SYN flood attacks.

#### I7. NewRelic Monitoring Active
- `newrelic-infra` agent and `fluent-bit` are running for monitoring/logging.

---

## Prioritized Recommendations

### Immediate (Do Today)

1. **Install and configure fail2ban**
   ```bash
   apt install -y fail2ban
   cat > /etc/fail2ban/jail.local << 'EOF'
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
   EOF
   systemctl enable --now fail2ban
   ```

2. **Enable UFW firewall**
   ```bash
   ufw default deny incoming
   ufw default allow outgoing
   ufw allow 22/tcp    # SSH (change if moving SSH port)
   ufw allow 80/tcp    # HTTP
   ufw allow 443/tcp   # HTTPS
   ufw enable
   ```

3. **Disable SSH root login and password authentication**
   ```bash
   # First ensure your SSH key is in /root/.ssh/authorized_keys or a sudo user
   sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
   sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
   echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/50-cloud-init.conf
   systemctl reload sshd
   ```

### This Week

4. **Harden Apache**
   ```bash
   # Enable headers module
   a2enmod headers

   # Update security.conf
   cat > /etc/apache2/conf-enabled/security.conf << 'EOF'
   ServerTokens Prod
   ServerSignature Off
   TraceEnable Off
   RedirectMatch 404 /\.git
   RedirectMatch 404 /\.svn

   <IfModule mod_headers.c>
       Header always set X-Content-Type-Options "nosniff"
       Header always set X-Frame-Options "SAMEORIGIN"
       Header always set Referrer-Policy "strict-origin-when-cross-origin"
       Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
       Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
   </IfModule>
   EOF

   # Disable mod_status
   a2dismod status

   systemctl reload apache2
   ```

5. **Add `Options -Indexes` globally**
   ```bash
   # In /etc/apache2/apache2.conf, ensure the /var/www directory block has:
   # Options -Indexes +FollowSymLinks
   ```

6. **Apply pending system updates**
   ```bash
   apt update && apt upgrade -y
   ```

7. **Harden kernel network parameters**
   ```bash
   cat >> /etc/sysctl.d/99-hardening.conf << 'EOF'
   net.ipv4.conf.all.accept_redirects = 0
   net.ipv4.conf.default.accept_redirects = 0
   net.ipv4.conf.all.send_redirects = 0
   net.ipv4.conf.default.send_redirects = 0
   net.ipv4.conf.all.log_martians = 1
   net.ipv4.conf.default.log_martians = 1
   net.ipv6.conf.all.accept_redirects = 0
   net.ipv6.conf.default.accept_redirects = 0
   EOF
   sysctl --system
   ```

### This Month

8. **Set up a dedicated admin user**
   ```bash
   usermod -s /bin/bash david
   usermod -aG sudo david
   # Copy root's authorized_keys to david
   mkdir -p /home/david/.ssh
   cp /root/.ssh/authorized_keys /home/david/.ssh/
   chown -R david:david /home/david/.ssh
   chmod 700 /home/david/.ssh
   chmod 600 /home/david/.ssh/authorized_keys
   # Then set PermitRootLogin no
   ```

9. **Disable X11Forwarding**
   ```bash
   sed -i 's/^X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config
   systemctl reload sshd
   ```

10. **Consider moving SSH to a non-standard port** (reduces log noise)

11. **Verify certbot auto-renewal**
    ```bash
    certbot renew --dry-run
    ```

12. **Review and clean up cloud-init sudoers rule**
    ```bash
    # Remove if ubuntu user is not needed
    rm /etc/sudoers.d/90-cloud-init-users
    ```

---

## Hardening Checklist

- [ ] Install and enable fail2ban
- [ ] Enable UFW firewall (allow 22, 80, 443 only)
- [ ] Disable SSH password authentication
- [ ] Disable SSH root login (after setting up key-based admin user)
- [ ] Enable `mod_headers` in Apache
- [ ] Set `ServerTokens Prod` and `ServerSignature Off`
- [ ] Add security headers (HSTS, X-Frame-Options, X-Content-Type-Options, CSP, Referrer-Policy)
- [ ] Block `.git`/`.svn` access in Apache
- [ ] Disable `mod_status` or restrict to localhost
- [ ] Add `Options -Indexes` to all virtual hosts
- [ ] Apply all pending system updates (`apt upgrade`)
- [ ] Harden sysctl network parameters (disable ICMP redirects, log martians)
- [ ] Set up dedicated admin user with sudo
- [ ] Disable X11Forwarding in SSH
- [ ] Verify certbot auto-renewal (`certbot renew --dry-run`)
- [ ] Remove cloud-init NOPASSWD sudoers rule if unused
- [ ] Consider changing SSH port
- [ ] Fix duplicate VirtualHost for davidwhittington.com
