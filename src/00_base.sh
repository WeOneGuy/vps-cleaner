#!/usr/bin/env bash
# ============================================================================
# vps-cleaner — Comprehensive VPS Disk Cleaner
# Version:  managed by SCRIPT_VERSION
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

readonly SCRIPT_VERSION="1.1.0"
readonly SCRIPT_NAME="vps-cleaner"
readonly SCRIPT_REPO="https://github.com/WeOneGuy/vps-cleaner"
readonly SCRIPT_RAW_URL="https://raw.githubusercontent.com/WeOneGuy/vps-cleaner/main/vps-cleaner.sh"
readonly SCRIPT_VERSION_URL="https://raw.githubusercontent.com/WeOneGuy/vps-cleaner/main/VERSION"
readonly CONFIG_FILE="${HOME}/.vps-cleaner.conf"
readonly LOG_FILE="/var/log/vps-cleaner.log"
readonly SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
readonly INSTALL_PATH="/usr/local/bin/vps-cleaner"
readonly DISK_OVERVIEW_SCAN_TIMEOUT_SEC=45
readonly DISK_SCAN_CACHE_TTL_SEC=300
readonly DISK_SCAN_CACHE_MAGIC="vps-cleaner-disk-scan-cache-v1"
readonly DISK_OVERVIEW_SCAN_DEPTH=3
readonly DISK_OVERVIEW_ROOT_LIMIT=6
readonly DISK_OVERVIEW_HOTSPOT_LIMIT=10
readonly DISK_OVERVIEW_TOP_FILES_LIMIT=10
readonly CLI_TOP_DEFAULT_LIMIT=10

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
FIND_SUPPORTS_PRINTF=""
SCAN_CACHE_LAST_STATUS=""
SCAN_CACHE_LAST_AGE_SEC=0

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
