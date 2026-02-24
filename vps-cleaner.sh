#!/usr/bin/env bash
# ============================================================================
# vps-cleaner — Comprehensive VPS Disk Cleaner
# Version:  1.0.0
# GitHub:   https://github.com/WeOneGuy/vps-cleaner
# License:  MIT
# ============================================================================
# A production-quality, interactive disk cleanup tool for Linux VPS instances.
# Supports: Ubuntu/Debian, CentOS/RHEL/Rocky/Alma, Fedora, Arch, Alpine
# ============================================================================

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="vps-cleaner"
readonly SCRIPT_REPO="https://github.com/WeOneGuy/vps-cleaner"
readonly SCRIPT_RAW_URL="https://raw.githubusercontent.com/WeOneGuy/vps-cleaner/main/vps-cleaner.sh"
readonly CONFIG_FILE="${HOME}/.vps-cleaner.conf"
readonly LOG_FILE="/var/log/vps-cleaner.log"
readonly SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
readonly INSTALL_PATH="/usr/local/bin/vps-cleaner"
readonly DISK_OVERVIEW_SCAN_TIMEOUT_SEC=45

# Protected paths — NEVER delete these
readonly PROTECTED_PATHS=(
    "/" "/bin" "/sbin" "/usr" "/etc" "/boot"
    "/root" "/home" "/lib" "/lib64" "/var"
    "/usr/bin" "/usr/sbin" "/usr/lib" "/usr/lib64"
    "/usr/local" "/usr/local/bin" "/usr/local/sbin"
)

# Pseudo-filesystems to exclude from searches
readonly EXCLUDED_FS="/proc /sys /dev /run /snap"
readonly ROTATED_LOG_FIND_ARGS=(
    -name '*.gz' -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9][0-9]*' -o -name '*.xz' -o -name '*.zst'
)

# Temp file for operations
TEMP_FILE=""

# ============================================================================
# COLOR & UI SYSTEM
# ============================================================================

setup_colors() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
        RED="" ; GREEN="" ; YELLOW="" ; BLUE="" ; MAGENTA="" ; CYAN=""
        WHITE="" ; BOLD="" ; DIM="" ; RESET=""
    else
        RED=$'\033[0;31m'
        GREEN=$'\033[0;32m'
        YELLOW=$'\033[0;33m'
        BLUE=$'\033[0;34m'
        MAGENTA=$'\033[0;35m'
        CYAN=$'\033[0;36m'
        WHITE=$'\033[0;37m'
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        RESET=$'\033[0m'
    fi
}

# Unicode box-drawing characters
readonly BOX_TL="╭"
readonly BOX_TR="╮"
readonly BOX_BL="╰"
readonly BOX_BR="╯"
readonly BOX_H="─"
readonly BOX_V="│"

# Spinner frames
readonly SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# ============================================================================
# GLOBAL STATE
# ============================================================================

DISTRO_FAMILY=""
DISTRO_NAME=""
DISTRO_VERSION=""
DISTRO_PRETTY=""
PKG_MANAGER=""

DISK_START_USED=0
DRY_RUN=0
JOURNAL_RETENTION_DAYS=7
LOG_TRUNCATE_THRESHOLD_MB=50
LARGE_FILE_MIN_SIZE_MB=100
TEMP_FILE_AGE_DAYS=7
LAST_UPDATE_CHECK=0

declare -a AVAILABLE_FEATURES=()
declare -a MISSING_OPTIONAL_DEPS=()

HAS_DOCKER=0
HAS_SNAP=0
HAS_FLATPAK=0
HAS_BC=0
HAS_TPUT=0
HAS_CURL=0
HAS_WGET=0
HAS_DU_BYTES=0

# ============================================================================
# CONFIGURATION — defaults + load from file
# ============================================================================

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local key val
        while IFS='=' read -r key val; do
            key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -z "$key" || "$key" == \#* ]] && continue
            case "$key" in
                DRY_RUN)                  [[ "$val" =~ ^[01]$ ]] && DRY_RUN="${val}" ;;
                JOURNAL_RETENTION_DAYS)   [[ "$val" =~ ^[0-9]+$ ]] && JOURNAL_RETENTION_DAYS="${val}" ;;
                LOG_TRUNCATE_THRESHOLD_MB) [[ "$val" =~ ^[0-9]+$ ]] && LOG_TRUNCATE_THRESHOLD_MB="${val}" ;;
                LARGE_FILE_MIN_SIZE_MB)   [[ "$val" =~ ^[0-9]+$ ]] && LARGE_FILE_MIN_SIZE_MB="${val}" ;;
                TEMP_FILE_AGE_DAYS)       [[ "$val" =~ ^[0-9]+$ ]] && TEMP_FILE_AGE_DAYS="${val}" ;;
                LAST_UPDATE_CHECK)        [[ "$val" =~ ^[0-9]+$ ]] && LAST_UPDATE_CHECK="${val}" ;;
            esac
        done < "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# vps-cleaner configuration
# Generated on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
DRY_RUN=${DRY_RUN}
JOURNAL_RETENTION_DAYS=${JOURNAL_RETENTION_DAYS}
LOG_TRUNCATE_THRESHOLD_MB=${LOG_TRUNCATE_THRESHOLD_MB}
LARGE_FILE_MIN_SIZE_MB=${LARGE_FILE_MIN_SIZE_MB}
TEMP_FILE_AGE_DAYS=${TEMP_FILE_AGE_DAYS}
LAST_UPDATE_CHECK=${LAST_UPDATE_CHECK}
EOF
}

# ============================================================================
# UTILITY FUNCTIONS — UI, formatting, logging, size calculation
# ============================================================================

# --- Logging ----------------------------------------------------------------

log_action() {
    local category="${1:-}" action="${2:-}" bytes_freed="${3:-0}"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s [%s] %s | freed=%s\n' "$ts" "$category" "$action" "$bytes_freed" \
        >> "$LOG_FILE" 2>/dev/null || true
}

# --- Size formatting --------------------------------------------------------

format_size() {
    local bytes="${1:-0}"
    if (( bytes < 0 )); then bytes=0; fi
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1099511627776)      printf "%.2f TB", b / 1099511627776;
        else if (b >= 1073741824)    printf "%.2f GB", b / 1073741824;
        else if (b >= 1048576)       printf "%.2f MB", b / 1048576;
        else if (b >= 1024)          printf "%.2f KB", b / 1024;
        else                         printf "%d B", b;
    }'
}

# Convert human-readable size strings (e.g. "1.2G") to bytes (approximate)
parse_size_to_bytes() {
    local raw="${1:-0}"
    raw="$(echo "$raw" | sed 's/[[:space:]]//g')"
    local num unit
    num="$(echo "$raw" | sed 's/[^0-9.]//g')"
    unit="$(echo "$raw" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')"
    [[ -z "$num" ]] && num=0

    if [[ "$HAS_BC" -eq 1 ]]; then
        case "$unit" in
            T|TB) echo "$(echo "$num * 1099511627776" | bc | sed 's/\..*$//')" ;;
            G|GB) echo "$(echo "$num * 1073741824"    | bc | sed 's/\..*$//')" ;;
            M|MB) echo "$(echo "$num * 1048576"       | bc | sed 's/\..*$//')" ;;
            K|KB) echo "$(echo "$num * 1024"          | bc | sed 's/\..*$//')" ;;
            *)    echo "$(echo "$num" | sed 's/\..*$//')" ;;
        esac
    else
        local int_num
        int_num="$(echo "$num" | sed 's/\..*$//')"
        [[ -z "$int_num" ]] && int_num=0
        case "$unit" in
            T|TB) echo "$(( int_num * 1099511627776 ))" ;;
            G|GB) echo "$(( int_num * 1073741824 ))" ;;
            M|MB) echo "$(( int_num * 1048576 ))" ;;
            K|KB) echo "$(( int_num * 1024 ))" ;;
            *)    echo "$int_num" ;;
        esac
    fi
}

# Get size of a path in bytes (directory or file)
get_size_bytes() {
    local path="${1:-}"
    [[ -z "$path" ]] && echo 0 && return
    if [[ -e "$path" ]]; then
        if [[ "$HAS_DU_BYTES" -eq 1 ]]; then
            du -sb -- "$path" 2>/dev/null | awk '{print $1}' || echo 0
        else
            du -sk -- "$path" 2>/dev/null | awk '{printf "%d", $1 * 1024}' || echo 0
        fi
    else
        echo 0
    fi
}

