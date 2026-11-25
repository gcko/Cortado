# shellcheck shell=bash
# =============================================================================
# Directory Module - Shows current working directory
# =============================================================================
# Configuration options:
#   DIRECTORY_ICON          - Icon before directory name (default: 📁)
#   DIRECTORY_STYLE         - "icon", "text", "both" (default: icon)
#   DIRECTORY_SHOW_FULL_PATH - Show full path instead of basename (default: false)
#   DIRECTORY_MAX_LENGTH    - Max length before truncation (default: 20, 0=no limit)
# =============================================================================

module_directory() {
    local current_dir="$1"
    local icon=$(get_icon "${DIRECTORY_ICON:-📁}" "DIR:")
    local style="${DIRECTORY_STYLE:-icon}"
    local show_full="${DIRECTORY_SHOW_FULL_PATH:-false}"
    local max_len="${DIRECTORY_MAX_LENGTH:-20}"

    # Get directory name
    local dir_name
    if [ "$show_full" = "true" ]; then
        dir_name="$current_dir"
    elif [ -n "$current_dir" ]; then
        case "$current_dir" in
            -*) current_dir="./$current_dir" ;;
        esac
        dir_name=$(basename "$current_dir" 2>/dev/null) || dir_name=""
    fi

    # Truncate if needed
    dir_name="${dir_name:-}"
    if [ -n "$dir_name" ]; then
        dir_name=$(truncate_string "$dir_name" "$max_len")
    else
        dir_name="--"
    fi

    # Format output based on style
    case "$style" in
        text)
            echo "Dir: $dir_name"
            ;;
        both)
            echo "$icon Dir: $dir_name"
            ;;
        *)  # icon (default)
            echo "$icon $dir_name"
            ;;
    esac
}
