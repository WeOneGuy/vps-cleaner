#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/WeOneGuy/vps-cleaner/main"
INSTALL_PATH="/usr/local/bin/vps-cleaner"
SCRIPT_NAME="vps-cleaner.sh"
VERSION_FILE_NAME="VERSION"
CONF_FILE="$HOME/.vps-cleaner.conf"
TMP_FILE=""
TMP_VERSION_FILE=""

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { printf "${CYAN}[*]${NC} %s\n" "$1"; }
success() { printf "${GREEN}[?]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error()   { printf "${RED}[?]${NC} %s\n" "$1" >&2; }
die()     { error "$1"; exit 1; }

cleanup() {
    [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"
    [[ -n "$TMP_VERSION_FILE" && -f "$TMP_VERSION_FILE" ]] && rm -f "$TMP_VERSION_FILE"
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

is_valid_semver() {
    local version="${1:-}"
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ ]] || return 1

    local prerelease=""
    if [[ "$version" == *-* ]]; then
        prerelease="${version#*-}"
        prerelease="${prerelease%%+*}"
    fi

    if [[ -n "$prerelease" ]]; then
        local identifier
        local -a identifiers=()
        IFS='.' read -r -a identifiers <<< "$prerelease"
        for identifier in "${identifiers[@]}"; do
            [[ -n "$identifier" ]] || return 1
            if [[ "$identifier" =~ ^[0-9]+$ ]] && [[ "$identifier" =~ ^0[0-9]+$ ]]; then
                return 1
            fi
        done
    fi

    return 0
}

extract_script_version_from_file() {
    local script_path="${1:-}"
    [[ -n "$script_path" && -f "$script_path" ]] || return 1

    local version=""
    version="$(sed -nE 's/^[[:space:]]*readonly[[:space:]]+SCRIPT_VERSION="([^"]+)".*$/\1/p' "$script_path" 2>/dev/null | head -1)"
    is_valid_semver "$version" || return 1
    printf '%s' "$version"
}

stamp_script_version_in_file() {
    local script_path="${1:-}" target_version="${2:-}"
    [[ -n "$script_path" && -f "$script_path" ]] || return 1
    is_valid_semver "$target_version" || return 1

    local tmp_file=""
    tmp_file="$(mktemp /tmp/vps-cleaner-stamp.XXXXXX)" || return 1

    if ! awk -v version="$target_version" '
        BEGIN { replaced=0 }
        /^[[:space:]]*readonly[[:space:]]+SCRIPT_VERSION="[^"]*".*$/ {
            if (replaced == 0) {
                print "readonly SCRIPT_VERSION=\"" version "\""
                replaced=1
                next
            }
        }
        { print }
        END { if (replaced == 0) exit 1 }
    ' "$script_path" > "$tmp_file"; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi

    if ! cat "$tmp_file" > "$script_path"; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi

    rm -f "$tmp_file" 2>/dev/null || true
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
TMP_VERSION_FILE="$(mktemp /tmp/vps-cleaner-version.XXXXXX)"
info "Downloading $SCRIPT_NAME..."
download "${REPO_URL}/${SCRIPT_NAME}" "$TMP_FILE"
info "Downloading $VERSION_FILE_NAME..."
download "${REPO_URL}/${VERSION_FILE_NAME}" "$TMP_VERSION_FILE"

[[ ! -s "$TMP_FILE" ]] && die "Download failed - file is empty."
[[ ! -s "$TMP_VERSION_FILE" ]] && die "Download failed - version file is empty."
head -c 2 "$TMP_FILE" | grep -q '#!' || die "Download failed - invalid script content."

REMOTE_VERSION="$(head -n 1 "$TMP_VERSION_FILE" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
is_valid_semver "$REMOTE_VERSION" || die "Download failed - invalid version format in VERSION file."

stamp_script_version_in_file "$TMP_FILE" "$REMOTE_VERSION" || die "Download failed - unable to apply version stamp."
EXTRACTED_VERSION="$(extract_script_version_from_file "$TMP_FILE" || true)"
[[ "$EXTRACTED_VERSION" == "$REMOTE_VERSION" ]] || die "Download failed - script version stamp mismatch."

chmod +x "$TMP_FILE"
success "Download verified."

printf "\n${GREEN}--- One-Time Launch ---${NC}\n"
printf "  The script will run now and be deleted after exit.\n"
printf "  Permanent install is optional from menu: ${CYAN}11) Install/Update vps-cleaner${NC}\n\n"

exec "$TMP_FILE" "$@"
