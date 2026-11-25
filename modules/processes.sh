# shellcheck shell=bash
# =============================================================================
# Processes Module - Shows process count and info
# =============================================================================
# Configuration options:
#   PROC_ICON              - Icon for processes (default: 🔄)
#   PROC_SHOW_TOTAL        - Show total process count (default: true)
#   PROC_SHOW_RUNNING      - Show running process count (default: false)
#   PROC_WARNING_THRESHOLD - Yellow at count (default: 300)
#   PROC_CRITICAL_THRESHOLD - Red at count (default: 500)
#   PROC_SHOW_STATUS       - Show status indicator (default: false)
# =============================================================================

module_processes() {
    local icon=$(get_icon "${PROC_ICON:-🔄}" "PROC:")
    local show_total="${PROC_SHOW_TOTAL:-true}"
    local show_running="${PROC_SHOW_RUNNING:-false}"
    local warn_thresh="${PROC_WARNING_THRESHOLD:-300}"
    local crit_thresh="${PROC_CRITICAL_THRESHOLD:-500}"
    local show_status="${PROC_SHOW_STATUS:-false}"

    local total_procs=""
    local running_procs=""

    if [ "$(uname)" != "Darwin" ] && [ -d /proc ]; then
        total_procs=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
        if [ "$show_running" = "true" ]; then
            local status_counts statuses_read running_count
            running_procs="--"
            # grep exits 1 for a complete scan with no running processes.
            # A read error or a PID vanishing before the glob makes it partial.
            if status_counts=$(grep -cE '^State:[[:space:]]*R' /proc/[0-9]*/status 2>/dev/null) \
                || [ "$?" -eq 1 ]; then
                IFS=' ' read -r statuses_read running_count <<< "$(awk -F: '
                    NF { read_count++; if ($NF > 0) running++ }
                    END { print read_count+0, running+0 }
                ' <<< "$status_counts")"
                if [ "$statuses_read" -eq "$total_procs" ] 2>/dev/null; then
                    running_procs="$running_count"
                fi
            fi
        fi
    else
        local snapshot counts
        if ! snapshot=$(ps aux 2>/dev/null) || [ -z "$snapshot" ]; then
            echo "$icon --"
            return
        fi

        # Count both readings from the same snapshot, skipping the header.
        counts=$(printf '%s\n' "$snapshot" | awk '
            NF && ++lines > 1 { total++; if ($8 ~ /R/) running++ }
            END { if (total) print total, running+0 }
        ')
        IFS=' ' read -r total_procs running_procs <<< "$counts"
    fi

    if [ "${total_procs:-0}" -le 0 ]; then
        echo "$icon --"
        return
    fi

    local result="$icon"

    if [ "$show_total" = "true" ] && [ "$show_running" = "true" ]; then
        result="$result ${running_procs}/${total_procs}"
    elif [ "$show_running" = "true" ]; then
        result="$result $running_procs"
    elif [ "$show_total" = "true" ]; then
        result="$result $total_procs"
    fi

    if [ "$show_status" = "true" ]; then
        local status_ind=$(get_status "$total_procs" "$warn_thresh" "$crit_thresh")
        result="$result${status_ind}"
    fi

    echo "$result"
}
