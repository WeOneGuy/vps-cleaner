install_script_atomically() {
    local source_path="${1:-}"
    local target_path="${2:-$INSTALL_PATH}"
    [[ -n "$source_path" && -f "$source_path" ]] || return 1

    local source_real target_real
    source_real="$(realpath -m "$source_path" 2>/dev/null || echo "$source_path")"
    target_real="$(realpath -m "$target_path" 2>/dev/null || echo "$target_path")"
    if [[ "$source_real" == "$target_real" ]]; then
        chmod +x -- "$target_path" 2>/dev/null || return 1
        return 0
    fi

    local target_dir staged_file
    target_dir="$(dirname "$target_path")"
    staged_file="$(mktemp "${target_dir}/.vps-cleaner-stage.XXXXXX")" || return 1

    if ! cp -- "$source_path" "$staged_file" 2>/dev/null; then
        rm -f -- "$staged_file" 2>/dev/null || true
        return 1
    fi
    if ! chmod +x -- "$staged_file" 2>/dev/null; then
        rm -f -- "$staged_file" 2>/dev/null || true
        return 1
    fi
    if ! mv -f -- "$staged_file" "$target_path" 2>/dev/null; then
        rm -f -- "$staged_file" 2>/dev/null || true
        return 1
    fi
}

install_self() {
    echo ""
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_prefix
        printf 'Would install %s to %s\n' "$SELF_PATH" "$INSTALL_PATH"
        return
    fi

    local install_version=""
    install_version="$(get_current_script_version 2>/dev/null || true)"
    [[ -z "$install_version" ]] && install_version="$SCRIPT_VERSION"
    if ! is_valid_semver "$install_version"; then
        print_error "Current script version is invalid: $install_version"
        return
    fi

    local staged_copy=""
    staged_copy="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-install.XXXXXX")" || {
        print_error "Failed to create temporary file for install."
        return
    }

    if ! cp -- "$SELF_PATH" "$staged_copy" 2>/dev/null; then
        rm -f -- "$staged_copy" 2>/dev/null || true
        print_error "Failed to prepare script for install."
        return
    fi

    if ! stamp_script_version_in_file "$staged_copy" "$install_version"; then
        rm -f -- "$staged_copy" 2>/dev/null || true
        print_error "Failed to stamp script version for install."
        return
    fi

    if ! install_script_atomically "$staged_copy" "$INSTALL_PATH"; then
        rm -f -- "$staged_copy" 2>/dev/null || true
        print_error "Failed to copy to $INSTALL_PATH"
        return
    fi
    rm -f -- "$staged_copy" 2>/dev/null || true

    print_success "Installed to $INSTALL_PATH"
    log_action "install" "install" "0"
}

installed_script_exists() {
    [[ -f "$INSTALL_PATH" ]]
}

check_update() {
    echo ""
    if [[ "$HAS_CURL" -eq 0 ]] && [[ "$HAS_WGET" -eq 0 ]]; then
        print_warning "curl/wget not available — cannot check for updates."
        return
    fi

    printf '  Checking for updates...\n'
    local current_version=""
    local remote_version=""
    local compare_result=""
    local temp_download=""
    local same_version_update=0

    current_version="$(get_current_script_version 2>/dev/null || true)"
    [[ -z "$current_version" ]] && current_version="$SCRIPT_VERSION"
    if ! is_valid_semver "$current_version"; then
        print_warning "Current version is invalid: $current_version"
        return
    fi

    remote_version="$(fetch_remote_version 10 2>/dev/null || true)"

    if [[ -z "$remote_version" ]]; then
        print_warning "Could not fetch remote version."
        return
    fi

    LAST_UPDATE_CHECK="$(date +%s)"
    save_config

    printf '  Current:  %s\n' "$current_version"
    printf '  Latest:   %s\n' "$remote_version"

    compare_result="$(compare_semver "$current_version" "$remote_version" 2>/dev/null || true)"
    if [[ -z "$compare_result" ]]; then
        print_warning "Failed to compare versions: current=$current_version remote=$remote_version"
        return
    fi

    if [[ "$compare_result" == "-1" ]]; then
        print_info "A newer version ($remote_version) is available."
    elif [[ "$compare_result" == "0" ]]; then
        local content_compare_status=0
        temp_download="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-update.XXXXXX")" || {
            print_error "Failed to create temporary file for update verification."
            return
        }

        if ! prepare_remote_update_script "$temp_download" "$remote_version" 30; then
            rm -f -- "$temp_download" 2>/dev/null || true
            print_warning "Remote version matches current, but remote script contents could not be verified."
            return
        fi

        if are_script_contents_different "$SELF_PATH" "$temp_download"; then
            same_version_update=1
        else
            content_compare_status=$?
        fi

        if (( content_compare_status == 1 )); then
            rm -f -- "$temp_download" 2>/dev/null || true
            print_success "Already on the latest version."
            return
        fi

        if (( content_compare_status != 0 )); then
            rm -f -- "$temp_download" 2>/dev/null || true
            print_warning "Remote version matches current, but script contents could not be compared safely."
            return
        fi

        print_info "A newer build of version $remote_version is available."
    else
        print_info "Current version ($current_version) is newer than remote ($remote_version)."
        return
    fi

    if ! confirm "Download and install update?"; then
        rm -f -- "$temp_download" 2>/dev/null || true
        return
    fi

    if [[ -z "$temp_download" ]]; then
        temp_download="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-update.XXXXXX")" || {
            print_error "Failed to create temporary file for update."
            return
        }

        if ! prepare_remote_update_script "$temp_download" "$remote_version" 30; then
            rm -f -- "$temp_download" 2>/dev/null || true
            print_error "Failed to prepare downloaded update."
            return
        fi
    fi

    if ! install_script_atomically "$temp_download" "$INSTALL_PATH"; then
        rm -f -- "$temp_download" 2>/dev/null || true
        print_error "Failed to install update to $INSTALL_PATH."
        return
    fi

    rm -f -- "$temp_download" 2>/dev/null || true
    if (( same_version_update == 1 )); then
        print_success "Updated script contents for v${remote_version}. Restart the script to use the refreshed build."
        log_action "update" "updated-build-$remote_version" "0"
    else
        print_success "Updated to v${remote_version}. Restart the script to use the new version."
        log_action "update" "updated-to-$remote_version" "0"
    fi
}

uninstall_self() {
    echo ""
    if [[ ! -f "$INSTALL_PATH" ]]; then
        print_info "Not installed at $INSTALL_PATH."
        return
    fi

    if ! confirm "Remove $INSTALL_PATH?"; then return; fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        rm -f "$INSTALL_PATH" 2>/dev/null
    fi
    print_success "Uninstalled from $INSTALL_PATH"
    log_action "install" "uninstall" "0"
}