# Get size of matching files
get_find_size_bytes() {
    local dir="${1:-}" ; shift
    # remaining args are find predicates
    if [[ -d "$dir" ]]; then
        if [[ "$HAS_DU_BYTES" -eq 1 ]]; then
            if (( $# > 0 )); then
                find "$dir" -type f \( "$@" \) -exec du -sb -- {} + 2>/dev/null \
                    | awk '{s+=$1} END {printf "%d", s+0}' || echo 0
            else
                find "$dir" -type f -exec du -sb -- {} + 2>/dev/null \
                    | awk '{s+=$1} END {printf "%d", s+0}' || echo 0
            fi
        else
            if (( $# > 0 )); then
                find "$dir" -type f \( "$@" \) -exec du -sk -- {} + 2>/dev/null \
                    | awk '{s+=$1*1024} END {printf "%d", s+0}' || echo 0
            else
                find "$dir" -type f -exec du -sk -- {} + 2>/dev/null \
                    | awk '{s+=$1*1024} END {printf "%d", s+0}' || echo 0
            fi
        fi
    else
        echo 0
    fi
}

get_rotated_logs_size() {
    get_find_size_bytes /var/log "${ROTATED_LOG_FIND_ARGS[@]}"
}

delete_rotated_logs() {
    find /var/log -type f \( "${ROTATED_LOG_FIND_ARGS[@]}" \) -delete 2>/dev/null
}

# Record starting disk usage
get_total_used_bytes() {
    df -P -k -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk '
        NR > 1 {
            fs=$1; mp=$6
            if (fs ~ /^\/var\/lib\/docker\/rootfs\/overlayfs\//) next
            if (fs ~ /^\/var\/lib\/docker\/overlay2\//) next
            if (mp ~ /^\/var\/lib\/docker\/rootfs\/overlayfs\//) next
            if (mp ~ /^\/var\/lib\/docker\/overlay2\//) next
            s += $3 * 1024
        }
        END { printf "%d", s + 0 }
    '
}

record_disk_start() {
    DISK_START_USED="$(get_total_used_bytes)" || DISK_START_USED=0
}

# Calculate freed space since last recorded start
calc_freed_since_start() {
    local current_used
    current_used="$(get_total_used_bytes)" || current_used=0
    local freed=$(( DISK_START_USED - current_used ))
    (( freed < 0 )) && freed=0
    echo "$freed"
}

# --- UI helpers -------------------------------------------------------------

repeat_char() {
    local ch="$1" count="$2" i
    for (( i = 0; i < count; i++ )); do printf '%s' "$ch"; done
}

get_ui_content_width() {
    local cols="${COLUMNS:-}"
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || (( cols <= 0 )); then
        if command -v tput &>/dev/null; then
            cols="$(tput cols 2>/dev/null || echo 0)"
        fi
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || (( cols <= 0 )); then
        cols=80
    fi

    local width=$(( cols - 2 ))
    (( width < 50 )) && width=50
    (( width > 120 )) && width=120
    printf '%d' "$width"
}

print_header() {
    local disk_info
    disk_info="$(get_disk_summary_line)"
    local title="VPS Cleaner v${SCRIPT_VERSION}"
    local distro_line="Distro: ${DISTRO_PRETTY:-Unknown}"
    local disk_line="Disk: ${disk_info}"
    local rule_len
    rule_len="$(get_ui_content_width)"

    echo ""
    printf '  %s%s%s\n' "$CYAN" "$(repeat_char '=' "$rule_len")" "$RESET"
    printf '  %s%s%s%s\n' "$CYAN" "$BOLD" "$(truncate_for_table "$title" "$rule_len")" "$RESET"
    printf '  %s%s%s\n' "$CYAN" "$(truncate_for_table "$distro_line" "$rule_len")" "$RESET"
    printf '  %s%s%s\n' "$CYAN" "$(truncate_for_table "$disk_line" "$rule_len")" "$RESET"
    printf '  %s%s%s\n' "$CYAN" "$(repeat_char '=' "$rule_len")" "$RESET"
    echo ""
}

print_menu() {
    printf '  %s1)%s  📊 Disk Space Overview\n'        "$BOLD" "$RESET"
    printf '  %s2)%s  🚀 Quick Clean (Safe)\n'          "$BOLD" "$RESET"
    printf '  %s3)%s  📋 System Logs Cleanup\n'          "$BOLD" "$RESET"
    printf '  %s4)%s  📦 Package Manager Cleanup\n'      "$BOLD" "$RESET"
    printf '  %s5)%s  🗂️  Cache Cleanup\n'               "$BOLD" "$RESET"
    printf '  %s6)%s  🐳 Docker Cleanup\n'               "$BOLD" "$RESET"
    printf '  %s7)%s  📎 Snap/Flatpak Cleanup\n'         "$BOLD" "$RESET"
    printf '  %s8)%s  🔍 Find Large Files\n'             "$BOLD" "$RESET"
    printf '  %s9)%s  🗑️  Full Deep Clean\n'             "$BOLD" "$RESET"
    printf '  %s10)%s ⚙️  Settings\n'                    "$BOLD" "$RESET"
    printf '  %s11)%s 📥 Install/Update vps-cleaner\n'   "$BOLD" "$RESET"
    printf '  %s12)%s 🗑️  Uninstall vps-cleaner\n'        "$BOLD" "$RESET"
    printf '  %s0)%s  🚪 Exit\n'                         "$BOLD" "$RESET"
    echo ""
}

print_success() { printf '  %s✅ %s%s\n' "$GREEN"  "$*" "$RESET"; }
print_warning() { printf '  %s⚠️  %s%s\n' "$YELLOW" "$*" "$RESET"; }
print_error()   { printf '  %s❌ %s%s\n' "$RED"    "$*" "$RESET"; }
print_info()    { printf '  %sℹ️  %s%s\n' "$BLUE"   "$*" "$RESET"; }

print_separator() {
    local width="${1:-}"
    if [[ ! "$width" =~ ^[0-9]+$ ]] || (( width <= 0 )); then
        width="$(get_ui_content_width)"
    fi
    (( width < 20 )) && width=20
    printf '  %s%s%s\n' "$DIM" "$(repeat_char "$BOX_H" "$width")" "$RESET"
}

print_dry_run_prefix() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s[DRY RUN]%s ' "$MAGENTA" "$RESET"
    fi
}

print_cleanup_result() {
    local removed="${1:-0}" freed="${2:-0}"
    (( removed < 0 )) && removed=0
    (( freed < 0 )) && freed=0

    if (( removed > 0 )); then
        print_success "Removed data: $(format_size "$removed")"
    fi
    print_success "Freed on filesystem: $(format_size "$freed")"
    if (( removed > 0 && freed == 0 )); then
        print_warning "Filesystem free space may update later (open files, reserved blocks, or delayed reclaim)."
    fi
}

# Draw a colored usage bar
# Usage: draw_bar <percent> <width>
draw_bar() {
    local pct="${1:-0}" width="${2:-30}"
    local filled empty color

    # Clamp
    (( pct > 100 )) && pct=100
    (( pct < 0 ))   && pct=0

    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))

    if (( pct < 60 )); then
        color="$GREEN"
    elif (( pct < 80 )); then
        color="$YELLOW"
    else
        color="$RED"
    fi

    printf '%s' "$color"
    repeat_char '█' "$filled"
    printf '%s' "$DIM"
    repeat_char '░' "$empty"
    printf '%s %3d%%%s' "$RESET$color" "$pct" "$RESET"
}

# Spinner — runs a command while showing an animation
# Usage: show_spinner "message" command [args...]
show_spinner() {
    local msg="$1"; shift
    local pid frame_idx=0

    "$@" &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s %s %s' "${CYAN}${SPINNER_FRAMES[$frame_idx]}${RESET}" "$msg" "$DIM...$RESET"
        frame_idx=$(( (frame_idx + 1) % ${#SPINNER_FRAMES[@]} ))
        sleep 0.1
    done

    wait "$pid" 2>/dev/null
    local rc=$?
    printf '\r%*s\r' "$(( ${#msg} + 15 ))" ""
    return $rc
}

get_disk_summary_line() {
    local size_bytes used_bytes avail_bytes pct
    read -r size_bytes used_bytes avail_bytes pct _ < <(df -P -B1 / 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5, $6}')
    if [[ -z "${size_bytes:-}" || -z "${used_bytes:-}" || -z "${avail_bytes:-}" || -z "${pct:-}" ]]; then
        echo "N/A"
        return
    fi

    printf '%s / %s used, free %s (%s)' \
        "$(format_size "$used_bytes")" \
        "$(format_size "$size_bytes")" \
        "$(format_size "$avail_bytes")" \
        "$pct"
}

# Prompt user: returns 0 if user said yes
# Always reads from /dev/tty so stdin piping never interferes
is_confirm_yes() {
    local reply="${1:-}"
    case "${reply,,}" in
        y|yes|д|да) return 0 ;;
        *) return 1 ;;
    esac
}

confirm() {
    local prompt="${1:-Continue?}"
    local default="y"
    local reply=""

    printf '  %s [Y/n]: ' "$prompt" > /dev/tty

    if [[ -r /dev/tty ]]; then
        IFS= read -r reply < /dev/tty || reply=""
    else
        IFS= read -r reply || reply=""
    fi

    reply="$(echo "$reply" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    reply="${reply:-$default}"
    is_confirm_yes "$reply"
}

extract_reclaimed_bytes() {
    local raw_output="${1:-}" reclaimed_raw=""
    reclaimed_raw="$(echo "$raw_output" | sed -n 's/.*Total reclaimed space:[[:space:]]*\([^[:space:]]\+\).*/\1/p' | tail -1)"
    if [[ -z "$reclaimed_raw" ]]; then
        echo 0
        return
    fi
    parse_size_to_bytes "$reclaimed_raw"
}

get_docker_reclaimable_estimate_bytes() {
    local total=0 line token bytes

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        token="$(echo "$line" | awk '{print $1}')"
        bytes="$(parse_size_to_bytes "$token")"
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        total=$(( total + bytes ))
    done < <(docker system df --format '{{.Reclaimable}}' 2>/dev/null)

    echo "$total"
}

# Read numeric choice
READ_CHOICE_VALUE=""
read_choice() {
    local prompt="${1:-Enter choice}" max="${2:-11}"
    local choice=""

    if [[ -r /dev/tty ]] && [[ -w /dev/tty ]]; then
        printf '  %s%s [0-%d]: %s' "$BOLD" "$prompt" "$max" "$RESET" > /dev/tty
        if ! IFS= read -r choice < /dev/tty; then
            READ_CHOICE_VALUE=""
            return 1
        fi
    else
        printf '  %s%s [0-%d]: %s' "$BOLD" "$prompt" "$max" "$RESET" >&2
        if ! IFS= read -r choice; then
            READ_CHOICE_VALUE=""
            return 1
        fi
    fi

    choice="$(echo "$choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    READ_CHOICE_VALUE="$choice"
    return 0
}

# Press enter to continue
pause() {
    if [[ -w /dev/tty ]]; then
        printf '\n  %sPress Enter to continue...%s' "$DIM" "$RESET" > /dev/tty
    else
        printf '\n  %sPress Enter to continue...%s' "$DIM" "$RESET" >&2
    fi

    if [[ -r /dev/tty ]]; then
        IFS= read -r < /dev/tty || true
    else
        IFS= read -r || true
    fi
}

truncate_for_table() {
    local text="${1:-}" width="${2:-20}"
    if (( width <= 0 )); then
        return
    fi
    if (( ${#text} <= width )); then
        printf '%s' "$text"
        return
    fi
    if (( width <= 3 )); then
        printf '%s' "${text:0:width}"
        return
    fi
    printf '%s...' "${text:0:width-3}"
}

truncate_path_for_display() {
    local path="${1:-}" width="${2:-40}"
    if (( width <= 0 )); then
        return
    fi
    if (( ${#path} <= width )); then
        printf '%s' "$path"
        return
    fi
    if (( width <= 3 )); then
        printf '%s' "${path:0:width}"
        return
    fi

    local tail_keep=$(( (width - 3) / 2 ))
    local head_keep=$(( width - 3 - tail_keep ))
    printf '%s...%s' "${path:0:head_keep}" "${path: -tail_keep}"
}

print_labeled_size_row() {
    local label="${1:-}"
    local size_text="${2:-0 B}"
    local label_width="${3:-35}"
    local indent="${4:-4}"

    if (( label_width < 8 )); then
        label_width=8
    fi
    local shown_label
    shown_label="$(truncate_for_table "$label" "$label_width")"
    printf '%*s%-*s %10s\n' "$indent" "" "$label_width" "$shown_label" "$size_text"
}

should_skip_mountpoint() {
    local mount_point="${1:-}"
    [[ "$mount_point" == /var/lib/docker/rootfs/overlayfs/* ]] && return 0
    [[ "$mount_point" == /var/lib/docker/overlay2/* ]] && return 0
    return 1
}

should_skip_filesystem() {
    local filesystem="${1:-}"
    [[ "$filesystem" == /var/lib/docker/rootfs/overlayfs/* ]] && return 0
    [[ "$filesystem" == /var/lib/docker/overlay2/* ]] && return 0
    return 1
}

run_timed_pipeline() {
    local timeout_sec="${1:-20}"
    shift
    local cmd="$*"

    if command -v timeout &>/dev/null; then
        timeout --foreground "$timeout_sec" bash -o pipefail -c "$cmd"
        return $?
    fi

    # Fallback timeout for systems without GNU timeout.
    local out_file status_file runner_pid watcher_pid rc
    out_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-run.XXXXXX")"
    status_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-run.XXXXXX")"

    (
        bash -o pipefail -c "$cmd" > "$out_file"
        printf '%s' "$?" > "$status_file"
    ) &
    runner_pid=$!

    (
        sleep "$timeout_sec"
        kill -TERM "$runner_pid" 2>/dev/null || true
    ) &
    watcher_pid=$!

    wait "$runner_pid" 2>/dev/null || true

    if kill -0 "$watcher_pid" 2>/dev/null; then
        kill "$watcher_pid" 2>/dev/null || true
    fi
    wait "$watcher_pid" 2>/dev/null || true

    rc=124
    if [[ -s "$status_file" ]]; then
        rc="$(cat "$status_file" 2>/dev/null || echo 1)"
    fi

    cat "$out_file"
    rm -f -- "$out_file" "$status_file"
    return "$rc"
}

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

# ============================================================================
# SIGNAL HANDLING
# ============================================================================

cleanup() {
    if [[ -n "$TEMP_FILE" && -f "$TEMP_FILE" ]]; then
        rm -f "$TEMP_FILE" 2>/dev/null
    fi
    printf '\n'
    print_warning "Interrupted. Exiting."
    exit 130
}

trap cleanup SIGINT SIGTERM

# ============================================================================
# SAFETY FUNCTIONS
# ============================================================================

# Verify a path is safe to delete (not a protected path)
is_safe_path() {
    local target="$1"
    target="$(realpath -m "$target" 2>/dev/null || echo "$target")"

    for protected in "${PROTECTED_PATHS[@]}"; do
        if [[ "$target" == "$protected" ]]; then
            return 1
        fi
    done
    # Never allow anything that resolves to /
    if [[ "$target" == "/" ]]; then
        return 1
    fi
    return 0
}

safe_rm_file() {
    local f="$1"
    if ! is_safe_path "$f"; then
        print_error "Refusing to delete protected path: $f"
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_prefix
        printf 'Would delete file: %s\n' "$f"
    else
        rm -f -- "$f" 2>/dev/null
    fi
}

safe_rm_dir_contents() {
    local d="$1"
    if ! is_safe_path "$d"; then
        print_error "Refusing to delete protected path: $d"
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_prefix
        printf 'Would clean directory contents: %s\n' "$d"
    else
        if [[ -d "$d" ]]; then
            find "$d" -mindepth 1 -delete 2>/dev/null || true
        fi
    fi
}

safe_rm_cache_dir() {
    local d="$1"
    if ! is_safe_path "$d"; then
        print_error "Refusing to delete protected path: $d"
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_prefix
        printf 'Would remove cache directory: %s\n' "$d"
    else
        rm -rf -- "$d" 2>/dev/null
    fi
}

truncate_matching_files_and_count_removed() {
    local dir="${1:-}"
    shift
    local removed=0 f size

    [[ -d "$dir" ]] || { echo 0; return; }

    if (( $# > 0 )); then
        while IFS= read -r -d '' f; do
            size="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"
            [[ "$size" =~ ^[0-9]+$ ]] || size=0
            if truncate -s 0 -- "$f" 2>/dev/null; then
                removed=$(( removed + size ))
            fi
        done < <(find "$dir" -type f \( "$@" \) -print0 2>/dev/null)
    else
        while IFS= read -r -d '' f; do
            size="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"
            [[ "$size" =~ ^[0-9]+$ ]] || size=0
            if truncate -s 0 -- "$f" 2>/dev/null; then
                removed=$(( removed + size ))
            fi
        done < <(find "$dir" -type f -print0 2>/dev/null)
    fi

    echo "$removed"
}

# ============================================================================
# CLEANUP FUNCTIONS
# ============================================================================

# --- Option 1: Disk Space Overview -----------------------------------------

show_disk_overview() {
    local choice_before
    local ui_width mount_col_width bar_width fs_table_width inode_mount_col_width inode_table_width
    local top_dirs_path_width top_files_path_width
    record_disk_start
    ui_width="$(get_ui_content_width)"

    bar_width=20
    mount_col_width=$(( ui_width - bar_width - 46 ))
    (( mount_col_width > 32 )) && mount_col_width=32
    (( mount_col_width < 12 )) && mount_col_width=12
    bar_width=$(( ui_width - mount_col_width - 46 ))
    (( bar_width > 24 )) && bar_width=24
    (( bar_width < 8 )) && bar_width=8
    fs_table_width=$(( mount_col_width + bar_width + 46 ))

    inode_mount_col_width=$(( ui_width - 39 ))
    (( inode_mount_col_width > 32 )) && inode_mount_col_width=32
    (( inode_mount_col_width < 12 )) && inode_mount_col_width=12
    inode_table_width=$(( inode_mount_col_width + 39 ))

    top_dirs_path_width=$(( ui_width - 12 ))
    (( top_dirs_path_width < 20 )) && top_dirs_path_width=20
    top_files_path_width=$(( ui_width - 12 ))
    (( top_files_path_width < 20 )) && top_files_path_width=20

    echo ""
    printf '  %s%s📊 Disk Space Overview%s\n\n' "$BOLD" "$CYAN" "$RESET"

    # Filesystem usage
    printf '  %s%sFilesystem Usage:%s\n' "$BOLD" "$WHITE" "$RESET"
    print_separator "$fs_table_width"

    printf '  %-*s %10s %10s %10s %5s  %s\n' "$mount_col_width" "Mount" "Size" "Used" "Avail" "Use%" "Bar"
    print_separator "$fs_table_width"

    while IFS= read -r line; do
        local fs mp sz used avail pct pct_num
        local sz_h used_h avail_h
        read -r fs sz used avail pct mp _ <<< "$line"
        [[ -z "${mp:-}" ]] && continue
        should_skip_filesystem "$fs" && continue
        should_skip_mountpoint "$mp" && continue
        pct_num="${pct/\%/}"
        sz_h="$(format_size "$sz")"
        used_h="$(format_size "$used")"
        avail_h="$(format_size "$avail")"

        printf '  %-*s %10s %10s %10s %5s  ' \
            "$mount_col_width" "$(truncate_for_table "$mp" "$mount_col_width")" "$sz_h" "$used_h" "$avail_h" "$pct"
        draw_bar "$pct_num" "$bar_width"
        printf '\n'
    done < <(df -P -B1 -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR>1 {print}')

    # Inode usage
    echo ""
    printf '  %s%sInode Usage:%s\n' "$BOLD" "$WHITE" "$RESET"
    print_separator "$inode_table_width"
    printf '  %-*s %10s %10s %10s %5s\n' "$inode_mount_col_width" "Mount" "Inodes" "Used" "Free" "Use%"
    print_separator "$inode_table_width"

    while IFS= read -r line; do
        local fs mp total used free pct
        read -r fs total used free pct mp _ <<< "$line"
        [[ -z "${mp:-}" ]] && continue
        should_skip_filesystem "$fs" && continue
        should_skip_mountpoint "$mp" && continue

        printf '  %-*s %10s %10s %10s %5s\n' \
            "$inode_mount_col_width" "$(truncate_for_table "$mp" "$inode_mount_col_width")" "$total" "$used" "$free" "$pct"
    done < <(df -P -i -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR>1 {print}')

    # Top 15 directories
    echo ""
    printf '  %s%sTop 15 Largest Directories (under /):%s\n' "$BOLD" "$WHITE" "$RESET"
    print_separator

    local top_dirs_output
    printf '  %s\n' "Scanning directories (can take up to ${DISK_OVERVIEW_SCAN_TIMEOUT_SEC}s)..."
    if top_dirs_output="$(run_timed_pipeline "$DISK_OVERVIEW_SCAN_TIMEOUT_SEC" "du -x -h -d 2 / --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/snap --exclude=/var/lib/docker/rootfs/overlayfs --exclude=/var/lib/docker/overlay2 2>/dev/null | sort -rh | head -15")"; then
        while IFS= read -r dline; do
            local dsize dpath
            [[ -z "$dline" ]] && continue
            dsize="${dline%%[[:space:]]*}"
            dpath="$(echo "$dline" | sed 's/^[^[:space:]]*[[:space:]]*//')"
            if [[ -z "$dpath" || "$dpath" == "$dline" ]]; then
                printf '  %s\n' "$(truncate_path_for_display "$dline" "$ui_width")"
            else
                printf '  %10s  %s\n' "$dsize" "$(truncate_path_for_display "$dpath" "$top_dirs_path_width")"
            fi
        done <<< "$top_dirs_output"
    else
        print_warning "Directory scan timed out. Showing partial or no data."
    fi

    # Top 10 files
    echo ""
    printf '  %s%sTop 10 Largest Files:%s\n' "$BOLD" "$WHITE" "$RESET"
    print_separator

    local top_files_output
    printf '  %s\n' "Scanning files (can take up to ${DISK_OVERVIEW_SCAN_TIMEOUT_SEC}s)..."
    if top_files_output="$(run_timed_pipeline "$DISK_OVERVIEW_SCAN_TIMEOUT_SEC" "find /var /usr /home /root /opt /srv /tmp -xdev -type f -not -path '/var/lib/docker/rootfs/overlayfs/*' -not -path '/var/lib/docker/overlay2/*' -exec stat -c '%s %n' {} + 2>/dev/null | sort -rn | head -10")"; then
        while IFS=' ' read -r size fpath; do
            [[ -z "${size:-}" || -z "${fpath:-}" ]] && continue
            printf '  %10s  %s\n' "$(format_size "$size")" "$(truncate_path_for_display "$fpath" "$top_files_path_width")"
        done <<< "$top_files_output"
    else
        print_warning "Large file scan timed out. Showing partial or no data."
    fi

    echo ""
    pause
}

# --- Option 2: Quick Clean (Safe) ------------------------------------------

quick_clean() {
    record_disk_start
    echo ""
    printf '  %s%s🚀 Quick Clean (Safe)%s\n\n' "$BOLD" "$CYAN" "$RESET"

    local ui_width estimate_label_width estimate_table_width
    local total_est=0
    local size_rotated size_pkg_cache size_tmp size_thumb size_trash size_crash
    local had_warnings=0
    ui_width="$(get_ui_content_width)"
    estimate_label_width=$(( ui_width - 15 ))
    (( estimate_label_width > 48 )) && estimate_label_width=48
    (( estimate_label_width < 20 )) && estimate_label_width=20
    estimate_table_width=$(( estimate_label_width + 11 ))

    # Estimate sizes
    size_rotated=$(get_rotated_logs_size)
    size_pkg_cache=$(estimate_pkg_cache_size)
    size_tmp=$(get_find_size_bytes /tmp -mtime +"$TEMP_FILE_AGE_DAYS")
    size_tmp=$(( size_tmp + $(get_find_size_bytes /var/tmp -mtime +"$TEMP_FILE_AGE_DAYS") ))
    size_thumb=0
    for d in /root/.cache/thumbnails /home/*/.cache/thumbnails; do
        [[ -d "$d" ]] && size_thumb=$(( size_thumb + $(get_size_bytes "$d") ))
    done
    size_trash=0
    for d in /root/.local/share/Trash /home/*/.local/share/Trash; do
        [[ -d "$d" ]] && size_trash=$(( size_trash + $(get_size_bytes "$d") ))
    done
    size_crash=$(get_size_bytes /var/crash 2>/dev/null || echo 0)

    total_est=$(( size_rotated + size_pkg_cache + size_tmp + size_thumb + size_trash + size_crash ))

    printf '  %sThe following will be cleaned:%s\n\n' "$BOLD" "$RESET"
    print_labeled_size_row "Rotated logs (.gz, .old, .1-.5)" "$(format_size "$size_rotated")" "$estimate_label_width"
    print_labeled_size_row "Package manager cache" "$(format_size "$size_pkg_cache")" "$estimate_label_width"
    print_labeled_size_row "Temp files older than ${TEMP_FILE_AGE_DAYS} days" "$(format_size "$size_tmp")" "$estimate_label_width"
    print_labeled_size_row "Thumbnail cache" "$(format_size "$size_thumb")" "$estimate_label_width"
    print_labeled_size_row "Trash directories" "$(format_size "$size_trash")" "$estimate_label_width"
    print_labeled_size_row "Core dumps (/var/crash)" "$(format_size "$size_crash")" "$estimate_label_width"
    print_separator "$estimate_table_width"
    printf '    %-*s %s%10s%s\n' "$estimate_label_width" \
        "$(truncate_for_table "Estimated total savings" "$estimate_label_width")" "$BOLD" "$(format_size "$total_est")" "$RESET"
    echo ""

    if ! confirm "Proceed with Quick Clean?"; then
        print_info "Cancelled."
        pause
        return
    fi

    echo ""

    # 1. Rotated logs
    printf '  Cleaning rotated logs...'
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! delete_rotated_logs; then
            had_warnings=1
            print_warning "Rotated logs cleanup encountered errors."
        fi
    fi
    printf ' done\n'
    log_action "quick-clean" "rotated-logs" "$size_rotated"

    # 2. Package cache
    printf '  Cleaning package manager cache...'
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! clean_pkg_cache_silent; then
            had_warnings=1
            print_warning "Package cache cleanup encountered errors."
        fi
    fi
    printf ' done\n'
    log_action "quick-clean" "pkg-cache" "$size_pkg_cache"

    # 3. Temp files
    printf '  Cleaning old temp files...'
    if [[ "$DRY_RUN" -eq 0 ]]; then
        find /tmp -mindepth 1 -mtime +"$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || true
        find /var/tmp -mindepth 1 -mtime +"$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    fi
    printf ' done\n'
    log_action "quick-clean" "temp-files" "$size_tmp"

    # 4. Thumbnails
    printf '  Cleaning thumbnail cache...'
    if [[ "$DRY_RUN" -eq 0 ]]; then
        for d in /root/.cache/thumbnails /home/*/.cache/thumbnails; do
            [[ -d "$d" ]] && safe_rm_dir_contents "$d"
        done
    fi
    printf ' done\n'
    log_action "quick-clean" "thumbnails" "$size_thumb"

    # 5. Trash
    printf '  Cleaning trash...'
    if [[ "$DRY_RUN" -eq 0 ]]; then
        for d in /root/.local/share/Trash /home/*/.local/share/Trash; do
            [[ -d "$d" ]] && safe_rm_dir_contents "$d"
        done
    fi
    printf ' done\n'
    log_action "quick-clean" "trash" "$size_trash"

    # 6. Crash dumps
    printf '  Cleaning core dumps...'
    if [[ "$DRY_RUN" -eq 0 ]] && [[ -d /var/crash ]]; then
        safe_rm_dir_contents /var/crash
    fi
    printf ' done\n'
    log_action "quick-clean" "crash-dumps" "$size_crash"

    echo ""
    local freed
    freed=$(calc_freed_since_start)
    print_success "Freed on filesystem: $(format_size "$freed")"
    if (( total_est > 0 )); then
        print_info "Estimated cleaned data: $(format_size "$total_est")"
        if (( freed == 0 )); then
            print_warning "Filesystem free space may update later (open files, reserved blocks, or delayed reclaim)."
        fi
    fi
    if (( had_warnings == 1 )); then
        print_warning "Quick Clean finished with warnings. Some cleanup steps may need a retry."
    fi
    log_action "quick-clean" "total" "$freed"

    pause
}

estimate_pkg_cache_size() {
    local size=0
    case "$PKG_MANAGER" in
        apt)
            [[ -d /var/cache/apt/archives ]] && size=$(get_size_bytes /var/cache/apt/archives)
            ;;
        dnf|yum)
            for d in /var/cache/dnf /var/cache/yum; do
                [[ -d "$d" ]] && size=$(( size + $(get_size_bytes "$d") ))
            done
            ;;
        pacman)
            [[ -d /var/cache/pacman/pkg ]] && size=$(get_size_bytes /var/cache/pacman/pkg)
            ;;
        apk)
            [[ -d /var/cache/apk ]] && size=$(get_size_bytes /var/cache/apk)
            ;;
        zypper)
            [[ -d /var/cache/zypp ]] && size=$(get_size_bytes /var/cache/zypp)
            ;;
    esac
    echo "$size"
}

clean_pkg_cache_silent() {
    local status=0
    case "$PKG_MANAGER" in
        apt)
            apt-get clean -y 2>/dev/null || status=1
            ;;
        dnf)
            dnf clean all 2>/dev/null || status=1
            ;;
        yum)
            yum clean all 2>/dev/null || status=1
            ;;
        pacman)
            pacman -Scc --noconfirm 2>/dev/null || status=1
            ;;
        apk)
            apk cache clean 2>/dev/null || status=1
            ;;
        zypper)
            zypper clean --all 2>/dev/null || status=1
            ;;
    esac
    return "$status"
}

# --- Option 3: System Logs Cleanup -----------------------------------------

menu_logs_cleanup() {
    while true; do
        echo ""
        printf '  %s%s📋 System Logs Cleanup%s\n\n' "$BOLD" "$CYAN" "$RESET"

        local log_size
        log_size="$(get_size_bytes /var/log)"
        printf '  Current /var/log size: %s%s%s\n\n' "$BOLD" "$(format_size "$log_size")" "$RESET"

        printf '  1) Clean rotated/archived logs (.gz, .old, .1-.9)  %s[SAFE]%s\n' "$GREEN" "$RESET"
        printf '  2) Truncate large log files (> %dMB)              %s[MODERATE]%s\n' "$LOG_TRUNCATE_THRESHOLD_MB" "$YELLOW" "$RESET"
        printf '  3) Clean journal logs (keep last %d days)         %s[SAFE]%s\n' "$JOURNAL_RETENTION_DAYS" "$GREEN" "$RESET"
        printf '  4) Clean application logs                         %s[MODERATE]%s\n' "$YELLOW" "$RESET"
        printf '  5) Clean ALL logs                                 %s[DANGEROUS]%s\n' "$RED" "$RESET"
        printf '  6) Back\n'
        echo ""

        local choice
        read_choice "Enter choice" 6
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1) clean_rotated_logs ;;
            2) truncate_large_logs ;;
            3) clean_journal_logs ;;
            4) clean_app_logs ;;
            5) clean_all_logs ;;
            6|"") return ;;
            *) print_error "Invalid choice." ;;
        esac
    done
}

