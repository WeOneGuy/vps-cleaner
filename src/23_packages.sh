# --- Option 4: Package Manager Cleanup -------------------------------------

menu_package_cleanup() {
    while true; do
        echo ""
        printf '  %s%s📦 Package Manager Cleanup%s\n' "$BOLD" "$CYAN" "$RESET"
        printf '  Package manager: %s%s%s\n\n' "$BOLD" "${PKG_MANAGER:-none}" "$RESET"

        printf '  1) Clean package cache\n'
        printf '  2) Remove orphaned packages\n'
        printf '  3) Remove old kernels (keep current + 1)\n'
        printf '  4) All of the above\n'
        printf '  5) Back\n'
        echo ""

        local choice
        read_choice "Enter choice" 5
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1) clean_package_cache ;;
            2) remove_orphaned_packages ;;
            3) remove_old_kernels ;;
            4)
                clean_package_cache
                remove_orphaned_packages
                remove_old_kernels
                ;;
            5|"") return ;;
            *) print_error "Invalid choice." ;;
        esac
    done
}

clean_package_cache() {
    record_disk_start
    echo ""
    local size size_after removed
    size="$(estimate_pkg_cache_size)"
    printf '  Package cache size: %s\n' "$(format_size "$size")"

    if ! confirm "Clean package cache?"; then pause; return; fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        case "$PKG_MANAGER" in
            apt)
                apt-get clean -y 2>/dev/null || true
                apt-get autoclean -y 2>/dev/null || true
                ;;
            dnf)
                dnf clean all 2>/dev/null || true
                ;;
            yum)
                yum clean all 2>/dev/null || true
                ;;
            pacman)
                pacman -Scc --noconfirm 2>/dev/null || true
                ;;
            apk)
                apk cache clean 2>/dev/null || true
                ;;
            zypper)
                zypper clean --all 2>/dev/null || true
                ;;
        esac
    fi

    size_after="$(estimate_pkg_cache_size)"
    removed=$(( size - size_after ))
    (( removed < 0 )) && removed=0

    local freed
    freed=$(calc_freed_since_start)
    print_cleanup_result "$removed" "$freed"
    log_action "package" "cache-clean" "$freed"
    pause
}

remove_orphaned_packages() {
    record_disk_start
    echo ""
    printf '  Checking for orphaned packages...\n'

    if [[ "$DRY_RUN" -eq 0 ]]; then
        case "$PKG_MANAGER" in
            apt)
                apt-get autoremove -y 2>/dev/null || true
                ;;
            dnf)
                dnf autoremove -y 2>/dev/null || true
                ;;
            yum)
                yum autoremove -y 2>/dev/null || true
                ;;
            pacman)
                # Remove orphans if any exist
                local orphans
                orphans="$(pacman -Qdtq 2>/dev/null || true)"
                if [[ -n "$orphans" ]]; then
                    echo "$orphans" | pacman -Rns --noconfirm - 2>/dev/null || true
                fi
                ;;
            apk)
                # apk doesn't have autoremove; skip
                print_info "apk does not support orphan removal directly."
                ;;
            zypper)
                # zypper packages --orphaned, then remove
                local orphans
                orphans="$(zypper packages --orphaned 2>/dev/null | awk -F'|' 'NR>2 && NF>2 {gsub(/^ +| +$/, "", $3); print $3}' || true)"
                if [[ -n "$orphans" ]]; then
                    echo "$orphans" | xargs zypper remove -y 2>/dev/null || true
                fi
                ;;
        esac
    fi

    local freed
    freed=$(calc_freed_since_start)
    print_success "Freed: $(format_size "$freed")"
    log_action "package" "orphan-remove" "$freed"
    pause
}

remove_old_kernels() {
    record_disk_start
    echo ""
    local current_kernel
    current_kernel="$(uname -r)"
    printf '  Current kernel: %s%s%s\n' "$BOLD" "$current_kernel" "$RESET"

    case "$PKG_MANAGER" in
        apt)
            local old_kernels
            old_kernels="$(dpkg -l 'linux-image-*' 2>/dev/null \
                | awk '/^ii/ && !/'"$current_kernel"'/ {print $2}' \
                | grep -v "$(uname -r | sed 's/-generic//')" \
                | head -n -1 || true)"

            if [[ -z "$old_kernels" ]]; then
                print_info "No old kernels to remove."
                pause
                return
            fi

            printf '  Old kernels found:\n'
            echo "$old_kernels" | while read -r k; do printf '    %s\n' "$k"; done

            if confirm "Remove old kernels?"; then
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    echo "$old_kernels" | xargs apt-get purge -y 2>/dev/null || true
                fi
            fi
            ;;
        dnf|yum)
            printf '  Checking for old kernels...\n'
            if [[ "$DRY_RUN" -eq 0 ]]; then
                if [[ "$PKG_MANAGER" == "dnf" ]]; then
                    dnf remove --oldinstallonly --setopt installonly_limit=2 -y 2>/dev/null || true
                fi
            fi
            ;;
        *)
            print_info "Kernel cleanup not supported for $PKG_MANAGER."
            pause
            return
            ;;
    esac

    local freed
    freed=$(calc_freed_since_start)
    print_success "Freed: $(format_size "$freed")"
    log_action "package" "old-kernels" "$freed"
    pause
}

