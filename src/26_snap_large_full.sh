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
    if read_interactive_line; then
        input_size="$READ_LINE_VALUE"
    else
        input_size=""
    fi
    if [[ -n "$input_size" ]]; then
        if [[ "$input_size" =~ ^[0-9]+$ ]] && [[ "$input_size" -gt 0 ]]; then
            LARGE_FILE_MIN_SIZE_MB="$input_size"
        else
            print_error "Invalid input. Using default: ${LARGE_FILE_MIN_SIZE_MB}MB"
        fi
    fi

    printf '\n  Searching for files larger than %dMB (cached for %s)...\n\n' \
        "$LARGE_FILE_MIN_SIZE_MB" "$(format_scan_cache_age "$DISK_SCAN_CACHE_TTL_SEC")"

    TEMP_FILE="$(mktemp /tmp/vps-cleaner-largefiles.XXXXXX)"

    if ! get_cached_large_files_scan "$TEMP_FILE" "$LARGE_FILE_MIN_SIZE_MB"; then
        print_error "Large file scan failed."
        rm -f "$TEMP_FILE" 2>/dev/null
        TEMP_FILE=""
        pause
        return
    fi

    if [[ "$SCAN_CACHE_LAST_STATUS" == "hit" ]]; then
        print_info "Using cached large-file scan from $(format_scan_cache_age "$SCAN_CACHE_LAST_AGE_SEC") ago."
        echo ""
    fi

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
    if read_interactive_line; then
        selection="$READ_LINE_VALUE"
    else
        selection=""
    fi

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
    if [[ "$DRY_RUN" -eq 0 ]]; then
        invalidate_disk_scan_cache || true
    fi
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
    local had_errors=0
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
    if [[ "$DRY_RUN" -eq 0 ]] && (( est_total > 0 || freed > 0 )); then
        invalidate_disk_scan_cache || true
    fi
    printf '\n'
    if (( had_errors == 1 )); then
        print_warning "Full Deep Clean finished with warnings. Freed: $(format_size "$freed")"
    else
        print_success "Full Deep Clean complete! Freed: $(format_size "$freed")"
    fi
    log_action "deep-clean" "full" "$freed"
    pause
}

