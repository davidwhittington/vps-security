#!/usr/bin/env bash
# ssh-key-rotate.sh — SSH authorized key rotation helper
#
# Helps safely rotate SSH authorized keys for root or an admin user:
#   - Displays current authorized keys with fingerprints
#   - Backs up authorized_keys before any change
#   - Accepts a new public key and adds it
#   - Optionally removes a specified old key by fingerprint or line number
#   - Verifies new key is valid before committing
#   - Does NOT remove the last key (lockout protection)
#
# Usage:
#   bash scripts/hardening/ssh-key-rotate.sh --show
#   bash scripts/hardening/ssh-key-rotate.sh --add-key "ssh-ed25519 AAAA... comment"
#   bash scripts/hardening/ssh-key-rotate.sh --add-key "ssh-ed25519 AAAA..." --remove-line 2
#   bash scripts/hardening/ssh-key-rotate.sh --user myuser --add-key "ssh-ed25519 AAAA..."
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# --- Arg parsing ---
TARGET_USER="root"
NEW_KEY=""
REMOVE_LINE=""
SHOW_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)        TARGET_USER="$2"; shift 2 ;;
        --add-key)     NEW_KEY="$2"; shift 2 ;;
        --remove-line) REMOVE_LINE="$2"; shift 2 ;;
        --show)        SHOW_ONLY=true; shift ;;
        *)             echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Determine home directory and authorized_keys path
if [[ "$TARGET_USER" == "root" ]]; then
    USER_HOME="/root"
else
    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [[ -z "$USER_HOME" ]]; then
        echo "ERROR: User '${TARGET_USER}' not found." >&2
        exit 1
    fi
fi

AUTH_KEYS="${USER_HOME}/.ssh/authorized_keys"

echo "========================================="
echo "  SSH Key Rotation Helper"
echo "  User: ${TARGET_USER}"
echo "  Keys: ${AUTH_KEYS}"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================="
echo ""

# --- Show current keys ---
show_keys() {
    if [[ ! -f "$AUTH_KEYS" ]]; then
        echo "  No authorized_keys file found at ${AUTH_KEYS}"
        return
    fi

    echo "  Current authorized keys:"
    echo ""
    LINE=0
    while IFS= read -r key; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        LINE=$(( LINE + 1 ))
        FP=$(echo "$key" | ssh-keygen -lf /dev/stdin 2>/dev/null || echo "  (could not read fingerprint)")
        echo "  Line ${LINE}: ${FP}"
        echo "         ${key:0:60}..."
        echo ""
    done < "$AUTH_KEYS"
    echo "  Total: ${LINE} key(s)"
}

show_keys

if $SHOW_ONLY; then
    exit 0
fi

if [[ -z "$NEW_KEY" && -z "$REMOVE_LINE" ]]; then
    echo "  Nothing to do. Use --add-key or --remove-line."
    echo ""
    echo "  Usage:"
    echo "    --show                   Show current keys with fingerprints"
    echo "    --add-key \"KEY\"          Add a new public key"
    echo "    --remove-line N          Remove key at line N (after adding new key)"
    echo "    --user USERNAME          Target a non-root user (default: root)"
    exit 0
fi

# Backup current keys
BACKUP="${AUTH_KEYS}.bak.$(date '+%Y%m%d%H%M%S')"
if [[ -f "$AUTH_KEYS" ]]; then
    cp "$AUTH_KEYS" "$BACKUP"
    echo "  Backed up: ${BACKUP}"
fi

# --- Add new key ---
if [[ -n "$NEW_KEY" ]]; then
    echo ""
    echo "  Validating new key..."

    # Validate key by checking its fingerprint
    if ! echo "$NEW_KEY" | ssh-keygen -lf /dev/stdin &>/dev/null; then
        echo "ERROR: Invalid SSH public key format. Key not added." >&2
        exit 1
    fi

    FP=$(echo "$NEW_KEY" | ssh-keygen -lf /dev/stdin 2>/dev/null)
    echo "  Valid key: ${FP}"

    # Check for duplicate
    if [[ -f "$AUTH_KEYS" ]] && grep -qF "$NEW_KEY" "$AUTH_KEYS"; then
        echo "  Key already present — not adding duplicate."
    else
        mkdir -p "${USER_HOME}/.ssh"
        chmod 700 "${USER_HOME}/.ssh"
        echo "$NEW_KEY" >> "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.ssh" 2>/dev/null || true
        echo "  Key added to ${AUTH_KEYS}"
    fi
fi

# --- Remove old key by line number ---
if [[ -n "$REMOVE_LINE" ]]; then
    if ! [[ "$REMOVE_LINE" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --remove-line requires a positive integer." >&2
        exit 1
    fi

    # Count actual (non-empty, non-comment) key lines
    KEY_COUNT=$(grep -cE "^ssh-|^ecdsa-|^sk-" "$AUTH_KEYS" 2>/dev/null || echo 0)

    if [[ "$KEY_COUNT" -le 1 ]]; then
        echo "ERROR: Only ${KEY_COUNT} key(s) remaining — will not remove the last key (lockout protection)." >&2
        exit 1
    fi

    # Map line number to actual file line
    ACTUAL_LINE=0
    CURRENT=0
    while IFS= read -r line; do
        ACTUAL_LINE=$(( ACTUAL_LINE + 1 ))
        [[ -z "$line" || "$line" == \#* ]] && continue
        CURRENT=$(( CURRENT + 1 ))
        if [[ "$CURRENT" -eq "$REMOVE_LINE" ]]; then
            break
        fi
    done < "$AUTH_KEYS"

    if [[ "$CURRENT" -ne "$REMOVE_LINE" ]]; then
        echo "ERROR: Key line ${REMOVE_LINE} not found (file has ${KEY_COUNT} keys)." >&2
        exit 1
    fi

    KEY_TO_REMOVE=$(sed -n "${ACTUAL_LINE}p" "$AUTH_KEYS")
    FP=$(echo "$KEY_TO_REMOVE" | ssh-keygen -lf /dev/stdin 2>/dev/null || echo "(unknown)")
    sed -i "${ACTUAL_LINE}d" "$AUTH_KEYS"
    echo "  Removed key at line ${REMOVE_LINE}: ${FP}"
fi

# --- Final state ---
echo ""
echo "  Updated key list:"
show_keys

echo ""
echo "========================================="
echo "  Key rotation complete."
echo "  Backup: ${BACKUP:-none}"
echo ""
echo "  IMPORTANT: Test SSH login in a NEW session before"
echo "  closing this one."
echo "========================================="
