#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../vps-cleaner.sh
source "$REPO_ROOT/vps-cleaner.sh"

test_clean_pkg_cache_silent_success() {
    if ! (
        PKG_MANAGER=dnf
        dnf() { return 0; }
        clean_pkg_cache_silent
    ); then
        printf 'FAIL: clean_pkg_cache_silent should succeed when cleanup command succeeds\n' >&2
        exit 1
    fi
}

test_clean_pkg_cache_silent_failure() {
    if (
        PKG_MANAGER=dnf
        dnf() { return 1; }
        clean_pkg_cache_silent
    ); then
        printf 'FAIL: clean_pkg_cache_silent should fail when cleanup command fails\n' >&2
        exit 1
    fi
}

test_delete_rotated_logs_propagates_status() {
    if ! (
        find() { return 0; }
        delete_rotated_logs
    ); then
        printf 'FAIL: delete_rotated_logs should succeed when find succeeds\n' >&2
        exit 1
    fi

    if (
        find() { return 1; }
        delete_rotated_logs
    ); then
        printf 'FAIL: delete_rotated_logs should fail when find fails\n' >&2
        exit 1
    fi
}

main() {
    test_clean_pkg_cache_silent_success
    test_clean_pkg_cache_silent_failure
    test_delete_rotated_logs_propagates_status
    printf 'PASS: vps-cleaner cleanup helper tests\n'
}

main "$@"