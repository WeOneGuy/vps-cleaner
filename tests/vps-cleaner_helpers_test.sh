#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../vps-cleaner.sh
source "$REPO_ROOT/vps-cleaner.sh"

assert_eq() {
    local got="$1" expected="$2" msg="$3"
    if [[ "$got" != "$expected" ]]; then
        printf 'FAIL: %s\nExpected: %s\nGot: %s\n' "$msg" "$expected" "$got" >&2
        exit 1
    fi
}

assert_success() {
    local msg="$1"
    shift
    if ! "$@"; then
        printf 'FAIL: %s\n' "$msg" >&2
        exit 1
    fi
}

assert_failure() {
    local msg="$1"
    shift
    if "$@"; then
        printf 'FAIL: %s\n' "$msg" >&2
        exit 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'FAIL: %s\nExpected to find: %s\nIn: %s\n' "$msg" "$needle" "$haystack" >&2
        exit 1
    fi
}

test_truncate_for_table() {
    assert_eq "$(truncate_for_table "short" 20)" "short" "does not alter short strings"
    assert_eq "$(truncate_for_table "1234567890" 5)" "12..." "truncates with ellipsis"
    assert_eq "$(truncate_for_table "abcdef" 3)" "abc" "truncates without ellipsis when width <= 3"
}

test_format_size() {
    assert_eq "$(format_size 0)" "0 B" "formats bytes without unit scaling"
    assert_eq "$(format_size 1024)" "1.00 KB" "formats kilobytes with 2 decimals"
    assert_eq "$(format_size 1048576)" "1.00 MB" "formats megabytes with 2 decimals"
    assert_eq "$(format_size 1572864)" "1.50 MB" "formats fractional megabytes with 2 decimals"
}

test_should_skip_mountpoint() {
    assert_success "skips docker rootfs overlay mount" should_skip_mountpoint "/var/lib/docker/rootfs/overlayfs/abc123"
    assert_success "skips docker overlay2 mount" should_skip_mountpoint "/var/lib/docker/overlay2/abc123"
    assert_failure "does not skip regular root mount" should_skip_mountpoint "/"
}

test_should_skip_filesystem() {
    assert_success "skips docker rootfs overlay filesystem" should_skip_filesystem "/var/lib/docker/rootfs/overlayfs/abc123"
    assert_success "skips docker overlay2 filesystem" should_skip_filesystem "/var/lib/docker/overlay2/abc123"
    assert_failure "does not skip regular overlay filesystem" should_skip_filesystem "overlay"
}

test_run_timed_pipeline() {
    local output
    output="$(run_timed_pipeline 2 "printf 'ok'")"
    assert_eq "$output" "ok" "returns command output"

    if command -v timeout >/dev/null 2>&1; then
        if run_timed_pipeline 1 "sleep 2" >/dev/null 2>&1; then
            printf 'FAIL: timeout should interrupt long command\n' >&2
            exit 1
        fi
    fi
}

test_get_find_size_bytes() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    printf 'abc' > "$tmpdir/a.log.1"
    printf 'defgh' > "$tmpdir/b.log.2"
    printf 'ignore' > "$tmpdir/c.txt"

    local matched no_match
    matched="$(get_find_size_bytes "$tmpdir" -name '*.log.*')"
    no_match="$(get_find_size_bytes "$tmpdir" -name '*.does-not-exist')"

    if [[ "$matched" -lt 8 ]]; then
        printf 'FAIL: get_find_size_bytes should count matching files\n' >&2
        exit 1
    fi
    assert_eq "$no_match" "0" "returns 0 for no matches"

    rm -rf -- "$tmpdir"
    trap - RETURN
}

test_print_menu_contains_uninstall_option() {
    BOLD="" RESET=""
    local menu_output
    menu_output="$(print_menu)"
    assert_contains "$menu_output" "12) 🗑️  Uninstall vps-cleaner" "main menu includes uninstall option"
}

test_clean_all_logs_confirmation_keyword() {
    local script_content
    script_content="$(cat "$REPO_ROOT/vps-cleaner.sh")"
    assert_contains "$script_content" 'Type "CONFIRM" to proceed' "clean_all_logs prompt uses CONFIRM"
    assert_contains "$script_content" '[[ "$reply" != "CONFIRM" ]]' "clean_all_logs validates CONFIRM"
}

test_is_confirm_yes() {
    assert_success "accepts uppercase Y" is_confirm_yes "Y"
    assert_success "accepts lowercase yes" is_confirm_yes "yes"
    assert_success "accepts russian yes" is_confirm_yes "Да"
    assert_failure "rejects no" is_confirm_yes "n"
}

test_extract_reclaimed_bytes() {
    local parsed
    parsed="$(extract_reclaimed_bytes $'Deleted: 3\\nTotal reclaimed space: 2.017GB')"
    if [[ "$parsed" -lt 2000000000 ]]; then
        printf 'FAIL: extract_reclaimed_bytes should parse reclaimed size\n' >&2
        exit 1
    fi
    assert_eq "$(extract_reclaimed_bytes "nothing here")" "0" "returns 0 when reclaimed line is missing"
}

main() {
    test_truncate_for_table
    test_format_size
    test_should_skip_mountpoint
    test_should_skip_filesystem
    test_run_timed_pipeline
    test_get_find_size_bytes
    test_print_menu_contains_uninstall_option
    test_clean_all_logs_confirmation_keyword
    test_is_confirm_yes
    test_extract_reclaimed_bytes
    printf 'PASS: vps-cleaner helper tests\n'
}

main "$@"