clean_rotated_logs() {
    record_disk_start
    echo ""
    local size size_after removed
    size=$(get_rotated_logs_size)
    printf '  Rotated logs size: %s\n' "$(format_size "$size")"

    if [[ "$size" -eq 0 ]]; then
        print_info "Nothing to clean."
        pause
        return
    fi

    if ! confirm "Delete rotated logs?"; then pause; return; fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! delete_rotated_logs; then
            print_warning "Some rotated logs could not be removed."
        fi
    fi

    size_after=$(get_rotated_logs_size)
    removed=$(( size - size_after ))
    (( removed < 0 )) && removed=0

    local freed
    freed=$(calc_freed_since_start)
    print_success "Removed rotated logs: $(format_size "$removed")"
    print_success "Freed on filesystem: $(format_size "$freed")"
    if (( removed > 0 && freed == 0 )); then
        print_warning "Filesystem free space may update later (open files, reserved blocks, or delayed reclaim)."
    fi
    log_action "logs" "rotated-clean" "$freed"
    pause
}

truncate_large_logs() {
    record_disk_start
    echo ""
    local found=0 removed=0
    local ui_width log_path_width
    ui_width="$(get_ui_content_width)"
    log_path_width=$(( ui_width - 12 ))
    (( log_path_width < 20 )) && log_path_width=20

    printf '  Large log files (> %dMB):\n' "$LOG_TRUNCATE_THRESHOLD_MB"
    print_separator

    while IFS= read -r line; do
        local fsize fpath
        fsize="$(echo "$line" | awk '{print $1}')"
        fpath="$(echo "$line" | awk '{print $2}')"
        printf '  %10s  %s\n' "$(format_size "$fsize")" "$(truncate_path_for_display "$fpath" "$log_path_width")"
        found=1
    done < <(find /var/log -type f -size +"${LOG_TRUNCATE_THRESHOLD_MB}M" -exec stat -c '%s %n' {} + 2>/dev/null | sort -rn)

    if [[ "$found" -eq 0 ]]; then
        print_info "No log files larger than ${LOG_TRUNCATE_THRESHOLD_MB}MB."
        pause
        return
    fi

    echo ""
    print_warning "This will truncate (empty) these files, not delete them."
    if ! confirm "Truncate large log files?"; then pause; return; fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        removed="$(truncate_matching_files_and_count_removed /var/log -size +"${LOG_TRUNCATE_THRESHOLD_MB}M")"
    fi

    local freed
    freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "logs" "truncate-large" "$freed"
    pause
}

