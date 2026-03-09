#!/usr/bin/env bash
# install.sh — linux-security single-command installer
#
# Copies scripts to /opt/linux-security/, config templates to
# /etc/linux-security/, and symlinks the entry points into /usr/local/bin/.
# Run as root on the target server.
set -euo pipefail

usage() {
    cat <<EOF
Usage: install.sh [OPTIONS]

Install, upgrade, or uninstall linux-security system-wide. Must be run as root.

Options:
  --prefix PATH     Install scripts to PATH instead of /opt/linux-security
  --no-symlinks     Skip creating symlinks in /usr/local/bin/
  --upgrade         Upgrade an existing install; preserves /etc/linux-security/ config
  --uninstall       Remove installed files; preserves /etc/linux-security/ config
  --help, -h        Show this help

After install, files are placed at:
  /opt/linux-security/          scripts, profiles, lib, docs, VERSION
  /etc/linux-security/          config.env and config.web.env (from examples, first install only)
  /usr/local/bin/
    linux-security-bootstrap    symlink to bootstrap.sh
    linux-security-audit        symlink to scripts/audit/audit.sh

Examples:
  bash install.sh                          # install from local clone
  bash install.sh --prefix /opt/custom     # custom install directory
  bash install.sh --no-symlinks            # skip /usr/local/bin/ symlinks
  bash install.sh --upgrade                # upgrade scripts, preserve config
  bash install.sh --uninstall              # remove installed files

  # Remote one-liner (run as root on target server):
  curl -fsSL https://raw.githubusercontent.com/davidwhittington/linux-security/main/install.sh | bash
EOF
}

# --- Defaults ---
INSTALL_PREFIX="/opt/linux-security"
CONFIG_DIR="/etc/linux-security"
SYMLINK_DIR="/usr/local/bin"
MODE="install"       # install | upgrade | uninstall
DO_SYMLINKS=true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            INSTALL_PREFIX="${2:?--prefix requires a value}"
            shift ;;
        --no-symlinks)
            DO_SYMLINKS=false ;;
        --upgrade)
            MODE="upgrade" ;;
        --uninstall)
            MODE="uninstall" ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage >&2; exit 1 ;;
    esac
    shift
done

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: install.sh must be run as root." >&2
    exit 1
fi

# --- OS check ---
if [[ ! -f /etc/os-release ]]; then
    echo "WARNING: /etc/os-release not found — OS detection skipped." >&2
else
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        echo "WARNING: linux-security is tested on Ubuntu 22.04/24.04 and Debian 12." >&2
        echo "  Detected: ${PRETTY_NAME:-$OS_ID}" >&2
        echo "  Proceeding, but some scripts may require adjustment." >&2
    fi
fi

# --- Banner ---
echo "========================================="
echo "  linux-security installer"
echo "  Mode:    $MODE"
echo "  Prefix:  $INSTALL_PREFIX"
echo "  Config:  $CONFIG_DIR"
echo "  Links:   $SYMLINK_DIR"
echo "========================================="
echo ""

# ============================================================
# UNINSTALL
# ============================================================
if [[ "$MODE" == "uninstall" ]]; then
    echo "[1/3] Removing symlinks from $SYMLINK_DIR..."
    rm -f "$SYMLINK_DIR/linux-security-bootstrap"
    rm -f "$SYMLINK_DIR/linux-security-audit"
    echo "  -> Symlinks removed."

    echo ""
    echo "[2/3] Removing install directory $INSTALL_PREFIX..."
    if [[ -d "$INSTALL_PREFIX" ]]; then
        rm -rf "$INSTALL_PREFIX"
        echo "  -> $INSTALL_PREFIX removed."
    else
        echo "  -> $INSTALL_PREFIX not found (already removed?)."
    fi

    echo ""
    echo "[3/3] Preserving config directory $CONFIG_DIR..."
    echo "  -> Config preserved. Remove manually if desired:"
    echo "     rm -rf $CONFIG_DIR"

    echo ""
    echo "========================================="
    echo "  Uninstall complete."
    echo "========================================="
    exit 0
fi

# ============================================================
# INSTALL / UPGRADE
# ============================================================

# Validate source: install.sh must be run from the repo root
REQUIRED_FILES=(bootstrap.sh profiles/baseline.conf lib/output.sh scripts/core/audit/preflight-check.sh)
for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        echo "ERROR: $SCRIPT_DIR/$f not found." >&2
        echo "  Run install.sh from the linux-security repo root." >&2
        exit 1
    fi
done

# Determine version
VERSION=""
if command -v git &>/dev/null && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    VERSION=$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)
fi
VERSION="${VERSION:-unknown}"

# --- Step 1: Copy files ---
STEP=1
echo "[$STEP/4] Copying scripts to $INSTALL_PREFIX..."
if [[ "$MODE" == "upgrade" && -d "$INSTALL_PREFIX" ]]; then
    INSTALLED_VERSION=""
    [[ -f "$INSTALL_PREFIX/VERSION" ]] && INSTALLED_VERSION=$(cat "$INSTALL_PREFIX/VERSION")
    if [[ -n "$INSTALLED_VERSION" ]]; then
        echo "  Upgrading from ${INSTALLED_VERSION} -> ${VERSION}"
    fi
fi

mkdir -p "$INSTALL_PREFIX"

