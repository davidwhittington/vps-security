#!/usr/bin/env bash
# 17-mysql-hardening.sh — MySQL/MariaDB security baseline
#
# Applies security hardening equivalent to mysql_secure_installation plus more:
#   - Removes anonymous users
#   - Removes remote root login
#   - Removes test database
#   - Flushes privileges
#   - Writes a hardened /etc/mysql/conf.d/security.cnf:
#       bind-address = 127.0.0.1 (local only)
#       local-infile = 0
#       skip-symbolic-links
#       skip-show-database
#
# Requires MySQL/MariaDB already installed. Root password must be set or
# socket authentication must be available.
#
# Usage:
#   bash scripts/hardening/17-mysql-hardening.sh
#   bash scripts/hardening/17-mysql-hardening.sh --dry-run
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# --- Dry-run support ---
DRYRUN=false
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRYRUN=true; done

cmd() {
    if $DRYRUN; then echo "  [dry-run] $*"; return 0; fi
    "$@"
}

STEPS=3

echo "========================================="
echo "  MySQL/MariaDB Security Hardening"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

# Check MySQL/MariaDB is installed
if ! command -v mysql &>/dev/null; then
    echo "  MySQL/MariaDB not found — nothing to do."
    echo ""
    echo "  Install first: apt-get install mariadb-server"
    exit 0
fi

DB_FLAVOR="MySQL"
if mysql --version 2>&1 | grep -qi "mariadb"; then
    DB_FLAVOR="MariaDB"
fi
echo "  Detected: ${DB_FLAVOR}"
echo ""

# Test connectivity (socket auth as root)
if ! $DRYRUN; then
    if ! mysql -u root --execute "SELECT 1;" &>/dev/null; then
        echo "ERROR: Cannot connect to ${DB_FLAVOR} as root via socket." >&2
        echo "  Ensure ${DB_FLAVOR} is running and the root socket auth is configured." >&2
        exit 1
    fi
fi

# [1/3] Write hardened config file
echo "[1/${STEPS}] Writing security configuration..."

MYSQL_CONF="/etc/mysql/conf.d/security.cnf"
MYSQL_CONF_DIR="/etc/mysql/conf.d"

cmd mkdir -p "$MYSQL_CONF_DIR"

if [[ -f "$MYSQL_CONF" ]]; then
    cmd cp "$MYSQL_CONF" "${MYSQL_CONF}.bak"
    echo "  Backed up: ${MYSQL_CONF}.bak"
fi

if ! $DRYRUN; then
    cat > "$MYSQL_CONF" << 'EOF'
# vps-security MySQL/MariaDB security hardening
# Applied by scripts/hardening/17-mysql-hardening.sh

[mysqld]
# Bind to localhost only — no remote DB connections
bind-address = 127.0.0.1

# Disable loading local files (prevents LOAD DATA INFILE attacks)
local-infile = 0

# Disable following symbolic links (prevents symlink attacks on data files)
symbolic-links = 0

# Hide database list from users without SHOW DATABASES privilege
skip-show-database

# Disable older insecure authentication for new installations
# (MariaDB 10.4+: unix_socket is default for root anyway)
# explicit_defaults_for_timestamp = ON

[mysql]
# Client: also disable local file loading on the client side
local-infile = 0
EOF
    echo "  Written: ${MYSQL_CONF}"
else
    echo "  [dry-run] Would write: ${MYSQL_CONF}"
fi

# [2/3] Run security SQL
echo "[2/${STEPS}] Applying SQL security settings..."

SQL_COMMANDS="
-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';

-- Remove remote root (root should only use socket/localhost)
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Drop test database if it exists
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Flush privileges
FLUSH PRIVILEGES;
"

if $DRYRUN; then
    echo "  [dry-run] Would execute SQL:"
    echo "$SQL_COMMANDS" | sed 's/^/    /'
else
    if mysql -u root --execute "$SQL_COMMANDS" 2>/dev/null; then
        echo "  Anonymous users removed."
        echo "  Remote root login removed."
        echo "  Test database dropped."
        echo "  Privileges flushed."
    else
        echo "  WARNING: Some SQL commands failed — check output above."
    fi
fi

# [3/3] Restart MySQL to apply config changes
echo "[3/${STEPS}] Restarting ${DB_FLAVOR}..."

if systemctl is-active --quiet mariadb 2>/dev/null; then
    cmd systemctl restart mariadb
    echo "  MariaDB restarted."
elif systemctl is-active --quiet mysql 2>/dev/null; then
    cmd systemctl restart mysql
    echo "  MySQL restarted."
else
    echo "  WARNING: Could not determine ${DB_FLAVOR} service name — restart manually."
    echo "  Try: systemctl restart mariadb  OR  systemctl restart mysql"
fi

echo ""
echo "========================================="
echo "  ${DB_FLAVOR} hardening complete."
echo ""
echo "  Config: ${MYSQL_CONF}"
echo ""
echo "  What was done:"
echo "  - Bound DB to 127.0.0.1 (local only)"
echo "  - Disabled local-infile"
echo "  - Disabled symbolic-links"
echo "  - Removed anonymous users"
echo "  - Removed remote root access"
echo "  - Dropped test database"
echo ""
echo "  Verify: mysql -u root -e \"SELECT User, Host FROM mysql.user;\""
echo "========================================="
