# shellcheck shell=bash
# @cortado-module uptime
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu system 17
# @description System uptime
# @config UPTIME_ICON:string
# @config UPTIME_STYLE:string
# =============================================================================
# Uptime Module - Shows system uptime
# =============================================================================
# Configuration options:
#   UPTIME_ICON       - Icon for uptime (default: ⏱️)
#   UPTIME_STYLE      - Display style: "short", "long", "days" (default: short)
#   UPTIME_SHOW_LOAD  - Show load average (default: false); [--] when unreadable
# =============================================================================

module_uptime() {
    local icon=$(get_icon "${UPTIME_ICON:-⏱️}" "UP:")
    local style="${UPTIME_STYLE:-short}"
    local show_load="${UPTIME_SHOW_LOAD:-false}"

    # Only a whole number of seconds is a reading; anything else shows -- (#82).
    local uptime_secs=""

    if [ "${CORTADO_OS:-}" = darwin ]; then
        # macOS: parse boot time
        local boot_time now
        boot_time=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
        now=$(date +%s 2>/dev/null)
        if [[ "$boot_time" =~ ^[1-9][0-9]{0,11}$ && "$now" =~ ^[1-9][0-9]{0,11}$ ]] &&
            [ "$boot_time" -le "$now" ]; then
            uptime_secs=$((now - boot_time))
        fi
    else
        # Linux: use /proc/uptime
        uptime_secs=$(cut -d. -f1 /proc/uptime 2>/dev/null)
        [[ "$uptime_secs" =~ ^(0|[1-9][0-9]{0,11})$ ]] || uptime_secs=""
    fi

    if [ -z "$uptime_secs" ]; then
        echo "$icon --"
        return
    fi

    local uptime_str=$(format_uptime "$uptime_secs" "$style")
    local result="$icon $uptime_str"

    # Add load average if requested
    if [ "$show_load" = "true" ]; then
        # macOS prints "load averages:" (plural), Linux "load average:" — match both.
        # A missing or non-numeric average keeps its place as [--].
        local load=$(uptime 2>/dev/null | awk -F'load averages?:' '{print $2}' | awk '{print $1}' | tr -d ',')
        [[ "$load" =~ ^[0-9]+([.][0-9]+)?$ ]] || load=--
        result="$result [$load]"
    fi

    echo "$result"
}

format_uptime() {
    local secs=$1
    local style=${2:-short}

    local days=$((secs / 86400))
    local hours=$(((secs % 86400) / 3600))
    local mins=$(((secs % 3600) / 60))

    case "$style" in
        days)
            if [ "$days" -gt 0 ]; then
                echo "${days}d"
            else
                echo "${hours}h"
            fi
            ;;
        long)
            if [ "$days" -gt 0 ]; then
                echo "${days} days, ${hours} hours"
            elif [ "$hours" -gt 0 ]; then
                echo "${hours} hours, ${mins} mins"
            else
                echo "${mins} mins"
            fi
            ;;
        short|*)
            if [ "$days" -gt 0 ]; then
                echo "${days}d ${hours}h"
            elif [ "$hours" -gt 0 ]; then
                echo "${hours}h ${mins}m"
            else
                echo "${mins}m"
            fi
            ;;
    esac
}
