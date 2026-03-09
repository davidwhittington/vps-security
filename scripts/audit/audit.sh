#!/usr/bin/env bash
# audit.sh — linux-security baseline checker
#
# Read-only. Profile-aware dispatcher: runs core checks always, web checks
# when profile is web-server (default).
# Exits 0 if all checks pass, 1 if any fail.
set -uo pipefail

usage() {
    cat <<EOF
Usage: audit.sh [OPTIONS]

Run security posture checks against this server. Read-only — makes no changes.
Exits 0 if all checks pass, non-zero if any fail.

Options:
  --profile PROFILE       Profile to audit (default: web-server)
                            baseline    — core checks only (SSH, firewall, users, services, etc.)
                            web-server  — core + Apache headers, TLS certificates, vhost config
  --json                  Output results as JSON to stdout
  --report [FORMAT]       Write a report file; FORMAT is md (default) or html
  --output PATH           Write the report to PATH instead of the default timestamped filename
  --help, -h              Show this help

Examples:
  bash scripts/audit/audit.sh
  bash scripts/audit/audit.sh --profile baseline
  bash scripts/audit/audit.sh --report html --output /tmp/audit.html
  bash scripts/audit/audit.sh --json | jq .
  linux-security-audit --profile web-server --report md
EOF
}

# --- Args ---
JSON=false
REPORT=false
REPORT_FMT="md"
REPORT_OUTPUT=""
PROFILE="web-server"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)     JSON=true ;;
        --profile)  PROFILE="${2:-web-server}"; shift ;;
        --report)   REPORT=true; [[ "${2:-}" =~ ^(md|html)$ ]] && { REPORT_FMT="$2"; shift; } ;;
        --output)   REPORT_OUTPUT="${2:-}"; shift ;;
        --help|-h)  usage; exit 0 ;;
        *)          echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# --- Config discovery ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    for loc in \
        "$SCRIPT_DIR/../../config.env" \
        "$SCRIPT_DIR/../config.env" \
        /etc/linux-security/config.env; do
        if [[ -f "$loc" ]]; then CONFIG_FILE="$loc"; break; fi
    done
fi
if [[ -n "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi
SSH_PORT="${SSH_PORT:-22}"

# --- Output helpers ---
PASS=0
FAIL=0
WARN=0
RESULTS=()

# check NAME STATUS DETAIL REMEDIATION
check() {
    local name="$1" status="$2" detail="${3:-}" remediation="${4:-}"
    RESULTS+=("${status}|${name}|${detail}|${remediation}")
    case "$status" in
        PASS) ((PASS++)) ;;
        FAIL) ((FAIL++)) ;;
        WARN) ((WARN++)) ;;
    esac
}

# Colors (disabled if not a terminal, JSON mode, or report mode)
if $JSON || $REPORT || [[ ! -t 1 ]]; then
    GREEN="" YELLOW="" RED="" RESET=""
else
    GREEN="\033[0;32m" YELLOW="\033[0;33m" RED="\033[0;31m" RESET="\033[0m"
fi

print_result() {
    local status="$1" name="$2" detail="$3"
    case "$status" in
        PASS) printf "${GREEN}  [PASS]${RESET} %s\n" "$name" ;;
        WARN) printf "${YELLOW}  [WARN]${RESET} %s — %s\n" "$name" "$detail" ;;
        FAIL) printf "${RED}  [FAIL]${RESET} %s — %s\n" "$name" "$detail" ;;
    esac
}

# ============================================================================
# CHECKS
# ============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "WARNING: Some checks require root. Run as root for full results." >&2
fi

