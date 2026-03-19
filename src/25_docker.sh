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