# Copy everything except the config examples (handled separately) and git internals
rsync -a --exclude='.git' --exclude='config.env' --exclude='config.web.env' \
      --exclude='config.env.example' --exclude='config.web.env.example' \
      "$SCRIPT_DIR/" "$INSTALL_PREFIX/" 2>/dev/null \
|| {
    # rsync not available — use cp
    cp -r "$SCRIPT_DIR/." "$INSTALL_PREFIX/"
    rm -rf "$INSTALL_PREFIX/.git" 2>/dev/null || true
    rm -f "$INSTALL_PREFIX/config.env" "$INSTALL_PREFIX/config.web.env" 2>/dev/null || true
}

# Always install examples (safe to overwrite — they are not user config)
[[ -f "$SCRIPT_DIR/config.env.example" ]] && cp "$SCRIPT_DIR/config.env.example" "$INSTALL_PREFIX/config.env.example"
[[ -f "$SCRIPT_DIR/config.web.env.example" ]] && cp "$SCRIPT_DIR/config.web.env.example" "$INSTALL_PREFIX/config.web.env.example"

# Write VERSION file
echo "$VERSION" > "$INSTALL_PREFIX/VERSION"

echo "  -> Files installed."

# --- Step 2: Set permissions ---
STEP=2
echo ""
echo "[$STEP/4] Setting permissions..."
find "$INSTALL_PREFIX" -type f -name "*.sh" -exec chmod 750 {} \;
find "$INSTALL_PREFIX" -type f ! -name "*.sh" -exec chmod 640 {} \;
find "$INSTALL_PREFIX" -type d -exec chmod 750 {} \;
# Ensure bootstrap and audit dispatcher are executable
chmod 750 "$INSTALL_PREFIX/bootstrap.sh" 2>/dev/null || true
chmod 750 "$INSTALL_PREFIX/scripts/audit/audit.sh" 2>/dev/null || true
echo "  -> Permissions set (scripts: 750, data files: 640)."

# --- Step 3: Config directory ---
STEP=3
echo ""
echo "[$STEP/4] Configuring $CONFIG_DIR..."
mkdir -p "$CONFIG_DIR"
chmod 750 "$CONFIG_DIR"

if [[ ! -f "$CONFIG_DIR/config.env" ]]; then
    if [[ -f "$INSTALL_PREFIX/config.env.example" ]]; then
        cp "$INSTALL_PREFIX/config.env.example" "$CONFIG_DIR/config.env"
        chmod 640 "$CONFIG_DIR/config.env"
        echo "  -> Created $CONFIG_DIR/config.env from example."
        echo "     Edit it before running bootstrap.sh."
    else
        echo "  WARNING: config.env.example not found — create $CONFIG_DIR/config.env manually."
    fi
else
    echo "  -> $CONFIG_DIR/config.env exists — not overwritten."
fi

if [[ ! -f "$CONFIG_DIR/config.web.env" ]]; then
    if [[ -f "$INSTALL_PREFIX/config.web.env.example" ]]; then
        cp "$INSTALL_PREFIX/config.web.env.example" "$CONFIG_DIR/config.web.env"
        chmod 640 "$CONFIG_DIR/config.web.env"
        echo "  -> Created $CONFIG_DIR/config.web.env from example."
    fi
else
    echo "  -> $CONFIG_DIR/config.web.env exists — not overwritten."
fi

# --- Step 4: Symlinks ---
STEP=4
echo ""
echo "[$STEP/4] Installing symlinks..."
if $DO_SYMLINKS; then
    mkdir -p "$SYMLINK_DIR"
    ln -sf "$INSTALL_PREFIX/bootstrap.sh" "$SYMLINK_DIR/linux-security-bootstrap"
    ln -sf "$INSTALL_PREFIX/scripts/audit/audit.sh" "$SYMLINK_DIR/linux-security-audit"
    echo "  -> linux-security-bootstrap -> $INSTALL_PREFIX/bootstrap.sh"
    echo "  -> linux-security-audit     -> $INSTALL_PREFIX/scripts/audit/audit.sh"
else
    echo "  -> Skipped (--no-symlinks)."
fi

# --- Summary ---
echo ""
echo "========================================="
if [[ "$MODE" == "upgrade" ]]; then
    echo "  Upgrade complete! Version: $VERSION"
else
    echo "  Installation complete! Version: $VERSION"
fi
echo ""
echo "  Next steps:"
echo "  1. Edit $CONFIG_DIR/config.env"
echo "     (set ADMIN_EMAIL, SSH_PORT, ADMIN_USER, SMTP_* vars)"
echo ""
echo "  2. Run the pre-flight check:"
echo "     bash $INSTALL_PREFIX/scripts/core/audit/preflight-check.sh"
echo ""
echo "  3. Run bootstrap (baseline = no Apache deps):"
echo "     bash $INSTALL_PREFIX/bootstrap.sh --profile baseline --dry-run"
echo "     bash $INSTALL_PREFIX/bootstrap.sh --profile baseline"
echo ""
if $DO_SYMLINKS; then
    echo "  Or use the installed commands:"
    echo "     linux-security-bootstrap --profile baseline --dry-run"
    echo "     linux-security-bootstrap --profile baseline"
    echo ""
fi
echo "  Installed: $INSTALL_PREFIX"
echo "  Config:    $CONFIG_DIR"
echo "  Version:   $VERSION"
echo "========================================="
