# shellcheck shell=bash
# @cortado-module load
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu system 18
# @description Load average
# @config LOAD_ICON:string
# @config LOAD_SHOW_ALL:bool
# @config LOAD_WARNING_THRESHOLD:int
# @config LOAD_CRITICAL_THRESHOLD:int
# @config LOAD_SHOW_STATUS:bool
# =============================================================================
# Load Average Module - Shows system load average
# =============================================================================
# Configuration options:
#   LOAD_ICON              - Icon for load (default: 📊)
#   LOAD_SHOW_ALL          - Show 1, 5, 15 min averages (default: false)
#   LOAD_WARNING_THRESHOLD - Yellow at load (default: num_cpus)
#   LOAD_CRITICAL_THRESHOLD - Red at load (default: num_cpus * 2)
#   LOAD_SHOW_STATUS       - Show status indicator (default: true)
# =============================================================================

_load_probe() {
    local os="$1" num_cpus uptime_output load1 load5 load15
    local load_number='^[0-9]+([.][0-9]+)?$'
    case "$os" in
        darwin) num_cpus=$(sysctl -n hw.ncpu) || num_cpus=4 ;;
        *) num_cpus=$(nproc) || num_cpus=4 ;;
    esac
    [[ "$num_cpus" =~ ^[1-9][0-9]{0,5}$ ]] || num_cpus=4

    uptime_output=$(LC_ALL=C uptime) || return 1
    case "$uptime_output" in
        *'load averages:'*) uptime_output=${uptime_output#*load averages:} ;;
        *'load average:'*) uptime_output=${uptime_output#*load average:} ;;
        *) return 1 ;;
    esac
    IFS=$' ,\t' read -r load1 load5 load15 <<< "$uptime_output"
    [[ "$load1" =~ $load_number ]] || return 1
    [[ "$load5" =~ $load_number ]] || load5=--
    [[ "$load15" =~ $load_number ]] || load15=--
    printf '%s %s %s %s\n' "$num_cpus" "$load1" "$load5" "$load15"
}

# The former integer percentage rounded the threshold down by its remainder
# modulo the CPU count. Compare in hundredths without multiplying large loads.
_load_reaches_threshold() {
    local whole="$1" fraction="$2" threshold="$3" cpus="$4"
    [ "$whole" -lt "$threshold" ] || return 0
    local gap=$((threshold - whole))
    (( gap <= 10000 && gap * 100 - fraction <= ((threshold % cpus) * 100) % cpus ))
}

module_load() {
    get_icon_reply "${LOAD_ICON:-📊}" "LOAD:"
    local icon="$REPLY"
    local os="${CORTADO_OS:-}"
    cached_probe load 10 5 "${BASH_SOURCE[0]}" _load_probe "$os"

    local num_cpus load1 load5 load15
    local load_number='[0-9]+([.][0-9]+)?'
    IFS=' ' read -r num_cpus load1 load5 load15 <<< "$REPLY"
    if ! [[ "$num_cpus" =~ ^[1-9][0-9]{0,5}$ && "$load1" =~ ^$load_number$ &&
        "$load5" =~ ^($load_number|--)$ && "$load15" =~ ^($load_number|--)$ ]]; then
        echo "$icon --"
        return
    fi

    local result="$icon $load1"
    if [ "${LOAD_SHOW_ALL:-false}" = true ]; then
        result="$result $load5 $load15"
    fi

    if [ "${LOAD_SHOW_STATUS:-true}" = true ]; then
        local warn_thresh crit_thresh whole fraction level=0
        # Only hundredths can affect the integer percentage bucket.
        whole=${load1%%.*}
        if [ "$whole" -ge 0 ] 2>/dev/null; then
            whole=$((10#$whole))
            fraction=00
            if [[ "$load1" == *.* ]]; then fraction=${load1#*.}00; fi
            fraction=$((10#${fraction:0:2}))
            decimal_int_reply "${LOAD_WARNING_THRESHOLD:-$num_cpus}" "$num_cpus"
            warn_thresh=$REPLY
            decimal_int_reply "${LOAD_CRITICAL_THRESHOLD:-$((num_cpus * 2))}" "$((num_cpus * 2))"
            crit_thresh=$REPLY
            if _load_reaches_threshold "$whole" "$fraction" "$crit_thresh" "$num_cpus"; then
                level=2
            elif _load_reaches_threshold "$whole" "$fraction" "$warn_thresh" "$num_cpus"; then
                level=1
            fi
            get_status_reply "$level" 1 2
            result="$result$REPLY"
        fi
    fi

    echo "$result"
}
