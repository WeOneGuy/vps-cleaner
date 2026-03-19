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
    local current_version=""
    current_version="$(get_current_script_version 2>/dev/null || true)"
    [[ -z "$current_version" ]] && current_version="$SCRIPT_VERSION"

    local title="VPS Cleaner v${current_version}"
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

print_menu_item() {
    local option="${1:-}"
    local icon="${2:-}"
    local label="${3:-}"
    printf '  %s%s)%s %s %s\n' "$BOLD" "$option" "$RESET" "$icon" "$label"
}

print_menu() {
    print_menu_item "1" " 📊" "Disk Space Overview"
    print_menu_item "2" " 🚀" "Quick Clean (Safe)"
    print_menu_item "3" " 📋" "System Logs Cleanup"
    print_menu_item "4" " 📦" "Package Manager Cleanup"
    print_menu_item "5" " 🗂️ " "Cache Cleanup"
    print_menu_item "6" " 🐳" "Docker Cleanup"
    print_menu_item "7" " 📎" "Snap/Flatpak Cleanup"
    print_menu_item "8" " 🔍" "Find Large Files"
    print_menu_item "9" " 🗑️ " "Full Deep Clean"
    print_menu_item "10" "⚙️ " "Settings"
    print_menu_item "11" "📥" "Install/Update vps-cleaner"
    print_menu_item "12" "🗑️ " "Uninstall vps-cleaner"
    print_menu_item "0" " 🚪" "Exit"
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

    if [[ "$DRY_RUN" -eq 0 ]] && (( removed > 0 || freed > 0 )); then
        invalidate_disk_scan_cache || true
    fi

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

READ_LINE_VALUE=""
read_interactive_line() {
    local value=""

    if [[ -r /dev/tty ]]; then
        if ! IFS= read -r value < /dev/tty; then
            READ_LINE_VALUE=""
            return 1
        fi
    else
        if ! IFS= read -r value; then
            READ_LINE_VALUE=""
            return 1
        fi
    fi

    READ_LINE_VALUE="$value"
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
