# ============================================================================
# AUTO-UPDATE CHECK
# ============================================================================

auto_update_check() {
    # Only check if installed and if we have curl/wget
    if ! installed_script_exists; then return; fi
    if [[ "$HAS_CURL" -eq 0 ]] && [[ "$HAS_WGET" -eq 0 ]]; then return; fi

    local now
    now="$(date +%s)"
    local diff=$(( now - LAST_UPDATE_CHECK ))

    # Check once per 24 hours (86400 seconds)
    if (( diff < 86400 )); then return; fi

    local current_version=""
    current_version="$(get_current_script_version 2>/dev/null || true)"
    [[ -z "$current_version" ]] && current_version="$SCRIPT_VERSION"
    is_valid_semver "$current_version" || return

    local remote_version=""
    remote_version="$(fetch_remote_version 5 2>/dev/null || true)"
    [[ -z "$remote_version" ]] && return

    local compare_result=""
    compare_result="$(compare_semver "$current_version" "$remote_version" 2>/dev/null || true)"
    [[ -z "$compare_result" ]] && return

    LAST_UPDATE_CHECK="$now"
    save_config

    if [[ "$compare_result" == "-1" ]]; then
        print_info "Update available: v${remote_version} (current: v${current_version})"
        print_info "Use menu option 11 to update."
        echo ""
        return
    fi

    if [[ "$compare_result" != "0" ]]; then
        return
    fi

    local temp_download=""
    local content_compare_status=0
    [[ -f "$SELF_PATH" ]] || return

    temp_download="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-update.XXXXXX")" || return
    if ! prepare_remote_update_script "$temp_download" "$remote_version" 15; then
        rm -f -- "$temp_download" 2>/dev/null || true
        return
    fi

    if are_script_contents_different "$SELF_PATH" "$temp_download"; then
        rm -f -- "$temp_download" 2>/dev/null || true
        print_info "Update available: newer build of v${remote_version} detected."
        print_info "Use menu option 11 to update."
        echo ""
        return
    fi

    content_compare_status=$?
    if (( content_compare_status != 1 )); then
        rm -f -- "$temp_download" 2>/dev/null || true
        return
    fi

    rm -f -- "$temp_download" 2>/dev/null || true
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

run_interactive_menu() {
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

run_menu_command() {
    if (( $# > 0 )); then
        print_error "The menu command does not accept extra arguments."
        return 1
    fi

    initialize_interactive_runtime
    run_interactive_menu
}

dispatch_cli_command() {
    local command="${1:-menu}"
    shift || true

    case "$command" in
        help|-h|--help)
            print_cli_help
            ;;
        menu)
            run_menu_command "$@"
            ;;
        top)
            cli_top_command "$@"
            ;;
        *)
            print_error "Unknown command: $command"
            print_cli_help
            return 1
            ;;
    esac
}

main() {
    setup_colors

    if (( $# == 0 )); then
        dispatch_cli_command menu
        return
    fi

    dispatch_cli_command "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
