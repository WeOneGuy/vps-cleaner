# ============================================================================
# CLI HELPERS
# ============================================================================

print_cli_command_row() {
    local command_label="${1:-}"
    local description="${2:-}"
    local label_width="${3:-18}"
    printf '  %-*s %s\n' "$label_width" "$command_label" "$description"
}

print_cli_help() {
    local current_version=""
    current_version="$(get_current_script_version 2>/dev/null || true)"
    [[ -z "$current_version" ]] && current_version="$SCRIPT_VERSION"

    echo ""
    printf '  %s%s%s CLI%s\n\n' "$BOLD" "$CYAN" "$SCRIPT_NAME" "$RESET"
    printf '  Version: %s\n' "$current_version"
    printf '  Usage:   %s [command] [options]\n' "$SCRIPT_NAME"
    echo ""

    printf '  %sCommands:%s\n' "$BOLD" "$RESET"
    print_cli_command_row "menu" "Launch the interactive cleanup menu"
    print_cli_command_row "top [PATH]" "Show the largest direct subdirectories and files"
    print_cli_command_row "--help" "Show CLI help"
    print_cli_command_row "help" "Show CLI help"
    echo ""

    printf '  %sExamples:%s\n' "$BOLD" "$RESET"
    print_cli_command_row "$SCRIPT_NAME" "Open the interactive menu"
    print_cli_command_row "$SCRIPT_NAME menu" "Explicitly open the interactive menu"
    print_cli_command_row "$SCRIPT_NAME top" "Inspect the current directory"
    print_cli_command_row "$SCRIPT_NAME top /var --limit 15" "Inspect /var with a custom row limit"
    print_cli_command_row "curl ... | bash -s -- top /var" "Run the one-time launcher with CLI args"
    echo ""
}

print_top_help() {
    echo ""
    printf '  %s%s%s top%s\n\n' "$BOLD" "$CYAN" "$SCRIPT_NAME" "$RESET"
    printf '  Usage: %s top [PATH] [--limit N]\n' "$SCRIPT_NAME"
    printf '  PATH defaults to the current directory.\n'
    printf '  The command prints separate tables for direct subdirectories and files.\n'
    echo ""
}
