# shellcheck shell=bash
# @cortado-module cpu
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu system 13
# @description CPU usage
# @config CPU_ICON:string
# @config CPU_SHOW_PERCENTAGE:bool
# @config CPU_WARNING_THRESHOLD:int
# @config CPU_CRITICAL_THRESHOLD:int
# @config CPU_SHOW_STATUS:bool
# =============================================================================
# CPU Module - Shows CPU usage percentage
# =============================================================================
# Configuration options:
#   CPU_ICON            - Icon for CPU (default: 💻)
#   CPU_SHOW_PERCENTAGE - Show percentage (default: true)
#   CPU_WARNING_THRESHOLD - Yellow at % (default: 60)
#   CPU_CRITICAL_THRESHOLD - Red at % (default: 80)
#   CPU_SHOW_STATUS     - Show status indicator (default: true)
# =============================================================================

_cpu_probe() {
    local LC_ALL=C
    export LC_ALL
    if [ "$1" = darwin ]; then
        local samples
        # iostat samples aggregate CPU counters without enumerating processes.
        # Its first reading is since boot, so take the following interval.
        samples=$(iostat -d -C -n 0 -c 2 -w 1) || return 1
        awk '
            { for (i = 1; i <= NF - 2; i++)
                if ($i == "us" && $(i+1) == "sy" && $(i+2) == "id") cpu = i
            }
            cpu && $cpu ~ /^[0-9]+$/ && $(cpu+1) ~ /^[0-9]+$/ && $(cpu+2) ~ /^[0-9]+$/ {
                busy = $cpu + $(cpu+1)
                accounted = busy + $(cpu+2)
                if (++samples == 2 && busy <= 100 && $(cpu+2) <= 100 &&
                    accounted >= 99 && accounted <= 101) print busy
            }
        ' <<< "$samples"
        return
    fi

    local prev cur label puser pnice psystem pidle cuser cnice csystem cidle remainder
    local duser dnice dsystem didle dtotal
    local sample_pattern='^cpu([[:blank:]]+[0-9]{1,15}){4}([[:blank:]]|$)'
    prev=$(grep '^cpu ' /proc/stat) && [[ "$prev" =~ $sample_pattern ]] || return 1
    sleep 1 || return 1
    cur=$(grep '^cpu ' /proc/stat) && [[ "$cur" =~ $sample_pattern ]] || return 1
    IFS=$' \t' read -r label puser pnice psystem pidle remainder <<< "$prev"
    IFS=$' \t' read -r label cuser cnice csystem cidle remainder <<< "$cur"
    duser=$((10#$cuser - 10#$puser))
    dnice=$((10#$cnice - 10#$pnice))
    dsystem=$((10#$csystem - 10#$psystem))
    didle=$((10#$cidle - 10#$pidle))
    dtotal=$((duser + dnice + dsystem + didle))
    (( duser >= 0 && dnice >= 0 && dsystem >= 0 && didle >= 0 && dtotal > 0 )) || return 1
    printf '%d\n' "$(( (duser + dnice + dsystem) * 100 / dtotal ))"
}

module_cpu() {
    get_icon_reply "${CPU_ICON:-💻}" "CPU:"
    local icon="$REPLY"
    local show_pct="${CPU_SHOW_PERCENTAGE:-true}"
    local warn_thresh="${CPU_WARNING_THRESHOLD:-60}"
    local crit_thresh="${CPU_CRITICAL_THRESHOLD:-80}"
    local show_status="${CPU_SHOW_STATUS:-true}"

    local os="${CORTADO_OS:-}"
    cached_probe cpu 5 5 "${BASH_SOURCE[0]}" _cpu_probe "$os"
    local cpu_int="$REPLY"
    if ! [[ "$cpu_int" =~ ^[0-9]{1,3}$ ]] || (( 10#$cpu_int > 100 )); then
        printf '%s --\n' "$icon"
        return
    fi

    local result="$icon"

    if [ "$show_pct" = "true" ]; then
        result="$result ${cpu_int}%"
    fi

    if [ "$show_status" = "true" ]; then
        get_status_reply "$cpu_int" "$warn_thresh" "$crit_thresh"
        result="$result$REPLY"
    fi

    echo "$result"
}
