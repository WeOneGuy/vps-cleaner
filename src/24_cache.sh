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