# --- UFW ---
echo ""
echo "[ Firewall ]"

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    check "UFW active" "PASS" "" ""

    if ufw status | grep -q "^${SSH_PORT}/tcp.*ALLOW"; then
        check "UFW allows SSH (port ${SSH_PORT})" "PASS" "" ""
    else
        check "UFW allows SSH (port ${SSH_PORT})" "FAIL" "Port ${SSH_PORT}/tcp not found in UFW rules" \
            "Add rule: ufw allow ${SSH_PORT}/tcp comment 'SSH'"
    fi

    if ufw status | grep -q "^80/tcp.*ALLOW"; then
        check "UFW allows HTTP (80)" "PASS" "" ""
    else
        check "UFW allows HTTP (80)" "WARN" "Port 80/tcp not in UFW rules — intended?" \
            "Add if needed: ufw allow 80/tcp comment 'HTTP'"
    fi

    if ufw status | grep -q "^443/tcp.*ALLOW"; then
        check "UFW allows HTTPS (443)" "PASS" "" ""
    else
        check "UFW allows HTTPS (443)" "WARN" "Port 443/tcp not in UFW rules — intended?" \
            "Add if needed: ufw allow 443/tcp comment 'HTTPS'"
    fi
else
    check "UFW active" "FAIL" "UFW is not installed or not active" \
        "Install and enable: apt-get install ufw && ufw --force enable. Then run 01-immediate-hardening.sh"
fi

# --- SSH ---
echo ""
echo "[ SSH ]"

if command -v sshd &>/dev/null; then
    SSHD_T=$(sshd -T 2>/dev/null || true)

    pw_auth=$(echo "$SSHD_T" | grep "^passwordauthentication " | awk '{print $2}')
    if [[ "$pw_auth" == "no" ]]; then
        check "SSH PasswordAuthentication no" "PASS" "" ""
    else
        check "SSH PasswordAuthentication no" "FAIL" "Currently: ${pw_auth:-unknown}" \
            "Run 01-immediate-hardening.sh, or: echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/50-hardening.conf && systemctl reload ssh"
    fi

    root_login=$(echo "$SSHD_T" | grep "^permitrootlogin " | awk '{print $2}')
    if [[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]]; then
        check "SSH PermitRootLogin restricted" "PASS" "(${root_login})" ""
    else
        check "SSH PermitRootLogin restricted" "FAIL" "Currently: ${root_login:-unknown}" \
            "Set PermitRootLogin prohibit-password in /etc/ssh/sshd_config and reload SSH"
    fi

    x11=$(echo "$SSHD_T" | grep "^x11forwarding " | awk '{print $2}')
    if [[ "$x11" == "no" ]]; then
        check "SSH X11Forwarding no" "PASS" "" ""
    else
        check "SSH X11Forwarding no" "WARN" "X11 forwarding enabled (unnecessary on headless server)" \
            "Add to sshd_config: X11Forwarding no"
    fi

    tcp_fwd=$(echo "$SSHD_T" | grep "^allowtcpforwarding " | awk '{print $2}')
    if [[ "$tcp_fwd" == "no" ]]; then
        check "SSH AllowTcpForwarding no" "PASS" "" ""
    else
        check "SSH AllowTcpForwarding no" "WARN" "TCP forwarding enabled" \
            "Add to /etc/ssh/sshd_config.d/99-hardening.conf: AllowTcpForwarding no"
    fi
else
    check "SSH daemon" "WARN" "sshd not found or not accessible" \
        "Install OpenSSH: apt-get install openssh-server"
fi

# --- fail2ban ---
echo ""
echo "[ fail2ban ]"

if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
    check "fail2ban running" "PASS" "" ""

    if fail2ban-client status sshd &>/dev/null; then
        check "fail2ban SSH jail active" "PASS" "" ""
    else
        check "fail2ban SSH jail active" "FAIL" "sshd jail not found or not active" \
            "Run 01-immediate-hardening.sh to configure SSH and Apache fail2ban jails"
    fi

    if [[ "$PROFILE" == "web-server" ]]; then
        for jail in apache-auth apache-badbots apache-noscript; do
            if fail2ban-client status "$jail" &>/dev/null; then
                check "fail2ban ${jail} jail" "PASS" "" ""
            else
                check "fail2ban ${jail} jail" "WARN" "Jail not active" \
                    "Run core/01-immediate-hardening.sh to add Apache jails"
            fi
        done
    fi
