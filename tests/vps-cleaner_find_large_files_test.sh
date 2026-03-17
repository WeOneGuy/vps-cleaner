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

test_find_large_files_handles_eof_on_size_input() {
    if ! (
        BOLD=""
        CYAN=""
        RESET=""
        LARGE_FILE_MIN_SIZE_MB=100
        TEMP_FILE=""

        get_ui_content_width() { echo 80; }
        read_interactive_line() { READ_LINE_VALUE=""; return 1; }
        get_cached_large_files_scan() {
            SCAN_CACHE_LAST_STATUS="miss"
            : > "$1"
            return 0
        }
        format_size() { echo "0 B"; }
        print_info() { :; }
        print_error() { :; }
        pause() { :; }

        find_large_files >/dev/null 2>&1
    ); then
        fail "find_large_files should not fail when minimum-size input stream is closed"
    fi
}

test_find_large_files_handles_eof_on_selection_input() {
    if ! (
        BOLD=""
        CYAN=""
        RESET=""
        LARGE_FILE_MIN_SIZE_MB=100
        TEMP_FILE=""
        read_calls=0

        get_ui_content_width() { echo 80; }
        read_interactive_line() {
            read_calls=$(( read_calls + 1 ))
            if (( read_calls == 1 )); then
                READ_LINE_VALUE=""
                return 0
            fi
            READ_LINE_VALUE=""
            return 1
        }
        get_cached_large_files_scan() {
            SCAN_CACHE_LAST_STATUS="miss"
            printf '12345 /tmp/test-large-file.log\n' > "$1"
        }
        format_size() { echo "12.06 KB"; }
        truncate_path_for_display() { printf '%s' "$1"; }
        print_info() { :; }
        print_error() { :; }
        pause() { :; }

        find_large_files >/dev/null 2>&1
    ); then
        fail "find_large_files should not fail when selection input stream is closed"
    fi
}

main() {
    test_find_large_files_handles_eof_on_size_input
    test_find_large_files_handles_eof_on_selection_input
    printf 'PASS: vps-cleaner large files input tests\n'
}

main "$@"
