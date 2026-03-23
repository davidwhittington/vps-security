#!/usr/bin/env bash
# domain-onboard.sh — New domain onboarding for server1.ipvegan.com
#
# Usage:
#   bash domain-onboard.sh <domain> [forward-to-email]
#
# Examples:
#   bash domain-onboard.sh mynewdomain.com
#   bash domain-onboard.sh mynewdomain.com me@gmail.com
#
# Steps:
#   1. Create Cloudflare DNS zone
#   2. Add DNS records (A, www, email if forwarding)
#   3. Configure ForwardEmail (if forward-to given)
#   4. Update Namecheap nameservers to Cloudflare (if domain is on Namecheap)
#   5. Create Apache vhost on VPS
#   6. Issue Let's Encrypt SSL cert
#   7. Save zone info to CF_API.txt
#
# Credential files (all in ~/Documents/projects/keys/):
#   CF_API.txt          — Cloudflare per-zone tokens + standalone account token at bottom
#   CF_Workers_API.txt  — CF_Account_ID
#   .forwardemail       — ForwardEmail API key (required only if forwarding)
#   .namecheap          — NC_API_USER, NC_API_KEY, NC_USERNAME (optional; skips NS update if absent)
#
# All credential files can be overridden with env vars:
#   CF_ACCOUNT_TOKEN, CF_ACCOUNT_ID, FORWARDEMAIL_KEY, NC_API_USER, NC_API_KEY, NC_USERNAME
#
# Dependencies: curl, jq, ssh (with key auth to VPS configured)

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────

DOMAIN="${1:-}"
FORWARD_TO="${2:-}"

VPS_HOST="server1.ipvegan.com"
VPS_IP="159.198.64.231"
VPS_USER="root"
VPS_SSH_PORT="22"

KEYS_DIR="$HOME/Documents/projects/keys"
CF_API_FILE="$KEYS_DIR/CF_API.txt"
CF_WORKERS_FILE="$KEYS_DIR/CF_Workers_API.txt"
FE_KEY_FILE="$KEYS_DIR/.forwardemail"
NC_KEY_FILE="$KEYS_DIR/.namecheap"

CF_BASE="https://api.cloudflare.com/client/v4"
FE_BASE="https://api.forwardemail.net/v1"
NC_BASE="https://api.namecheap.com/xml.response"

# Step status tracking (for the admin summary at the end)
declare -A STEP_STATUS
declare -A STEP_NOTE

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[→]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
die()     { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}── $* ${RESET}"; }

mark_ok()   { STEP_STATUS["$1"]="ok";      STEP_NOTE["$1"]="${2:-}"; }
mark_warn() { STEP_STATUS["$1"]="warn";    STEP_NOTE["$1"]="${2:-}"; }
mark_skip() { STEP_STATUS["$1"]="skip";    STEP_NOTE["$1"]="${2:-}"; }
mark_fail() { STEP_STATUS["$1"]="fail";    STEP_NOTE["$1"]="${2:-}"; }

# ─── Dependency checks ────────────────────────────────────────────────────────

for cmd in curl jq ssh; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ─── Args ─────────────────────────────────────────────────────────────────────

if [[ -z "$DOMAIN" ]]; then
    echo "Usage: bash domain-onboard.sh <domain> [forward-to-email]"
    echo "  domain            e.g. mynewdomain.com"
    echo "  forward-to-email  e.g. me@gmail.com  (optional)"
    exit 1
fi

DOMAIN="${DOMAIN#www.}"

if [[ -n "$FORWARD_TO" && "$FORWARD_TO" != *@* ]]; then
    die "forward-to-email doesn't look like a valid email address: $FORWARD_TO"
fi

# Split domain into SLD + TLD for Namecheap (handles .com, .net, .io, .co.uk, etc.)
TLD=$(echo "$DOMAIN" | rev | cut -d. -f1 | rev)
SLD=$(echo "$DOMAIN" | rev | cut -d. -f2- | rev | cut -d. -f1)

# ─── Load credentials ─────────────────────────────────────────────────────────

