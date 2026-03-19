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

test_main_defaults_to_menu_command() {
    local output
    output="$(
        setup_colors() { :; }
        dispatch_cli_command() { printf 'command:%s\n' "$1"; }
        main
    )"

    assert_contains "$output" "command:menu" "main without arguments should dispatch to menu"
}

test_help_lists_supported_commands() {
    local output
    output="$(
        setup_colors() {
            BOLD=""
            CYAN=""
            RESET=""
        }
        main --help
    )"

    assert_contains "$output" "Commands:" "help should show the commands section"
    assert_contains "$output" "menu" "help should list the menu command"
    assert_contains "$output" "top [PATH]" "help should list the top command"
}

test_unknown_command_fails() {
    if (
        setup_colors() { :; }
        print_error() { printf 'ERR:%s\n' "$*"; }
        print_cli_help() { printf 'HELP\n'; }
        dispatch_cli_command "unknown-command" >/dev/null
    ); then
        fail "dispatch_cli_command should fail for an unknown command"
    fi
}

main() {
    test_main_defaults_to_menu_command
    test_help_lists_supported_commands
    test_unknown_command_fails
    printf 'PASS: vps-cleaner CLI dispatcher tests\n'
}

main "$@"
