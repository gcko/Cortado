# shellcheck shell=bash
# =============================================================================
# Brightness Module - Shows screen brightness (macOS)
# =============================================================================
# Configuration options:
#   BRIGHTNESS_ICON         - Icon for brightness (default: ☀️)
#   BRIGHTNESS_SHOW_PERCENT - Show percentage (default: true)
#   BRIGHTNESS_SHOW_BAR     - Show progress bar (default: false)
#   BRIGHTNESS_BAR_WIDTH    - Width of progress bar (default: 5)
# =============================================================================

# macOS: prefer IODisplayParameters via ioreg (works without third-party tools).
# Optional accelerator: brew install brightness. Legacy appearance-preferences
# AppleScript and fixed 0–1024 AppleBacklightDisplay scale are dead on modern macOS.

module_brightness() {
    local icon
    icon=$(get_icon "${BRIGHTNESS_ICON:-☀️}" "BRT:")
    local show_pct="${BRIGHTNESS_SHOW_PERCENT:-true}"
    local show_bar="${BRIGHTNESS_SHOW_BAR:-false}"
    local bar_width="${BRIGHTNESS_BAR_WIDTH:-5}"

    local brightness="" reading

    if [ "${render_os-$(uname)}" = Darwin ]; then
        # Prefer brew brightness CLI when present (fast, direct)
        if reading=$(brightness -l 2>/dev/null); then
            local fraction
            fraction=$(printf '%s\n' "$reading" | grep -o 'brightness [0-9.]*' | awk 'NR == 1 {print $2}')
            if [[ "$fraction" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]; then
                brightness=$(echo "scale=0; $fraction * 100" | bc -l 2>/dev/null) || brightness=""
            fi
        fi

        if [ -z "$brightness" ] && reading=$(ioreg -l 2>/dev/null); then
            local key dict max val
            # Prefer the IODisplayParameters brightness dict. Fall back to
            # rawBrightness, which has its own scale.
            for key in brightness rawBrightness; do
                dict=$(printf '%s\n' "$reading" | grep -oE "\"$key\"=\{\"min\"=[0-9]+,\"max\"=[0-9]+,\"value\"=[0-9]+\}" | head -1)
                [ -n "$dict" ] || continue
                max=$(echo "$dict" | grep -o '"max"=[0-9]*' | cut -d= -f2)
                val=$(echo "$dict" | grep -o '"value"=[0-9]*' | cut -d= -f2)
                if [ "$max" -gt 0 ]; then
                    brightness=$((10#$val * 100 / 10#$max))
                    break
                fi
            done
        fi
    else
        # Linux: try various methods
        local path curr max
        for path in /sys/class/backlight/*/brightness; do
            [ -f "$path" ] || continue
            if curr=$(cat "$path" 2>/dev/null) &&
               max=$(cat "${path%/*}/max_brightness" 2>/dev/null) &&
               [[ "$curr" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then
                brightness=$((10#$curr * 100 / 10#$max))
                break
            fi
        done
        # Try xbacklight
        if [ -z "$brightness" ] && reading=$(xbacklight -get 2>/dev/null) &&
           [[ "$reading" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            brightness="${reading%%.*}"
        fi
    fi

    local brightness_int
    if [ -z "$brightness" ] || ! brightness_int=$(printf "%.0f" "$brightness" 2>/dev/null); then
        echo "$icon --"
        return
    fi

    local result="$icon"

    if [ "$show_pct" = "true" ]; then
        result="$result ${brightness_int}%"
    fi

    if [ "$show_bar" = "true" ]; then
        local bar
        bar=$(progress_bar "$brightness_int" "$bar_width")
        result="$result $bar"
    fi

    echo "$result"
}