# Cloudflare account-level token (standalone line after the table in CF_API.txt)
if [[ -z "${CF_ACCOUNT_TOKEN:-}" ]] && [[ -f "$CF_API_FILE" ]]; then
    CF_ACCOUNT_TOKEN=$(grep -v '│' "$CF_API_FILE" \
        | grep -v '^[[:space:]]*#' \
        | grep -v '^[[:space:]]*$' \
        | grep -vE '^[┌└├]' \
        | head -1 | tr -d '[:space:]')
fi
[[ -n "${CF_ACCOUNT_TOKEN:-}" ]] || die "CF_ACCOUNT_TOKEN not set. Ensure standalone token exists in $CF_API_FILE or export CF_ACCOUNT_TOKEN=..."

# Cloudflare account ID
if [[ -z "${CF_ACCOUNT_ID:-}" ]] && [[ -f "$CF_WORKERS_FILE" ]]; then
    CF_ACCOUNT_ID=$(grep '^CF_Account_ID=' "$CF_WORKERS_FILE" | cut -d= -f2 | tr -d '[:space:]')
fi
[[ -n "${CF_ACCOUNT_ID:-}" ]] || die "CF_ACCOUNT_ID not set. Ensure it exists in $CF_WORKERS_FILE or export CF_ACCOUNT_ID=..."

# ForwardEmail API key (only required if forwarding)
FORWARDEMAIL_KEY="${FORWARDEMAIL_KEY:-}"
if [[ -n "$FORWARD_TO" ]]; then
    if [[ -z "$FORWARDEMAIL_KEY" ]] && [[ -f "$FE_KEY_FILE" ]]; then
        FORWARDEMAIL_KEY=$(grep -v '^#' "$FE_KEY_FILE" | tr -d '[:space:]' | head -1)
    fi
    [[ -n "$FORWARDEMAIL_KEY" && "$FORWARDEMAIL_KEY" != PASTE_* ]] \
        || die "FORWARDEMAIL_KEY not configured. Edit $FE_KEY_FILE or export FORWARDEMAIL_KEY=..."
fi

# Namecheap credentials (optional — skip NS update if absent)
NC_API_USER="${NC_API_USER:-}"
NC_API_KEY="${NC_API_KEY:-}"
NC_USERNAME="${NC_USERNAME:-}"
NC_AVAILABLE=false

