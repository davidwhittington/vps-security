#!/usr/bin/env bash
# web-root-perms.sh — file permission scanner for web roots
#
# Scans /var/www for insecure file permissions:
#   - World-writable files and directories
#   - Files not owned by www-data or root
#   - Executable files in web roots (potential webshells)
#   - Sensitive files readable by others (.env, wp-config.php, etc.)
# Read-only. Exits 1 if critical issues found.
#
# Usage:
#   bash scripts/audit/web-root-perms.sh
#   bash scripts/audit/web-root-perms.sh --webroot /var/www/mysite
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"

WEB_ROOT="/var/www"
for arg in "$@"; do
    [[ "$arg" == "--webroot" ]] && shift && WEB_ROOT="${1:-/var/www}"
done

banner "Web Root Permission Scan"
echo "  Scanning: ${WEB_ROOT}"
echo ""

if [[ ! -d "$WEB_ROOT" ]]; then
    check_fail "Web root exists" "${WEB_ROOT} not found"
    summary "Web root not found."
    exit 1
fi

# --- World-writable files ---
section_header "World-Writable Files"
WW_FILES=$(find "$WEB_ROOT" -type f -perm -002 2>/dev/null | sort)
if [[ -n "$WW_FILES" ]]; then
    check_fail "World-writable files" "$(echo "$WW_FILES" | wc -l | tr -d ' ') file(s) writable by anyone"
    echo "$WW_FILES" | head -20 | sed 's/^/    /'
    [[ $(echo "$WW_FILES" | wc -l) -gt 20 ]] && echo "    ... (truncated)"
    echo ""
    check_info "Fix: find ${WEB_ROOT} -type f -perm -002 -exec chmod o-w {} +"
else
    check_pass "No world-writable files in ${WEB_ROOT}"
fi

# --- World-writable directories ---
section_header "World-Writable Directories"
WW_DIRS=$(find "$WEB_ROOT" -type d -perm -002 2>/dev/null | sort)
if [[ -n "$WW_DIRS" ]]; then
    check_fail "World-writable directories" "$(echo "$WW_DIRS" | wc -l | tr -d ' ') directory/ies writable by anyone"
    echo "$WW_DIRS" | head -10 | sed 's/^/    /'
    echo ""
    check_info "Fix: find ${WEB_ROOT} -type d -perm -002 -exec chmod o-w {} +"
else
    check_pass "No world-writable directories in ${WEB_ROOT}"
fi

# --- Files not owned by www-data or root ---
section_header "Unexpected File Ownership"
BAD_OWNED=$(find "$WEB_ROOT" -type f ! -user www-data ! -user root 2>/dev/null | head -20 | sort)
if [[ -n "$BAD_OWNED" ]]; then
    check_warn "Files not owned by www-data or root" "$(echo "$BAD_OWNED" | wc -l | tr -d ' ') file(s)"
    echo "$BAD_OWNED" | sed 's/^/    /'
    echo ""
    check_info "Fix: chown -R www-data:www-data ${WEB_ROOT}/<site>"
else
    check_pass "All files owned by www-data or root"
fi

# --- Executable files in web root (webshell risk) ---
section_header "Executable Files (Webshell Risk)"
# Exclude known legitimate executables (PHP, CGI in designated dirs)
EXEC_FILES=$(find "$WEB_ROOT" -type f \( -perm -0111 \) \
    ! -name "*.php" ! -name "*.cgi" ! -name "*.pl" \
    2>/dev/null | sort)
if [[ -n "$EXEC_FILES" ]]; then
    check_warn "Executable non-script files in web root" "Review these — legitimate files should not be executable"
    echo "$EXEC_FILES" | head -20 | sed 's/^/    /'
    echo ""
fi

# PHP files with suspicious names (webshell indicators)
SUSPICIOUS=$(find "$WEB_ROOT" -type f -name "*.php" 2>/dev/null \
    | xargs grep -l "eval\s*(base64_decode\|str_rot13\|gzinflate\|gzuncompress" 2>/dev/null \
    | head -10 || true)
if [[ -n "$SUSPICIOUS" ]]; then
    check_fail "Suspicious PHP files (possible webshells)" "Obfuscated PHP eval() detected"
    echo "$SUSPICIOUS" | sed 's/^/    /'
    echo ""
else
    check_pass "No obfuscated PHP eval() patterns detected"
fi

# --- Sensitive files with weak permissions ---
section_header "Sensitive File Exposure"
SENSITIVE_PATTERNS=(".env" "wp-config.php" "config.php" "settings.php" "database.php" ".htpasswd")
for pattern in "${SENSITIVE_PATTERNS[@]}"; do
    FOUND=$(find "$WEB_ROOT" -name "$pattern" -type f 2>/dev/null | sort)
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        perms=$(stat -c "%a" "$f" 2>/dev/null || true)
        # Flag if world-readable (others can read)
        if [[ "${perms: -1}" -ge 4 ]] 2>/dev/null; then
            check_fail "World-readable sensitive file: ${f}" "Permissions: ${perms} — remove world-read: chmod o-r '${f}'"
        else
            check_pass "Sensitive file permissions OK: $(basename "$f") (${perms})"
        fi
    done <<< "$FOUND"
done

# --- Summary ---
summary "Web root permission scan complete."
[[ "$FAIL" -eq 0 ]]
