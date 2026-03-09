#!/usr/bin/env bash
# ports-check.sh — open port scanner and allowlist validator
#
# Compares listening TCP services against a configurable allowlist.
# Flags anything not in the allowlist as unexpected.
# Read-only. Exits 1 if unexpected ports are found.
#
# Usage:
#   bash scripts/core/audit/ports-check.sh
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

SSH_PORT="${SSH_PORT:-22}"

# Allowlist: space-separated port numbers.
# Override in config.env with: ALLOWED_PORTS="22 80 443"
ALLOWED_PORTS="${ALLOWED_PORTS:-${SSH_PORT} 80 443}"

# --- Output ---
if [[ -t 1 ]]; then
    GREEN="\033[0;32m" RED="\033[0;31m" RESET="\033[0m"
else
    GREEN="" RED="" RESET=""
fi

UNEXPECTED=0

echo "========================================="
echo "  Open Port Check"
echo "  Host: $(hostname -f)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "  Allowlist: ${ALLOWED_PORTS}"
echo "========================================="
echo ""

if ! command -v ss &>/dev/null; then
    echo "ERROR: 'ss' not found. Install iproute2." >&2
    exit 1
fi

echo "Listening TCP services:"
echo ""

# Parse ss output: proto, local address:port, process
while IFS= read -r line; do
    # Extract port from local address (last colon-separated field)
    local_addr=$(echo "$line" | awk '{print $5}')
    port=$(echo "$local_addr" | rev | cut -d: -f1 | rev)
    process=$(echo "$line" | awk '{print $7}')

    # Skip non-numeric ports
    [[ "$port" =~ ^[0-9]+$ ]] || continue

    allowed=false
    for ap in $ALLOWED_PORTS; do
        if [[ "$port" == "$ap" ]]; then allowed=true; break; fi
    done

    if $allowed; then
        printf "  ${GREEN}[OK]${RESET}          :%s  %s\n" "$port" "$process"
    else
        printf "  ${RED}[UNEXPECTED]${RESET}  :%s  %s\n" "$port" "$process"
        ((UNEXPECTED++))
    fi
done < <(ss -tlnp 2>/dev/null | tail -n +2)

echo ""
if [[ "$UNEXPECTED" -eq 0 ]]; then
    printf "  ${GREEN}All listening ports are in the allowlist.${RESET}\n"
else
    printf "  ${RED}%d unexpected port(s) found.${RESET}\n" "$UNEXPECTED"
    echo ""
    echo "  If these are intentional, add them to ALLOWED_PORTS in config.env:"
    echo "    ALLOWED_PORTS=\"${ALLOWED_PORTS} <port>\""
fi
echo "========================================="

[[ "$UNEXPECTED" -eq 0 ]]