if [[ -z "$NC_API_KEY" ]] && [[ -f "$NC_KEY_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$NC_KEY_FILE"
fi

if [[ -n "${NC_API_KEY:-}" && "${NC_API_KEY}" != PASTE_* ]]; then
    NC_AVAILABLE=true
fi

# ─── Banner ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=========================================${RESET}"
echo -e "${BOLD}  Domain Onboarding${RESET}"
echo    "  Domain:   $DOMAIN"
echo    "  VPS:      $VPS_HOST ($VPS_IP)"
[[ -n "$FORWARD_TO" ]] && echo "  Email:    *@$DOMAIN → $FORWARD_TO" || echo "  Email:    (none)"
$NC_AVAILABLE && echo "  Namecheap: credentials loaded" || echo "  Namecheap: (no credentials — NS update will be manual)"
echo -e "${BOLD}=========================================${RESET}"
echo ""

# ─── Step 1: Create Cloudflare zone ──────────────────────────────────────────

step "Step 1/7: Cloudflare zone"

CF_ZONE_RESPONSE=$(curl -s -X POST "$CF_BASE/zones" \
    -H "Authorization: Bearer $CF_ACCOUNT_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"name\":\"$DOMAIN\",\"account\":{\"id\":\"$CF_ACCOUNT_ID\"},\"jump_start\":false}")

CF_ZONE_SUCCESS=$(echo "$CF_ZONE_RESPONSE" | jq -r '.success')
CF_ZONE_ID=""
CF_NAMESERVERS=""

if [[ "$CF_ZONE_SUCCESS" == "true" ]]; then
    CF_ZONE_ID=$(echo "$CF_ZONE_RESPONSE" | jq -r '.result.id')
    CF_NAMESERVERS=$(echo "$CF_ZONE_RESPONSE" | jq -r '.result.name_servers | join(" ")')
    success "Zone created  ID: $CF_ZONE_ID"
    info "Nameservers: $CF_NAMESERVERS"
    mark_ok "cf_zone" "$CF_ZONE_ID"
else
    CF_ERRORS=$(echo "$CF_ZONE_RESPONSE" | jq -r '.errors[] | "\(.code): \(.message)"' 2>/dev/null || echo "$CF_ZONE_RESPONSE")
    if echo "$CF_ERRORS" | grep -qi "already exists\|1061"; then
        warn "Zone already exists — fetching..."
        EXISTING=$(curl -s "$CF_BASE/zones?name=$DOMAIN" -H "Authorization: Bearer $CF_ACCOUNT_TOKEN")
        CF_ZONE_ID=$(echo "$EXISTING" | jq -r '.result[0].id')
        CF_NAMESERVERS=$(echo "$EXISTING" | jq -r '.result[0].name_servers | join(" ")')
        [[ "$CF_ZONE_ID" != "null" && -n "$CF_ZONE_ID" ]] || die "Could not retrieve existing zone ID."
        success "Using existing zone  ID: $CF_ZONE_ID"
        mark_warn "cf_zone" "Zone already existed — re-used $CF_ZONE_ID"
    else
        mark_fail "cf_zone" "$CF_ERRORS"
        die "Failed to create Cloudflare zone: $CF_ERRORS"
    fi
fi

# ─── Step 2: DNS records ──────────────────────────────────────────────────────

step "Step 2/7: DNS records"

DNS_FAILURES=()

cf_dns() {
    local type="$1" name="$2" content="$3" priority="${4:-}" proxied="${5:-false}"
    local data="{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"ttl\":1,\"proxied\":$proxied}"
    [[ -n "$priority" ]] && data=$(echo "$data" | jq --argjson p "$priority" '. + {priority: $p}')
    local resp ok err
    resp=$(curl -s -X POST "$CF_BASE/zones/$CF_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_ACCOUNT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$data")
    ok=$(echo "$resp" | jq -r '.success')
    if [[ "$ok" == "true" ]]; then
        success "  $type $name → $content"
    else
        err=$(echo "$resp" | jq -r '.errors[] | "\(.code): \(.message)"' 2>/dev/null || echo "$resp")
        if echo "$err" | grep -q "81057\|already exists"; then
            warn "  $type $name → already exists, skipping"
        else
            warn "  $type $name → FAILED: $err"
            DNS_FAILURES+=("$type $name: $err")
        fi
    fi
}

cf_dns A    "$DOMAIN" "$VPS_IP" "" true
cf_dns CNAME "www"    "$DOMAIN" "" true

if [[ -n "$FORWARD_TO" ]]; then
    cf_dns MX  "$DOMAIN"        "mx1.forwardemail.net"                            10
    cf_dns MX  "$DOMAIN"        "mx2.forwardemail.net"                            20
    cf_dns TXT "$DOMAIN"        "v=spf1 include:spf.forwardemail.net ~all"
    cf_dns TXT "_dmarc.$DOMAIN" "v=DMARC1; p=quarantine; rua=mailto:dmarc@$DOMAIN"
    cf_dns TXT "$DOMAIN"        "forward-email=$FORWARD_TO"
fi

if [[ ${#DNS_FAILURES[@]} -eq 0 ]]; then
    mark_ok "dns" "All records created"
else
    mark_warn "dns" "${#DNS_FAILURES[@]} record(s) failed: ${DNS_FAILURES[*]}"
fi

# ─── Step 3: ForwardEmail ─────────────────────────────────────────────────────

step "Step 3/7: ForwardEmail"

if [[ -n "$FORWARD_TO" ]]; then
    # Register domain
    FE_DOMAIN_RESP=$(curl -s -X POST "$FE_BASE/domains" \
        -u "$FORWARDEMAIL_KEY:" \
        -H "Content-Type: application/json" \
        --data "{\"domain\":\"$DOMAIN\"}")

    FE_DOMAIN_ID=$(echo "$FE_DOMAIN_RESP" | jq -r '.id // empty')
    FE_DOMAIN_ERR=$(echo "$FE_DOMAIN_RESP" | jq -r '.message // empty')

    if [[ -n "$FE_DOMAIN_ID" ]]; then
        success "Domain registered with ForwardEmail (id: $FE_DOMAIN_ID)"
    elif echo "$FE_DOMAIN_ERR" | grep -qi "already exists\|duplicate"; then
        warn "Domain already registered with ForwardEmail — continuing"
    else
        warn "ForwardEmail domain registration response: $FE_DOMAIN_RESP"
    fi

    # Create catch-all alias
    FE_ALIAS_RESP=$(curl -s -X POST "$FE_BASE/domains/$DOMAIN/aliases" \
        -u "$FORWARDEMAIL_KEY:" \
        -H "Content-Type: application/json" \
        --data "{\"name\":\"*\",\"recipients\":[\"$FORWARD_TO\"],\"description\":\"Catch-all for $DOMAIN\"}")

    FE_ALIAS_ID=$(echo "$FE_ALIAS_RESP" | jq -r '.id // empty')
    FE_ALIAS_ERR=$(echo "$FE_ALIAS_RESP" | jq -r '.message // .error // empty')

    if [[ -n "$FE_ALIAS_ID" ]]; then
        success "Alias created: *@$DOMAIN → $FORWARD_TO"
        mark_ok "forwardemail" "*@$DOMAIN → $FORWARD_TO"
    elif echo "$FE_ALIAS_ERR" | grep -qi "already exists\|duplicate"; then
        warn "Alias already exists — skipping"
        mark_warn "forwardemail" "Alias already existed"
    else
        warn "Failed to create alias: $FE_ALIAS_ERR"
        mark_fail "forwardemail" "Alias creation failed: $FE_ALIAS_ERR"
    fi
else
    info "Skipped (no forward-to address)"
    mark_skip "forwardemail" "No forward-to address provided"
fi

# ─── Step 4: Namecheap nameserver update ─────────────────────────────────────

step "Step 4/7: Namecheap nameserver update"

NC_CURRENT_NS=""

if $NC_AVAILABLE && [[ -n "$CF_NAMESERVERS" ]]; then
    # Detect public IP (Namecheap requires whitelisted IP in the request)
    CLIENT_IP=$(curl -s https://api.ipify.org || curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
    [[ -n "$CLIENT_IP" ]] || die "Could not detect public IP (required by Namecheap API)"
    info "Client IP: $CLIENT_IP"

    # Comma-separate the nameservers for Namecheap
    NC_NS_PARAM=$(echo "$CF_NAMESERVERS" | tr ' ' ',')

    NC_RESP=$(curl -s -G "$NC_BASE" \
        --data-urlencode "ApiUser=$NC_API_USER" \
        --data-urlencode "ApiKey=$NC_API_KEY" \
        --data-urlencode "UserName=$NC_USERNAME" \
        --data-urlencode "ClientIp=$CLIENT_IP" \
        --data-urlencode "Command=namecheap.domains.dns.setCustom" \
        --data-urlencode "SLD=$SLD" \
        --data-urlencode "TLD=$TLD" \
        --data-urlencode "Nameservers=$NC_NS_PARAM")

    NC_STATUS=$(echo "$NC_RESP" | grep -oP '(?<=Status=")[^"]+' || echo "")
    NC_ERROR=$(echo "$NC_RESP"  | grep -oP '(?<=<Error[^>]*>)[^<]+' | head -1 || echo "")

    if echo "$NC_RESP" | grep -q 'IsSuccess="true"'; then
        success "Namecheap nameservers updated:"
        for ns in $CF_NAMESERVERS; do echo "    $ns"; done
        mark_ok "namecheap" "Nameservers set to: $CF_NAMESERVERS"
    elif echo "$NC_ERROR" | grep -qi "not found\|2019166"; then
        warn "Domain $DOMAIN not found in Namecheap account — may be at another registrar"
        mark_warn "namecheap" "Domain not found in Namecheap — update NS manually"
    elif echo "$NC_ERROR" | grep -qi "whitelisted\|2030280"; then
        warn "IP $CLIENT_IP is not whitelisted in Namecheap API settings"
        warn "Whitelist it at: https://ap.www.namecheap.com/settings/tools/apiaccess/"
        mark_warn "namecheap" "IP $CLIENT_IP not whitelisted — add it in Namecheap API settings, then re-run"
    else
        warn "Namecheap API response: $NC_RESP"
        mark_warn "namecheap" "Unexpected response — check above output. NS update may need manual action."
    fi
else
    if ! $NC_AVAILABLE; then
        info "Skipped (no Namecheap credentials — edit $NC_KEY_FILE to enable)"
        mark_skip "namecheap" "No credentials. Edit $NC_KEY_FILE then re-run, or update NS manually."
    else
        warn "Skipped (no nameservers returned from Cloudflare)"
        mark_skip "namecheap" "No Cloudflare nameservers to set"
    fi
fi

# ─── Step 5: Apache vhost on VPS ─────────────────────────────────────────────

step "Step 5/7: Apache vhost on $VPS_HOST"

VHOST_BLOCK="<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /var/www/$DOMAIN/public_html

    <Directory /var/www/$DOMAIN/public_html>
        Options -Indexes -FollowSymLinks
        AllowOverride FileInfo
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>"

PLACEHOLDER_HTML="<!DOCTYPE html>
<html lang=\"en\">
<head><meta charset=\"UTF-8\"><title>${DOMAIN}</title></head>
<body><h1>${DOMAIN}</h1><p>Coming soon.</p></body>
</html>"

if ssh -p "$VPS_SSH_PORT" "$VPS_USER@$VPS_HOST" bash -s -- "$DOMAIN" "$VHOST_BLOCK" "$PLACEHOLDER_HTML" <<'SSHEOF'
set -euo pipefail
DOMAIN="$1"
VHOST_BLOCK="$2"
PLACEHOLDER_HTML="$3"

mkdir -p "/var/www/$DOMAIN/public_html"
chown -R www-data:www-data "/var/www/$DOMAIN"
chmod -R 755 "/var/www/$DOMAIN"

if [[ ! -f "/var/www/$DOMAIN/public_html/index.html" ]]; then
    printf '%s\n' "$PLACEHOLDER_HTML" > "/var/www/$DOMAIN/public_html/index.html"
fi

printf '%s\n' "$VHOST_BLOCK" > "/etc/apache2/sites-available/${DOMAIN}.conf"
a2ensite "${DOMAIN}.conf" >/dev/null 2>&1
apache2ctl configtest
systemctl reload apache2
echo "ok"
SSHEOF
then
    success "Apache vhost enabled: /etc/apache2/sites-available/$DOMAIN.conf"
    mark_ok "apache" "/var/www/$DOMAIN/public_html"
else
    warn "SSH command returned non-zero — check Apache config on VPS"
    mark_warn "apache" "vhost may not be fully configured — verify on VPS"
fi

# ─── Step 6: Let's Encrypt SSL ────────────────────────────────────────────────

step "Step 6/7: Let's Encrypt SSL"

warn "HTTP-01 challenge requires DNS to be propagated and Cloudflare to proxy to VPS."
info "If this fails, re-run once DNS is live: certbot --apache -d $DOMAIN -d www.$DOMAIN"

CERT_STATUS="ok"

if ssh -p "$VPS_SSH_PORT" "$VPS_USER@$VPS_HOST" bash -s -- "$DOMAIN" <<'SSHEOF'
set -uo pipefail
DOMAIN="$1"
if ! command -v certbot &>/dev/null; then
    echo "[warn] certbot not installed"
    exit 1
fi
certbot --apache \
    --non-interactive \
    --agree-tos \
    --email "admin@${DOMAIN}" \
    -d "$DOMAIN" \
    -d "www.${DOMAIN}" \
    --redirect 2>&1
SSHEOF
then
    success "SSL certificate issued and HTTPS redirect configured"
    mark_ok "ssl" "Let's Encrypt cert active for $DOMAIN + www"
else
    warn "certbot exited non-zero — SSL may need to be issued once DNS propagates"
    CERT_STATUS="warn"
    mark_warn "ssl" "Run: certbot --apache -d $DOMAIN -d www.$DOMAIN (after DNS propagates)"
fi

# ─── Step 7: Save zone info ───────────────────────────────────────────────────

step "Step 7/7: Saving zone info"

{
    printf "\n# Added by domain-onboard.sh on %s\n" "$(date +%Y-%m-%d)"
    printf "│ %-21s │ %-32s │ %-40s │\n" "$DOMAIN" "$CF_ZONE_ID" "$CF_ACCOUNT_TOKEN"
} >> "$CF_API_FILE"

success "Appended to $CF_API_FILE"
mark_ok "saved" "$CF_ZONE_ID"

# ─── Admin Summary ────────────────────────────────────────────────────────────

status_icon() {
    case "${STEP_STATUS[$1]:-unknown}" in
        ok)   echo -e "${GREEN}[✓]${RESET}" ;;
        warn) echo -e "${YELLOW}[~]${RESET}" ;;
        skip) echo -e "${DIM}[-]${RESET}"   ;;
        fail) echo -e "${RED}[✗]${RESET}"   ;;
        *)    echo -e "${DIM}[?]${RESET}"   ;;
    esac
}

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Onboarding Summary — $DOMAIN${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════${RESET}"
echo ""
echo -e "  $(status_icon cf_zone)      Cloudflare zone    ${DIM}${STEP_NOTE[cf_zone]:-}${RESET}"
echo -e "  $(status_icon dns)          DNS records        ${DIM}${STEP_NOTE[dns]:-}${RESET}"
echo -e "  $(status_icon forwardemail) ForwardEmail       ${DIM}${STEP_NOTE[forwardemail]:-}${RESET}"
echo -e "  $(status_icon namecheap)    Namecheap NS       ${DIM}${STEP_NOTE[namecheap]:-}${RESET}"
echo -e "  $(status_icon apache)       Apache vhost       ${DIM}${STEP_NOTE[apache]:-}${RESET}"
echo -e "  $(status_icon ssl)          SSL cert           ${DIM}${STEP_NOTE[ssl]:-}${RESET}"
echo -e "  $(status_icon saved)        Credentials saved  ${DIM}${STEP_NOTE[saved]:-}${RESET}"

# ─── Admin Todos ──────────────────────────────────────────────────────────────

TODOS=()

# Namecheap NS
case "${STEP_STATUS[namecheap]:-}" in
    skip)
        TODOS+=("Point nameservers to Cloudflare at your registrar:")
        for ns in $CF_NAMESERVERS; do TODOS+=("    → $ns"); done
        ;;
    warn)
        TODOS+=("Namecheap NS update incomplete: ${STEP_NOTE[namecheap]:-}")
        TODOS+=("  Nameservers to set: $CF_NAMESERVERS")
        ;;
