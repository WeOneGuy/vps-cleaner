# ============================================================================
# DETECTION FUNCTIONS
# ============================================================================

# --- Distribution detection -------------------------------------------------

detect_distro() {
    DISTRO_NAME="unknown"
    DISTRO_VERSION=""
    DISTRO_FAMILY="unknown"
    DISTRO_PRETTY="Unknown Linux"

    # Primary: /etc/os-release
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DISTRO_NAME="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-}"
        DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_NAME $DISTRO_VERSION}"

        local id_like="${ID_LIKE:-}"
        case "$DISTRO_NAME" in
            ubuntu|debian|raspbian|linuxmint|pop|elementary|kali|parrot)
                DISTRO_FAMILY="debian" ;;
            centos|rhel|rocky|almalinux|ol|scientific|amzn)
                DISTRO_FAMILY="rhel" ;;
            fedora)
                DISTRO_FAMILY="rhel" ;;
            arch|manjaro|endeavouros|artix|garuda)
                DISTRO_FAMILY="arch" ;;
            alpine)
                DISTRO_FAMILY="alpine" ;;
            opensuse*|sles|suse)
                DISTRO_FAMILY="suse" ;;
            *)
                if echo "$id_like" | grep -qiw debian; then
                    DISTRO_FAMILY="debian"
                elif echo "$id_like" | grep -qiwE 'rhel|centos|fedora'; then
                    DISTRO_FAMILY="rhel"
                elif echo "$id_like" | grep -qiw arch; then
                    DISTRO_FAMILY="arch"
                elif echo "$id_like" | grep -qiw suse; then
                    DISTRO_FAMILY="suse"
                fi
                ;;
        esac
    # Fallback: lsb_release
    elif command -v lsb_release &>/dev/null; then
        DISTRO_NAME="$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        DISTRO_VERSION="$(lsb_release -sr 2>/dev/null)"
        DISTRO_PRETTY="$(lsb_release -sd 2>/dev/null | tr -d '"')"
        case "$DISTRO_NAME" in
            ubuntu|debian) DISTRO_FAMILY="debian" ;;
            centos|redhat*|rocky|alma*) DISTRO_FAMILY="rhel" ;;
            arch*) DISTRO_FAMILY="arch" ;;
            *suse*) DISTRO_FAMILY="suse" ;;
        esac
    # Fallback: /etc/*-release
    elif ls /etc/*-release &>/dev/null; then
        local rel_content
        rel_content="$(cat /etc/*-release 2>/dev/null | head -20)"
        DISTRO_PRETTY="$(echo "$rel_content" | head -1)"
        if echo "$rel_content" | grep -qi debian; then DISTRO_FAMILY="debian"
        elif echo "$rel_content" | grep -qiE 'centos|red.hat|rocky|alma'; then DISTRO_FAMILY="rhel"
        elif echo "$rel_content" | grep -qi arch; then DISTRO_FAMILY="arch"
        elif echo "$rel_content" | grep -qi alpine; then DISTRO_FAMILY="alpine"
        elif echo "$rel_content" | grep -qi suse; then DISTRO_FAMILY="suse"
        fi
    fi

    # Detect package manager
    case "$DISTRO_FAMILY" in
        debian)  PKG_MANAGER="apt"    ;;
        rhel)
            if command -v dnf &>/dev/null; then PKG_MANAGER="dnf"
            elif command -v yum &>/dev/null; then PKG_MANAGER="yum"
            fi ;;
        arch)    PKG_MANAGER="pacman" ;;
        alpine)  PKG_MANAGER="apk"   ;;
        suse)    PKG_MANAGER="zypper" ;;
        *)
            # Best-effort fallback
            if   command -v apt    &>/dev/null; then PKG_MANAGER="apt"
            elif command -v dnf    &>/dev/null; then PKG_MANAGER="dnf"
            elif command -v yum    &>/dev/null; then PKG_MANAGER="yum"
            elif command -v pacman &>/dev/null; then PKG_MANAGER="pacman"
            elif command -v apk    &>/dev/null; then PKG_MANAGER="apk"
            elif command -v zypper &>/dev/null; then PKG_MANAGER="zypper"
            fi ;;
    esac
}

# --- Dependency checking ----------------------------------------------------

check_dependencies() {
    local required_cmds=(du df find awk sed sort)
    local optional_cmds=(bc tput curl wget)

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            print_error "Required command '$cmd' is not available. Aborting."
            exit 1
        fi
    done

    MISSING_OPTIONAL_DEPS=()
    AVAILABLE_FEATURES=("core")

    if command -v bc &>/dev/null; then
        HAS_BC=1
        AVAILABLE_FEATURES+=("precise-math")
    else
        HAS_BC=0
        MISSING_OPTIONAL_DEPS+=("bc")
    fi

    if command -v tput &>/dev/null; then
        HAS_TPUT=1
        AVAILABLE_FEATURES+=("terminal-control")
    else
        HAS_TPUT=0
        MISSING_OPTIONAL_DEPS+=("tput")
    fi

    if command -v curl &>/dev/null; then
        HAS_CURL=1
        AVAILABLE_FEATURES+=("update-check")
    else
        HAS_CURL=0
        if command -v wget &>/dev/null; then
            HAS_WGET=1
            AVAILABLE_FEATURES+=("update-check")
        else
            HAS_WGET=0
            MISSING_OPTIONAL_DEPS+=("curl or wget")
        fi
    fi

    # Check du -sb support (BusyBox du on Alpine lacks -b flag)
    if du -sb /dev/null &>/dev/null 2>&1; then
        HAS_DU_BYTES=1
    fi

    # Service-specific detections
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        HAS_DOCKER=1
        AVAILABLE_FEATURES+=("docker")
    fi

    if command -v snap &>/dev/null; then
        HAS_SNAP=1
        AVAILABLE_FEATURES+=("snap")
    fi

    if command -v flatpak &>/dev/null; then
        HAS_FLATPAK=1
        AVAILABLE_FEATURES+=("flatpak")
    fi
}

offer_install_optional_deps() {
    if [[ ${#MISSING_OPTIONAL_DEPS[@]} -eq 0 ]]; then return; fi

    print_warning "Optional dependencies missing: ${MISSING_OPTIONAL_DEPS[*]}"
    print_info "Some features may be limited."

    if confirm "Install missing optional dependencies?" "y"; then
        for dep in "${MISSING_OPTIONAL_DEPS[@]}"; do
            [[ "$dep" == "curl or wget" ]] && dep="curl"
            [[ "$dep" == "tput" ]] && dep="ncurses-bin" # Common provider
            printf '  Installing %s...\n' "$dep"
            case "$PKG_MANAGER" in
                apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$dep" || print_warning "Failed to install $dep" ;;
                dnf)    dnf install -y "$dep" || print_warning "Failed to install $dep" ;;
                yum)    yum install -y "$dep" || print_warning "Failed to install $dep" ;;
                pacman) pacman -S --noconfirm "$dep" || print_warning "Failed to install $dep" ;;
                apk)    apk add "$dep" || print_warning "Failed to install $dep" ;;
                zypper) zypper install -y "$dep" || print_warning "Failed to install $dep" ;;
            esac
        done
        # Restore terminal state in case package manager changed it
        stty sane 2>/dev/null || true
        # Re-check after install attempt
        check_dependencies
    fi
}

# --- Root check -------------------------------------------------------------

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo ""
        print_error "This script must be run as root."
        print_info "Try: sudo $0"
        echo ""
        exit 1
    fi
}

ensure_log_file() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
}

initialize_runtime() {
    setup_colors
    detect_distro
    check_dependencies
    load_config
    ensure_log_file
}

initialize_interactive_runtime() {
    setup_colors
    check_root
    detect_distro
    check_dependencies
    load_config
    ensure_log_file
    record_disk_start
    auto_update_check

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo ""
        print_warning "DRY-RUN MODE ENABLED. No changes will be made."
    fi
}
