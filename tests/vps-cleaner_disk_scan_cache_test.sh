#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../vps-cleaner.sh
source "$REPO_ROOT/vps-cleaner.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'FAIL: %s\nExpected to find: %s\nIn: %s\n' "$msg" "$needle" "$haystack" >&2
        exit 1
    fi
}

test_run_cached_disk_scan_reuses_fresh_cache() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    if ! (
        HOME="$tmpdir/home"
        XDG_CACHE_HOME="$tmpdir/cache"
        mkdir -p "$HOME" "$XDG_CACHE_HOME"

        local call_log="$tmpdir/calls.log"
        local first_file second_file first second
        first_file="$(mktemp "$tmpdir/scan-first.XXXXXX")"
        second_file="$(mktemp "$tmpdir/scan-second.XXXXXX")"
        producer() {
            printf 'run\n' >> "$call_log"
            printf '123\t/var\n'
        }

        collect_cached_disk_scan "$first_file" "overview-tree" 300 producer
        first="$(cat "$first_file")"
        collect_cached_disk_scan "$second_file" "overview-tree" 300 producer
        second="$(cat "$second_file")"

        [[ "$first" == $'123\t/var' ]]
        [[ "$second" == $'123\t/var' ]]
        [[ "$(wc -l < "$call_log")" -eq 1 ]]
        [[ "$SCAN_CACHE_LAST_STATUS" == "hit" ]]
    ); then
        fail "run_cached_disk_scan should reuse a fresh cache entry"
    fi

    rm -rf -- "$tmpdir"
    trap - RETURN
}

test_run_cached_disk_scan_refreshes_invalid_cache() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    if ! (
        HOME="$tmpdir/home"
        XDG_CACHE_HOME="$tmpdir/cache"
        mkdir -p "$HOME" "$XDG_CACHE_HOME"

        local cache_path call_log result output_file
        call_log="$tmpdir/calls.log"
        output_file="$(mktemp "$tmpdir/scan-refresh.XXXXXX")"
        cache_path="$(get_disk_scan_cache_path "overview-tree")"
        mkdir -p "$(dirname "$cache_path")"
        printf 'broken-cache\nstale\n' > "$cache_path"

        producer() {
            printf 'run\n' >> "$call_log"
            printf '456\t/usr\n'
        }

        collect_cached_disk_scan "$output_file" "overview-tree" 300 producer
        result="$(cat "$output_file")"

        [[ "$result" == $'456\t/usr' ]]
        [[ "$(head -n 1 "$cache_path")" == "$DISK_SCAN_CACHE_MAGIC" ]]
        [[ "$(wc -l < "$call_log")" -eq 1 ]]
    ); then
        fail "run_cached_disk_scan should ignore invalid cache contents and refresh them"
    fi

    rm -rf -- "$tmpdir"
    trap - RETURN
}

test_invalidate_disk_scan_cache_removes_entries() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    if ! (
        HOME="$tmpdir/home"
        XDG_CACHE_HOME="$tmpdir/cache"
        mkdir -p "$HOME" "$XDG_CACHE_HOME"

        write_disk_scan_cache "overview-tree" $'1\t/\n'
        write_disk_scan_cache "large-files-100mb" "100 /tmp/example.log"
        invalidate_disk_scan_cache

        ! compgen -G "$(get_disk_scan_cache_dir)/${DISK_SCAN_CACHE_MAGIC}-*.cache" >/dev/null
    ); then
        fail "invalidate_disk_scan_cache should remove all disk scan cache files"
    fi

    rm -rf -- "$tmpdir"
    trap - RETURN
}

test_show_disk_overview_highlights_exact_hotspots() {
    local output
    output="$(
        BOLD=""
        CYAN=""
        WHITE=""
        RESET=""
        DIM=""

        record_disk_start() { :; }
        get_ui_content_width() { echo 88; }
        pause() { :; }
        print_separator() { :; }
        truncate_for_table() { printf '%s' "$1"; }
        truncate_path_for_display() { printf '%s' "$1"; }
        draw_bar() { printf '[%s%%]' "$1"; }
        format_size() { printf '%sB' "$1"; }
        format_scan_cache_age() { printf '%ss' "$1"; }
        get_total_used_bytes() { printf '15000'; }
        print_info() { printf 'INFO:%s\n' "$*"; }
        print_warning() { printf 'WARN:%s\n' "$*"; }

        get_cached_disk_overview_directory_tree() {
            SCAN_CACHE_LAST_STATUS="hit"
            SCAN_CACHE_LAST_AGE_SEC=42
            printf '15000\t/\n9000\t/var\n8500\t/var/lib\n8000\t/var/lib/docker\n4000\t/usr\n2000\t/usr/local\n900\t/home\n900\t/home/deploy\n80\t/var/log\n' > "$1"
        }

        get_cached_disk_overview_top_files() {
            SCAN_CACHE_LAST_STATUS="hit"
            SCAN_CACHE_LAST_AGE_SEC=42
            printf '7000 /var/lib/docker/image.db\n600 /usr/local/bin/node\n' > "$1"
        }

        df() {
            local mode="bytes"
            local arg
            for arg in "$@"; do
                if [[ "$arg" == "-i" ]]; then
                    mode="inode"
                    break
                fi
            done

            if [[ "$mode" == "inode" ]]; then
                printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/sda1 1000 100 900 10%% /\n'
                return
            fi

            printf 'Filesystem 1B-blocks Used Available Use%% Mounted on\n/dev/sda1 20000 15000 5000 75%% /\n'
        }

        show_disk_overview
    )"

    assert_contains "$output" "Where Space Goes (Root Directories)" "overview should show a root-directory breakdown"
    assert_contains "$output" "Biggest Hotspots (Exact Paths)" "overview should show an exact hotspot section"
    assert_contains "$output" "/var/lib/docker" "overview should surface deep hotspot paths"
    assert_contains "$output" "/home/deploy" "overview should keep useful non-root paths visible"
    assert_contains "$output" "Largest Individual Files" "overview should keep the large-file section"
    assert_contains "$output" "INFO:Using cached directory breakdown from 42s ago." "overview should report cache hits"
}

main() {
    test_run_cached_disk_scan_reuses_fresh_cache
    test_run_cached_disk_scan_refreshes_invalid_cache
    test_invalidate_disk_scan_cache_removes_entries
    test_show_disk_overview_highlights_exact_hotspots
    printf 'PASS: vps-cleaner disk scan cache tests\n'
}

main "$@"