else
    check "fail2ban running" "FAIL" "fail2ban is not installed or not active" \
        "Install and configure: apt-get install fail2ban && run 01-immediate-hardening.sh"
fi

# --- Apache (web-server profile only) ---
if [[ "$PROFILE" == "web-server" ]]; then
echo ""
echo "[ Apache ]"

if command -v apache2 &>/dev/null && systemctl is-active --quiet apache2 2>/dev/null; then
    check "Apache running" "PASS" "" ""

    if command -v curl &>/dev/null; then
        HEADERS=$(curl -sk -o /dev/null -D - http://localhost/ 2>/dev/null || true)

        server_hdr=$(echo "$HEADERS" | grep -i "^server:" | tr -d '\r')
        if echo "$server_hdr" | grep -q "Apache$"; then
            check "ServerTokens Prod (no version in Server header)" "PASS" "" ""
        else
            check "ServerTokens Prod (no version in Server header)" "WARN" \
                "Server header: ${server_hdr:-not found}" \
                "Run web/01-apache-hardening.sh to set ServerTokens Prod and ServerSignature Off"
        fi

        for hdr in "strict-transport-security" "x-content-type-options" "referrer-policy" "content-security-policy"; do
            if echo "$HEADERS" | grep -qi "^${hdr}:"; then
                check "Apache header: ${hdr}" "PASS" "" ""
            else
                check "Apache header: ${hdr}" "FAIL" "Header missing from HTTP response" \
                    "Run web/01-apache-hardening.sh to apply full security header suite"
            fi
        done
    else
        check "Apache headers" "WARN" "curl not available — skipping header checks" \
            "Install curl: apt-get install curl"
    fi

    if apache2ctl -M 2>/dev/null | grep -q "status_module"; then
        check "mod_status disabled" "FAIL" "status_module is loaded" \
            "Disable: a2dismod status && systemctl reload apache2"
    else
        check "mod_status disabled" "PASS" "" ""
    fi
else
    check "Apache running" "WARN" "Apache not active or not installed" \
        "Install: apt-get install apache2"
fi
fi # end web-server profile

# --- Updates ---
echo ""
echo "[ System Updates ]"

if command -v apt &>/dev/null; then
    apt-get update -qq 2>/dev/null || true
    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c "\[upgradable" || true)
    if [[ "$UPGRADABLE" -eq 0 ]]; then
        check "No pending updates" "PASS" "" ""
    elif [[ "$UPGRADABLE" -lt 10 ]]; then
        check "Pending updates" "WARN" "${UPGRADABLE} packages upgradable" \
            "Run: apt-get upgrade -y"
    else
        check "Pending updates" "FAIL" "${UPGRADABLE} packages upgradable" \
            "Run immediately: apt-get update && apt-get upgrade -y && reboot (if kernel updated)"
    fi

    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        check "unattended-upgrades active" "PASS" "" ""
    else
        check "unattended-upgrades active" "WARN" "Automatic security updates may not be running" \
            "Enable: apt-get install unattended-upgrades && systemctl enable --now unattended-upgrades"
    fi
fi

# --- Certificates (web-server profile only) ---
if [[ "$PROFILE" == "web-server" ]]; then
echo ""
echo "[ TLS Certificates ]"

