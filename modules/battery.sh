# shellcheck shell=bash
# @cortado-module battery
# @default true
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu core 12
# @description Battery (macOS)
# @config BATTERY_ICON:string
# @config BATTERY_SHOW_CHARGING:bool
# @config BATTERY_CHARGING_ICON:string
# @config BATTERY_LOW_ICON:string
# @config BATTERY_CRITICAL_ICON:string
# @config BATTERY_LOW_THRESHOLD:int
# @config BATTERY_CRITICAL_THRESHOLD:int
# @config BATTERY_SHOW_PERCENTAGE:bool
# =============================================================================
# Battery Module - Shows battery percentage (macOS only)
# =============================================================================
# Configuration options:
#   BATTERY_ICON              - Icon for battery (default: 🔋)
#   BATTERY_SHOW_CHARGING     - Show charging indicator (default: true)
#   BATTERY_CHARGING_ICON     - Icon when charging (default: ⚡)
#   BATTERY_LOW_ICON          - Icon when low (default: 🪫)
#   BATTERY_CRITICAL_ICON     - Icon when critical (default: 🔴)
#   BATTERY_LOW_THRESHOLD     - Low battery threshold (default: 20)
#   BATTERY_CRITICAL_THRESHOLD - Critical threshold (default: 10)
#   BATTERY_SHOW_PERCENTAGE   - Show percentage number (default: true)
# =============================================================================

module_battery() {
    local icon="${BATTERY_ICON:-🔋}"
    local show_charging="${BATTERY_SHOW_CHARGING:-true}"
    local charging_icon="${BATTERY_CHARGING_ICON:-⚡}"
    local low_icon="${BATTERY_LOW_ICON:-🪫}"
    local critical_icon="${BATTERY_CRITICAL_ICON:-🔴}"
    # Thresholds may come from an untrusted project .cortado.conf and feed the integer
    # comparisons below — coerce non-numeric values to the defaults (matches cpu.sh).
    local low_thresh crit_thresh
    safe_int_reply "${BATTERY_LOW_THRESHOLD:-20}" 20
    low_thresh=$REPLY
    safe_int_reply "${BATTERY_CRITICAL_THRESHOLD:-10}" 10
    crit_thresh=$REPLY
    local show_pct="${BATTERY_SHOW_PERCENTAGE:-true}"

    # Get battery info
    local batt_info pct_num pattern='([0-9]+)%'
    if ! batt_info=$(pmset -g batt 2>/dev/null) || ! [[ "$batt_info" =~ $pattern ]]; then
        get_icon_reply "$icon" "BAT:"
        echo "$REPLY --"
        return
    fi
    pct_num=${BASH_REMATCH[1]}

    # Determine icon based on level
    if [ "$pct_num" -le "$crit_thresh" ] 2>/dev/null; then
        get_icon_reply "$critical_icon" "CRIT:"
    elif [ "$pct_num" -le "$low_thresh" ] 2>/dev/null; then
        get_icon_reply "$low_icon" "LOW:"
    else
        get_icon_reply "$icon" "BAT:"
    fi
    local display_icon="$REPLY"

    # Check if charging
    local charging=""
    if [ "$show_charging" = "true" ]; then
        if [[ "$batt_info" == *'AC Power'* || "$batt_info" == *charging* ]]; then
            charging=" $charging_icon"
        fi
    fi

    # Build output
    if [ "$show_pct" = "true" ]; then
        echo "$display_icon $pct_num%$charging"
    else
        echo "$display_icon$charging"
    fi
}
