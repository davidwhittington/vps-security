#!/usr/bin/env bash
# 09-php-hardening.sh — PHP security baseline
#
# Applies security-focused php.ini settings across all installed PHP versions:
#   - Disable dangerous functions (exec, system, passthru, etc.)
#   - Hide PHP version (expose_php = Off)
#   - Disable remote file access (allow_url_fopen, allow_url_include)
#   - Limit file uploads and POST size
#   - Set safe session configuration
#   - Disable display_errors for production
#   - Enable error logging to file
#
# Backs up php.ini before each modification.
#
# Usage:
#   bash scripts/web/hardening/16-php-hardening.sh
#   bash scripts/web/hardening/16-php-hardening.sh --dry-run
set -euo pipefail

# --- Dry-run support ---
DRYRUN=false
CONFIRM=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRYRUN=true
    [[ "$arg" == "--confirm" ]] && CONFIRM=true
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        echo "09-php-hardening.sh — harden PHP configuration: disable dangerous functions, hide version"
        echo
        echo "Usage:"
        echo "  bash scripts/web/hardening/09-php-hardening.sh [--dry-run] [--confirm]"
        echo
        echo "Flags:"
        echo "  --dry-run   Preview all changes without applying anything"
        echo "  --confirm   Skip the interactive confirmation prompt"
        echo "  --help      Show this help and exit"
        exit 0
    fi
done

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

cmd() {
    if $DRYRUN; then echo "  [dry-run] $*"; return 0; fi
    "$@"
}

STEPS=3

echo "========================================="
echo "  PHP Security Hardening"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

# [1/3] Detect installed PHP versions
echo "[1/${STEPS}] Detecting installed PHP versions..."

PHP_INI_FILES=()
for dir in /etc/php/*/; do
    ver=$(basename "$dir")
    for sapi in apache2 fpm cli; do
        ini="${dir}${sapi}/php.ini"
        if [[ -f "$ini" ]]; then
            PHP_INI_FILES+=("$ini")
            echo "  Found: ${ini}"
        fi
    done
done

if [[ ${#PHP_INI_FILES[@]} -eq 0 ]]; then
    echo "  No PHP installations found — nothing to do."
    echo ""
    echo "========================================="
    echo "  PHP hardening complete (no PHP installed)."
    echo "========================================="
    exit 0
fi

# [2/3] Apply hardening to each php.ini
echo "[2/${STEPS}] Applying PHP security settings..."

# Helper: set or update a php.ini value using sed
set_ini() {
    local file="$1" key="$2" value="$3"
    if $DRYRUN; then
        echo "    [dry-run] ${key} = ${value}  (in ${file})"
        return 0
    fi
    # If the key exists (possibly commented), replace it; otherwise append
    if grep -qE "^[;[:space:]]*${key}\s*=" "$file" 2>/dev/null; then
        sed -i "s|^[;[:space:]]*${key}\s*=.*|${key} = ${value}|" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

for ini in "${PHP_INI_FILES[@]}"; do
    echo ""
    echo "  Hardening: ${ini}"

    if ! $DRYRUN; then
        cp "$ini" "${ini}.bak"
        echo "    Backed up: ${ini}.bak"
    fi

    # Hide PHP version
    set_ini "$ini" "expose_php" "Off"

    # Disable dangerous execution functions
    set_ini "$ini" "disable_functions" "exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source,pcntl_exec"

    # Disable remote file access
    set_ini "$ini" "allow_url_fopen" "Off"
    set_ini "$ini" "allow_url_include" "Off"

    # File upload limits (keep enabled but constrained)
    set_ini "$ini" "file_uploads" "On"
    set_ini "$ini" "upload_max_filesize" "10M"
    set_ini "$ini" "max_file_uploads" "5"
    set_ini "$ini" "post_max_size" "12M"

    # Error handling — never display errors in production
    set_ini "$ini" "display_errors" "Off"
    set_ini "$ini" "display_startup_errors" "Off"
    set_ini "$ini" "log_errors" "On"
    set_ini "$ini" "error_log" "/var/log/php/php_errors.log"

    # Session security
    set_ini "$ini" "session.cookie_httponly" "1"
    set_ini "$ini" "session.cookie_secure" "1"
    set_ini "$ini" "session.use_strict_mode" "1"
    set_ini "$ini" "session.cookie_samesite" "Strict"
    set_ini "$ini" "session.gc_maxlifetime" "1440"

    # Disable dangerous globals
    set_ini "$ini" "register_globals" "Off"
    set_ini "$ini" "magic_quotes_gpc" "Off"

    # Execution time limits
    set_ini "$ini" "max_execution_time" "30"
    set_ini "$ini" "max_input_time" "30"
    set_ini "$ini" "memory_limit" "128M"

    echo "    Settings applied."
done

# [3/3] Create PHP log directory and reload Apache
echo ""
echo "[3/${STEPS}] Setting up PHP error log directory..."
cmd mkdir -p /var/log/php
cmd chown www-data:www-data /var/log/php
cmd chmod 750 /var/log/php

if command -v apache2ctl &>/dev/null; then
    echo "  Reloading Apache..."
    cmd apache2ctl graceful
fi

if command -v systemctl &>/dev/null; then
    for fpm in $(systemctl list-units --type=service --state=active 2>/dev/null | grep -o 'php[0-9.]*-fpm' | head -5 || true); do
        echo "  Reloading ${fpm}..."
        cmd systemctl reload "$fpm"
    done
fi

echo ""
echo "========================================="
echo "  PHP hardening complete."
echo ""
echo "  INIs modified: ${#PHP_INI_FILES[@]}"
echo "  Error log:     /var/log/php/php_errors.log"
echo ""
echo "  Review disabled_functions for your app's needs."
echo "  Roll back: restore .bak files in /etc/php/*/"
echo "========================================="
