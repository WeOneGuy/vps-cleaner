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
    if [[ "$DRY_RUN" -eq 0 ]] && (( total_est > 0 || freed > 0 )); then
        invalidate_disk_scan_cache || true
    fi
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

