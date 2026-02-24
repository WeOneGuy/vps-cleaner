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
success() { printf "${GREEN}[?]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error()   { printf "${RED}[?]${NC} %s\n" "$1" >&2; }
die()     { error "$1"; exit 1; }

cleanup() {
    [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"
}
trap cleanup EXIT

banner() {
    printf "${GREEN}"
printf "██╗   ██╗██████╗ ███████╗\n"                                 
printf "██║   ██║██╔══██╗██╔════╝\n"                                  
printf "██║   ██║██████╔╝███████╗\n"                                  
printf "╚██╗ ██╔╝██╔═══╝ ╚════██║\n"                                  
printf " ╚████╔╝ ██║     ███████║\n"                                  
printf "  ╚═══╝  ╚═╝     ╚══════╝\n\n"                                                                
printf " ██████╗██╗     ███████╗ █████╗ ███╗   ██╗███████╗██████╗\n"  
printf "██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║██╔════╝██╔══██╗\n" 
printf "██║     ██║     █████╗  ███████║██╔██╗ ██║█████╗  ██████╔╝\n" 
printf "██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║██╔══╝  ██╔══██╗\n" 
printf "╚██████╗███████╗███████╗██║  ██║██║ ╚████║███████╗██║  ██║\n" 
printf " ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝\n\n" 


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
info "Starting VPS Cleaner (ephemeral mode)..."

if command -v curl &>/dev/null; then
    info "Using curl for download."
elif command -v wget &>/dev/null; then
    info "Using wget for download."
else
    die "Neither curl nor wget found. Install one and retry."
fi

TMP_FILE="$(mktemp /tmp/vps-cleaner.XXXXXX)"
info "Downloading $SCRIPT_NAME..."
download "${REPO_URL}/${SCRIPT_NAME}" "$TMP_FILE"

[[ ! -s "$TMP_FILE" ]] && die "Download failed - file is empty."
head -c 2 "$TMP_FILE" | grep -q '#!' || die "Download failed - invalid script content."
chmod +x "$TMP_FILE"
success "Download verified."

printf "\n${GREEN}--- One-Time Launch ---${NC}\n"
printf "  The script will run now and be deleted after exit.\n"
printf "  Permanent install is optional from menu: ${CYAN}11) Install/Update vps-cleaner${NC}\n\n"

exec "$TMP_FILE" "$@"