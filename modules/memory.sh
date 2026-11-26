# shellcheck shell=bash
# @cortado-module memory
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu system 14
# @description RAM usage
# @config MEMORY_ICON:string
# @config MEMORY_SHOW_PERCENTAGE:bool
# @config MEMORY_SHOW_USED:bool
# @config MEMORY_WARNING_THRESHOLD:int
# @config MEMORY_CRITICAL_THRESHOLD:int
# @config MEMORY_SHOW_STATUS:bool
# =============================================================================
# Memory Module - Shows RAM usage
# =============================================================================
# Configuration options:
#   MEMORY_ICON              - Icon for memory (default: 🧠)
#   MEMORY_SHOW_PERCENTAGE   - Show percentage (default: true)
#   MEMORY_SHOW_USED         - Show used/total (default: false)
#   MEMORY_WARNING_THRESHOLD - Yellow at % (default: 70)
#   MEMORY_CRITICAL_THRESHOLD - Red at % (default: 85)
#   MEMORY_SHOW_STATUS       - Show status indicator (default: true)
# =============================================================================

_memory_darwin_reading() {
    local vm_output pages_active pages_wired page_size total_mem
    local free='Pages free:[[:blank:]]+[0-9]+[.]'
    local active='Pages active:[[:blank:]]+([0-9]{1,12})[.]'
    local wired='Pages wired down:[[:blank:]]+([0-9]{1,12})[.]'
    local page='page size of ([0-9]{1,8}) bytes'
    vm_output=$(vm_stat 2>/dev/null) || return 1
    [[ "$vm_output" =~ $free && "$vm_output" =~ $active ]] || return 1
    pages_active=${BASH_REMATCH[1]}
    [[ "$vm_output" =~ $wired ]] || return 1
    pages_wired=${BASH_REMATCH[1]}
    if [[ "$vm_output" =~ $page ]]; then
        page_size=${BASH_REMATCH[1]}
    else
        page_size=$(sysctl -n hw.pagesize 2>/dev/null) || return 1
    fi
    total_mem=$(sysctl -n hw.memsize 2>/dev/null) || return 1
    [[ "$page_size" =~ ^[1-9][0-9]{0,7}$ && "$total_mem" =~ ^[1-9][0-9]{0,15}$ ]] || return 1
    local used_pages=$((10#$pages_active + 10#$pages_wired))
    [ "$used_pages" -le "$((total_mem / page_size))" ] || return 1
    REPLY="$((used_pages * page_size)) $total_mem"
}

module_memory() {
    get_icon_reply "${MEMORY_ICON:-🧠}" "MEM:"
    local icon="$REPLY"
    local show_pct="${MEMORY_SHOW_PERCENTAGE:-true}"
    local show_used="${MEMORY_SHOW_USED:-false}"
    local warn_thresh="${MEMORY_WARNING_THRESHOLD:-70}"
    local crit_thresh="${MEMORY_CRITICAL_THRESHOLD:-85}"
    local show_status="${MEMORY_SHOW_STATUS:-true}"

    local mem_pct=""
    local mem_used=""
    local mem_total=""

    if [ "${render_os-$(uname)}" = Darwin ]; then
        local used_bytes total_mem
        if ! _memory_darwin_reading; then
            printf '%s --\n' "$icon"
            return
        fi
        IFS=' ' read -r used_bytes total_mem <<< "$REPLY"
        safe_percent_reply "$used_bytes" "$total_mem"
        mem_pct=$REPLY
        mem_used="$((used_bytes / 1073741824))G"
        mem_total="$((total_mem / 1073741824))G"
    else
        # Linux: use /proc/meminfo
        local total=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
        local avail=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')

        if [ -n "$total" ] && [ -n "$avail" ]; then
            # Empty or zero MemTotal would crash the raw divisions below
            safe_int_reply "$total" 0
            if [ "$REPLY" -eq 0 ]; then
                return
            fi
            local used=$((total - avail))
            safe_percent_reply "$used" "$total"
            mem_pct=$REPLY
            mem_used="$((used / 1048576))G"
            mem_total="$((total / 1048576))G"
        fi
    fi

    if [ -z "$mem_pct" ]; then
        return
    fi

    local result="$icon"

    if [ "$show_used" = "true" ]; then
        result="$result ${mem_used}/${mem_total}"
    elif [ "$show_pct" = "true" ]; then
        result="$result ${mem_pct}%"
    fi

    if [ "$show_status" = "true" ]; then
        get_status_reply "$mem_pct" "$warn_thresh" "$crit_thresh"
        result="$result$REPLY"
    fi

    echo "$result"
}
