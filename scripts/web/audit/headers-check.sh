#!/usr/bin/env bash
# headers-check.sh — Apache security header validator
#
# Tests each configured domain against the expected security header set.
# Auto-detects domains from enabled Apache vhosts, or reads from DOMAINS
# in config.env.
# Read-only. Exits 1 if any required header is missing on any domain.
#
# Usage:
#   bash scripts/web/audit/headers-check.sh
set -uo pipefail

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

# DOMAINS: space-separated list. If not set, auto-detect from Apache vhosts.
DOMAINS="${DOMAINS:-}"

# Required headers (lowercase names)
REQUIRED_HEADERS=(
    "strict-transport-security"
    "x-content-type-options"
    "referrer-policy"
    "content-security-policy"
)

# --- Output ---
if [[ -t 1 ]]; then
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" DIM="\033[2m" RESET="\033[0m"
else
    GREEN="" YELLOW="" RED="" DIM="" RESET=""
fi

# --- Domain discovery ---
if [[ -z "$DOMAINS" ]]; then
    if [[ -d /etc/apache2/sites-enabled ]]; then
        DOMAINS=$(grep -rh "ServerName\|ServerAlias" /etc/apache2/sites-enabled/ 2>/dev/null \
            | awk '{print $2}' \
            | grep -v '^\*\.' \
            | grep '\.' \
            | sort -u \
            | tr '\n' ' ')
    fi
fi

if [[ -z "$DOMAINS" ]]; then
    echo "WARNING: No domains found. Set DOMAINS in config.env or ensure Apache vhosts are configured." >&2
    echo "  Example: DOMAINS=\"yourdomain.com www.yourdomain.com\"" >&2
    exit 0
fi

if ! command -v curl &>/dev/null; then
    echo "ERROR: curl is required for header checks." >&2
    exit 1
fi

echo "========================================="
echo "  Security Header Check"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="

TOTAL_FAIL=0

for domain in $DOMAINS; do
    echo ""
    echo "  ${domain}"
    echo "  $(printf '%0.s-' $(seq 1 ${#domain}))"

    # Fetch headers — follow redirects, timeout 10s
    HEADERS=$(curl -sk --max-time 10 -o /dev/null -D - "https://${domain}/" 2>/dev/null || \
              curl -sk --max-time 10 -o /dev/null -D - "http://${domain}/"  2>/dev/null || true)

    if [[ -z "$HEADERS" ]]; then
        printf "  ${YELLOW}[SKIP]${RESET} Could not connect to %s\n" "$domain"
        continue
    fi

    domain_fail=0
    for hdr in "${REQUIRED_HEADERS[@]}"; do
        value=$(echo "$HEADERS" | grep -i "^${hdr}:" | head -1 | sed 's/^[^:]*: //' | tr -d '\r')
        if [[ -n "$value" ]]; then
            printf "  ${GREEN}[PASS]${RESET} %s\n" "$hdr"
            printf "         ${DIM}%s${RESET}\n" "$value"
        else
            printf "  ${RED}[MISS]${RESET} %s\n" "$hdr"
            ((domain_fail++))
            ((TOTAL_FAIL++))
        fi
    done

    # Also show Server header (informational — should be just "Apache")
    server=$(echo "$HEADERS" | grep -i "^server:" | head -1 | sed 's/^[^:]*: //' | tr -d '\r')
    if [[ -n "$server" ]]; then
        if [[ "$server" == "Apache" ]]; then
            printf "  ${GREEN}[PASS]${RESET} server: %s\n" "$server"
        else
            printf "  ${YELLOW}[WARN]${RESET} server: %s (expected bare 'Apache' — check ServerTokens Prod)\n" "$server"
        fi
    fi

    if [[ "$domain_fail" -eq 0 ]]; then
        echo ""
        printf "  ${GREEN}All required headers present.${RESET}\n"
    else
        echo ""
        printf "  ${RED}%d missing header(s). Run 02-apache-hardening.sh.${RESET}\n" "$domain_fail"
    fi
done

echo ""
echo "========================================="
if [[ "$TOTAL_FAIL" -eq 0 ]]; then
    printf "  ${GREEN}All domains passed header checks.${RESET}\n"
else
    printf "  ${RED}%d missing header(s) across all domains.${RESET}\n" "$TOTAL_FAIL"
fi
echo "========================================="

[[ "$TOTAL_FAIL" -eq 0 ]]