clean_journal_logs() {
    record_disk_start
    echo ""
    if ! command -v journalctl &>/dev/null; then
        print_info "journalctl not found — skipping."
        pause
        return
    fi

    local jsize jsize_after jsize_bytes jsize_after_bytes removed
    jsize="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?' || echo '0')"
    printf '  Journal size: %s\n' "$jsize"
    jsize_bytes="$(parse_size_to_bytes "$jsize")"

    if ! confirm "Clean journal logs older than ${JOURNAL_RETENTION_DAYS} days?"; then
        pause
        return
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        journalctl --vacuum-time="${JOURNAL_RETENTION_DAYS}d" 2>/dev/null || true
    fi

    jsize_after="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?' || echo '0')"
    jsize_after_bytes="$(parse_size_to_bytes "$jsize_after")"
    removed=$(( jsize_bytes - jsize_after_bytes ))
    (( removed < 0 )) && removed=0

    local freed
    freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "logs" "journal-clean" "$freed"
    pause
}

clean_app_logs() {
    echo ""
    printf '  %s%sApplication Logs:%s\n\n' "$BOLD" "$WHITE" "$RESET"

    local apps_found=0
    declare -A app_logs

    # nginx
    if [[ -d /var/log/nginx ]]; then
        app_logs["nginx"]="/var/log/nginx"
        printf '  1) nginx     (%s)\n' "$(format_size "$(get_size_bytes /var/log/nginx)")"
        apps_found=1
    fi
    # apache
    for d in /var/log/apache2 /var/log/httpd; do
        if [[ -d "$d" ]]; then
            app_logs["apache"]="$d"
            printf '  2) apache    (%s)\n' "$(format_size "$(get_size_bytes "$d")")"
            apps_found=1
            break
        fi
    done
    # mysql
    if [[ -d /var/log/mysql ]]; then
        app_logs["mysql"]="/var/log/mysql"
        printf '  3) mysql     (%s)\n' "$(format_size "$(get_size_bytes /var/log/mysql)")"
        apps_found=1
    fi
    # postgresql
    if [[ -d /var/log/postgresql ]]; then
        app_logs["postgresql"]="/var/log/postgresql"
        printf '  4) postgresql (%s)\n' "$(format_size "$(get_size_bytes /var/log/postgresql)")"
        apps_found=1
    fi
    # mail
    for d in /var/log/mail; do
        if [[ -d "$d" ]]; then
            app_logs["mail"]="$d"
            printf '  5) mail      (%s)\n' "$(format_size "$(get_size_bytes "$d")")"
            apps_found=1
            break
        fi
    done

    if [[ "$apps_found" -eq 0 ]]; then
        print_info "No known application logs detected."
        pause
        return
    fi

    echo ""
    printf '  Enter app names to clean (comma-separated), or "all": '
    read -r app_input

    if [[ -z "$app_input" ]]; then pause; return; fi

    record_disk_start
    local removed=0

    if [[ "${app_input,,}" == "all" ]]; then
        for app in "${!app_logs[@]}"; do
            local d="${app_logs[$app]}" before_d after_d delta_d
            printf '  Cleaning %s logs...' "$app"
            before_d="$(get_size_bytes "$d")"
            if [[ "$DRY_RUN" -eq 0 ]]; then
                find "$d" -type f \( -name '*.gz' -o -name '*.old' -o -name '*.1' -o -name '*.2' \) \
                    -delete 2>/dev/null || true
                truncate_matching_files_and_count_removed "$d" -size +10M >/dev/null
            fi
            after_d="$(get_size_bytes "$d")"
            delta_d=$(( before_d - after_d ))
            (( delta_d < 0 )) && delta_d=0
            removed=$(( removed + delta_d ))
            printf ' done\n'
        done
    else
        IFS=',' read -ra selected <<< "$app_input"
        for app in "${selected[@]}"; do
            app="$(echo "$app" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [[ -n "${app_logs[$app]:-}" ]]; then
                local d="${app_logs[$app]}" before_d after_d delta_d
                printf '  Cleaning %s logs...' "$app"
                before_d="$(get_size_bytes "$d")"
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    find "$d" -type f \( -name '*.gz' -o -name '*.old' -o -name '*.1' -o -name '*.2' \) \
                        -delete 2>/dev/null || true
                    truncate_matching_files_and_count_removed "$d" -size +10M >/dev/null
                fi
                after_d="$(get_size_bytes "$d")"
                delta_d=$(( before_d - after_d ))
                (( delta_d < 0 )) && delta_d=0
                removed=$(( removed + delta_d ))
                printf ' done\n'
            else
                print_warning "Unknown app: $app"
            fi
        done
    fi

    local freed
    freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "logs" "app-logs-clean" "$freed"
    pause
}

