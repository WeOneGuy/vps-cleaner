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

test_is_valid_semver_accepts_cases() {
    local version
    for version in \
        "0.0.0" \
        "1.2.3" \
        "1.0.0-alpha" \
        "1.0.0-alpha.1" \
        "2.3.4-rc.1+build.5" \
        "10.20.30+meta"; do
        assert_success "accepts valid semver: $version" is_valid_semver "$version"
    done
}

test_is_valid_semver_rejects_cases() {
    local version
    for version in \
        "" \
        "v1.2.3" \
        "1.2" \
        "01.2.3" \
        "1.02.3" \
        "1.2.03" \
        "1.2.3-" \
        "1.2.3-alpha..1" \
        "1.2.3-01" \
        "1.2.3+"; do
        assert_failure "rejects invalid semver: $version" is_valid_semver "$version"
    done
}

test_compare_semver_core() {
    assert_eq "$(compare_semver "1.2.3" "1.2.4")" "-1" "patch version ordering"
    assert_eq "$(compare_semver "1.2.3" "1.3.0")" "-1" "minor version ordering"
    assert_eq "$(compare_semver "1.2.3" "2.0.0")" "-1" "major version ordering"
    assert_eq "$(compare_semver "2.1.0" "1.9.9")" "1" "higher major is newer"
    assert_eq "$(compare_semver "1.2.3" "1.2.3")" "0" "equal versions compare as equal"
}

test_compare_semver_prerelease_ordering() {
    assert_eq "$(compare_semver "1.2.3-rc.1" "1.2.3")" "-1" "stable outranks prerelease"
    assert_eq "$(compare_semver "1.2.3-alpha" "1.2.3-beta")" "-1" "alpha lower than beta"
    assert_eq "$(compare_semver "1.2.3-beta.2" "1.2.3-beta.11")" "-1" "numeric prerelease ordering"
    assert_eq "$(compare_semver "1.2.3-beta.11" "1.2.3-beta.2")" "1" "numeric prerelease reverse ordering"
    assert_eq "$(compare_semver "1.2.3-alpha.1" "1.2.3-alpha.1")" "0" "equal prerelease versions"
}

test_compare_semver_ignores_build_metadata() {
    assert_eq "$(compare_semver "1.2.3+build.1" "1.2.3+build.2")" "0" "build metadata does not affect precedence"
    assert_eq "$(compare_semver "1.2.3-rc.1+exp.sha" "1.2.3-rc.1+meta")" "0" "build metadata ignored for prerelease"
}

test_is_remote_version_newer() {
    assert_success "remote higher patch is newer" is_remote_version_newer "1.2.3" "1.2.4"
    assert_success "remote stable newer than local prerelease" is_remote_version_newer "1.2.3-rc.1" "1.2.3"
    assert_failure "remote equal is not newer" is_remote_version_newer "1.2.3" "1.2.3"
    assert_failure "remote lower is not newer" is_remote_version_newer "1.2.3" "1.2.2"
    assert_failure "invalid version inputs fail" is_remote_version_newer "1.2" "1.2.3"
}

main() {
    test_is_valid_semver_accepts_cases
    test_is_valid_semver_rejects_cases
    test_compare_semver_core
    test_compare_semver_prerelease_ordering
    test_compare_semver_ignores_build_metadata
    test_is_remote_version_newer
    printf 'PASS: vps-cleaner versioning tests\n'
}

main "$@"