CERTBOT_CMD=$(command -v certbot 2>/dev/null)
[[ -z "$CERTBOT_CMD" && -x /snap/bin/certbot ]] && CERTBOT_CMD=/snap/bin/certbot
if [[ -n "$CERTBOT_CMD" ]]; then
    CERT_OUTPUT=$("$CERTBOT_CMD" certificates 2>/dev/null || true)
    EXPIRING=$(echo "$CERT_OUTPUT" | grep "VALID:" | grep -E "VALID: [0-9] days|VALID: [12][0-9] days" || true)
    EXPIRED=$(echo "$CERT_OUTPUT" | grep "INVALID\|EXPIRED" || true)

    if [[ -n "$EXPIRED" ]]; then
        check "TLS certificates valid" "FAIL" "Expired certificates found" \
            "Renew immediately: certbot renew && systemctl reload apache2"
    elif [[ -n "$EXPIRING" ]]; then
        check "TLS certificates valid" "WARN" "Certs expiring within 30 days" \
            "Verify auto-renewal: certbot renew --dry-run. If OK, auto-renewal will handle it."
    else
        check "TLS certificates valid" "PASS" "" ""
    fi
else
    check "TLS certificates" "WARN" "certbot not found — cannot check cert expiry" \
        "Install certbot: apt-get install -y certbot (Debian) or snap install --classic certbot (Ubuntu)"
fi
fi # end web-server profile

# ============================================================================
# OUTPUT — CONSOLE / JSON
# ============================================================================

if ! $REPORT; then
    if $JSON; then
        echo "{"
        echo "  \"host\": \"$(hostname -f)\","
        echo "  \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"profile\": \"${PROFILE}\","
        echo "  \"summary\": {\"pass\": $PASS, \"warn\": $WARN, \"fail\": $FAIL},"
        echo "  \"checks\": ["
        local_sep=""
        for result in "${RESULTS[@]}"; do
            IFS='|' read -r s n d r <<< "$result"
            printf '%s    {"status": "%s", "name": "%s", "detail": "%s", "remediation": "%s"}' \
                "$local_sep" "$s" "$n" "$d" "$r"
            local_sep=$'\n'
        done
        echo ""
        echo "  ]"
        echo "}"
    else
        echo ""
        echo "========================================="
        echo "  Audit Summary — $(hostname -f)"
        echo "  $(date '+%Y-%m-%d %H:%M %Z')  [profile: ${PROFILE}]"
        echo ""
        for result in "${RESULTS[@]}"; do
            IFS='|' read -r s n d r <<< "$result"
            print_result "$s" "$n" "$d"
        done
        echo ""
        printf "  ${GREEN}PASS: %d${RESET}  ${YELLOW}WARN: %d${RESET}  ${RED}FAIL: %d${RESET}\n" \
            "$PASS" "$WARN" "$FAIL"
        echo "========================================="
    fi
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

# ============================================================================
# OUTPUT — REPORT (MD or HTML)
# ============================================================================

HOST="$(hostname -f)"
REPORT_DATE="$(date '+%Y-%m-%d %H:%M %Z')"
REPORT_DATE_SHORT="$(date '+%Y-%m-%d')"

# Default output path
if [[ -z "$REPORT_OUTPUT" ]]; then
    REPORT_OUTPUT="/tmp/linux-security-audit-${HOST}-${REPORT_DATE_SHORT}.${REPORT_FMT}"
fi

# --- Collect grouped results ---
FAIL_ITEMS=() WARN_ITEMS=() PASS_ITEMS=()
for result in "${RESULTS[@]}"; do
    IFS='|' read -r s n d r <<< "$result"
    case "$s" in
        FAIL) FAIL_ITEMS+=("${n}|${d}|${r}") ;;
        WARN) WARN_ITEMS+=("${n}|${d}|${r}") ;;
        PASS) PASS_ITEMS+=("${n}|${d}|${r}") ;;
    esac
done