clean_all_logs() {
    echo ""
    print_warning "WARNING: This will clean ALL logs from /var/log!"
    print_warning "This includes system logs, auth logs, and application logs."
    print_warning "This is IRREVERSIBLE and may hinder troubleshooting."
    echo ""
    printf '  Type "CONFIRM" to proceed: ' > /dev/tty
    local reply=""
    if [[ -r /dev/tty ]]; then
        IFS= read -r reply < /dev/tty || reply=""
    else
        IFS= read -r reply || reply=""
    fi

    if [[ "$reply" != "CONFIRM" ]]; then
        print_info "Cancelled."
        pause
        return
    fi

    record_disk_start
    local varlog_before varlog_after removed_varlog had_errors=0
    varlog_before=$(get_size_bytes /var/log)

    if [[ "$DRY_RUN" -eq 0 ]]; then
        # Delete all rotated/archived logs
        if ! delete_rotated_logs; then
            had_errors=1
            print_warning "Failed to remove some rotated log files."
        fi
        # Truncate all remaining log files, except binary login accounting files.
        if ! find /var/log -type f ! -name 'wtmp' ! -name 'btmp' ! -name 'lastlog' \
            -exec truncate -s 0 {} \; 2>/dev/null; then
            had_errors=1
            print_warning "Failed to truncate some log files."
        fi
        # Clean journal if available
        if command -v journalctl &>/dev/null; then
            if ! journalctl --vacuum-size=1M 2>/dev/null; then
                had_errors=1
                print_warning "Failed to vacuum journal logs."
            fi
        fi
    fi

    varlog_after=$(get_size_bytes /var/log)
    removed_varlog=$(( varlog_before - varlog_after ))
    (( removed_varlog < 0 )) && removed_varlog=0

    local freed
    freed=$(calc_freed_since_start)
    print_success "Removed from /var/log: $(format_size "$removed_varlog")"
    print_success "Freed on filesystem: $(format_size "$freed")"
    if (( removed_varlog > 0 && freed == 0 )); then
        print_warning "Filesystem free space may update later (open files, reserved blocks, or delayed reclaim)."
    fi
    if (( had_errors == 1 )); then
        print_warning "All logs cleanup completed with warnings."
    fi
    log_action "logs" "all-logs-clean" "$freed"
    pause
}

# --- Option 4: Package Manager Cleanup -------------------------------------

menu_package_cleanup() {
    while true; do
        echo ""
        printf '  %s%s📦 Package Manager Cleanup%s\n' "$BOLD" "$CYAN" "$RESET"
        printf '  Package manager: %s%s%s\n\n' "$BOLD" "${PKG_MANAGER:-none}" "$RESET"

        printf '  1) Clean package cache\n'
        printf '  2) Remove orphaned packages\n'
        printf '  3) Remove old kernels (keep current + 1)\n'
        printf '  4) All of the above\n'
        printf '  5) Back\n'
        echo ""

        local choice
        read_choice "Enter choice" 5
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1) clean_package_cache ;;
            2) remove_orphaned_packages ;;
            3) remove_old_kernels ;;
            4)
                clean_package_cache
                remove_orphaned_packages
                remove_old_kernels
                ;;
            5|"") return ;;
            *) print_error "Invalid choice." ;;
        esac
    done
}

clean_package_cache() {
    record_disk_start
    echo ""
    local size size_after removed
    size="$(estimate_pkg_cache_size)"
    printf '  Package cache size: %s\n' "$(format_size "$size")"

    if ! confirm "Clean package cache?"; then pause; return; fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        case "$PKG_MANAGER" in
            apt)
                apt-get clean -y 2>/dev/null || true
                apt-get autoclean -y 2>/dev/null || true
                ;;
            dnf)
                dnf clean all 2>/dev/null || true
                ;;
            yum)
                yum clean all 2>/dev/null || true
                ;;
            pacman)
                pacman -Scc --noconfirm 2>/dev/null || true
                ;;
            apk)
                apk cache clean 2>/dev/null || true
                ;;
            zypper)
                zypper clean --all 2>/dev/null || true
                ;;
        esac
    fi

    size_after="$(estimate_pkg_cache_size)"
    removed=$(( size - size_after ))
    (( removed < 0 )) && removed=0

    local freed
    freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "package" "cache-clean" "$freed"
    pause
}

remove_orphaned_packages() {
    record_disk_start
    echo ""
    printf '  Checking for orphaned packages...\n'

    if [[ "$DRY_RUN" -eq 0 ]]; then
        case "$PKG_MANAGER" in
            apt)
                apt-get autoremove -y 2>/dev/null || true
                ;;
            dnf)
                dnf autoremove -y 2>/dev/null || true
                ;;
            yum)
                yum autoremove -y 2>/dev/null || true
                ;;
            pacman)
                # Remove orphans if any exist
                local orphans
                orphans="$(pacman -Qdtq 2>/dev/null || true)"
                if [[ -n "$orphans" ]]; then
                    echo "$orphans" | pacman -Rns --noconfirm - 2>/dev/null || true
                fi
                ;;
            apk)
                # apk doesn't have autoremove; skip
                print_info "apk does not support orphan removal directly."
                ;;
            zypper)
                # zypper packages --orphaned, then remove
                local orphans
                orphans="$(zypper packages --orphaned 2>/dev/null | awk -F'|' 'NR>2 && NF>2 {gsub(/^ +| +$/, "", $3); print $3}' || true)"
                if [[ -n "$orphans" ]]; then
                    echo "$orphans" | xargs zypper remove -y 2>/dev/null || true
                fi
                ;;
        esac
    fi

    local freed
    freed=$(calc_freed_since_start)
    print_success "Freed: $(format_size "$freed")"
    log_action "package" "orphan-remove" "$freed"
    pause
}

remove_old_kernels() {
    record_disk_start
    echo ""
    local current_kernel
    current_kernel="$(uname -r)"
    printf '  Current kernel: %s%s%s\n' "$BOLD" "$current_kernel" "$RESET"

    case "$PKG_MANAGER" in
        apt)
            local old_kernels
            old_kernels="$(dpkg -l 'linux-image-*' 2>/dev/null \
                | awk '/^ii/ && !/'"$current_kernel"'/ {print $2}' \
                | grep -v "$(uname -r | sed 's/-generic//')" \
                | head -n -1 || true)"

            if [[ -z "$old_kernels" ]]; then
                print_info "No old kernels to remove."
                pause
                return
            fi

            printf '  Old kernels found:\n'
            echo "$old_kernels" | while read -r k; do printf '    %s\n' "$k"; done

            if confirm "Remove old kernels?"; then
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    echo "$old_kernels" | xargs apt-get purge -y 2>/dev/null || true
                fi
            fi
            ;;
        dnf|yum)
            printf '  Checking for old kernels...\n'
            if [[ "$DRY_RUN" -eq 0 ]]; then
                if [[ "$PKG_MANAGER" == "dnf" ]]; then
                    dnf remove --oldinstallonly --setopt installonly_limit=2 -y 2>/dev/null || true
                fi
            fi
            ;;
        *)
            print_info "Kernel cleanup not supported for $PKG_MANAGER."
            pause
            return
            ;;
    esac

    local freed
    freed=$(calc_freed_since_start)
    print_success "Freed: $(format_size "$freed")"
    log_action "package" "old-kernels" "$freed"
    pause
}

# --- Option 5: Cache Cleanup -----------------------------------------------

menu_cache_cleanup() {
    while true; do
        echo ""
        printf '  %s%s🗂️  Cache Cleanup%s\n\n' "$BOLD" "$CYAN" "$RESET"

        printf '  1) Package manager cache\n'
        printf '  2) Pip cache\n'
        printf '  3) npm cache\n'
        printf '  4) Composer cache\n'
        printf '  5) General /tmp cleanup\n'
        printf '  6) /var/tmp cleanup\n'
        printf '  7) Font cache, man-db cache\n'
        printf '  8) All caches\n'
        printf '  9) Back\n'
        echo ""

        local choice
        read_choice "Enter choice" 9
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1) clean_pkg_cache_interactive ;;
            2) clean_pip_cache ;;
            3) clean_npm_cache ;;
            4) clean_composer_cache ;;
            5) clean_tmp ;;
            6) clean_var_tmp ;;
            7) clean_font_man_cache ;;
            8)
                clean_pkg_cache_interactive
                clean_pip_cache
                clean_npm_cache
                clean_composer_cache
                clean_tmp
                clean_var_tmp
                clean_font_man_cache
                ;;
            9|"") return ;;
            *) print_error "Invalid choice." ;;
        esac
    done
}

clean_pkg_cache_interactive() {
    record_disk_start
    echo ""
    local size size_after removed
    size="$(estimate_pkg_cache_size)"
    printf '  Package cache size: %s\n' "$(format_size "$size")"
    if ! confirm "Clean package cache?"; then return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! clean_pkg_cache_silent; then
            print_warning "Package cache cleanup encountered errors."
        fi
    fi
    size_after="$(estimate_pkg_cache_size)"
    removed=$(( size - size_after ))
    (( removed < 0 )) && removed=0
    local freed; freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "cache" "pkg-cache" "$freed"
}

clean_pip_cache() {
    record_disk_start
    echo ""
    local total=0 total_after=0 removed=0
    for d in /root/.cache/pip /home/*/.cache/pip; do
        [[ -d "$d" ]] && total=$(( total + $(get_size_bytes "$d") ))
    done
    printf '  Pip cache size: %s\n' "$(format_size "$total")"
    if [[ "$total" -eq 0 ]]; then print_info "Nothing to clean."; return; fi
    if ! confirm "Clean pip cache?"; then return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        for d in /root/.cache/pip /home/*/.cache/pip; do
            [[ -d "$d" ]] && safe_rm_cache_dir "$d"
        done
    fi
    for d in /root/.cache/pip /home/*/.cache/pip; do
        [[ -d "$d" ]] && total_after=$(( total_after + $(get_size_bytes "$d") ))
    done
    removed=$(( total - total_after ))
    (( removed < 0 )) && removed=0
    local freed; freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "cache" "pip-cache" "$freed"
}

clean_npm_cache() {
    record_disk_start
    echo ""
    local total=0 total_after=0 removed=0
    for d in /root/.npm /home/*/.npm; do
        [[ -d "$d" ]] && total=$(( total + $(get_size_bytes "$d") ))
    done
    printf '  npm cache size: %s\n' "$(format_size "$total")"
    if [[ "$total" -eq 0 ]]; then print_info "Nothing to clean."; return; fi
    if ! confirm "Clean npm cache?"; then return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        for d in /root/.npm /home/*/.npm; do
            [[ -d "$d" ]] && safe_rm_cache_dir "$d"
        done
    fi
    for d in /root/.npm /home/*/.npm; do
        [[ -d "$d" ]] && total_after=$(( total_after + $(get_size_bytes "$d") ))
    done
    removed=$(( total - total_after ))
    (( removed < 0 )) && removed=0
    local freed; freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "cache" "npm-cache" "$freed"
}

