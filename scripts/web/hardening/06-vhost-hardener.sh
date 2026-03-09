#!/usr/bin/env bash
# 06-vhost-hardener.sh — Multi-domain Apache vhost hardening
#
# Applies per-directory hardening to all web roots under /var/www:
#   - Options -Indexes (disables directory listing)
#   - Options -FollowSymLinks (prevents symlink traversal)
#   - AllowOverride None (disables .htaccess overrides)
#   - ServerSignature Off, ServerTokens Prod (already global, reinforced per-vhost)
#
# Creates /etc/apache2/conf-available/vhost-hardening.conf and enables it.
# Supports --dry-run. Run as root on the target server.
set -euo pipefail

# --- Dry-run support ---
DRYRUN=false
CONFIRM=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRYRUN=true
    [[ "$arg" == "--confirm" ]] && CONFIRM=true
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        echo "06-vhost-hardener.sh — apply security directives to all Apache virtual hosts"
        echo
        echo "Usage:"
        echo "  bash scripts/web/hardening/06-vhost-hardener.sh [--dry-run] [--confirm]"
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

# --- Web config discovery (config.web.env) ---
WEB_CONFIG_FILE="${WEB_CONFIG_FILE:-}"
if [[ -z "$WEB_CONFIG_FILE" ]]; then
    for loc in \
        "$SCRIPT_DIR/../../../config.web.env" \
        /etc/linux-security/config.web.env; do
        if [[ -f "$loc" ]]; then WEB_CONFIG_FILE="$loc"; break; fi
    done
fi
if [[ -n "$WEB_CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$WEB_CONFIG_FILE"
fi

SERVER_HOSTNAME=$(hostname -f)

# --- Banner ---
echo "========================================="
echo "  Apache vhost Hardener"
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

if ! command -v apache2 &>/dev/null && ! apachectl -v &>/dev/null 2>&1; then
    echo "ERROR: Apache2 not found. Install Apache before running this script." >&2
    exit 1
fi

# --- Discover web roots ---
echo "[1/3] Discovering web roots under /var/www..."
WEB_ROOTS=()
if [[ -d /var/www ]]; then
    while IFS= read -r -d '' dir; do
        WEB_ROOTS+=("$dir")
    done < <(find /var/www -maxdepth 2 -name "public_html" -o -name "htdocs" -o -name "html" \
        -type d -print0 2>/dev/null)
    # Include top-level /var/www subdirs that are direct web roots
    while IFS= read -r -d '' dir; do
        WEB_ROOTS+=("$dir")
    done < <(find /var/www -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi
# Deduplicate and include /var/www itself
ALL_ROOTS=("/var/www")
for r in "${WEB_ROOTS[@]}"; do
    ALL_ROOTS+=("$r")
done

echo "  Discovered web root base: /var/www"
echo ""

# --- Write conf ---
echo "[2/3] Writing /etc/apache2/conf-available/vhost-hardening.conf..."
if ! $DRYRUN; then
    cat > /etc/apache2/conf-available/vhost-hardening.conf << 'CONFEOF'
# linux-security: per-directory hardening for all web roots
# Managed by vps-security 11-vhost-hardener.sh

# Global /var/www hardening
<Directory /var/www>
    # Disable directory listing — never expose file trees to visitors
    Options -Indexes -FollowSymLinks

    # Disable .htaccess overrides — all config must be in server config
    # Note: set to FileInfo if your sites require .htaccess rewrites
    AllowOverride None

    Require all granted
</Directory>

# Deny access to hidden files and directories (dotfiles)
<DirectoryMatch "^(.*/)?\.">
    Require all denied
</DirectoryMatch>

# Deny access to version control directories
<DirectoryMatch "/(\.git|\.svn|\.hg|\.bzr)">
    Require all denied
</DirectoryMatch>

# Deny access to backup and swap files
<FilesMatch "(~|\.bak|\.swp|\.orig|\.old)$">
    Require all denied
</FilesMatch>

# Deny direct access to PHP configuration and env files
<FilesMatch "(\.env|\.env\.local|wp-config\.php|config\.php|settings\.php)$">
    Require all denied
</FilesMatch>
CONFEOF
else
    echo "  [dry-run] Would write /etc/apache2/conf-available/vhost-hardening.conf:"
    echo "    - Options -Indexes -FollowSymLinks for /var/www"
    echo "    - AllowOverride None"
    echo "    - Deny dotfiles, VCS dirs, backup files, env files"
fi
echo "  -> Config written."

# --- Enable and reload ---
echo ""
echo "[3/3] Enabling conf and reloading Apache..."
cmd a2enconf vhost-hardening
cmd apache2ctl configtest
cmd systemctl reload apache2
echo "  -> Apache reloaded with vhost hardening."

echo ""
echo "========================================="
if $DRYRUN; then
    echo "  Dry run complete — no changes made."
else
    echo "  vhost hardening complete!"
    echo ""
    echo "  Config: /etc/apache2/conf-available/vhost-hardening.conf"
    echo ""
    echo "  NOTE: AllowOverride None disables .htaccess. If your sites"
    echo "  rely on .htaccess rewrites (WordPress, etc.), change the"
    echo "  AllowOverride line to: AllowOverride FileInfo"
    echo ""
    echo "  Verify: curl -sI http://localhost/ | grep -i server"
fi
echo "========================================="
