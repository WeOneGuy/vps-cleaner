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

test_truncate_for_table() {
    assert_eq "$(truncate_for_table "short" 20)" "short" "does not alter short strings"
    assert_eq "$(truncate_for_table "1234567890" 5)" "12..." "truncates with ellipsis"
    assert_eq "$(truncate_for_table "abcdef" 3)" "abc" "truncates without ellipsis when width <= 3"
}

test_should_skip_mountpoint() {
    assert_success "skips docker rootfs overlay mount" should_skip_mountpoint "/var/lib/docker/rootfs/overlayfs/abc123"
    assert_success "skips docker overlay2 mount" should_skip_mountpoint "/var/lib/docker/overlay2/abc123"
    assert_failure "does not skip regular root mount" should_skip_mountpoint "/"
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

main() {
    test_truncate_for_table
    test_should_skip_mountpoint
    test_run_timed_pipeline
    printf 'PASS: vps-cleaner helper tests\n'
}

main "$@"