# ── Markdown report ──────────────────────────────────────────────────────────
generate_md() {
    cat << MDEOF
# linux-security Audit Report

**Host:** ${HOST}
**Date:** ${REPORT_DATE}
**Profile:** ${PROFILE}
**Result:** PASS: ${PASS} · WARN: ${WARN} · FAIL: ${FAIL}

---

MDEOF

    if [[ "${#FAIL_ITEMS[@]}" -gt 0 ]]; then
        echo "## Action Required (${#FAIL_ITEMS[@]} FAIL)"
        echo ""
        for item in "${FAIL_ITEMS[@]}"; do
            IFS='|' read -r n d r <<< "$item"
            echo "### ❌ ${n}"
            [[ -n "$d" ]] && echo "> ${d}"
            echo ""
            if [[ -n "$r" ]]; then
                echo "**Remediation:** ${r}"
                echo ""
            fi
        done
        echo "---"
        echo ""
    fi

    if [[ "${#WARN_ITEMS[@]}" -gt 0 ]]; then
        echo "## Attention (${#WARN_ITEMS[@]} WARN)"
        echo ""
        for item in "${WARN_ITEMS[@]}"; do
            IFS='|' read -r n d r <<< "$item"
            echo "### ⚠️ ${n}"
            [[ -n "$d" ]] && echo "> ${d}"
            echo ""
            if [[ -n "$r" ]]; then
                echo "**Suggestion:** ${r}"
                echo ""
            fi
        done
        echo "---"
        echo ""
    fi

    if [[ "${#PASS_ITEMS[@]}" -gt 0 ]]; then
        echo "## Passing Checks (${#PASS_ITEMS[@]})"
        echo ""
        for item in "${PASS_ITEMS[@]}"; do
            IFS='|' read -r n d r <<< "$item"
            echo "- ✅ ${n}${d:+ — ${d}}"
        done
        echo ""
    fi

    echo "---"
    echo "_Generated by linux-security audit.sh · https://github.com/davidwhittington/linux-security_"
}

