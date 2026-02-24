#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/WeOneGuy/vps-cleaner/main"
INSTALL_PATH="/usr/local/bin/vps-cleaner"
SCRIPT_NAME="vps-cleaner.sh"
CONF_FILE="$HOME/.vps-cleaner.conf"
TMP_FILE=""

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { printf "${CYAN}[*]${NC} %s\n" "$1"; }
success() { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error()   { printf "${RED}[✗]${NC} %s\n" "$1" >&2; }
die()     { error "$1"; exit 1; }

cleanup() {
    [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"
}
trap cleanup EXIT

banner() {
    printf "${GREEN}"
    printf '  _   ______  ___    ___ __                       \n'
    printf ' | | / / __ \\/ __\\  / __/ /__ ___ ____  ___ ____  \n'
    printf ' | |/ / /_/ /\\ \\   / _// / -_) _ `/ _ \\/ -_) __/ \n'
    printf ' |___/ .___/___/  /___/_/\\__/\\_,_/_//_/\\__/_/    \n'
    printf '    /_/                                            \n'
    printf "${NC}\n"
}

# --- Uninstall ---
if [[ "${1:-}" == "--uninstall" ]]; then
    banner
    info "Uninstalling VPS Cleaner..."
    [[ -f "$INSTALL_PATH" ]] && rm -f "$INSTALL_PATH" && success "Removed $INSTALL_PATH"
    [[ -f "$CONF_FILE" ]] && rm -f "$CONF_FILE" && success "Removed $CONF_FILE"
    success "VPS Cleaner uninstalled."
    exit 0
fi

# --- Root check ---
run_as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        die "Root privileges required. Install sudo or run as root."
    fi
}

# --- Download tool detection ---
download() {
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -qO "$dest" "$url"
    else
        die "Neither curl nor wget found. Install one and retry."
    fi
}

# --- Main ---
banner
info "Installing VPS Cleaner..."

# Check root/sudo availability
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        die "Root privileges required. Install sudo or run as root."
    fi
    warn "Not running as root — will use sudo."
fi

# Detect download tool
if command -v curl &>/dev/null; then
    info "Using curl for download."
elif command -v wget &>/dev/null; then
    info "Using wget for download."
else
    die "Neither curl nor wget found. Install one and retry."
fi

# Download to temp file
TMP_FILE="$(mktemp /tmp/vps-cleaner.XXXXXX)"
info "Downloading $SCRIPT_NAME..."
download "${REPO_URL}/${SCRIPT_NAME}" "$TMP_FILE"

# Validate download
[[ ! -s "$TMP_FILE" ]] && die "Download failed — file is empty."
head -c 2 "$TMP_FILE" | grep -q '#!' || die "Download failed — invalid script content."
success "Download verified."

# Install
info "Installing to $INSTALL_PATH..."
run_as_root mv "$TMP_FILE" "$INSTALL_PATH"
TMP_FILE=""  # prevent cleanup from removing installed file
run_as_root chmod +x "$INSTALL_PATH"
success "VPS Cleaner installed to $INSTALL_PATH"

# Usage instructions
printf "\n${GREEN}━━━ Installation Complete ━━━${NC}\n"
printf "  Run:       ${CYAN}vps-cleaner${NC}\n"
printf "  Uninstall: ${CYAN}curl -fsSL %s/install.sh | bash -s -- --uninstall${NC}\n\n" "$REPO_URL"

# Offer to run only in interactive TTY
if [[ -t 0 && -t 1 ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]]; then
    printf "${YELLOW}Run VPS Cleaner now? [y/N]${NC} " > /dev/tty
    answer=""
    if IFS= read -r -t 10 answer < /dev/tty; then
        answer="$(echo "$answer" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    else
        answer=""
    fi

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        exec vps-cleaner
    fi
else
    info "Non-interactive install detected. Skipping auto-run."
    info "Run manually: vps-cleaner"
fi
