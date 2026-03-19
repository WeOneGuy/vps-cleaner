# --- Option 11: Install/Update ---------------------------------------------

menu_install_update() {
    while true; do
        echo ""
        printf '  %s%s📥 Install/Update vps-cleaner%s\n\n' "$BOLD" "$CYAN" "$RESET"

        local installed="no"
        local installed_version="N/A"
        if [[ -f "$INSTALL_PATH" ]]; then
            installed="yes"
            installed_version="$(extract_script_version_from_file "$INSTALL_PATH" 2>/dev/null || true)"
            [[ -z "$installed_version" ]] && installed_version="unknown"
        fi

        local current_version=""
        current_version="$(get_current_script_version 2>/dev/null || true)"
        [[ -z "$current_version" ]] && current_version="$SCRIPT_VERSION"

        printf '  Installed:       %s\n' "$installed"
        printf '  Current version: %s\n' "$current_version"
        [[ "$installed" == "yes" ]] && printf '  Installed version: %s\n' "$installed_version"
        echo ""

        printf '  1) Install to %s\n' "$INSTALL_PATH"
        printf '  2) Check for updates\n'
        printf '  3) Uninstall\n'
        printf '  4) Install optional dependencies\n'
        printf '  5) Back\n'
        echo ""

        local choice
        read_choice "Enter choice" 5
        choice="$READ_CHOICE_VALUE"

        case "$choice" in
            1) install_self ;;
            2) check_update ;;
            3) uninstall_self ;;
            4) offer_install_optional_deps ;;
            5|"") return ;;
            *) print_error "Invalid choice." ;;
        esac
    done
}

