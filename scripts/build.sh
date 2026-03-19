#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="$REPO_ROOT/vps-cleaner.sh"
TEMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/vps-cleaner-build.XXXXXX")"

cleanup() {
    rm -f -- "$TEMP_OUTPUT"
}
trap cleanup EXIT

sources=(
    "$REPO_ROOT/src/00_base.sh"
    "$REPO_ROOT/src/01_ui.sh"
    "$REPO_ROOT/src/02_scan_helpers.sh"
    "$REPO_ROOT/src/10_system.sh"
    "$REPO_ROOT/src/11_safety.sh"
    "$REPO_ROOT/src/15_cli.sh"
    "$REPO_ROOT/src/16_top_command.sh"
    "$REPO_ROOT/src/20_disk_overview.sh"
    "$REPO_ROOT/src/21_quick_clean.sh"
    "$REPO_ROOT/src/22_logs.sh"
    "$REPO_ROOT/src/23_packages.sh"
    "$REPO_ROOT/src/24_cache.sh"
    "$REPO_ROOT/src/25_docker.sh"
    "$REPO_ROOT/src/26_snap_large_full.sh"
    "$REPO_ROOT/src/27_settings.sh"
    "$REPO_ROOT/src/28_update_versioning.sh"
    "$REPO_ROOT/src/29_update_install.sh"
    "$REPO_ROOT/src/30_entrypoint.sh"
)

for source_file in "${sources[@]}"; do
    [[ -f "$source_file" ]] || {
        printf 'Missing source file: %s\n' "$source_file" >&2
        exit 1
    }

    cat "$source_file" >> "$TEMP_OUTPUT"
    printf '\n' >> "$TEMP_OUTPUT"
done

chmod +x "$TEMP_OUTPUT"
mv -f -- "$TEMP_OUTPUT" "$OUTPUT_PATH"
