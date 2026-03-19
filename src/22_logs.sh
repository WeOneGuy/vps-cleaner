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
    if [[ "$DRY_RUN" -eq 0 ]] && (( removed_varlog > 0 || freed > 0 )); then
        invalidate_disk_scan_cache || true
    fi
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

