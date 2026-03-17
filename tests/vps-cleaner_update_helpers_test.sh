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

test_extract_script_version_from_file() {
    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f -- "$tmpfile"' RETURN

    cat > "$tmpfile" <<'EOF'
#!/usr/bin/env bash
readonly SCRIPT_VERSION="9.8.7"
EOF

    assert_eq "$(extract_script_version_from_file "$tmpfile")" "9.8.7" "extracts script version from file"

    rm -f -- "$tmpfile"
    trap - RETURN
}

test_extract_script_version_from_file_failure() {
    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f -- "$tmpfile"' RETURN

    printf '#!/usr/bin/env bash\nno version here\n' > "$tmpfile"
    assert_failure "fails when version is missing" extract_script_version_from_file "$tmpfile"

    rm -f -- "$tmpfile"
    trap - RETURN
}

test_validate_downloaded_script() {
    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f -- "$tmpfile"' RETURN

    cat > "$tmpfile" <<'EOF'
#!/usr/bin/env bash
readonly SCRIPT_VERSION="1.2.3"
EOF

    assert_success "valid script passes validation" validate_downloaded_script "$tmpfile" "1.2.3"
    assert_failure "version mismatch fails validation" validate_downloaded_script "$tmpfile" "2.0.0"

    printf 'readonly SCRIPT_VERSION="1.2.3"\n' > "$tmpfile"
    assert_failure "missing shebang fails validation" validate_downloaded_script "$tmpfile" "1.2.3"

    rm -f -- "$tmpfile"
    trap - RETURN
}

test_fetch_remote_version_with_curl_stub() {
    local out
    out="$({
        HAS_CURL=1
        HAS_WGET=0
        curl() {
            printf '5.4.3\n'
        }
        fetch_remote_version 1
    })"

    assert_eq "$out" "5.4.3" "fetch_remote_version reads semver from VERSION file content"
}

test_fetch_remote_version_failure_on_invalid_response() {
    if ({
        HAS_CURL=1
        HAS_WGET=0
        curl() {
            printf 'invalid content\n'
        }
        fetch_remote_version 1 >/dev/null
    }); then
        printf 'FAIL: fetch_remote_version should fail on invalid response\n' >&2
        exit 1
    fi
}

test_download_remote_script_with_curl_stub() {
    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f -- "$tmpfile"' RETURN

    ({
        HAS_CURL=1
        HAS_WGET=0
        curl() {
            local out=""
            while (( $# > 0 )); do
                case "$1" in
                    -o)
                        out="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            [[ -n "$out" ]] || return 1
            printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="7.7.7"\n' > "$out"
        }
        download_remote_script "$tmpfile" 1
    })

    [[ -s "$tmpfile" ]] || {
        printf 'FAIL: downloaded script should not be empty\n' >&2
        exit 1
    }

    rm -f -- "$tmpfile"
    trap - RETURN
}

test_stamp_script_version_in_file() {
    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f -- "$tmpfile"' RETURN

    cat > "$tmpfile" <<'EOF'
#!/usr/bin/env bash
readonly SCRIPT_VERSION="1.0.0"
EOF

    assert_success "stamps script version" stamp_script_version_in_file "$tmpfile" "2.3.4-rc.1+build.7"
    assert_eq "$(extract_script_version_from_file "$tmpfile")" "2.3.4-rc.1+build.7" "extracts stamped version"
    assert_failure "rejects invalid semver for stamp" stamp_script_version_in_file "$tmpfile" "invalid"

    rm -f -- "$tmpfile"
    trap - RETURN
}

test_calculate_file_fingerprint_ignores_line_endings() {
    local tmpdir lf crlf
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    lf="$tmpdir/lf.sh"
    crlf="$tmpdir/crlf.sh"

    printf '#!/usr/bin/env bash\necho same\n' > "$lf"
    printf '#!/usr/bin/env bash\r\necho same\r\n' > "$crlf"

    assert_eq "$(calculate_file_fingerprint "$lf")" "$(calculate_file_fingerprint "$crlf")" "fingerprint ignores line-ending differences"

    rm -rf -- "$tmpdir"
    trap - RETURN
}

test_are_script_contents_different() {
    local tmpdir left same different
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    left="$tmpdir/left.sh"
    same="$tmpdir/same.sh"
    different="$tmpdir/different.sh"

    printf '#!/usr/bin/env bash\necho same\n' > "$left"
    printf '#!/usr/bin/env bash\r\necho same\r\n' > "$same"
    printf '#!/usr/bin/env bash\necho different\n' > "$different"

    assert_failure "normalized identical scripts are not different" are_script_contents_different "$left" "$same"
    assert_success "different scripts compare as different" are_script_contents_different "$left" "$different"

    rm -rf -- "$tmpdir"
    trap - RETURN
}

test_prepare_remote_update_script() {
    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f -- "$tmpfile"' RETURN

    assert_success "downloads, stamps, and validates remote update script" bash -lc '
        set -euo pipefail
        source "$1"
        download_remote_script() {
            local output_path="${1:-}"
            printf "#!/usr/bin/env bash\nreadonly SCRIPT_VERSION=\"0.0.1\"\n" > "$output_path"
        }
        prepare_remote_update_script "$2" "4.5.6" 1
    ' _ "$REPO_ROOT/vps-cleaner.sh" "$tmpfile"

    assert_eq "$(extract_script_version_from_file "$tmpfile")" "4.5.6" "prepared update script is stamped with expected version"

    assert_failure "rejects invalid prepared update script" bash -lc '
        set -euo pipefail
        source "$1"
        download_remote_script() {
            local output_path="${1:-}"
            printf "broken\n" > "$output_path"
        }
        prepare_remote_update_script "$2" "9.9.9" 1
    ' _ "$REPO_ROOT/vps-cleaner.sh" "$tmpfile"

    rm -f -- "$tmpfile"
    trap - RETURN
}

test_install_script_atomically() {
    local tmpdir source target
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN

    source="$tmpdir/source.sh"
    target="$tmpdir/target.sh"

    printf '#!/usr/bin/env bash\necho old\n' > "$target"
    chmod 0644 "$target"

    printf '#!/usr/bin/env bash\necho new\n' > "$source"
    chmod 0600 "$source"

    assert_success "installs source atomically to target" install_script_atomically "$source" "$target"
    assert_eq "$(cat "$target")" $'#!/usr/bin/env bash\necho new' "target content replaced"

    if [[ ! -x "$target" ]]; then
        printf 'FAIL: target should be executable after atomic install\n' >&2
        exit 1
    fi

    rm -rf -- "$tmpdir"
    trap - RETURN
}

main() {
    test_extract_script_version_from_file
    test_extract_script_version_from_file_failure
    test_validate_downloaded_script
    test_fetch_remote_version_with_curl_stub
    test_fetch_remote_version_failure_on_invalid_response
    test_download_remote_script_with_curl_stub
    test_stamp_script_version_in_file
    test_install_script_atomically
    test_calculate_file_fingerprint_ignores_line_endings
    test_are_script_contents_different
    test_prepare_remote_update_script
    printf 'PASS: vps-cleaner update helper tests\n'
}

main "$@"
