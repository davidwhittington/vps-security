#!/usr/bin/env bash
# services-check.sh — running services baseline and drift detector
#
# On first run: saves baseline of active systemd services.
# On subsequent runs: compares current services against baseline,
# flags new services not in the baseline.
# Read-only. Exits 1 if unexpected new services are found.
#
# Usage:
#   bash scripts/core/audit/services-check.sh              # compare against baseline
#   bash scripts/core/audit/services-check.sh --update     # overwrite baseline
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/output.sh"

BASELINE_DIR="/var/lib/vps-security"
BASELINE_FILE="${BASELINE_DIR}/services-baseline.txt"
UPDATE=false
for arg in "$@"; do [[ "$arg" == "--update" ]] && UPDATE=true; done

banner "Running Services Check"

if ! command -v systemctl &>/dev/null; then
    check_fail "systemd" "systemctl not found — this script requires systemd"
    exit 1
fi

# --- Current active services ---
CURRENT=$(systemctl list-units --type=service --state=active --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | sort)
CURRENT_COUNT=$(echo "$CURRENT" | grep -c . || true)

echo "  Active services: ${CURRENT_COUNT}"
echo ""

# --- First-run or update ---
if $UPDATE || [[ ! -f "$BASELINE_FILE" ]]; then
    if [[ ! -f "$BASELINE_FILE" ]]; then
        echo "No baseline found — saving current services as baseline."
    else
        echo "Updating baseline with current state."
    fi
    mkdir -p "$BASELINE_DIR"
    echo "$CURRENT" > "$BASELINE_FILE"
    echo "  Baseline saved: $BASELINE_FILE (${CURRENT_COUNT} services)"
    echo ""
    echo "  Run this script again (without --update) to check for drift."
    echo "========================================="
    exit 0
fi

# --- Compare ---
BASELINE=$(cat "$BASELINE_FILE")
BASELINE_COUNT=$(echo "$BASELINE" | grep -c . || true)

ADDED=$(comm -23 <(echo "$CURRENT") <(echo "$BASELINE") | grep -v '^$' || true)
REMOVED=$(comm -13 <(echo "$CURRENT") <(echo "$BASELINE") | grep -v '^$' || true)

section_header "Drift Analysis"
echo "  Baseline: ${BASELINE_COUNT} services"
echo "  Current:  ${CURRENT_COUNT} services"
echo ""

if [[ -n "$REMOVED" ]]; then
    printf "  Services stopped since baseline:\n"
    echo "$REMOVED" | sed 's/^/    /'
    echo ""
fi

if [[ -n "$ADDED" ]]; then
    check_fail "New services since baseline" "$(echo "$ADDED" | wc -l | tr -d ' ') new service(s) not in baseline"
    printf "  New services:\n"
    echo "$ADDED" | sed 's/^/    /'
    echo ""
    echo "  Investigate each. If legitimate, update the baseline:"
    echo "    bash scripts/core/audit/services-check.sh --update"
else
    check_pass "No new services since baseline"
fi

# --- Full current list ---
section_header "All Active Services"
echo "$CURRENT" | sed 's/^/  /'

summary "Services check complete."
[[ "$FAIL" -eq 0 ]]