clean_composer_cache() {
    record_disk_start
    echo ""
    local total=0 total_after=0 removed=0
    for d in /root/.composer/cache /home/*/.composer/cache /root/.cache/composer /home/*/.cache/composer; do
        [[ -d "$d" ]] && total=$(( total + $(get_size_bytes "$d") ))
    done
    printf '  Composer cache size: %s\n' "$(format_size "$total")"
    if [[ "$total" -eq 0 ]]; then print_info "Nothing to clean."; return; fi
    if ! confirm "Clean Composer cache?"; then return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        for d in /root/.composer/cache /home/*/.composer/cache /root/.cache/composer /home/*/.cache/composer; do
            [[ -d "$d" ]] && safe_rm_cache_dir "$d"
        done
    fi
    for d in /root/.composer/cache /home/*/.composer/cache /root/.cache/composer /home/*/.cache/composer; do
        [[ -d "$d" ]] && total_after=$(( total_after + $(get_size_bytes "$d") ))
    done
    removed=$(( total - total_after ))
    (( removed < 0 )) && removed=0
    local freed; freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "cache" "composer-cache" "$freed"
}

clean_tmp() {
    record_disk_start
    echo ""
    local size size_after removed
    size=$(get_find_size_bytes /tmp -mtime +"$TEMP_FILE_AGE_DAYS")
    printf '  /tmp files older than %d days: %s\n' "$TEMP_FILE_AGE_DAYS" "$(format_size "$size")"
    if [[ "$size" -eq 0 ]]; then print_info "Nothing to clean."; return; fi
    if ! confirm "Clean old /tmp files?"; then return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        find /tmp -mindepth 1 -mtime +"$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    fi
    size_after=$(get_find_size_bytes /tmp -mtime +"$TEMP_FILE_AGE_DAYS")
    removed=$(( size - size_after ))
    (( removed < 0 )) && removed=0
    local freed; freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "cache" "tmp-clean" "$freed"
}

clean_var_tmp() {
    record_disk_start
    echo ""
    local size size_after removed
    size=$(get_find_size_bytes /var/tmp -mtime +"$TEMP_FILE_AGE_DAYS")
    printf '  /var/tmp files older than %d days: %s\n' "$TEMP_FILE_AGE_DAYS" "$(format_size "$size")"
    if [[ "$size" -eq 0 ]]; then print_info "Nothing to clean."; return; fi
    if ! confirm "Clean old /var/tmp files?"; then return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        find /var/tmp -mindepth 1 -mtime +"$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    fi
    size_after=$(get_find_size_bytes /var/tmp -mtime +"$TEMP_FILE_AGE_DAYS")
    removed=$(( size - size_after ))
    (( removed < 0 )) && removed=0
    local freed; freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "cache" "var-tmp-clean" "$freed"
}

clean_font_man_cache() {
    record_disk_start
    echo ""
    local total=0 total_after=0 removed=0
    [[ -d /var/cache/fontconfig ]] && total=$(( total + $(get_size_bytes /var/cache/fontconfig) ))
    [[ -d /var/cache/man ]]        && total=$(( total + $(get_size_bytes /var/cache/man) ))
    printf '  Font/man cache size: %s\n' "$(format_size "$total")"
    if [[ "$total" -eq 0 ]]; then print_info "Nothing to clean."; return; fi
    if ! confirm "Clean font and man-db cache?"; then return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        [[ -d /var/cache/fontconfig ]] && safe_rm_dir_contents /var/cache/fontconfig
        [[ -d /var/cache/man ]]        && safe_rm_dir_contents /var/cache/man
    fi
    [[ -d /var/cache/fontconfig ]] && total_after=$(( total_after + $(get_size_bytes /var/cache/fontconfig) ))
    [[ -d /var/cache/man ]]        && total_after=$(( total_after + $(get_size_bytes /var/cache/man) ))
    removed=$(( total - total_after ))
    (( removed < 0 )) && removed=0
    local freed; freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "cache" "font-man-cache" "$freed"
}

# --- Option 6: Docker Cleanup ----------------------------------------------

menu_docker_cleanup() {
    if [[ "$HAS_DOCKER" -eq 0 ]]; then
        echo ""
        print_warning "Docker is not installed or not running."
        pause
        return
    fi

    while true; do
        local ui_width
        ui_width="$(get_ui_content_width)"
        echo ""
        printf '  %s%s🐳 Docker Cleanup%s\n\n' "$BOLD" "$CYAN" "$RESET"

        # Show Docker disk usage
        docker system df 2>/dev/null | while IFS= read -r line; do
            printf '  %s\n' "$(truncate_for_table "$line" "$ui_width")"
        done
        echo ""

        printf '  1) Remove stopped containers\n'
        printf '  2) Remove unused images\n'
        printf '  3) Remove unused volumes\n'
        printf '  4) Remove build cache\n'
        printf '  5) Docker system prune (all)\n'
        printf '  6) Clean container logs\n'
        printf '  7) Back\n'
        echo ""

        local choice
        read_choice "Enter choice" 7
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1) docker_rm_stopped ;;
            2) docker_rm_images ;;
            3) docker_rm_volumes ;;
            4) docker_rm_buildcache ;;
            5) docker_system_prune ;;
            6) docker_clean_logs ;;
            7|"") return ;;
            *) print_error "Invalid choice." ;;
        esac
    done
}

docker_rm_stopped() {
    record_disk_start
    echo ""
    local output="" removed=0
    local ui_width
    ui_width="$(get_ui_content_width)"
    local containers
    containers="$(docker ps -a --filter status=exited -q 2>/dev/null)"
    if [[ -z "$containers" ]]; then
        print_info "No stopped containers."
        pause
        return
    fi
    printf '  Stopped containers:\n'
    docker ps -a --filter status=exited --format '{{.ID}}  {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null \
        | while IFS= read -r line; do
            printf '  %s\n' "$(truncate_for_table "$line" "$ui_width")"
          done
    echo ""
    if ! confirm "Remove stopped containers?"; then pause; return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        output="$(docker container prune -f 2>/dev/null || true)"
        removed="$(extract_reclaimed_bytes "$output")"
    fi
    local freed; freed=$(calc_freed_since_start)
    (( removed > freed )) && freed="$removed"
    print_success "Freed: $(format_size "$freed")"
    log_action "docker" "rm-stopped" "$freed"
    pause
}

docker_rm_images() {
    record_disk_start
    echo ""
    local output="" removed=0
    if ! confirm "Remove all unused Docker images?"; then pause; return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        output="$(docker image prune -a -f 2>/dev/null || true)"
        removed="$(extract_reclaimed_bytes "$output")"
    fi
    local freed; freed=$(calc_freed_since_start)
    (( removed > freed )) && freed="$removed"
    print_success "Freed: $(format_size "$freed")"
    log_action "docker" "rm-images" "$freed"
    pause
}

docker_rm_volumes() {
    record_disk_start
    echo ""
    local output="" removed=0
    print_warning "Removing unused volumes will permanently destroy any data in them!"
    if ! confirm "Remove unused Docker volumes?"; then pause; return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        output="$(docker volume prune -f 2>/dev/null || true)"
        removed="$(extract_reclaimed_bytes "$output")"
    fi
    local freed; freed=$(calc_freed_since_start)
    (( removed > freed )) && freed="$removed"
    print_success "Freed: $(format_size "$freed")"
    log_action "docker" "rm-volumes" "$freed"
    pause
}

docker_rm_buildcache() {
    record_disk_start
    echo ""
    local output="" removed=0
    if ! confirm "Remove Docker build cache?"; then pause; return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        output="$(docker builder prune -a -f 2>/dev/null || true)"
        removed="$(extract_reclaimed_bytes "$output")"
    fi
    local freed; freed=$(calc_freed_since_start)
    (( removed > freed )) && freed="$removed"
    print_success "Freed: $(format_size "$freed")"
    log_action "docker" "rm-buildcache" "$freed"
    pause
}

docker_system_prune() {
    record_disk_start
    echo ""
    local output="" removed=0
    print_warning "This will remove ALL unused containers, images, networks, and optionally volumes."
    if ! confirm "Run docker system prune --all --volumes?"; then pause; return; fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        output="$(docker system prune -a --volumes -f 2>/dev/null || true)"
        removed="$(extract_reclaimed_bytes "$output")"
    fi
    local freed; freed=$(calc_freed_since_start)
    (( removed > freed )) && freed="$removed"
    print_success "Freed: $(format_size "$freed")"
    log_action "docker" "system-prune" "$freed"
    pause
}

docker_clean_logs() {
    record_disk_start
    echo ""
    local total=0 removed=0
    local log_dir="/var/lib/docker/containers"

    total=$(get_find_size_bytes "$log_dir" -name '*-json.log')

    printf '  Docker container log size: %s\n' "$(format_size "$total")"
    if [[ "$total" -eq 0 ]]; then print_info "Nothing to clean."; pause; return; fi
    if ! confirm "Truncate Docker container logs?"; then pause; return; fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        removed="$(truncate_matching_files_and_count_removed "$log_dir" -name '*-json.log')"
    fi

    local freed; freed=$(calc_freed_since_start)
    (( removed > freed )) && freed="$removed"
    print_cleanup_result "$removed" "$freed"
    log_action "docker" "clean-logs" "$freed"
    pause
}

# --- Option 7: Snap/Flatpak Cleanup ----------------------------------------

menu_snap_flatpak_cleanup() {
    if [[ "$HAS_SNAP" -eq 0 ]] && [[ "$HAS_FLATPAK" -eq 0 ]]; then
        echo ""
        print_warning "Neither snap nor flatpak is installed."
        pause
        return
    fi

    echo ""
    printf '  %s%s📎 Snap/Flatpak Cleanup%s\n\n' "$BOLD" "$CYAN" "$RESET"
    record_disk_start

    # Snap cleanup
    if [[ "$HAS_SNAP" -eq 1 ]]; then
        printf '  %s%sSnap:%s\n' "$BOLD" "$WHITE" "$RESET"

        local disabled_snaps
        disabled_snaps="$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')"

        if [[ -z "$disabled_snaps" ]]; then
            print_info "No disabled snap revisions found."
        else
            printf '  Disabled snap revisions:\n'
            echo "$disabled_snaps" | while read -r name rev; do
                printf '    %s (rev %s)\n' "$name" "$rev"
            done

            if confirm "Remove disabled snap revisions?"; then
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' \
                        | while read -r name rev; do
                            snap remove "$name" --revision="$rev" 2>/dev/null || true
                          done
                fi
            fi
        fi
        echo ""
    fi

    # Flatpak cleanup
    if [[ "$HAS_FLATPAK" -eq 1 ]]; then
        printf '  %s%sFlatpak:%s\n' "$BOLD" "$WHITE" "$RESET"

        local unused_runtimes
        unused_runtimes="$(flatpak list --runtime --columns=application 2>/dev/null | tail -n +1)"

        printf '  Cleaning unused flatpak runtimes...\n'
        if confirm "Remove unused flatpak runtimes?"; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                flatpak uninstall --unused -y 2>/dev/null || true
            fi
        fi
        echo ""
    fi

    local freed; freed=$(calc_freed_since_start)
    print_success "Freed: $(format_size "$freed")"
    log_action "snap-flatpak" "cleanup" "$freed"
    pause
}

# --- Option 8: Find Large Files --------------------------------------------