esac

# DNS propagation
TODOS+=("Verify DNS propagation (may take up to 24h):")
TODOS+=("    dig NS $DOMAIN +short")
TODOS+=("    dig A  $DOMAIN +short")

# SSL
if [[ "${STEP_STATUS[ssl]:-}" != "ok" ]]; then
    TODOS+=("Issue SSL cert once DNS is live:")
    TODOS+=("    ssh root@$VPS_HOST certbot --apache -d $DOMAIN -d www.$DOMAIN")
fi

# Email
if [[ -n "$FORWARD_TO" ]]; then
    TODOS+=("Verify email forwarding:")
    TODOS+=("    Send a test to: anything@$DOMAIN")
    TODOS+=("    Expected destination: $FORWARD_TO")
fi

# Site verification
TODOS+=("Verify live site:")
TODOS+=("    curl -sI https://$DOMAIN | head -5")

# Scoped CF token
TODOS+=("(Optional) Create a scoped Cloudflare API token for $DOMAIN")
TODOS+=("  and replace the account token in $CF_API_FILE")

if [[ ${#TODOS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}  Admin Todos${RESET}"
    echo    "  ──────────────────────────────────────────────"
    for todo in "${TODOS[@]}"; do
        if [[ "$todo" == "    "* ]]; then
            echo -e "  ${DIM}$todo${RESET}"
        else
            echo    "   • $todo"
        fi
    done
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${RESET}"
echo ""
