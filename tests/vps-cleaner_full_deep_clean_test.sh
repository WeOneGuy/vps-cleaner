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

test_full_deep_clean_dry_run_without_errors() {
    if ! (
        DRY_RUN=1
        HAS_DOCKER=0
        BOLD=""
        CYAN=""
        RESET=""

        get_ui_content_width() { echo 80; }
        get_rotated_logs_size() { echo 0; }
        estimate_pkg_cache_size() { echo 0; }
        get_find_size_bytes() { echo 0; }
        get_size_bytes() { echo 0; }
        print_labeled_size_row() { :; }
        print_separator() { :; }
        print_warning() { :; }
        print_info() { :; }
        print_success() { :; }
        confirm() { return 0; }
        record_disk_start() { :; }
        calc_freed_since_start() { echo 0; }
        log_action() { :; }
        pause() { :; }

        full_deep_clean >/dev/null 2>&1
    ); then
        fail "full_deep_clean should not fail in dry-run mode when no step errors occur"
    fi
}

test_full_deep_clean_non_dry_run_without_errors() {
    if ! (
        DRY_RUN=0
        HAS_DOCKER=0
        PKG_MANAGER=apt
        BOLD=""
        CYAN=""
        RESET=""

        get_ui_content_width() { echo 80; }
        get_rotated_logs_size() { echo 0; }
        estimate_pkg_cache_size() { echo 0; }
        get_find_size_bytes() { echo 0; }
        get_size_bytes() { echo 0; }
        print_labeled_size_row() { :; }
        print_separator() { :; }
        print_warning() { :; }
        print_info() { :; }
        print_success() { :; }
        confirm() { return 0; }
        record_disk_start() { :; }
        calc_freed_since_start() { echo 0; }
        log_action() { :; }
        pause() { :; }

        delete_rotated_logs() { return 0; }
        clean_pkg_cache_silent() { return 0; }
        apt-get() { return 0; }
        find() { return 0; }
        journalctl() { return 0; }
        safe_rm_dir_contents() { :; }

        full_deep_clean >/dev/null 2>&1
    ); then
        fail "full_deep_clean should not fail when all cleanup steps succeed"
    fi
}

main() {
    test_full_deep_clean_dry_run_without_errors
    test_full_deep_clean_non_dry_run_without_errors
    printf 'PASS: vps-cleaner full deep clean tests\n'
}

main "$@"