find_large_files() {
    echo ""
    printf '  %s%s🔍 Find Large Files%s\n\n' "$BOLD" "$CYAN" "$RESET"
    local ui_width listed_path_width selected_path_width
    ui_width="$(get_ui_content_width)"
    listed_path_width=$(( ui_width - 17 ))
    (( listed_path_width < 20 )) && listed_path_width=20
    selected_path_width=$(( ui_width - 20 ))
    (( selected_path_width < 20 )) && selected_path_width=20

    printf '  Minimum size in MB [%d]: ' "$LARGE_FILE_MIN_SIZE_MB"
    local input_size
    read -r input_size
    if [[ -n "$input_size" ]]; then
        if [[ "$input_size" =~ ^[0-9]+$ ]] && [[ "$input_size" -gt 0 ]]; then
            LARGE_FILE_MIN_SIZE_MB="$input_size"
        else
            print_error "Invalid input. Using default: ${LARGE_FILE_MIN_SIZE_MB}MB"
        fi
    fi

    printf '\n  Searching for files larger than %dMB...\n\n' "$LARGE_FILE_MIN_SIZE_MB"

    TEMP_FILE="$(mktemp /tmp/vps-cleaner-largefiles.XXXXXX)"

    find / -xdev -type f -not -path '/proc/*' -not -path '/sys/*' -not -path '/dev/*' \
        -not -path '/run/*' -not -path '/snap/*' \
        -size +"${LARGE_FILE_MIN_SIZE_MB}M" -exec stat -c '%s %n' {} + 2>/dev/null \
        | sort -rn > "$TEMP_FILE"

    local count=0
    while IFS=' ' read -r size fpath; do
        count=$(( count + 1 ))
        printf '  %s%3d)%s %10s  %s\n' "$BOLD" "$count" "$RESET" \
            "$(format_size "$size")" "$(truncate_path_for_display "$fpath" "$listed_path_width")"
    done < "$TEMP_FILE"

    if [[ "$count" -eq 0 ]]; then
        print_info "No files found larger than ${LARGE_FILE_MIN_SIZE_MB}MB."
        rm -f "$TEMP_FILE" 2>/dev/null
        TEMP_FILE=""
        pause
        return
    fi

    echo ""
    printf '  Select files to delete (e.g. 1,3,5 or 1-5 or "none"): '
    local selection
    read -r selection

    if [[ -z "$selection" || "${selection,,}" == "none" ]]; then
        print_info "No files selected."
        rm -f "$TEMP_FILE" 2>/dev/null
        TEMP_FILE=""
        pause
        return
    fi

    # Parse selection into list of line numbers
    local -a selected_lines=()
    IFS=',' read -ra parts <<< "$selection"
    for part in "${parts[@]}"; do
        part="$(echo "$part" | sed 's/[[:space:]]//g')"
        if [[ "$part" == *-* ]]; then
            local range_start range_end
            range_start="${part%-*}"
            range_end="${part#*-}"
            for (( i = range_start; i <= range_end; i++ )); do
                selected_lines+=("$i")
            done
        else
            selected_lines+=("$part")
        fi
    done

    # Show what will be deleted
    record_disk_start
    echo ""
    printf '  Files to delete:\n'
    for ln in "${selected_lines[@]}"; do
        local line
        line="$(sed -n "${ln}p" "$TEMP_FILE")"
        if [[ -n "$line" ]]; then
            local sz fp
            sz="$(echo "$line" | awk '{print $1}')"
            fp="$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ //')"
            printf '    %s (%s)\n' "$(truncate_path_for_display "$fp" "$selected_path_width")" "$(format_size "$sz")"
        fi
    done

    echo ""
    if ! confirm "Delete selected files?"; then
        rm -f "$TEMP_FILE" 2>/dev/null
        TEMP_FILE=""
        pause
        return
    fi

    for ln in "${selected_lines[@]}"; do
        local line
        line="$(sed -n "${ln}p" "$TEMP_FILE")"
        if [[ -n "$line" ]]; then
            local fp
            fp="$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ //')"
            safe_rm_file "$fp"
        fi
    done

    rm -f "$TEMP_FILE" 2>/dev/null
    TEMP_FILE=""

    local freed; freed=$(calc_freed_since_start)
    print_success "Freed: $(format_size "$freed")"
    log_action "large-files" "delete-selected" "$freed"
    pause
}

# --- Option 9: Full Deep Clean ---------------------------------------------

full_deep_clean() {
    echo ""
    printf '  %s%s🗑️  Full Deep Clean%s\n\n' "$BOLD" "$CYAN" "$RESET"
    print_warning "This will run all cleanup operations."
    print_info "Dangerous operations will still require individual confirmation."
    echo ""

    local ui_width estimate_label_width estimate_table_width
    # Comprehensive estimate
    local est_logs est_pkg est_tmp est_thumb est_trash est_crash est_docker est_total
    ui_width="$(get_ui_content_width)"
    estimate_label_width=$(( ui_width - 15 ))
    (( estimate_label_width > 48 )) && estimate_label_width=48
    (( estimate_label_width < 20 )) && estimate_label_width=20
    estimate_table_width=$(( estimate_label_width + 11 ))

    est_logs=$(get_rotated_logs_size)
    est_pkg=$(estimate_pkg_cache_size)
    est_tmp=$(get_find_size_bytes /tmp -mtime +"$TEMP_FILE_AGE_DAYS")
    est_tmp=$(( est_tmp + $(get_find_size_bytes /var/tmp -mtime +"$TEMP_FILE_AGE_DAYS") ))
    est_thumb=0
    for d in /root/.cache/thumbnails /home/*/.cache/thumbnails; do
        [[ -d "$d" ]] && est_thumb=$(( est_thumb + $(get_size_bytes "$d") ))
    done
    est_trash=0
    for d in /root/.local/share/Trash /home/*/.local/share/Trash; do
        [[ -d "$d" ]] && est_trash=$(( est_trash + $(get_size_bytes "$d") ))
    done
    est_crash=$(get_size_bytes /var/crash 2>/dev/null || echo 0)
    est_docker=0
    if [[ "$HAS_DOCKER" -eq 1 ]]; then
        est_docker="$(get_docker_reclaimable_estimate_bytes)"
    fi

    est_total=$(( est_logs + est_pkg + est_tmp + est_thumb + est_trash + est_crash + est_docker ))

    printf '  %sEstimated cleanable space:%s\n\n' "$BOLD" "$RESET"
    print_labeled_size_row "Rotated logs" "$(format_size "$est_logs")" "$estimate_label_width"
    print_labeled_size_row "Package cache" "$(format_size "$est_pkg")" "$estimate_label_width"
    print_labeled_size_row "Temp files" "$(format_size "$est_tmp")" "$estimate_label_width"
    print_labeled_size_row "Thumbnails" "$(format_size "$est_thumb")" "$estimate_label_width"
    print_labeled_size_row "Trash" "$(format_size "$est_trash")" "$estimate_label_width"
    print_labeled_size_row "Crash dumps" "$(format_size "$est_crash")" "$estimate_label_width"
    [[ "$HAS_DOCKER" -eq 1 ]] && print_labeled_size_row "Docker" "$(format_size "$est_docker")" "$estimate_label_width"
    print_separator "$estimate_table_width"
    printf '    %-*s %s%10s%s\n' "$estimate_label_width" \
        "$(truncate_for_table "Estimated total" "$estimate_label_width")" "$BOLD" "$(format_size "$est_total")" "$RESET"
    echo ""

    if ! confirm "Start Full Deep Clean?"; then
        print_info "Cancelled."
        pause
        return
    fi

    record_disk_start
    echo ""

    # Step 1: Rotated logs
    printf '  %s[1/7]%s Cleaning rotated logs...\n' "$BOLD" "$RESET"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! delete_rotated_logs; then
            had_errors=1
            print_warning "Failed to remove some rotated logs."
        fi
    fi
    print_success "Rotated logs cleaned."

    # Step 2: Package cache
    printf '  %s[2/7]%s Cleaning package cache...\n' "$BOLD" "$RESET"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! clean_pkg_cache_silent; then
            had_errors=1
            print_warning "Package cache cleanup encountered errors."
        fi
    fi
    print_success "Package cache cleaned."

    # Step 3: Orphaned packages
    printf '  %s[3/7]%s Removing orphaned packages...\n' "$BOLD" "$RESET"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        local orphan_status=0
        case "$PKG_MANAGER" in
            apt) apt-get autoremove -y 2>/dev/null || orphan_status=1 ;;
            dnf) dnf autoremove -y 2>/dev/null || orphan_status=1 ;;
            yum) yum autoremove -y 2>/dev/null || orphan_status=1 ;;
            pacman) pacman -Qdtq 2>/dev/null | pacman -Rns --noconfirm - 2>/dev/null || orphan_status=1 ;;
        esac
        if (( orphan_status == 1 )); then
            had_errors=1
            print_warning "Orphan package cleanup encountered errors."
        fi
    fi
    print_success "Orphaned packages removed."

    # Step 4: Temp files
    printf '  %s[4/7]%s Cleaning temp files...\n' "$BOLD" "$RESET"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        local temp_status=0
        find /tmp -mindepth 1 -mtime +"$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || temp_status=1
        find /var/tmp -mindepth 1 -mtime +"$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || temp_status=1
        if (( temp_status == 1 )); then
            had_errors=1
            print_warning "Temporary files cleanup encountered errors."
        fi
    fi
    print_success "Temp files cleaned."

    # Step 5: Thumbnails + Trash + Crash dumps
    printf '  %s[5/7]%s Cleaning thumbnails, trash, crash dumps...\n' "$BOLD" "$RESET"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        for d in /root/.cache/thumbnails /home/*/.cache/thumbnails; do
            [[ -d "$d" ]] && safe_rm_dir_contents "$d"
        done
        for d in /root/.local/share/Trash /home/*/.local/share/Trash; do
            [[ -d "$d" ]] && safe_rm_dir_contents "$d"
        done
        [[ -d /var/crash ]] && safe_rm_dir_contents /var/crash
    fi
    print_success "Thumbnails, trash, and crash dumps cleaned."

    # Step 6: Journal logs
    printf '  %s[6/7]%s Cleaning journal logs...\n' "$BOLD" "$RESET"
    if [[ "$DRY_RUN" -eq 0 ]] && command -v journalctl &>/dev/null; then
        if ! journalctl --vacuum-time="${JOURNAL_RETENTION_DAYS}d" 2>/dev/null; then
            had_errors=1
            print_warning "Journal cleanup encountered errors."
        fi
    fi
    print_success "Journal logs cleaned."

    # Step 7: Docker (requires confirmation)
    if [[ "$HAS_DOCKER" -eq 1 ]]; then
        printf '  %s[7/7]%s Docker cleanup\n' "$BOLD" "$RESET"
        if confirm "Run Docker system prune?"; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                if ! docker system prune -a -f 2>/dev/null; then
                    had_errors=1
                    print_warning "Docker cleanup encountered errors."
                fi
            fi
            print_success "Docker cleaned."
        else
            print_info "Docker cleanup skipped."
        fi
    else
        printf '  %s[7/7]%s Docker not available — skipped.\n' "$BOLD" "$RESET"
    fi

    echo ""
    print_separator
    local freed; freed=$(calc_freed_since_start)
    printf '\n'
    if (( had_errors == 1 )); then
        print_warning "Full Deep Clean finished with warnings. Freed: $(format_size "$freed")"
    else
        print_success "Full Deep Clean complete! Freed: $(format_size "$freed")"
    fi
    log_action "deep-clean" "full" "$freed"
    pause
}

# ============================================================================
# MENU FUNCTIONS
# ============================================================================

# --- Option 10: Settings ---------------------------------------------------

