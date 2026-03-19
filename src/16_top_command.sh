# ============================================================================
# CLI TOP COMMAND
# ============================================================================

count_lines_in_file() {
    local file_path="${1:-}"
    [[ -f "$file_path" ]] || {
        printf '0'
        return
    }

    awk 'END {print NR+0}' "$file_path"
}

print_ranked_path_table() {
    local title="${1:-}"
    local empty_message="${2:-}"
    local entries_file="${3:-}"
    local total_size_bytes="${4:-0}"
    local ui_width label_width bar_width table_width

    ui_width="$(get_ui_content_width)"
    label_width=$(( ui_width - 39 ))
    (( label_width > 42 )) && label_width=42
    (( label_width < 18 )) && label_width=18
    bar_width=$(( ui_width - label_width - 26 ))
    (( bar_width > 24 )) && bar_width=24
    (( bar_width < 8 )) && bar_width=8
    table_width=$(( label_width + bar_width + 26 ))

    echo ""
    printf '  %s%s%s%s\n' "$BOLD" "$WHITE" "$title" "$RESET"
    print_separator "$table_width"
    printf '  %-*s %10s %6s  %s\n' "$label_width" "Entry" "Size" "Share" "Bar"
    print_separator "$table_width"

    if [[ ! -s "$entries_file" ]]; then
        print_info "$empty_message"
        return
    fi

    [[ "$total_size_bytes" =~ ^[0-9]+$ ]] || total_size_bytes=0
    if (( total_size_bytes <= 0 )); then
        total_size_bytes=1
    fi

    while IFS=$'\t' read -r size path; do
        local label pct
        [[ -n "${size:-}" && -n "${path:-}" ]] || continue
        [[ "$size" =~ ^[0-9]+$ ]] || continue

        label="${path##*/}"
        [[ -n "$label" ]] || label="$path"
        pct=$(( size * 100 / total_size_bytes ))
        (( pct > 100 )) && pct=100
        (( pct < 0 )) && pct=0

        printf '  %-*s %10s %5s  ' \
            "$label_width" "$(truncate_for_table "$label" "$label_width")" "$(format_size "$size")" "${pct}%"
        draw_bar "$pct" "$bar_width"
        printf '\n'
    done < "$entries_file"
}

collect_direct_entries_by_type() {
    local target_path="${1:-}"
    local entry_type="${2:-}"
    local limit="${3:-$CLI_TOP_DEFAULT_LIMIT}"
    local output_file="${4:-}"
    local error_file="${5:-}"
    local paths_file=""

    [[ -d "$target_path" ]] || return 1
    [[ "$entry_type" == "d" || "$entry_type" == "f" ]] || return 1
    [[ -n "$output_file" && -n "$error_file" ]] || return 1

    paths_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-top-paths.XXXXXX")" || return 1

    if ! find "$target_path" -mindepth 1 -maxdepth 1 -type "$entry_type" -print0 > "$paths_file" 2>>"$error_file"; then
        :
    fi

    while IFS= read -r -d '' entry_path; do
        local entry_size=""
        if [[ "$entry_type" == "d" ]]; then
            entry_size="$(get_size_bytes "$entry_path")"
        else
            entry_size="$(stat -c '%s' -- "$entry_path" 2>>"$error_file" || true)"
        fi

        if [[ ! "$entry_size" =~ ^[0-9]+$ ]]; then
            printf 'Failed to inspect: %s\n' "$entry_path" >> "$error_file"
            continue
        fi

        printf '%s\t%s\n' "$entry_size" "$entry_path"
    done < "$paths_file" | sort -rn -k1,1 | head -n "$limit" > "$output_file"

    rm -f -- "$paths_file"
}