# ── HTML report ──────────────────────────────────────────────────────────────
generate_html() {
    # shellcheck disable=SC2034
    local status_class="pass"
    [[ "$WARN" -gt 0 ]] && status_class="warn"
    [[ "$FAIL" -gt 0 ]] && status_class="fail"

    cat << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>linux-security Audit — ${HOST} — ${REPORT_DATE_SHORT}</title>
<style>
:root{--bg:#0d1117;--surface:#161b22;--border:#30363d;--text:#e6edf3;--muted:#8b949e;
  --green:#3fb950;--yellow:#d29922;--red:#f85149;--blue:#58a6ff;}
*{box-sizing:border-box;margin:0;padding:0;}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;line-height:1.6;padding:2rem;}
.wrap{max-width:860px;margin:0 auto;}
header{margin-bottom:2rem;padding-bottom:1.5rem;border-bottom:1px solid var(--border);}
h1{font-size:1.75rem;font-weight:700;margin-bottom:.5rem;}
.meta{font-size:.85rem;color:var(--muted);}
.summary{display:flex;gap:1rem;margin-top:1rem;flex-wrap:wrap;}
.badge{padding:.35rem .9rem;border-radius:4px;font-size:.85rem;font-weight:600;}
.badge-pass{background:rgba(63,185,80,.15);color:var(--green);border:1px solid rgba(63,185,80,.3);}
.badge-warn{background:rgba(210,153,34,.15);color:var(--yellow);border:1px solid rgba(210,153,34,.3);}
.badge-fail{background:rgba(248,81,73,.15);color:var(--red);border:1px solid rgba(248,81,73,.3);}
section{margin-top:2rem;}
h2{font-size:1.1rem;font-weight:700;margin-bottom:1rem;padding-bottom:.5rem;border-bottom:1px solid var(--border);}
.item{background:var(--surface);border:1px solid var(--border);border-radius:.5rem;padding:1rem 1.2rem;margin-bottom:.75rem;}
.item-header{display:flex;align-items:center;gap:.6rem;margin-bottom:.4rem;}
.item-icon{font-size:1rem;flex-shrink:0;}
.item-name{font-weight:600;font-size:.95rem;}
.item-detail{font-size:.82rem;color:var(--muted);margin-bottom:.5rem;}
.item-fix{font-size:.82rem;color:var(--text);background:var(--bg);border:1px solid var(--border);
  border-radius:4px;padding:.5rem .75rem;font-family:"SF Mono","Fira Code",monospace;}
.item-fix-label{font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin-bottom:.25rem;}
.pass-list{list-style:none;}
.pass-list li{font-size:.85rem;color:var(--muted);padding:.3rem 0;border-bottom:1px solid var(--border);}
.pass-list li:last-child{border-bottom:none;}
.pass-list li::before{content:"✓ ";color:var(--green);}
footer{margin-top:3rem;padding-top:1rem;border-top:1px solid var(--border);font-size:.78rem;color:var(--muted);text-align:center;}
footer a{color:var(--muted);}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>linux-security Audit Report</h1>
  <div class="meta">
    <strong>${HOST}</strong> &nbsp;·&nbsp; ${REPORT_DATE} &nbsp;·&nbsp; profile: ${PROFILE}
  </div>
  <div class="summary">
    <span class="badge badge-fail">FAIL: ${FAIL}</span>
    <span class="badge badge-warn">WARN: ${WARN}</span>
    <span class="badge badge-pass">PASS: ${PASS}</span>
  </div>
</header>
HTMLEOF

    # FAIL section
    if [[ "${#FAIL_ITEMS[@]}" -gt 0 ]]; then
        echo "<section>"
        echo "<h2>❌ Action Required — ${#FAIL_ITEMS[@]} issue(s)</h2>"
        for item in "${FAIL_ITEMS[@]}"; do
            IFS='|' read -r n d r <<< "$item"
            echo "<div class=\"item\">"
            echo "  <div class=\"item-header\"><span class=\"item-icon\">❌</span><span class=\"item-name\">${n}</span></div>"
            [[ -n "$d" ]] && echo "  <div class=\"item-detail\">${d}</div>"
            if [[ -n "$r" ]]; then
                echo "  <div class=\"item-fix-label\">Remediation</div>"
                echo "  <div class=\"item-fix\">${r}</div>"
            fi
            echo "</div>"
        done
        echo "</section>"
    fi

    # WARN section
    if [[ "${#WARN_ITEMS[@]}" -gt 0 ]]; then
        echo "<section>"
        echo "<h2>⚠️ Attention — ${#WARN_ITEMS[@]} item(s)</h2>"
        for item in "${WARN_ITEMS[@]}"; do
            IFS='|' read -r n d r <<< "$item"
            echo "<div class=\"item\">"
            echo "  <div class=\"item-header\"><span class=\"item-icon\">⚠️</span><span class=\"item-name\">${n}</span></div>"
            [[ -n "$d" ]] && echo "  <div class=\"item-detail\">${d}</div>"
            if [[ -n "$r" ]]; then
                echo "  <div class=\"item-fix-label\">Suggestion</div>"
                echo "  <div class=\"item-fix\">${r}</div>"
            fi
            echo "</div>"
        done
        echo "</section>"
    fi

    # PASS section
    if [[ "${#PASS_ITEMS[@]}" -gt 0 ]]; then
        echo "<section>"
        echo "<h2>✅ Passing — ${#PASS_ITEMS[@]} check(s)</h2>"
        echo "<ul class=\"pass-list\">"
        for item in "${PASS_ITEMS[@]}"; do
            IFS='|' read -r n d r <<< "$item"
            echo "  <li>${n}${d:+ <span style=\"color:var(--muted);font-size:.8em\">— ${d}</span>}</li>"
        done
        echo "</ul>"
        echo "</section>"
    fi

    cat << HTMLFOOTER
<footer>
  Generated by <a href="https://github.com/davidwhittington/linux-security">linux-security</a> audit.sh
</footer>
</div>
</body>
</html>
HTMLFOOTER
}

# Generate and write report
if [[ "$REPORT_FMT" == "html" ]]; then
    generate_html > "$REPORT_OUTPUT"
else
    generate_md > "$REPORT_OUTPUT"
fi

echo ""
echo "  Report written: ${REPORT_OUTPUT}"
echo "  Summary: PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"
echo ""

[[ "$FAIL" -eq 0 ]]
