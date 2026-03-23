#!/usr/bin/env bash
# access-log-anomaly.sh — Apache access log anomaly detector
#
# Parses the Apache access log and flags statistical anomalies:
# - IPs with unusually high request counts
# - Known scanner / attack tool user agents
# - IPs with a high proportion of 404 responses (path scanning)
# - Requests to common attack paths (.env, wp-admin, xmlrpc, etc.)
# Read-only. Exits 1 if any anomalies are detected.
#
# Usage:
#   bash scripts/web/audit/access-log-anomaly.sh [--log <path>] [--threshold <n>] [--help]
#
# Options:
#   --log <path>       Path to Apache access log (default: /var/log/apache2/access.log)
#   --threshold <n>    Request count per IP to flag as high-volume (default: 500)
#   --help             Show this help message
set -uo pipefail

# --- Defaults ---
LOG_FILE="/var/log/apache2/access.log"
THRESHOLD=500

# --- Args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log)       LOG_FILE="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --help)
            sed -n '/^# Usage/,/^[^#]/{ /^[^#]/d; s/^# \{0,2\}//; p }' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Output ---
if [[ -t 1 ]]; then
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" DIM="\033[2m" RESET="\033[0m"
else
    GREEN="" YELLOW="" RED="" DIM="" RESET=""
fi

ANOMALIES=0

flag() {
    local severity="$1" msg="$2" detail="${3:-}"
    case "$severity" in
        WARN) ((ANOMALIES++)); printf "  ${YELLOW}[WARN]${RESET} %s\n" "$msg" ;;
        HIGH) ((ANOMALIES++)); printf "  ${RED}[HIGH]${RESET} %s\n" "$msg" ;;
    esac
    if [[ -n "$detail" ]]; then
        printf "         ${DIM}%s${RESET}\n" "$detail"
    fi
}

echo "========================================="
echo "  Apache Access Log Anomaly Detector"
echo "  Log:  $LOG_FILE"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

# --- Pre-flight ---
if [[ ! -f "$LOG_FILE" ]]; then
    echo "ERROR: Log file not found: $LOG_FILE" >&2
    echo "  Use --log to specify a different path." >&2
    exit 1
fi

TOTAL_LINES=$(wc -l < "$LOG_FILE")
if [[ "$TOTAL_LINES" -eq 0 ]]; then
    echo "  Log file is empty — nothing to analyse."
    exit 0
fi

printf "  ${DIM}%d log entries analysed.${RESET}\n\n" "$TOTAL_LINES"

# -------------------------------------------------------------------
# Section 1: High-volume IPs
# -------------------------------------------------------------------
echo "[ High-Volume IPs (threshold: ${THRESHOLD} requests) ]"
echo ""

HIGH_VOL=$(awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -rn | awk -v t="$THRESHOLD" '$1 >= t')

if [[ -z "$HIGH_VOL" ]]; then
    printf "  ${GREEN}[PASS]${RESET} No IPs exceeded the threshold.\n"
else
    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | awk '{print $2}')
        flag HIGH "High request volume: ${ip}" "${count} requests"
    done <<< "$HIGH_VOL"
fi

# -------------------------------------------------------------------
# Section 2: Known scanner / attack tool user agents
# -------------------------------------------------------------------
echo ""
echo "[ Scanner / Attack Tool User Agents ]"
echo ""

SCANNER_PATTERNS=(
    "nikto"
    "sqlmap"
    "masscan"
    "nmap"
    "zgrab"
    "dirbuster"
    "gobuster"
    "wfuzz"
    "nuclei"
    "hydra"
    "medusa"
    "acunetix"
    "nessus"
    "openvas"
    "burpsuite"
    "havij"
    "w3af"
    "skipfish"
    "ZmEu"
    "libwww-perl"
    "python-httpx"
    "Go-http-client/1.1"
)

