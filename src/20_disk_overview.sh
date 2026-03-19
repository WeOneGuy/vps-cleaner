# ============================================================================
# CLEANUP FUNCTIONS
# ============================================================================

# --- Option 1: Disk Space Overview -----------------------------------------

show_disk_overview() {
    local ui_width mount_col_width fs_bar_width fs_table_width inode_mount_col_width inode_table_width
    local usage_bar_width usage_table_width usage_path_width top_files_path_width
    local dir_scan_output top_files_output root_lines hotspot_lines total_dir_size
    local dir_scan_file top_files_file
    record_disk_start
    ui_width="$(get_ui_content_width)"
    dir_scan_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-overview.XXXXXX")" || return 1
    top_files_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-overview.XXXXXX")" || {
        rm -f -- "$dir_scan_file"
        return 1
    }

    fs_bar_width=20
    mount_col_width=$(( ui_width - fs_bar_width - 46 ))
    (( mount_col_width > 32 )) && mount_col_width=32
    (( mount_col_width < 12 )) && mount_col_width=12
    fs_bar_width=$(( ui_width - mount_col_width - 46 ))
    (( fs_bar_width > 24 )) && fs_bar_width=24
    (( fs_bar_width < 8 )) && fs_bar_width=8
    fs_table_width=$(( mount_col_width + fs_bar_width + 46 ))

    inode_mount_col_width=$(( ui_width - 39 ))
    (( inode_mount_col_width > 32 )) && inode_mount_col_width=32
    (( inode_mount_col_width < 12 )) && inode_mount_col_width=12
    inode_table_width=$(( inode_mount_col_width + 39 ))

    usage_bar_width=18
    usage_path_width=$(( ui_width - usage_bar_width - 20 ))
    (( usage_path_width < 24 )) && usage_path_width=24
    usage_table_width=$(( usage_path_width + usage_bar_width + 20 ))
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
        draw_bar "$pct_num" "$fs_bar_width"
        printf '\n'
    done < <(df -P -B1 -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR>1 {print}')

    echo ""
    printf '  %s%sWhere Space Goes (Root Directories):%s\n' "$BOLD" "$WHITE" "$RESET"
    print_separator "$usage_table_width"

    printf '  %s\n' "Building detailed directory breakdown (cached for $(format_scan_cache_age "$DISK_SCAN_CACHE_TTL_SEC"))..."
    if get_cached_disk_overview_directory_tree "$dir_scan_file"; then
        dir_scan_output="$(cat -- "$dir_scan_file")"
        if [[ "$SCAN_CACHE_LAST_STATUS" == "hit" ]]; then
            print_info "Using cached directory breakdown from $(format_scan_cache_age "$SCAN_CACHE_LAST_AGE_SEC") ago."
        fi

        total_dir_size="$(extract_size_for_path "$dir_scan_output" "/")"
        if [[ ! "$total_dir_size" =~ ^[0-9]+$ ]] || (( total_dir_size <= 0 )); then
            total_dir_size="$(get_total_used_bytes)"
        fi

        root_lines="$(filter_disk_usage_lines_by_depth "$dir_scan_output" 1 1 "$DISK_OVERVIEW_ROOT_LIMIT")"
        if [[ -n "$root_lines" ]]; then
            print_disk_usage_rows "$root_lines" "$total_dir_size" "$usage_path_width" "$usage_bar_width"
        else
            print_warning "No root-directory data available from the scan."
        fi
    else
        print_warning "Detailed directory scan timed out. Showing filesystem summary only."
    fi

    echo ""
    printf '  %s%sBiggest Hotspots (Exact Paths):%s\n' "$BOLD" "$WHITE" "$RESET"
    print_separator "$usage_table_width"

    if [[ -n "${dir_scan_output:-}" ]]; then
        hotspot_lines="$(filter_disk_usage_lines_by_depth "$dir_scan_output" 2 "$DISK_OVERVIEW_SCAN_DEPTH" "$DISK_OVERVIEW_HOTSPOT_LIMIT")"
        if [[ -n "$hotspot_lines" ]]; then
            print_disk_usage_rows "$hotspot_lines" "$total_dir_size" "$usage_path_width" "$usage_bar_width"
        else
            print_warning "No detailed hotspots found beyond the root directories."
        fi
    else
        print_warning "Hotspot breakdown is unavailable because the directory scan did not complete."
    fi

    echo ""
    printf '  %s%sLargest Individual Files:%s\n' "$BOLD" "$WHITE" "$RESET"
    print_separator "$usage_table_width"

    printf '  %s\n' "Scanning large files (cached for $(format_scan_cache_age "$DISK_SCAN_CACHE_TTL_SEC"))..."
    if get_cached_disk_overview_top_files "$top_files_file"; then
        top_files_output="$(cat -- "$top_files_file")"
        if [[ "$SCAN_CACHE_LAST_STATUS" == "hit" ]]; then
            print_info "Using cached file ranking from $(format_scan_cache_age "$SCAN_CACHE_LAST_AGE_SEC") ago."
        fi

        if [[ -n "$top_files_output" ]]; then
            print_top_file_rows "$top_files_output" "$top_files_path_width"
        else
            print_info "No files found in the scanned locations."
        fi
    else
        print_warning "Large file scan timed out. Use 'Find Large Files' for a deeper on-demand scan."
    fi

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

    rm -f -- "$dir_scan_file" "$top_files_file"
    echo ""
    pause
}