menu_settings() {
    while true; do
        echo ""
        printf '  %s%s⚙️  Settings%s\n\n' "$BOLD" "$CYAN" "$RESET"
        printf '  Current configuration:\n\n'
        printf '  1) Journal retention days:      %s%d%s\n' "$BOLD" "$JOURNAL_RETENTION_DAYS" "$RESET"
        printf '  2) Log truncation threshold:    %s%d MB%s\n' "$BOLD" "$LOG_TRUNCATE_THRESHOLD_MB" "$RESET"
        printf '  3) Large file min size:         %s%d MB%s\n' "$BOLD" "$LARGE_FILE_MIN_SIZE_MB" "$RESET"
        printf '  4) Temp file age threshold:     %s%d days%s\n' "$BOLD" "$TEMP_FILE_AGE_DAYS" "$RESET"
        printf '  5) Dry-run mode:                %s%s%s\n' "$BOLD" "$(if [[ $DRY_RUN -eq 1 ]]; then echo "ON"; else echo "OFF"; fi)" "$RESET"
        printf '  6) Save settings\n'
        printf '  7) Back\n'
        echo ""

        local choice
        read_choice "Enter choice" 7
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1)
                printf '  Journal retention days [%d]: ' "$JOURNAL_RETENTION_DAYS"
                local v; read -r v
                if [[ -n "$v" ]]; then
                    [[ "$v" =~ ^[0-9]+$ ]] && JOURNAL_RETENTION_DAYS="$v" || print_error "Must be a positive integer."
                fi
                ;;
            2)
                printf '  Log truncation threshold in MB [%d]: ' "$LOG_TRUNCATE_THRESHOLD_MB"
                local v; read -r v
                if [[ -n "$v" ]]; then
                    [[ "$v" =~ ^[0-9]+$ ]] && LOG_TRUNCATE_THRESHOLD_MB="$v" || print_error "Must be a positive integer."
                fi
                ;;
            3)
                printf '  Large file min size in MB [%d]: ' "$LARGE_FILE_MIN_SIZE_MB"
                local v; read -r v
                if [[ -n "$v" ]]; then
                    [[ "$v" =~ ^[0-9]+$ ]] && LARGE_FILE_MIN_SIZE_MB="$v" || print_error "Must be a positive integer."
                fi
                ;;
            4)
                printf '  Temp file age in days [%d]: ' "$TEMP_FILE_AGE_DAYS"
                local v; read -r v
                if [[ -n "$v" ]]; then
                    [[ "$v" =~ ^[0-9]+$ ]] && TEMP_FILE_AGE_DAYS="$v" || print_error "Must be a positive integer."
                fi
                ;;
            5)
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    DRY_RUN=0
                    print_info "Dry-run mode DISABLED."
                else
                    DRY_RUN=1
                    print_warning "Dry-run mode ENABLED. No actual deletions will occur."
                fi
                ;;
            6)
                save_config
                print_success "Settings saved to $CONFIG_FILE"
                ;;
            7|"") return ;;
            *) print_error "Invalid choice." ;;
        esac
    done
}

# --- Option 11: Install/Update ---------------------------------------------

menu_install_update() {
    while true; do
        echo ""
        printf '  %s%s📥 Install/Update vps-cleaner%s\n\n' "$BOLD" "$CYAN" "$RESET"

        local installed="no"
        local installed_version="N/A"
        if [[ -f "$INSTALL_PATH" ]]; then
            installed="yes"
            installed_version="$(extract_script_version_from_file "$INSTALL_PATH" 2>/dev/null || true)"
            [[ -z "$installed_version" ]] && installed_version="unknown"
        fi

        printf '  Installed:       %s\n' "$installed"
        printf '  Current version: %s\n' "$SCRIPT_VERSION"
        [[ "$installed" == "yes" ]] && printf '  Installed version: %s\n' "$installed_version"
        echo ""

        printf '  1) Install to %s\n' "$INSTALL_PATH"
        printf '  2) Check for updates\n'
        printf '  3) Uninstall\n'
        printf '  4) Install optional dependencies\n'
        printf '  5) Back\n'
        echo ""

        local choice
        read_choice "Enter choice" 5
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1) install_self ;;
            2) check_update ;;
            3) uninstall_self ;;
            4) offer_install_optional_deps ;;
            5|"") return ;;
            *) print_error "Invalid choice." ;;
        esac
    done
}

extract_script_version_from_file() {
    local script_path="${1:-}"
    [[ -n "$script_path" && -f "$script_path" ]] || return 1

    local version=""
    version="$(sed -n 's/.*SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$script_path" 2>/dev/null | head -1)"
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

fetch_remote_version() {
    local timeout_sec="${1:-10}"
    local remote_version=""

    if [[ "$HAS_CURL" -eq 1 ]]; then
        remote_version="$(curl -fsSL --max-time "$timeout_sec" "$SCRIPT_RAW_URL" 2>/dev/null \
            | sed -n 's/.*SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1 || true)"
    elif [[ "$HAS_WGET" -eq 1 ]]; then
        remote_version="$(wget -qO- --timeout="$timeout_sec" "$SCRIPT_RAW_URL" 2>/dev/null \
            | sed -n 's/.*SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1 || true)"
    fi

    [[ -n "$remote_version" ]] || return 1
    printf '%s' "$remote_version"
}

download_remote_script() {
    local output_path="${1:-}"
    local timeout_sec="${2:-30}"
    [[ -n "$output_path" ]] || return 1

    if [[ "$HAS_CURL" -eq 1 ]]; then
        curl -fsSL --max-time "$timeout_sec" "$SCRIPT_RAW_URL" -o "$output_path" 2>/dev/null || return 1
    elif [[ "$HAS_WGET" -eq 1 ]]; then
        wget -qO "$output_path" --timeout="$timeout_sec" "$SCRIPT_RAW_URL" 2>/dev/null || return 1
    else
        return 1
    fi

    [[ -s "$output_path" ]] || return 1
}

validate_downloaded_script() {
    local script_path="${1:-}"
    local expected_version="${2:-}"
    [[ -n "$script_path" && -s "$script_path" ]] || return 1

    if ! head -c 2 "$script_path" 2>/dev/null | grep -q '^#!'; then
        return 1
    fi

    local downloaded_version=""
    downloaded_version="$(extract_script_version_from_file "$script_path" 2>/dev/null || true)"
    [[ -n "$downloaded_version" ]] || return 1

    if [[ -n "$expected_version" ]] && [[ "$downloaded_version" != "$expected_version" ]]; then
        return 1
    fi
}

install_script_atomically() {
    local source_path="${1:-}"
    local target_path="${2:-$INSTALL_PATH}"
    [[ -n "$source_path" && -f "$source_path" ]] || return 1

    local source_real target_real
    source_real="$(realpath -m "$source_path" 2>/dev/null || echo "$source_path")"
    target_real="$(realpath -m "$target_path" 2>/dev/null || echo "$target_path")"
    if [[ "$source_real" == "$target_real" ]]; then
        chmod +x -- "$target_path" 2>/dev/null || return 1
        return 0
    fi

    local target_dir staged_file
    target_dir="$(dirname "$target_path")"
    staged_file="$(mktemp "${target_dir}/.vps-cleaner-stage.XXXXXX")" || return 1

    if ! cp -- "$source_path" "$staged_file" 2>/dev/null; then
        rm -f -- "$staged_file" 2>/dev/null || true
        return 1
    fi
    if ! chmod +x -- "$staged_file" 2>/dev/null; then
        rm -f -- "$staged_file" 2>/dev/null || true
        return 1
    fi
    if ! mv -f -- "$staged_file" "$target_path" 2>/dev/null; then
        rm -f -- "$staged_file" 2>/dev/null || true
        return 1
    fi
}

install_self() {
    echo ""
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_prefix
        printf 'Would install %s to %s\n' "$SELF_PATH" "$INSTALL_PATH"
        return
    fi

    if ! install_script_atomically "$SELF_PATH" "$INSTALL_PATH"; then
        print_error "Failed to copy to $INSTALL_PATH"
        return
    fi
    print_success "Installed to $INSTALL_PATH"
    log_action "install" "install" "0"
}

check_update() {
    echo ""
    if [[ "$HAS_CURL" -eq 0 ]] && [[ "$HAS_WGET" -eq 0 ]]; then
        print_warning "curl/wget not available — cannot check for updates."
        return
    fi

    printf '  Checking for updates...\n'
    local remote_version=""
    remote_version="$(fetch_remote_version 10 2>/dev/null || true)"

    if [[ -z "$remote_version" ]]; then
        print_warning "Could not fetch remote version."
        return
    fi

    LAST_UPDATE_CHECK="$(date +%s)"
    save_config

    printf '  Current:  %s\n' "$SCRIPT_VERSION"
    printf '  Latest:   %s\n' "$remote_version"

    if [[ "$remote_version" != "$SCRIPT_VERSION" ]]; then
        print_info "A newer version ($remote_version) is available."
        if confirm "Download and install update?"; then
            local temp_download=""
            temp_download="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-update.XXXXXX")" || {
                print_error "Failed to create temporary file for update."
                return
            }

            if ! download_remote_script "$temp_download" 30; then
                rm -f -- "$temp_download" 2>/dev/null || true
                print_error "Failed to download update."
                return
            fi

            if ! validate_downloaded_script "$temp_download" "$remote_version"; then
                rm -f -- "$temp_download" 2>/dev/null || true
                print_error "Downloaded update failed validation."
                return
            fi

            if ! install_script_atomically "$temp_download" "$INSTALL_PATH"; then
                rm -f -- "$temp_download" 2>/dev/null || true
                print_error "Failed to install update to $INSTALL_PATH."
                return
            fi
            rm -f -- "$temp_download" 2>/dev/null || true

            print_success "Updated to v${remote_version}. Restart the script to use the new version."
            log_action "update" "updated-to-$remote_version" "0"
        fi
    else
        print_success "Already on the latest version."
    fi
}

uninstall_self() {
    echo ""
    if [[ ! -f "$INSTALL_PATH" ]]; then
        print_info "Not installed at $INSTALL_PATH."
        return
    fi

    if ! confirm "Remove $INSTALL_PATH?"; then return; fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        rm -f "$INSTALL_PATH" 2>/dev/null
    fi
    print_success "Uninstalled from $INSTALL_PATH"
    log_action "install" "uninstall" "0"
}

# ============================================================================
# AUTO-UPDATE CHECK
# ============================================================================

auto_update_check() {
    # Only check if installed and if we have curl/wget
    if [[ ! -f "$INSTALL_PATH" ]]; then return; fi
    if [[ "$HAS_CURL" -eq 0 ]] && [[ "$HAS_WGET" -eq 0 ]]; then return; fi

    local now
    now="$(date +%s)"
    local diff=$(( now - LAST_UPDATE_CHECK ))

    # Check once per 24 hours (86400 seconds)
    if (( diff < 86400 )); then return; fi

    local remote_version=""
    remote_version="$(fetch_remote_version 5 2>/dev/null || true)"
    [[ -z "$remote_version" ]] && return

    LAST_UPDATE_CHECK="$now"
    save_config

    if [[ -n "$remote_version" && "$remote_version" != "$SCRIPT_VERSION" ]]; then
        print_info "Update available: v${remote_version} (current: v${SCRIPT_VERSION})"
        print_info "Use menu option 11 to update."
        echo ""
    fi
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    setup_colors
    check_root
    detect_distro
    check_dependencies
    load_config

    # Ensure log file directory exists
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true

    # Record starting disk state
    record_disk_start

    # Auto-update check (silent, fast)
    auto_update_check

    # Dry run notification
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo ""
        print_warning "DRY-RUN MODE ENABLED. No changes will be made."
    fi

    # Main menu loop
    while true; do
        print_header
        print_menu

        local choice
        if ! read_choice "Enter choice" 12; then
            echo ""
            print_error "Input stream is closed. Run script in an interactive terminal."
            exit 1
        fi
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1)  show_disk_overview ;;
            2)  quick_clean ;;
            3)  menu_logs_cleanup ;;
            4)  menu_package_cleanup ;;
            5)  menu_cache_cleanup ;;
            6)  menu_docker_cleanup ;;
            7)  menu_snap_flatpak_cleanup ;;
            8)  find_large_files ;;
            9)  full_deep_clean ;;
            10) menu_settings ;;
            11) menu_install_update ;;
            12) uninstall_self ;;
            0)
                echo ""
                print_info "Goodbye!"
                log_action "session" "exit" "0"
                exit 0
                ;;
            "")
                print_warning "Please enter a menu number (0-12)."
                ;;
            *)
                print_error "Invalid choice. Please enter 0-12."
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