parse_top_command_args() {
    CLI_TOP_TARGET_PATH="."
    CLI_TOP_LIMIT="$CLI_TOP_DEFAULT_LIMIT"

    local path_set=0
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                print_top_help
                return 2
                ;;
            --limit)
                shift
                if (( $# == 0 )) || [[ ! "$1" =~ ^[1-9][0-9]*$ ]]; then
                    print_error "Invalid value for --limit. Expected a positive integer."
                    return 1
                fi
                CLI_TOP_LIMIT="$1"
                ;;
            --limit=*)
                local limit_value="${1#*=}"
                if [[ ! "$limit_value" =~ ^[1-9][0-9]*$ ]]; then
                    print_error "Invalid value for --limit. Expected a positive integer."
                    return 1
                fi
                CLI_TOP_LIMIT="$limit_value"
                ;;
            --)
                shift
                if (( $# > 1 )); then
                    print_error "Too many positional arguments for top."
                    return 1
                fi
                if (( $# == 1 )); then
                    CLI_TOP_TARGET_PATH="$1"
                fi
                break
                ;;
            -*)
                print_error "Unknown option for top: $1"
                return 1
                ;;
            *)
                if (( path_set == 1 )); then
                    print_error "Too many positional arguments for top."
                    return 1
                fi
                CLI_TOP_TARGET_PATH="$1"
                path_set=1
                ;;
        esac
        shift
    done

    return 0
}

cli_top_command() {
    local parse_status=0
    parse_top_command_args "$@" || parse_status=$?
    if (( parse_status == 2 )); then
        return 0
    fi
    if (( parse_status != 0 )); then
        return "$parse_status"
    fi

    initialize_runtime

    local target_path="$CLI_TOP_TARGET_PATH"
    local resolved_target=""
    local total_size_bytes=0
    local dir_file file_file error_file

    if [[ ! -e "$target_path" ]]; then
        print_error "Path does not exist: $target_path"
        return 1
    fi
    if [[ ! -d "$target_path" ]]; then
        print_error "Path is not a directory: $target_path"
        return 1
    fi
    if [[ ! -r "$target_path" || ! -x "$target_path" ]]; then
        print_error "Directory is not accessible: $target_path"
        return 1
    fi

    resolved_target="$(realpath "$target_path" 2>/dev/null || printf '%s' "$target_path")"
    total_size_bytes="$(get_size_bytes "$target_path")"
    [[ "$total_size_bytes" =~ ^[0-9]+$ ]] || total_size_bytes=0

    dir_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-top-dirs.XXXXXX")" || return 1
    file_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-top-files.XXXXXX")" || {
        rm -f -- "$dir_file"
        return 1
    }
    error_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-top-errors.XXXXXX")" || {
        rm -f -- "$dir_file" "$file_file"
        return 1
    }

    collect_direct_entries_by_type "$target_path" "d" "$CLI_TOP_LIMIT" "$dir_file" "$error_file" || {
        rm -f -- "$dir_file" "$file_file" "$error_file"
        print_error "Failed to scan direct subdirectories."
        return 1
    }
    collect_direct_entries_by_type "$target_path" "f" "$CLI_TOP_LIMIT" "$file_file" "$error_file" || {
        rm -f -- "$dir_file" "$file_file" "$error_file"
        print_error "Failed to scan direct files."
        return 1
    }

    echo ""
    printf '  %s%s📁 Top Entries%s\n\n' "$BOLD" "$CYAN" "$RESET"
    printf '  Target: %s\n' "$resolved_target"
    printf '  Total size: %s\n' "$(format_size "$total_size_bytes")"
    printf '  Row limit: %s\n' "$CLI_TOP_LIMIT"

    print_ranked_path_table "Largest Directories" "No direct subdirectories found." "$dir_file" "$total_size_bytes"
    print_ranked_path_table "Largest Files" "No direct files found." "$file_file" "$total_size_bytes"

    local warning_count=0
    warning_count="$(count_lines_in_file "$error_file")"
    if [[ "$warning_count" =~ ^[0-9]+$ ]] && (( warning_count > 0 )); then
        print_warning "Skipped ${warning_count} entries due to permission or stat errors."
    fi

    rm -f -- "$dir_file" "$file_file" "$error_file"
}
