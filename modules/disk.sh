# shellcheck shell=bash
# =============================================================================
# Disk Module - Shows disk usage
# =============================================================================
# Configuration options:
#   DISK_ICON              - Icon for disk (default: 💾)
#   DISK_PATH              - Path to check (default: /)
#   DISK_SHOW_PERCENTAGE   - Show percentage (default: true)
#   DISK_SHOW_FREE         - Show free space instead of used (default: false)
#   DISK_WARNING_THRESHOLD - Yellow at % (default: 70)
#   DISK_CRITICAL_THRESHOLD - Red at % (default: 90)
#   DISK_SHOW_STATUS       - Show status indicator (default: true)
# =============================================================================

module_disk() {
    local icon=$(get_icon "${DISK_ICON:-💾}" "DISK:")
    local disk_path="${DISK_PATH:-/}"
    local show_pct="${DISK_SHOW_PERCENTAGE:-true}"
    local show_free="${DISK_SHOW_FREE:-false}"
    local warn_thresh="${DISK_WARNING_THRESHOLD:-70}"
    local crit_thresh="${DISK_CRITICAL_THRESHOLD:-90}"
    local show_status="${DISK_SHOW_STATUS:-true}"

    # Get disk usage. Reject leading-dash paths so untrusted DISK_PATH can't
    # inject df options (e.g. DISK_PATH=-a). Prefer end-of-options on GNU df;
    # BSD df (macOS) ignores -- and still needs the leading-dash guard.
    case "$disk_path" in
        -*) echo "$icon --"; return ;;
    esac
    local df_output
    if ! df_output=$(df -h -- "$disk_path" 2>/dev/null) &&
       ! df_output=$(df -h "$disk_path" 2>/dev/null); then
        echo "$icon --"
        return
    fi

    local free_space capacity used_pct=""
    IFS=' ' read -r free_space capacity <<< "$(printf '%s\n' "$df_output" | awk 'NR > 1 && NF >= 5 {print $4, $5}' | tail -1)"
    if [ -z "$free_space" ] && [ -z "$capacity" ]; then
        echo "$icon --"
        return
    fi
    if [[ "$capacity" =~ ^[0-9]+%$ ]]; then
        used_pct="${capacity%\%}"
    fi

    local result="$icon"

    if [ "$show_free" = "true" ]; then
        if [[ ! "$free_space" =~ ^[0-9]+([.,][0-9]+)?([KMGTPEZY]i?B?|B)?$ ]]; then
            echo "$icon --"
            return
        fi
        result="$result ${free_space} free"
    elif [ "$show_pct" = "true" ]; then
        if [ -z "$used_pct" ]; then
            echo "$icon --"
            return
        fi
        result="$result ${used_pct}%"
    fi

    if [ "$show_status" = "true" ]; then
        if [ -n "$used_pct" ]; then
            local status_ind=$(get_status "$used_pct" "$warn_thresh" "$crit_thresh")
            result="$result${status_ind}"
        elif [ "$result" = "$icon" ]; then
            result="$icon --"
        fi
    fi

    echo "$result"
}