extract_script_version_from_file() {
    local script_path="${1:-}"
    [[ -n "$script_path" && -f "$script_path" ]] || return 1

    local version=""
    version="$(sed -nE 's/^[[:space:]]*readonly[[:space:]]+SCRIPT_VERSION="([^"]+)".*$/\1/p' "$script_path" 2>/dev/null | head -1)"
    is_valid_semver "$version" || return 1
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

read_version_from_file() {
    local version_file="${1:-}"
    [[ -n "$version_file" && -f "$version_file" ]] || return 1

    local version=""
    version="$(head -n 1 "$version_file" 2>/dev/null | tr -d '\r' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    is_valid_semver "$version" || return 1
    printf '%s' "$version"
}

is_valid_semver() {
    local version="${1:-}"
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ ]] || return 1

    local prerelease=""
    if [[ "$version" == *-* ]]; then
        prerelease="${version#*-}"
        prerelease="${prerelease%%+*}"
    fi

    if [[ -n "$prerelease" ]]; then
        local identifier
        local -a identifiers=()
        IFS='.' read -r -a identifiers <<< "$prerelease"
        for identifier in "${identifiers[@]}"; do
            [[ -n "$identifier" ]] || return 1
            if [[ "$identifier" =~ ^[0-9]+$ ]] && [[ "$identifier" =~ ^0[0-9]+$ ]]; then
                return 1
            fi
        done
    fi

    return 0
}

compare_semver_identifiers() {
    local left="${1:-}" right="${2:-}"

    local left_is_numeric=0
    local right_is_numeric=0
    [[ "$left" =~ ^[0-9]+$ ]] && left_is_numeric=1
    [[ "$right" =~ ^[0-9]+$ ]] && right_is_numeric=1

    if (( left_is_numeric == 1 && right_is_numeric == 1 )); then
        if (( 10#$left < 10#$right )); then
            printf '%s' "-1"
        elif (( 10#$left > 10#$right )); then
            printf '%s' "1"
        else
            printf '%s' "0"
        fi
        return 0
    fi

    if (( left_is_numeric == 1 && right_is_numeric == 0 )); then
        printf '%s' "-1"
        return 0
    fi

    if (( left_is_numeric == 0 && right_is_numeric == 1 )); then
        printf '%s' "1"
        return 0
    fi

    if [[ "$left" < "$right" ]]; then
        printf '%s' "-1"
    elif [[ "$left" > "$right" ]]; then
        printf '%s' "1"
    else
        printf '%s' "0"
    fi
}

compare_semver() {
    local left="${1:-}" right="${2:-}"
    is_valid_semver "$left" || return 1
    is_valid_semver "$right" || return 1

    local left_no_build="${left%%+*}"
    local right_no_build="${right%%+*}"
    local left_core="${left_no_build%%-*}"
    local right_core="${right_no_build%%-*}"
    local left_pre="" right_pre=""

    [[ "$left_no_build" == *-* ]] && left_pre="${left_no_build#*-}"
    [[ "$right_no_build" == *-* ]] && right_pre="${right_no_build#*-}"

    local left_major left_minor left_patch
    local right_major right_minor right_patch
    IFS='.' read -r left_major left_minor left_patch <<< "$left_core"
    IFS='.' read -r right_major right_minor right_patch <<< "$right_core"

    if (( 10#$left_major < 10#$right_major )); then
        printf '%s' "-1"
        return 0
    fi
    if (( 10#$left_major > 10#$right_major )); then
        printf '%s' "1"
        return 0
    fi
    if (( 10#$left_minor < 10#$right_minor )); then
        printf '%s' "-1"
        return 0
    fi
    if (( 10#$left_minor > 10#$right_minor )); then
        printf '%s' "1"
        return 0
    fi
    if (( 10#$left_patch < 10#$right_patch )); then
        printf '%s' "-1"
        return 0
    fi
    if (( 10#$left_patch > 10#$right_patch )); then
        printf '%s' "1"
        return 0
    fi

    if [[ -z "$left_pre" && -z "$right_pre" ]]; then
        printf '%s' "0"
        return 0
    fi
    if [[ -z "$left_pre" ]]; then
        printf '%s' "1"
        return 0
    fi
    if [[ -z "$right_pre" ]]; then
        printf '%s' "-1"
        return 0
    fi

    local -a left_ids=() right_ids=()
    IFS='.' read -r -a left_ids <<< "$left_pre"
    IFS='.' read -r -a right_ids <<< "$right_pre"

    local max_len="${#left_ids[@]}"
    if (( ${#right_ids[@]} > max_len )); then
        max_len="${#right_ids[@]}"
    fi

    local i cmp
    for (( i=0; i<max_len; i++ )); do
        if (( i >= ${#left_ids[@]} )); then
            printf '%s' "-1"
            return 0
        fi
        if (( i >= ${#right_ids[@]} )); then
            printf '%s' "1"
            return 0
        fi

        cmp="$(compare_semver_identifiers "${left_ids[$i]}" "${right_ids[$i]}")" || return 1
        if [[ "$cmp" != "0" ]]; then
            printf '%s' "$cmp"
            return 0
        fi
    done

    printf '%s' "0"
}

is_remote_version_newer() {
    local current_version="${1:-}" remote_version="${2:-}"
    local cmp=""
    cmp="$(compare_semver "$current_version" "$remote_version" 2>/dev/null)" || return 1
    [[ "$cmp" == "-1" ]]
}

get_current_script_version() {
    local script_dir version=""
    script_dir="$(dirname "$SELF_PATH")"

    version="$(read_version_from_file "${script_dir}/VERSION" 2>/dev/null || true)"
    if [[ -n "$version" ]]; then
        printf '%s' "$version"
        return 0
    fi

    version="$(extract_script_version_from_file "$SELF_PATH" 2>/dev/null || true)"
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

stamp_script_version_in_file() {
    local script_path="${1:-}" target_version="${2:-}"
    [[ -n "$script_path" && -f "$script_path" ]] || return 1
    is_valid_semver "$target_version" || return 1

    local tmp_file=""
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-version-stamp.XXXXXX")" || return 1

    if ! awk -v version="$target_version" '
        BEGIN { replaced=0 }
        /^[[:space:]]*readonly[[:space:]]+SCRIPT_VERSION="[^"]*".*$/ {
            if (replaced == 0) {
                print "readonly SCRIPT_VERSION=\"" version "\""
                replaced=1
                next
            }
        }
        { print }
        END { if (replaced == 0) exit 1 }
    ' "$script_path" > "$tmp_file"; then
        rm -f -- "$tmp_file" 2>/dev/null || true
        return 1
    fi

    if ! cat -- "$tmp_file" > "$script_path" 2>/dev/null; then
        rm -f -- "$tmp_file" 2>/dev/null || true
        return 1
    fi

    rm -f -- "$tmp_file" 2>/dev/null || true
}

fetch_remote_version() {
    local timeout_sec="${1:-10}"
    local remote_version=""

    if [[ "$HAS_CURL" -eq 1 ]]; then
        remote_version="$(curl -fsSL --max-time "$timeout_sec" "$SCRIPT_VERSION_URL" 2>/dev/null || true)"
    elif [[ "$HAS_WGET" -eq 1 ]]; then
        remote_version="$(wget -qO- --timeout="$timeout_sec" "$SCRIPT_VERSION_URL" 2>/dev/null || true)"
    fi

    remote_version="$(printf '%s' "$remote_version" | tr -d '\r' \
        | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    is_valid_semver "$remote_version" || return 1
    printf '%s' "$remote_version"
}

download_remote_script() {
    local output_path="${1:-}"
    local timeout_sec="${2:-30}"
    [[ -n "$output_path" ]] || return 1

    if [[ "$HAS_CURL" -eq 1 ]]; then
        curl -fsSL --max-time "$timeout_sec" "$SCRIPT_RAW_URL" -o "$output_path" 2>/dev/null || return 1
    elif [[ "$HAS_WGET" -eq 1 ]]; then
        wget -qO "$output_path" --timeout="$timeout_sec" "$SCRIPT_RAW_URL" 2>/dev/null || return 1
    else
        return 1
    fi

    [[ -s "$output_path" ]] || return 1
}

validate_downloaded_script() {
    local script_path="${1:-}"
    local expected_version="${2:-}"
    [[ -n "$script_path" && -s "$script_path" ]] || return 1

    if ! head -c 2 "$script_path" 2>/dev/null | grep -q '^#!'; then
        return 1
    fi

    local downloaded_version=""
    downloaded_version="$(extract_script_version_from_file "$script_path" 2>/dev/null || true)"
    [[ -n "$downloaded_version" ]] || return 1

    if [[ -n "$expected_version" ]] && [[ "$downloaded_version" != "$expected_version" ]]; then
        return 1
    fi
}

prepare_remote_update_script() {
    local output_path="${1:-}"
    local expected_version="${2:-}"
    local timeout_sec="${3:-30}"
    [[ -n "$output_path" ]] || return 1

    download_remote_script "$output_path" "$timeout_sec" || return 1
    stamp_script_version_in_file "$output_path" "$expected_version" || return 1
    validate_downloaded_script "$output_path" "$expected_version" || return 1
}

calculate_file_fingerprint() {
    local file_path="${1:-}"
    [[ -n "$file_path" && -f "$file_path" ]] || return 1

    if command -v sha256sum &>/dev/null; then
        tr -d '\r' < "$file_path" | sha256sum | awk '{print $1}'
        return 0
    fi

    if command -v shasum &>/dev/null; then
        tr -d '\r' < "$file_path" | shasum -a 256 | awk '{print $1}'
        return 0
    fi

    if command -v openssl &>/dev/null; then
        tr -d '\r' < "$file_path" | openssl dgst -sha256 -r | awk '{print $1}'
        return 0
    fi

    command -v cksum &>/dev/null || return 1
    tr -d '\r' < "$file_path" | cksum | awk '{print $1 ":" $2}'
}

are_script_contents_different() {
    local left_path="${1:-}"
    local right_path="${2:-}"
    [[ -n "$left_path" && -f "$left_path" ]] || return 2
    [[ -n "$right_path" && -f "$right_path" ]] || return 2

    local left_fingerprint=""
    local right_fingerprint=""

    left_fingerprint="$(calculate_file_fingerprint "$left_path")" || return 2
    right_fingerprint="$(calculate_file_fingerprint "$right_path")" || return 2

    if [[ "$left_fingerprint" != "$right_fingerprint" ]]; then
        return 0
    fi

    return 1
}

