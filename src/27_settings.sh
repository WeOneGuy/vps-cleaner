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

