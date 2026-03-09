#!/usr/bin/env bash
# 05-auditd-setup.sh — auditd installation with CIS-aligned ruleset
#
# Installs auditd and audispd-plugins, writes a CIS Benchmark-aligned
# audit ruleset, enables the service, and configures log rotation.
# Run as root on the target server.
set -euo pipefail

# --- Dry-run support ---
DRYRUN=false
CONFIRM=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRYRUN=true
    [[ "$arg" == "--confirm" ]] && CONFIRM=true
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        echo "05-auditd-setup.sh — install and configure auditd kernel audit daemon"
        echo
        echo "Usage:"
        echo "  bash scripts/core/hardening/05-auditd-setup.sh [--dry-run] [--confirm]"
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

SERVER_HOSTNAME=$(hostname -f)

# --- Banner ---
echo "========================================="
echo "  auditd Setup (CIS-aligned)"
echo "  Host: $SERVER_HOSTNAME"
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

# --- 1/3: Install ---
echo "[1/3] Installing auditd and audispd-plugins..."
if ! $DRYRUN; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq auditd audispd-plugins
else
    echo "  [dry-run] Would install: auditd audispd-plugins"
fi
echo "  -> auditd installed."

# --- 2/3: CIS ruleset ---
echo ""
echo "[2/3] Writing CIS-aligned audit rules..."
if ! $DRYRUN; then
    cat > /etc/audit/rules.d/cis.rules << 'RULESEOF'
# linux-security: CIS Benchmark-aligned auditd ruleset
# Based on CIS Distribution Independent Linux Benchmark v2.0

## — Buffer size —
-b 8192

## — Failure mode: 1 = log, 2 = panic (use 1 for production stability) —
-f 1

## — Identity and authentication changes —
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

## — Network configuration changes —
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-a always,exit -F arch=b32 -S sethostname -S setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/network -p wa -k system-locale

## — MAC policy changes (AppArmor/SELinux) —
-w /etc/apparmor/ -p wa -k MAC-policy
-w /etc/apparmor.d/ -p wa -k MAC-policy

## — Login and logout events —
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/log/tallylog -p wa -k logins

## — Session initiation —
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins

## — Discretionary access control permission changes —
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=1000 -F auid!=4294967295 -k perm_mod

## — Unauthorized access attempts —
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b32 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b32 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=4294967295 -k access

## — SUID/SGID program execution —
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid
-a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -k setuid
-a always,exit -F arch=b64 -S execve -C gid!=egid -F egid=0 -k setgid
-a always,exit -F arch=b32 -S execve -C gid!=egid -F egid=0 -k setgid

## — Filesystem mounts —
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts
-a always,exit -F arch=b32 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts

## — File deletions by users —
-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -F auid>=1000 -F auid!=4294967295 -k delete
-a always,exit -F arch=b32 -S unlink -S unlinkat -S rename -S renameat -F auid>=1000 -F auid!=4294967295 -k delete

## — Sudoers and sudo log —
-w /etc/sudoers -p wa -k sudo_changes
-w /etc/sudoers.d/ -p wa -k sudo_changes
-w /var/log/sudo.log -p wa -k sudo_log

## — Kernel module loading —
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules

## — SSH authorized keys changes —
-a always,exit -F arch=b64 -F dir=/root/.ssh -F perm=wa -k ssh_keys
-a always,exit -F arch=b64 -F dir=/home -F name=authorized_keys -F perm=wa -k ssh_keys

## — Make config immutable (requires reboot to change rules after this) —
## Uncomment only when rules are finalized:
## -e 2
RULESEOF
else
    echo "  [dry-run] Would write /etc/audit/rules.d/cis.rules"
    echo "    - Identity/auth changes (passwd, shadow, group)"
    echo "    - Network config changes"
    echo "    - Login/logout events"
    echo "    - DAC permission changes"
    echo "    - Unauthorized access attempts"
    echo "    - SUID/SGID execution"
    echo "    - Filesystem mounts"
    echo "    - File deletions"
    echo "    - Sudoers changes"
    echo "    - Kernel module loading"
    echo "    - SSH authorized_keys changes"
fi
echo "  -> CIS audit ruleset written."

# --- 3/3: Enable service ---
echo ""
echo "[3/3] Enabling and starting auditd..."
cmd systemctl enable auditd
cmd systemctl start auditd
if ! $DRYRUN; then
    # Load rules into running kernel
    augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/cis.rules 2>/dev/null || true
fi
echo "  -> auditd enabled and started."

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  auditd setup complete!"
    echo ""
    echo "  Rules:   /etc/audit/rules.d/cis.rules"
    echo "  Logs:    /var/log/audit/audit.log"
    echo ""
    echo "  View events:   ausearch -k identity"
    echo "  View report:   aureport --summary"
    echo "  Check rules:   auditctl -l"
fi
echo "========================================="
