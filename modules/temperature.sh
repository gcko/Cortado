# shellcheck shell=bash
# @cortado-module temperature
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu system 19
# @description CPU temperature
# @config TEMP_ICON:string
# @config TEMP_UNITS:string
# @config TEMP_WARNING_THRESHOLD:int
# @config TEMP_CRITICAL_THRESHOLD:int
# @config TEMP_SHOW_STATUS:bool
# =============================================================================
# Temperature Module - Shows CPU/system temperature (macOS)
# =============================================================================
# Configuration options:
#   TEMP_ICON              - Icon for temp (default: 🌡️)
#   TEMP_UNITS             - Units: "C" or "F" (default: C)
#   TEMP_WARNING_THRESHOLD - Yellow at temp (default: 70)
#   TEMP_CRITICAL_THRESHOLD - Red at temp (default: 85)
#   TEMP_SHOW_STATUS       - Show status indicator (default: true)
# =============================================================================

# Note: On macOS, this requires either:
# - osx-cpu-temp (brew install osx-cpu-temp)
# - istats (gem install iStats)
# - powermetrics (requires sudo)

module_temperature() {
    local icon=$(get_icon "${TEMP_ICON:-🌡️}" "TEMP:")
    local units="${TEMP_UNITS:-C}"
    local warn_thresh=$(safe_int "${TEMP_WARNING_THRESHOLD:-70}" 70)
    local crit_thresh=$(safe_int "${TEMP_CRITICAL_THRESHOLD:-85}" 85)
    local show_status="${TEMP_SHOW_STATUS:-true}"

    local temp="" reading pattern
    local temp_number='-?([0-9]+([.][0-9]+)?|[.][0-9]+)'
    local celsius="($temp_number)[[:space:]]*°C"

    if [ "${render_os-$(uname)}" = Darwin ]; then
        # Try osx-cpu-temp first (most common)
        if command -v osx-cpu-temp >/dev/null 2>&1; then
            pattern="^[[:space:]]*${celsius}[[:space:]]*$"
            if reading=$(osx-cpu-temp 2>/dev/null) && [[ "$reading" =~ $pattern ]]; then
                temp="${BASH_REMATCH[1]}"
            fi
        # Try istats
        elif command -v istats >/dev/null 2>&1; then
            if reading=$(istats cpu temp 2>/dev/null); then
                temp=$(printf '%s\n' "$reading" |
                    sed -nE "s/^[[:space:]]*CPU temp:[[:space:]]*$celsius([[:space:]].*)?$/\\1/p" | head -1)
            fi
        # Try smctemp
        elif reading=$(smctemp -c 2>/dev/null); then
            temp="${reading%%$'\n'*}"
        fi
    else
        # Linux: read from thermal zones
        if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
            local millideg
            if millideg=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) &&
               [[ "$millideg" =~ ^-?(0|[1-9][0-9]*)$ ]]; then
                temp=$((millideg / 1000))
            fi
        # Try sensors command
        elif reading=$(sensors 2>/dev/null); then
            temp=$(printf '%s\n' "$reading" |
                sed -nE "s/^[Cc]ore 0:[[:space:]]*\\+?$celsius([[:space:]].*)?$/\\1/p" | head -1)
        fi
    fi

    local temp_int
    if [[ ! "$temp" =~ ^$temp_number$ ]] || ! temp_int=$(
        export LC_ALL=C
        printf "%.0f" "$temp" 2>/dev/null
    ); then
        echo "$icon --"
        return
    fi

    # Convert to Fahrenheit if requested
    local display_temp="$temp_int"
    if [ "$units" = "F" ]; then
        local integer='^-?[0-9]+$'
        if ! display_temp=$(echo "scale=0; ($temp_int * 9/5) + 32" | bc -l 2>/dev/null) ||
           [[ ! "$display_temp" =~ $integer ]]; then
            echo "$icon --"
            return
        fi
        if [ "$show_status" = "true" ]; then
            if ! warn_thresh=$(echo "scale=0; ($warn_thresh * 9/5) + 32" | bc -l 2>/dev/null) ||
               ! crit_thresh=$(echo "scale=0; ($crit_thresh * 9/5) + 32" | bc -l 2>/dev/null) ||
               [[ ! "$warn_thresh" =~ $integer || ! "$crit_thresh" =~ $integer ]]; then
                show_status=false
            fi
        fi
    fi

    local result="$icon ${display_temp}°${units}"

    if [ "$show_status" = "true" ]; then
        local status_ind=$(get_status "$display_temp" "$warn_thresh" "$crit_thresh")
        result="$result${status_ind}"
    fi

    echo "$result"
}
