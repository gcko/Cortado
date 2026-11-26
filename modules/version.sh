# shellcheck shell=bash
# @cortado-module version
# @default true
# @args payload
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu core 2
# @description Cortado version (brief)
# @config VERSION_ICON:string
# @config VERSION_SHOW_DURATION:bool
# =============================================================================
# Version Module - Shows Cortado version briefly on startup
# =============================================================================
# The display window starts when Cortado first sees a session ID. A payload
# without an ID hides the notice.
#
# Configuration options:
#   VERSION_SHOW_DURATION   - Seconds to show version for a new session (default: 120)
#   VERSION_ICON            - Icon to display (default: coffee emoji)
# =============================================================================

_version_session_start() (
    local session_id="$1" now="$2"
    local cache_key=version_sessions
    umask 077
    init_cache || return 1

    # Lock the read and publish together. The lock file stays in place so
    # later renders wait on the same inode even after the cache is replaced.
    exec 9>>"$CACHE_DIR/$cache_key-lock" || return 1
    if command -v flock >/dev/null 2>&1; then
        flock -w 5 9
    else
        # macOS can lock the inherited descriptor with its bundled Perl.
        perl -MFcntl=:flock -e 'open(my $lock, ">&=9") or exit 1; alarm 5; exit(!flock($lock, LOCK_EX))'
    fi || return 1

    local sessions updated session_start
    sessions=$(cache_get "$cache_key" 2147483647)
    # Move the current ID to the front without changing its first-seen time.
    updated=$(jq -Rsc --arg id "$session_id" --argjson now "$now" '
        (try fromjson catch [])
        | if type == "array" then map(objects) else [] end
        | ([.[] | select(.id == $id)][0] // {id: $id, first_seen: $now}) as $session
        | ([$session] + [.[] | select(.id != $id)])[:32]
        | .[0].first_seen, .
    ' <<< "$sessions") || return 1
    session_start="${updated%%$'\n'*}"
    updated="${updated#*$'\n'}"
    [ "$sessions" = "$updated" ] || cache_set "$cache_key" "$updated" || return 1
    printf '%s\n' "$session_start"
) 2>/dev/null

module_version() {
    local show_duration="${VERSION_SHOW_DURATION:-120}"
    case "$show_duration" in
        *[!0-9]*) show_duration=120 ;;
    esac
    [ "$show_duration" -ge 0 ] 2>/dev/null || show_duration=120
    [ "$show_duration" -gt 0 ] || return 0

    if [ "${CTX_READY:-}" != true ]; then
        with_payload_context module_version <<< "${1:-}"
        return
    fi
    local session_id="${CTX_SESSION_ID:-}"
    [ -n "$session_id" ] || return 0

    local now session_start
    now=$(date +%s)
    [[ "$now" =~ ^[1-9][0-9]*$ ]] || return 0
    session_start=$(_version_session_start "$session_id" "$now") || return 0
    [[ "$session_start" =~ ^[1-9][0-9]*$ ]] || return 0

    local elapsed=$((now - session_start))
    [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$show_duration" ] || return 0

    local version=""
    local version_file="$SCRIPT_DIR/VERSION"
    if [ -f "$version_file" ]; then
        version=$(cat "$version_file" 2>/dev/null | tr -d '[:space:]')
    fi

    if [ -z "$version" ]; then
        return
    fi

    local icon
    get_icon_reply "${VERSION_ICON:-☕}" "Cortado"; icon=$REPLY
    echo "${icon} v${version}"
}
