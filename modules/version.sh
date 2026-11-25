# shellcheck shell=bash
# =============================================================================
# Version Module - Shows Cortado version briefly on startup
# =============================================================================
# The display window starts when Cortado first sees a session ID.
#
# Configuration options:
#   VERSION_SHOW_DURATION   - Seconds to show version for a new session (default: 120)
#   VERSION_ICON            - Icon to display (default: coffee emoji)
# =============================================================================

module_version() {
    # run_module currently keeps the payload in its local input_json and
    # dispatches version without an argument. Bash exposes that caller local.
    local payload="${1:-${input_json:-}}"
    local session_key
    session_key=$(printf '%s' "$payload" | jq -r '
        .session_id | strings | select(length > 0) | @base64
        | select(length <= 200) | gsub("/"; "_") | gsub("[+]"; "-")
    ' 2>/dev/null)
    [ -n "$session_key" ] || return 0

    local show_duration="${VERSION_SHOW_DURATION:-120}"
    case "$show_duration" in
        *[!0-9]*) show_duration=120 ;;
    esac
    [ "$show_duration" -ge 0 ] 2>/dev/null || show_duration=120

    local now session_start
    now=$(date +%s)
    local cache_key="version_session_${session_key}"
    # Keep the first-seen time after the badge expires, including when
    # multiple Claude Code sessions render against the same config directory.
    session_start=$(cache_get "$cache_key" 2147483647)
    case "$session_start" in
        ''|*[!0-9]*|0*)
            session_start="$now"
            cache_set "$cache_key" "$session_start" || return 0
            ;;
    esac

    local elapsed=$((now - session_start))
    [ "$elapsed" -lt "$show_duration" ] || return 0

    local version=""
    local version_file="$SCRIPT_DIR/VERSION"
    if [ -f "$version_file" ]; then
        version=$(cat "$version_file" 2>/dev/null | tr -d '[:space:]')
    fi

    if [ -z "$version" ]; then
        return
    fi

    local icon
    icon=$(get_icon "${VERSION_ICON:-☕}" "Cortado")
    echo "${icon} v${version}"
}
