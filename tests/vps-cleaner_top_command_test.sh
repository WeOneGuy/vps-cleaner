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

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'FAIL: %s\nDid not expect to find: %s\nIn: %s\n' "$msg" "$needle" "$haystack" >&2
        exit 1
    fi
}

test_cli_top_command_prints_directory_and_file_sections() {
    local tmpdir output
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    mkdir -p "$tmpdir/big-dir" "$tmpdir/small-dir"
    printf '1234567890' > "$tmpdir/big-dir/payload.bin"
    printf '1234' > "$tmpdir/small-dir/payload.bin"
    printf '1234567' > "$tmpdir/top.log"
    printf '12' > "$tmpdir/tiny.log"

    output="$(
        initialize_runtime() {
            HAS_DU_BYTES=1
            BOLD=""
            CYAN=""
            WHITE=""
            RESET=""
            DIM=""
        }
        get_ui_content_width() { printf '90'; }
        print_separator() { :; }
        print_info() { printf 'INFO:%s\n' "$*"; }
        print_warning() { printf 'WARN:%s\n' "$*"; }
        print_error() { printf 'ERR:%s\n' "$*"; }
        draw_bar() { printf '[%s%%]' "$1"; }

        cli_top_command "$tmpdir"
    )"

    assert_contains "$output" "Largest Directories" "top command should print the directories section"
    assert_contains "$output" "Largest Files" "top command should print the files section"
    assert_contains "$output" "big-dir" "top command should list the largest directory"
    assert_contains "$output" "top.log" "top command should list the largest file"

    rm -rf -- "$tmpdir"
    trap - RETURN
}

test_cli_top_command_applies_limit_per_section() {
    local tmpdir output
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    mkdir -p "$tmpdir/first-dir" "$tmpdir/second-dir"
    printf '1234567890' > "$tmpdir/first-dir/payload.bin"
    printf '1234' > "$tmpdir/second-dir/payload.bin"
    printf '1234567' > "$tmpdir/first.log"
    printf '12' > "$tmpdir/second.log"

    output="$(
        initialize_runtime() {
            HAS_DU_BYTES=1
            BOLD=""
            CYAN=""
            WHITE=""
            RESET=""
            DIM=""
        }
        get_ui_content_width() { printf '90'; }
        print_separator() { :; }
        print_info() { printf 'INFO:%s\n' "$*"; }
        print_warning() { printf 'WARN:%s\n' "$*"; }
        print_error() { printf 'ERR:%s\n' "$*"; }
        draw_bar() { printf '[%s%%]' "$1"; }

        cli_top_command "$tmpdir" --limit 1
    )"

    assert_contains "$output" "first-dir" "top command should keep the largest directory when limit is 1"
    assert_not_contains "$output" "second-dir" "top command should omit extra directories when limit is 1"
    assert_contains "$output" "first.log" "top command should keep the largest file when limit is 1"
    assert_not_contains "$output" "second.log" "top command should omit extra files when limit is 1"

    rm -rf -- "$tmpdir"
    trap - RETURN
}

test_cli_top_command_fails_for_missing_path() {
    local output
    if output="$(
        initialize_runtime() { :; }
        print_error() { printf 'ERR:%s\n' "$*"; }
        cli_top_command "/tmp/vps-cleaner-missing-path-for-test"
    )"; then
        fail "cli_top_command should fail for a missing path"
    fi

    assert_contains "$output" "Path does not exist" "top command should report a missing path"
}

test_cli_top_command_fails_for_file_path() {
    local tmpfile output
    tmpfile="$(mktemp)"
    trap 'rm -f -- "$tmpfile"' RETURN
    printf 'payload' > "$tmpfile"

    if output="$(
        initialize_runtime() { :; }
        print_error() { printf 'ERR:%s\n' "$*"; }
        cli_top_command "$tmpfile"
    )"; then
        fail "cli_top_command should fail for a file path"
    fi

    assert_contains "$output" "Path is not a directory" "top command should reject file paths"

    rm -f -- "$tmpfile"
    trap - RETURN
}

main() {
    test_cli_top_command_prints_directory_and_file_sections
    test_cli_top_command_applies_limit_per_section
    test_cli_top_command_fails_for_missing_path
    test_cli_top_command_fails_for_file_path
    printf 'PASS: vps-cleaner top command tests\n'
}

main "$@"
