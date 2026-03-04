#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../vps-cleaner.sh
source "$REPO_ROOT/vps-cleaner.sh"

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

run_check_update_case() {
    local current_value="$1" remote_value="$2" confirm_log="$3"
    (
        HAS_CURL=1
        HAS_WGET=0
        LAST_UPDATE_CHECK=0

        get_current_script_version() { printf '%s' "$current_value"; }
        fetch_remote_version() { printf '%s' "$remote_value"; }
        save_config() { :; }
        confirm() {
            printf 'confirm-called\n' >> "$confirm_log"
            return 1
        }
        print_warning() { printf 'WARN:%s\n' "$1"; }
        print_info() { printf 'INFO:%s\n' "$1"; }
        print_success() { printf 'OK:%s\n' "$1"; }

        check_update
    )
}

test_check_update_offers_when_remote_newer() {
    local confirm_log output
    confirm_log="$(mktemp)"
    trap 'rm -f -- "$confirm_log"' RETURN

    output="$(run_check_update_case "1.0.0" "1.0.1" "$confirm_log")"
    assert_contains "$output" "A newer version (1.0.1) is available." "offers update when remote version is newer"
    assert_contains "$(cat "$confirm_log")" "confirm-called" "calls confirm for newer remote version"

    rm -f -- "$confirm_log"
    trap - RETURN
}

test_check_update_does_not_offer_when_remote_equal_or_older() {
    local confirm_log output
    confirm_log="$(mktemp)"
    trap 'rm -f -- "$confirm_log"' RETURN

    output="$(run_check_update_case "1.0.0" "1.0.0" "$confirm_log")"
    assert_contains "$output" "Already on the latest version." "reports latest when versions are equal"
    assert_not_contains "$(cat "$confirm_log")" "confirm-called" "does not call confirm when versions are equal"

    : > "$confirm_log"
    output="$(run_check_update_case "1.0.0" "0.9.9" "$confirm_log")"
    assert_contains "$output" "Current version (1.0.0) is newer than remote (0.9.9)." "does not offer update when remote is older"
    assert_not_contains "$(cat "$confirm_log")" "confirm-called" "does not call confirm when remote is older"

    rm -f -- "$confirm_log"
    trap - RETURN
}

test_check_update_handles_remote_fetch_failure() {
    local confirm_log output
    confirm_log="$(mktemp)"
    trap 'rm -f -- "$confirm_log"' RETURN

    output="$(
        (
            HAS_CURL=1
            HAS_WGET=0
            LAST_UPDATE_CHECK=0

            get_current_script_version() { printf '%s' "1.0.0"; }
            fetch_remote_version() { return 1; }
            save_config() { :; }
            confirm() {
                printf 'confirm-called\n' >> "$confirm_log"
                return 1
            }
            print_warning() { printf 'WARN:%s\n' "$1"; }
            print_info() { printf 'INFO:%s\n' "$1"; }
            print_success() { printf 'OK:%s\n' "$1"; }

            check_update
        )
    )"

    assert_contains "$output" "Could not fetch remote version." "warns when remote version cannot be fetched"
    assert_not_contains "$(cat "$confirm_log")" "confirm-called" "does not call confirm on fetch failure"

    rm -f -- "$confirm_log"
    trap - RETURN
}

main() {
    test_check_update_offers_when_remote_newer
    test_check_update_does_not_offer_when_remote_equal_or_older
    test_check_update_handles_remote_fetch_failure
    printf 'PASS: vps-cleaner update flow tests\n'
}

main "$@"