scanner_found=0
for pattern in "${SCANNER_PATTERNS[@]}"; do
    # Extract UA field: in combined log format, it's the 6th double-quoted section
    matches=$(awk -F'"' '{print $6}' "$LOG_FILE" | grep -ci "$pattern" 2>/dev/null || true)
    if [[ "$matches" -gt 0 ]]; then
        # Get IPs that used this UA
        ips=$(awk -F'"' -v pat="$pattern" 'tolower($6) ~ tolower(pat) {split($1,a," "); print a[1]}' \
              "$LOG_FILE" | sort -u | tr '\n' ' ' | sed 's/ $//')
        flag HIGH "Scanner UA detected: ${pattern}" "${matches} request(s) from: ${ips}"
        scanner_found=1
    fi
done

if [[ "$scanner_found" -eq 0 ]]; then
    printf "  ${GREEN}[PASS]${RESET} No known scanner user agents detected.\n"
fi

# -------------------------------------------------------------------
# Section 3: IPs with high 404 rate (path scanning)
# -------------------------------------------------------------------
echo ""
echo "[ High-404-Rate IPs (>=10 not-found responses) ]"
echo ""

# Combined log: status is the first word after the quoted request line
# awk splits on '"', $3 is " STATUS BYTES "
HIGH_404=$(awk -F'"' '{split($3,a," "); split($1,ip," "); print ip[1], a[2]}' "$LOG_FILE" \
    | awk '$2 == "404" {print $1}' \
    | sort | uniq -c | sort -rn \
    | awk '$1 >= 10')

if [[ -z "$HIGH_404" ]]; then
    printf "  ${GREEN}[PASS]${RESET} No IPs with elevated 404 rates.\n"
else
    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | awk '{print $2}')
        flag WARN "High 404 rate: ${ip}" "${count} not-found responses — possible path scanning"
    done <<< "$HIGH_404"
fi

# -------------------------------------------------------------------
# Section 4: Requests to common attack paths
# -------------------------------------------------------------------
echo ""
echo "[ Common Attack Path Probes ]"
echo ""

ATTACK_PATHS=(
    "\.env"
    "wp-login\.php"
    "xmlrpc\.php"
    "wp-admin"
    "phpmyadmin"
    "/admin"
    "\.git/"
    "\.svn/"
    "eval\("
    "base64_decode"
    "/etc/passwd"
    "\.php\?.*="
    "shellshock"
    "/cgi-bin/"
    "\.bak$"
    "\.sql$"
    "actuator"
    "\.aws/credentials"
    "config\.json"
    "server-status"
)

path_found=0
for path in "${ATTACK_PATHS[@]}"; do
    # The request URI is the second double-quoted field
    matches=$(awk -F'"' '{print $2}' "$LOG_FILE" | grep -ci "$path" 2>/dev/null || true)
    if [[ "$matches" -gt 0 ]]; then
        ips=$(awk -F'"' -v pat="$path" 'tolower($2) ~ tolower(pat) {split($1,a," "); print a[1]}' \
              "$LOG_FILE" | sort -u | tr '\n' ' ' | sed 's/ $//')
        flag WARN "Attack path probed: ${path}" "${matches} request(s) from: ${ips}"
        path_found=1
    fi
done

if [[ "$path_found" -eq 0 ]]; then
    printf "  ${GREEN}[PASS]${RESET} No common attack paths probed.\n"
fi

# -------------------------------------------------------------------
# Section 5: Top 5 IPs by volume (informational)
# -------------------------------------------------------------------
echo ""
echo "[ Top 5 IPs by Request Volume (informational) ]"
echo ""

awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -5 | \
while read -r count ip; do
    printf "  ${DIM}%6d  %s${RESET}\n" "$count" "$ip"
done

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "========================================="
if [[ "$ANOMALIES" -eq 0 ]]; then
    printf "  ${GREEN}No anomalies detected.${RESET}\n"
else
    printf "  ${RED}%d anomaly(s) detected.${RESET}\n" "$ANOMALIES"
    echo ""
    echo "  Recommended actions:"
    echo "  - Block persistent offenders: ufw deny from <ip>"
    echo "  - Check fail2ban jails: fail2ban-client status"
    echo "  - Review full log:    $LOG_FILE"
fi
echo "========================================="

[[ "$ANOMALIES" -eq 0 ]]
