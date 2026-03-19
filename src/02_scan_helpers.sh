should_skip_filesystem() {
    local filesystem="${1:-}"
    [[ "$filesystem" == /var/lib/docker/rootfs/overlayfs/* ]] && return 0
    [[ "$filesystem" == /var/lib/docker/overlay2/* ]] && return 0
    return 1
}

run_timed_pipeline() {
    local timeout_sec="${1:-20}"
    shift
    local cmd="$*"

    if command -v timeout &>/dev/null; then
        timeout --foreground "$timeout_sec" bash -o pipefail -c "$cmd"
        return $?
    fi

    # Fallback timeout for systems without GNU timeout.
    local out_file status_file runner_pid watcher_pid rc
    out_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-run.XXXXXX")"
    status_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-run.XXXXXX")"

    (
        bash -o pipefail -c "$cmd" > "$out_file"
        printf '%s' "$?" > "$status_file"
    ) &
    runner_pid=$!

    (
        sleep "$timeout_sec"
        kill -TERM "$runner_pid" 2>/dev/null || true
    ) &
    watcher_pid=$!

    wait "$runner_pid" 2>/dev/null || true

    if kill -0 "$watcher_pid" 2>/dev/null; then
        kill "$watcher_pid" 2>/dev/null || true
    fi
    wait "$watcher_pid" 2>/dev/null || true

    rc=124
    if [[ -s "$status_file" ]]; then
        rc="$(cat "$status_file" 2>/dev/null || echo 1)"
    fi

    cat "$out_file"
    rm -f -- "$out_file" "$status_file"
    return "$rc"
}

get_disk_scan_cache_dir() {
    local base_dir=""
    if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
        base_dir="${XDG_CACHE_HOME%/}"
    elif [[ -n "${HOME:-}" ]]; then
        base_dir="${HOME%/}/.cache"
    else
        base_dir="${TMPDIR:-/tmp}"
    fi

    printf '%s/vps-cleaner' "$base_dir"
}

sanitize_disk_scan_cache_key() {
    local key="${1:-scan}"
    printf '%s' "$key" | sed 's/[^[:alnum:]._-]/_/g'
}

get_disk_scan_cache_path() {
    local key
    key="$(sanitize_disk_scan_cache_key "${1:-scan}")"
    printf '%s/%s-%s.cache' "$(get_disk_scan_cache_dir)" "$DISK_SCAN_CACHE_MAGIC" "$key"
}

format_scan_cache_age() {
    local age_sec="${1:-0}"
    if [[ ! "$age_sec" =~ ^[0-9]+$ ]]; then
        age_sec=0
    fi

    if (( age_sec < 60 )); then
        printf '%ss' "$age_sec"
        return
    fi
    if (( age_sec < 3600 )); then
        printf '%sm' "$(( age_sec / 60 ))"
        return
    fi
    if (( age_sec < 86400 )); then
        printf '%sh' "$(( age_sec / 3600 ))"
        return
    fi
    printf '%sd' "$(( age_sec / 86400 ))"
}

read_disk_scan_cache() {
    local cache_key="${1:-}"
    local ttl_sec="${2:-0}"
    local cache_path cache_header cache_mtime now age_sec

    SCAN_CACHE_LAST_STATUS="miss"
    SCAN_CACHE_LAST_AGE_SEC=0

    [[ -n "$cache_key" ]] || return 1
    [[ "$ttl_sec" =~ ^[0-9]+$ ]] || return 1

    cache_path="$(get_disk_scan_cache_path "$cache_key")"
    [[ -f "$cache_path" ]] || return 1

    if ! IFS= read -r cache_header < "$cache_path"; then
        return 1
    fi
    [[ "$cache_header" == "$DISK_SCAN_CACHE_MAGIC" ]] || return 1

    cache_mtime="$(stat -c '%Y' -- "$cache_path" 2>/dev/null)" || return 1
    now="$(date '+%s')"
    age_sec=$(( now - cache_mtime ))
    (( age_sec < 0 )) && age_sec=0
    (( age_sec <= ttl_sec )) || return 1

    SCAN_CACHE_LAST_STATUS="hit"
    SCAN_CACHE_LAST_AGE_SEC="$age_sec"
    tail -n +2 -- "$cache_path"
}

write_disk_scan_cache() {
    local cache_key="${1:-}"
    local cache_payload="${2-}"
    local cache_dir cache_path temp_path

    [[ -n "$cache_key" ]] || return 1

    cache_dir="$(get_disk_scan_cache_dir)"
    cache_path="$(get_disk_scan_cache_path "$cache_key")"

    mkdir -p -- "$cache_dir" || return 1
    temp_path="$(mktemp "${cache_dir}/.scan-cache.XXXXXX")" || return 1

    if ! {
        printf '%s\n' "$DISK_SCAN_CACHE_MAGIC"
        printf '%s' "$cache_payload"
    } > "$temp_path"; then
        rm -f -- "$temp_path"
        return 1
    fi

    if ! mv -f -- "$temp_path" "$cache_path"; then
        rm -f -- "$temp_path"
        return 1
    fi
}

write_disk_scan_cache_from_file() {
    local cache_key="${1:-}"
    local source_file="${2:-}"
    local cache_dir cache_path temp_path

    [[ -n "$cache_key" ]] || return 1
    [[ -f "$source_file" ]] || return 1

    cache_dir="$(get_disk_scan_cache_dir)"
    cache_path="$(get_disk_scan_cache_path "$cache_key")"

    mkdir -p -- "$cache_dir" || return 1
    temp_path="$(mktemp "${cache_dir}/.scan-cache.XXXXXX")" || return 1

    if ! {
        printf '%s\n' "$DISK_SCAN_CACHE_MAGIC"
        cat -- "$source_file"
    } > "$temp_path"; then
        rm -f -- "$temp_path"
        return 1
    fi

    if ! mv -f -- "$temp_path" "$cache_path"; then
        rm -f -- "$temp_path"
        return 1
    fi
}

invalidate_disk_scan_cache() {
    local cache_dir
    cache_dir="$(get_disk_scan_cache_dir)"

    [[ -d "$cache_dir" ]] || return 0
    find "$cache_dir" -maxdepth 1 -type f -name "${DISK_SCAN_CACHE_MAGIC}-*.cache" -delete 2>/dev/null || return 1
}

collect_cached_disk_scan() {
    local output_file="${1:-}"
    local cache_key="${2:-}"
    local ttl_sec="${3:-0}"
    shift 3

    [[ -n "$output_file" ]] || return 1

    if read_disk_scan_cache "$cache_key" "$ttl_sec" > "$output_file"; then
        return 0
    fi

    SCAN_CACHE_LAST_STATUS="miss"
    SCAN_CACHE_LAST_AGE_SEC=0

    if ! "$@" > "$output_file"; then
        return 1
    fi

    write_disk_scan_cache_from_file "$cache_key" "$output_file" || true
}

run_cached_disk_scan() {
    local cache_key="${1:-}"
    local ttl_sec="${2:-0}"
    shift 2

    local output_file=""
    output_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-scan.XXXXXX")" || return 1

    if ! collect_cached_disk_scan "$output_file" "$cache_key" "$ttl_sec" "$@"; then
        rm -f -- "$output_file"
        return 1
    fi

    cat -- "$output_file"
    rm -f -- "$output_file"
}

find_supports_printf() {
    if [[ -z "$FIND_SUPPORTS_PRINTF" ]]; then
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
            FIND_SUPPORTS_PRINTF=1
        else
            FIND_SUPPORTS_PRINTF=0
        fi
    fi

    [[ "$FIND_SUPPORTS_PRINTF" -eq 1 ]]
}

extract_size_for_path() {
    local scan_output="${1-}"
    local target_path="${2:-/}"

    awk -F '\t' -v target_path="$target_path" '
        $2 == target_path {
            print $1
            exit
        }
    ' <<< "$scan_output"
}

filter_disk_usage_lines_by_depth() {
    local scan_output="${1-}"
    local min_depth="${2:-0}"
    local max_depth="${3:-0}"
    local limit="${4:-0}"

    awk -F '\t' -v min_depth="$min_depth" -v max_depth="$max_depth" -v limit="$limit" '
        function path_depth(path, normalized) {
            normalized = path
            if (normalized == "/") {
                return 0
            }
            sub(/^\/+/, "", normalized)
            if (normalized == "") {
                return 0
            }
            return split(normalized, segments, "/")
        }

        NF >= 2 {
            depth = path_depth($2)
            if (depth < min_depth || depth > max_depth) {
                next
            }

            print $0
            emitted += 1
            if (limit > 0 && emitted >= limit) {
                exit
            }
        }
    ' <<< "$scan_output"
}

print_disk_usage_rows() {
    local usage_lines="${1-}"
    local total_size_bytes="${2:-0}"
    local label_width="${3:-32}"
    local bar_width="${4:-18}"

    [[ "$total_size_bytes" =~ ^[0-9]+$ ]] || total_size_bytes=0
    if (( total_size_bytes <= 0 )); then
        total_size_bytes=1
    fi

    while IFS=$'\t' read -r size path; do
        [[ -n "${size:-}" && -n "${path:-}" ]] || continue
        [[ "$size" =~ ^[0-9]+$ ]] || continue

        local pct=0
        pct=$(( size * 100 / total_size_bytes ))
        (( pct > 100 )) && pct=100
        (( pct < 0 )) && pct=0

        printf '  %-*s %10s  ' \
            "$label_width" "$(truncate_path_for_display "$path" "$label_width")" "$(format_size "$size")"
        draw_bar "$pct" "$bar_width"
        printf '\n'
    done <<< "$usage_lines"
}

print_top_file_rows() {
    local file_lines="${1-}"
    local label_width="${2:-32}"

    while IFS=' ' read -r size path; do
        [[ -n "${size:-}" && -n "${path:-}" ]] || continue
        printf '  %-*s %10s\n' \
            "$label_width" "$(truncate_path_for_display "$path" "$label_width")" "$(format_size "$size")"
    done <<< "$file_lines"
}

scan_disk_overview_directory_tree() {
    run_timed_pipeline "$DISK_OVERVIEW_SCAN_TIMEOUT_SEC" \
        "du -x -B1 -d ${DISK_OVERVIEW_SCAN_DEPTH} / --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/snap --exclude=/var/lib/docker/rootfs/overlayfs --exclude=/var/lib/docker/overlay2 2>/dev/null | sort -rn"
}

scan_disk_overview_top_files() {
    local scan_cmd=""
    if find_supports_printf; then
        scan_cmd="find /var /usr /home /root /opt /srv /tmp -xdev -type f -not -path '/var/lib/docker/rootfs/overlayfs/*' -not -path '/var/lib/docker/overlay2/*' -printf '%s %p\n' 2>/dev/null | sort -rn | head -${DISK_OVERVIEW_TOP_FILES_LIMIT}"
    else
        scan_cmd="find /var /usr /home /root /opt /srv /tmp -xdev -type f -not -path '/var/lib/docker/rootfs/overlayfs/*' -not -path '/var/lib/docker/overlay2/*' -exec stat -c '%s %n' {} + 2>/dev/null | sort -rn | head -${DISK_OVERVIEW_TOP_FILES_LIMIT}"
    fi

    run_timed_pipeline "$DISK_OVERVIEW_SCAN_TIMEOUT_SEC" "$scan_cmd"
}

get_cached_disk_overview_directory_tree() {
    local output_file="${1:-}"
    collect_cached_disk_scan "$output_file" "disk-overview-tree-depth-${DISK_OVERVIEW_SCAN_DEPTH}" "$DISK_SCAN_CACHE_TTL_SEC" scan_disk_overview_directory_tree
}

get_cached_disk_overview_top_files() {
    local output_file="${1:-}"
    collect_cached_disk_scan "$output_file" "disk-overview-top-files" "$DISK_SCAN_CACHE_TTL_SEC" scan_disk_overview_top_files
}

scan_large_files_by_threshold() {
    local min_size_mb="${1:-0}"
    local scan_cmd=""

    if find_supports_printf; then
        scan_cmd="find / -xdev -type f -not -path '/proc/*' -not -path '/sys/*' -not -path '/dev/*' -not -path '/run/*' -not -path '/snap/*' -size +${min_size_mb}M -printf '%s %p\n' 2>/dev/null | sort -rn"
    else
        scan_cmd="find / -xdev -type f -not -path '/proc/*' -not -path '/sys/*' -not -path '/dev/*' -not -path '/run/*' -not -path '/snap/*' -size +${min_size_mb}M -exec stat -c '%s %n' {} + 2>/dev/null | sort -rn"
    fi

    bash -o pipefail -c "$scan_cmd"
}

get_cached_large_files_scan() {
    local output_file="${1:-}"
    local min_size_mb="${2:-0}"
    collect_cached_disk_scan "$output_file" "large-files-${min_size_mb}mb" "$DISK_SCAN_CACHE_TTL_SEC" scan_large_files_by_threshold "$min_size_mb"
}

