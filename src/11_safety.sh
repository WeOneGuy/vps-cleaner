# ============================================================================
# SIGNAL HANDLING
# ============================================================================

cleanup() {
    if [[ -n "$TEMP_FILE" && -f "$TEMP_FILE" ]]; then
        rm -f "$TEMP_FILE" 2>/dev/null
    fi
    printf '\n'
    print_warning "Interrupted. Exiting."
    exit 130
}

trap cleanup SIGINT SIGTERM

# ============================================================================
# SAFETY FUNCTIONS
# ============================================================================

# Verify a path is safe to delete (not a protected path)
is_safe_path() {
    local target="$1"
    target="$(realpath -m "$target" 2>/dev/null || echo "$target")"

    for protected in "${PROTECTED_PATHS[@]}"; do
        if [[ "$target" == "$protected" ]]; then
            return 1
        fi
    done
    # Never allow anything that resolves to /
    if [[ "$target" == "/" ]]; then
        return 1
    fi
    return 0
}

safe_rm_file() {
    local f="$1"
    if ! is_safe_path "$f"; then
        print_error "Refusing to delete protected path: $f"
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_prefix
        printf 'Would delete file: %s\n' "$f"
    else
        rm -f -- "$f" 2>/dev/null
    fi
}

safe_rm_dir_contents() {
    local d="$1"
    if ! is_safe_path "$d"; then
        print_error "Refusing to delete protected path: $d"
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_prefix
        printf 'Would clean directory contents: %s\n' "$d"
    else
        if [[ -d "$d" ]]; then
            find "$d" -mindepth 1 -delete 2>/dev/null || true
        fi
    fi
}

safe_rm_cache_dir() {
    local d="$1"
    if ! is_safe_path "$d"; then
        print_error "Refusing to delete protected path: $d"
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_dry_run_prefix
        printf 'Would remove cache directory: %s\n' "$d"
    else
        rm -rf -- "$d" 2>/dev/null
    fi
}

truncate_matching_files_and_count_removed() {
    local dir="${1:-}"
    shift
    local removed=0 f size

    [[ -d "$dir" ]] || { echo 0; return; }

    if (( $# > 0 )); then
        while IFS= read -r -d '' f; do
            size="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"
            [[ "$size" =~ ^[0-9]+$ ]] || size=0
            if truncate -s 0 -- "$f" 2>/dev/null; then
                removed=$(( removed + size ))
            fi
        done < <(find "$dir" -type f \( "$@" \) -print0 2>/dev/null)
    else
        while IFS= read -r -d '' f; do
            size="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"
            [[ "$size" =~ ^[0-9]+$ ]] || size=0
            if truncate -s 0 -- "$f" 2>/dev/null; then
                removed=$(( removed + size ))
            fi
        done < <(find "$dir" -type f -print0 2>/dev/null)
    fi

    echo "$removed"
}

