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

module_load() {
    local icon=$(get_icon "${LOAD_ICON:-📊}" "LOAD:")
    local show_all="${LOAD_SHOW_ALL:-false}"
    local show_status="${LOAD_SHOW_STATUS:-true}"

    # Get number of CPUs for threshold calculation
    local num_cpus
    if [ "${render_os-$(uname)}" = Darwin ]; then
        num_cpus=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    else
        num_cpus=$(nproc 2>/dev/null || echo 4)
    fi

    local warn_thresh=$(safe_int "${LOAD_WARNING_THRESHOLD:-$num_cpus}" "$num_cpus")
    local crit_thresh=$(safe_int "${LOAD_CRITICAL_THRESHOLD:-$((num_cpus * 2))}" "$((num_cpus * 2))")

    # Get load averages
    # macOS prints "load averages:" (plural), Linux "load average:" — match both.
    local uptime_output load_output load1 load5 load15
    if ! uptime_output=$(LC_ALL=C uptime 2>/dev/null); then
        echo "$icon --"
        return
    fi
    load_output=$(printf '%s\n' "$uptime_output" | awk -F'load averages?:' 'NF > 1 {print $2; exit}')
    IFS=$' ,\t' read -r load1 load5 load15 <<< "$load_output"
    local load_number='^[0-9]+([.][0-9]+)?$'
    if [[ ! "$load1" =~ $load_number ]]; then
        echo "$icon --"
        return
    fi

    local result="$icon"

    if [ "$show_all" = "true" ]; then
        [[ "$load5" =~ $load_number ]] || load5=--
        [[ "$load15" =~ $load_number ]] || load15=--
        result="$result $load1 $load5 $load15"
    else
        result="$result $load1"
    fi

    if [ "$show_status" = "true" ]; then
        # Convert load to percentage relative to num_cpus for status
        local load_pct warn_pct crit_pct integer='^-?[0-9]+$'
        if load_pct=$(echo "scale=0; $load1 * 100 / $num_cpus" | bc -l 2>/dev/null) &&
           warn_pct=$(echo "scale=0; $warn_thresh * 100 / $num_cpus" | bc -l 2>/dev/null) &&
           crit_pct=$(echo "scale=0; $crit_thresh * 100 / $num_cpus" | bc -l 2>/dev/null) &&
           [[ "$load_pct" =~ $integer && "$warn_pct" =~ $integer && "$crit_pct" =~ $integer ]]; then
            local status_ind=$(get_status "$load_pct" "$warn_pct" "$crit_pct")
            result="$result${status_ind}"
        fi
    fi

    echo "$result"
}
