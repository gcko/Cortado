# shellcheck shell=bash
# @cortado-module brightness
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu system 20
# @description Screen brightness
# @config BRIGHTNESS_ICON:string
# @config BRIGHTNESS_SHOW_PERCENT:bool
# @config BRIGHTNESS_SHOW_BAR:bool
# @config BRIGHTNESS_BAR_WIDTH:int
# =============================================================================
# Brightness Module - Shows screen brightness (macOS)
# =============================================================================
# Configuration options:
#   BRIGHTNESS_ICON         - Icon for brightness (default: ☀️)
#   BRIGHTNESS_SHOW_PERCENT - Show percentage (default: true)
#   BRIGHTNESS_SHOW_BAR     - Show progress bar (default: false)
#   BRIGHTNESS_BAR_WIDTH    - Width of progress bar (default: 5)
# =============================================================================

_brightness_probe() (
    set -o pipefail
    local LC_ALL=C reading brightness
    export LC_ALL
    if [ "$1" = darwin ]; then
        if reading=$(brightness -l); then
            brightness=$(awk '
                /brightness [0-9.]+$/ {
                    if ($NF ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/ && $NF <= 1) {
                        printf "%.0f\n", $NF * 100
                        exit
                    }
                }
            ' <<< "$reading")
            if [ -n "$brightness" ]; then
                printf '%s\n' "$brightness"
                return
            fi
        fi

        # Match just display entries and avoid walking their descendants.
        ioreg -r -d 1 -k IODisplayParameters | awk '
            function percentage(key, fields, dict) {
                if (!match($0, "\"" key "\"=\\{\"min\"=[0-9]+,\"max\"=[0-9]+,\"value\"=[0-9]+\\}"))
                    return ""
                dict = substr($0, RSTART, RLENGTH - 1)
                split(dict, fields, "=")
                if (fields[4] + 0 > 0 && fields[5] + 0 <= fields[4] + 0)
                    return int(100 * fields[5] / fields[4])
                return ""
            }
            /"IODisplayParameters"/ {
                if (normal == "") normal = percentage("brightness")
                if (raw == "") raw = percentage("rawBrightness")
            }
            END {
                if (normal != "") print normal
                else if (raw != "") print raw
            }
        '
    else
        local path curr max
        for path in /sys/class/backlight/*/brightness; do
            [ -f "$path" ] || continue
            if IFS= read -r curr < "$path" &&
               IFS= read -r max < "${path%/*}/max_brightness" &&
               [[ "$curr" =~ ^[0-9]{1,15}$ && "$max" =~ ^[0-9]{1,15}$ ]] &&
               (( 10#$max > 0 && 10#$curr <= 10#$max )); then
                printf '%d\n' "$((10#$curr * 100 / 10#$max))"
                return
            fi
        done
        if reading=$(xbacklight -get) &&
           [[ "$reading" =~ ^[0-9]{1,3}([.][0-9]+)?$ ]] &&
           [ "${reading%%.*}" -le 100 ]; then
            printf '%s\n' "${reading%%.*}"
        fi
    fi
)

module_brightness() {
    get_icon_reply "${BRIGHTNESS_ICON:-☀️}" "BRT:"
    local icon="$REPLY"
    local show_pct="${BRIGHTNESS_SHOW_PERCENT:-true}"
    local show_bar="${BRIGHTNESS_SHOW_BAR:-false}"
    local bar_width="${BRIGHTNESS_BAR_WIDTH:-5}"

    local os="${CORTADO_OS:-}"
    cached_probe brightness 10 5 "${BASH_SOURCE[0]}" _brightness_probe "$os"
    local brightness_int="$REPLY"
    if ! [[ "$brightness_int" =~ ^[0-9]{1,3}$ ]] || (( 10#$brightness_int > 100 )); then
        printf '%s --\n' "$icon"
        return
    fi

    local result="$icon"

    if [ "$show_pct" = "true" ]; then
        result="$result ${brightness_int}%"
    fi

    if [ "$show_bar" = "true" ]; then
        progress_bar_reply "$brightness_int" "$bar_width"
        result="$result $REPLY"
    fi

    echo "$result"
}
