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
            printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="5.4.3"\n'
        }
        fetch_remote_version 1
    })"

    assert_eq "$out" "5.4.3" "fetch_remote_version parses version from curl output"
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
    test_install_script_atomically
    printf 'PASS: vps-cleaner update helper tests\n'
}

main "$@"