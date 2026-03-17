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
    local current_value="$1"
    local remote_value="$2"
    local confirm_log="$3"
    local local_script_content="$4"
    local remote_script_content="$5"
    local remote_prepare_status="${6:-0}"

    (
        HAS_CURL=1
        HAS_WGET=0
        LAST_UPDATE_CHECK=0

        get_current_script_version() { printf '%s' "$current_value"; }
        fetch_remote_version() { printf '%s' "$remote_value"; }
        prepare_remote_update_script() {
            local output_path="${1:-}"
            if [[ "$remote_prepare_status" != "0" ]]; then
                return "$remote_prepare_status"
            fi
            printf '%s' "$remote_script_content" > "$output_path"
        }
        are_script_contents_different() {
            if [[ "$local_script_content" == "$remote_script_content" ]]; then
                return 1
            fi
            return 0
        }
        save_config() { :; }
        confirm() {
            printf 'confirm-called\n' >> "$confirm_log"
            return 1
        }
        print_warning() { printf 'WARN:%s\n' "$1"; }
        print_info() { printf 'INFO:%s\n' "$1"; }
        print_success() { printf 'OK:%s\n' "$1"; }
        print_error() { printf 'ERR:%s\n' "$1"; }

        check_update
    )
}

run_auto_update_check_case() {
    local current_value="$1"
    local remote_value="$2"
    local local_script_content="$3"
    local remote_script_content="$4"
    local remote_prepare_status="${5:-0}"

    (
        HAS_CURL=1
        HAS_WGET=0
        LAST_UPDATE_CHECK=0

        installed_script_exists() { return 0; }
        get_current_script_version() { printf '%s' "$current_value"; }
        fetch_remote_version() { printf '%s' "$remote_value"; }
        prepare_remote_update_script() {
            local output_path="${1:-}"
            if [[ "$remote_prepare_status" != "0" ]]; then
                return "$remote_prepare_status"
            fi
            printf '%s' "$remote_script_content" > "$output_path"
        }
        are_script_contents_different() {
            if [[ "$local_script_content" == "$remote_script_content" ]]; then
                return 1
            fi
            return 0
        }
        save_config() { :; }
        print_info() { printf 'INFO:%s\n' "$1"; }

        auto_update_check
    )
}

test_check_update_offers_when_remote_newer() {
    local confirm_log output local_script remote_script
    confirm_log="$(mktemp)"
    trap 'rm -f -- "$confirm_log"' RETURN

    local_script=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\n'
    remote_script=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.1"\n'
    output="$(run_check_update_case "1.0.0" "1.0.1" "$confirm_log" "$local_script" "$remote_script")"

    assert_contains "$output" "A newer version (1.0.1) is available." "offers update when remote version is newer"
    assert_contains "$(cat "$confirm_log")" "confirm-called" "calls confirm for newer remote version"

    rm -f -- "$confirm_log"
    trap - RETURN
}

test_check_update_handles_same_version_build_difference() {
    local confirm_log output local_script remote_script
    confirm_log="$(mktemp)"
    trap 'rm -f -- "$confirm_log"' RETURN

    local_script=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\necho local\n'
    remote_script=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\necho remote\n'
    output="$(run_check_update_case "1.0.0" "1.0.0" "$confirm_log" "$local_script" "$remote_script")"

    assert_contains "$output" "A newer build of version 1.0.0 is available." "offers update when same version has different script content"
    assert_contains "$(cat "$confirm_log")" "confirm-called" "calls confirm when a newer build with the same version is detected"

    rm -f -- "$confirm_log"
    trap - RETURN
}

test_check_update_does_not_offer_when_remote_equal_and_same() {
    local confirm_log output script_content
    confirm_log="$(mktemp)"
    trap 'rm -f -- "$confirm_log"' RETURN

    script_content=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\necho same\n'
    output="$(run_check_update_case "1.0.0" "1.0.0" "$confirm_log" "$script_content" "$script_content")"

    assert_contains "$output" "Already on the latest version." "reports latest when version and content are equal"
    assert_not_contains "$(cat "$confirm_log")" "confirm-called" "does not call confirm when scripts are identical"

    rm -f -- "$confirm_log"
    trap - RETURN
}

test_check_update_warns_when_same_version_cannot_be_verified() {
    local confirm_log output script_content
    confirm_log="$(mktemp)"
    trap 'rm -f -- "$confirm_log"' RETURN

    script_content=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\necho same\n'
    output="$(run_check_update_case "1.0.0" "1.0.0" "$confirm_log" "$script_content" "" "1")"

    assert_contains "$output" "Remote version matches current, but remote script contents could not be verified." "warns when equal-version build comparison fails"
    assert_not_contains "$(cat "$confirm_log")" "confirm-called" "does not call confirm when equal-version verification fails"

    rm -f -- "$confirm_log"
    trap - RETURN
}

test_check_update_does_not_offer_when_remote_older() {
    local confirm_log output local_script remote_script
    confirm_log="$(mktemp)"
    trap 'rm -f -- "$confirm_log"' RETURN

    local_script=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\n'
    remote_script=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="0.9.9"\n'
    output="$(run_check_update_case "1.0.0" "0.9.9" "$confirm_log" "$local_script" "$remote_script")"

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
            print_error() { printf 'ERR:%s\n' "$1"; }

            check_update
        )
    )"

    assert_contains "$output" "Could not fetch remote version." "warns when remote version cannot be fetched"
    assert_not_contains "$(cat "$confirm_log")" "confirm-called" "does not call confirm on fetch failure"

    rm -f -- "$confirm_log"
    trap - RETURN
}

test_auto_update_check_announces_same_version_new_build() {
    local output local_script remote_script
    local_script=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\necho local\n'
    remote_script=$'#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\necho remote\n'
    output="$(run_auto_update_check_case "1.0.0" "1.0.0" "$local_script" "$remote_script")"

    assert_contains "$output" "Update available: newer build of v1.0.0 detected." "auto update check should announce a newer build when same-version content differs"
}

main() {
    test_check_update_offers_when_remote_newer
    test_check_update_handles_same_version_build_difference
    test_check_update_does_not_offer_when_remote_equal_and_same
    test_check_update_warns_when_same_version_cannot_be_verified
    test_check_update_does_not_offer_when_remote_older
    test_check_update_handles_remote_fetch_failure
    test_auto_update_check_announces_same_version_new_build
    printf 'PASS: vps-cleaner update flow tests\n'
}

main "$@"
