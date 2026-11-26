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

module_cpu() {
    local icon=$(get_icon "${CPU_ICON:-💻}" "CPU:")
    local show_pct="${CPU_SHOW_PERCENTAGE:-true}"
    local warn_thresh="${CPU_WARNING_THRESHOLD:-60}"
    local crit_thresh="${CPU_CRITICAL_THRESHOLD:-80}"
    local show_status="${CPU_SHOW_STATUS:-true}"

    # Get CPU usage
    local cpu_usage
    if [ "${render_os-$(uname)}" = Darwin ]; then
        # macOS: count user and system usage from a successful top sample.
        local sample
        if sample=$(LC_ALL=C top -l 1 -n 0 2>/dev/null); then
            cpu_usage=$(printf '%s\n' "$sample" | LC_ALL=C awk '
                /^CPU usage:/ {
                    if ($3 ~ /^[0-9]+([.][0-9]+)?%$/ && $5 ~ /^[0-9]+([.][0-9]+)?%$/)
                        print $3 + $5
                    exit
                }')
        fi
    else
        # Linux: single-shot /proc/stat is lifetime average since boot — not
        # "current" CPU%. Diff against a previous sample cached under cortado-cache
        # (statusline re-renders often → second+ ticks are accurate; first tick
        # seeds the cache and renders --).
        local cur prev puser pnice psystem pidle cuser cnice csystem cidle
        local label remainder
        local duser dnice dsystem didle dtotal
        local sample_pattern='^cpu([[:blank:]]+[0-9]+){4}([[:blank:]]|$)'
        if cur=$(grep '^cpu ' /proc/stat 2>/dev/null) && [[ "$cur" =~ $sample_pattern ]]; then
            init_cache
            local stat_file="${CACHE_DIR}/cpu_stat"
            if [ -f "$stat_file" ] && prev=$(cat "$stat_file" 2>/dev/null) && [[ "$prev" =~ $sample_pattern ]]; then
                IFS=$' \t' read -r label puser pnice psystem pidle remainder <<< "$prev"
                IFS=$' \t' read -r label cuser cnice csystem cidle remainder <<< "$cur"
                duser=$((10#$cuser - 10#$puser))
                dnice=$((10#$cnice - 10#$pnice))
                dsystem=$((10#$csystem - 10#$psystem))
                didle=$((10#$cidle - 10#$pidle))
                dtotal=$((duser + dnice + dsystem + didle))
                if [ "$dtotal" -gt 0 ]; then
                    cpu_usage=$(( (duser + dnice + dsystem) * 100 / dtotal ))
                fi
            fi
            printf '%s\n' "$cur" > "$stat_file" 2>/dev/null
            chmod 600 "$stat_file" 2>/dev/null
        fi
    fi

    local cpu_int
    if [ -z "$cpu_usage" ] || ! cpu_int=$(
        LC_ALL=C
        printf "%.0f" "$cpu_usage" 2>/dev/null
    ); then
        echo "$icon --"
        return
    fi

    local result="$icon"

    if [ "$show_pct" = "true" ]; then
        result="$result ${cpu_int}%"
    fi

    if [ "$show_status" = "true" ]; then
        local status_ind=$(get_status "$cpu_int" "$warn_thresh" "$crit_thresh")
        result="$result${status_ind}"
    fi

    echo "$result"
}
