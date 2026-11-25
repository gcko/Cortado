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
        local pid_dir restore_noglob=false restore_failglob=false
        local pid_dirs=() status_paths=()
        # Snapshot in this shell so counting does not create transient PIDs.
        case "$-" in
            *f*) restore_noglob=true; set +f ;;
        esac
        if shopt -q failglob; then
            restore_failglob=true
            shopt -u failglob
        fi
        pid_dirs=(/proc/[0-9]*/)
        if [[ "$restore_noglob" = true ]]; then set -f; fi
        if [[ "$restore_failglob" = true ]]; then shopt -s failglob; fi

        total_procs=0
        for pid_dir in "${pid_dirs[@]+"${pid_dirs[@]}"}"; do
            pid_dir=${pid_dir%/}
            case "${pid_dir##*/}" in
                *[!0-9]*) continue ;;
            esac
            total_procs=$((total_procs + 1))
            if [ "$show_running" = "true" ]; then
                status_paths+=("$pid_dir/status")
            fi
        done

        if [ "$show_running" = "true" ] && [ "$total_procs" -gt 0 ]; then
            local status_counts
            running_procs="--"
            # Unlike a second glob, explicit paths preserve missing members.
            # grep exits 1 for a complete scan with no running processes.
            if status_counts=$(grep -cE '^State:[[:space:]]*R' "${status_paths[@]}" 2>/dev/null) \
                || [ "$?" -eq 1 ]; then
                running_procs=$(awk -F: '$NF > 0 { running++ } END { print running+0 }' <<< "$status_counts") \
                    || running_procs="--"
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

    if [ "$show_status" = "true" ] && { [ "$show_total" = "true" ] || [ "$running_procs" != "--" ]; }; then
        local status_ind=$(get_status "$total_procs" "$warn_thresh" "$crit_thresh")
        result="$result${status_ind}"
    fi

    echo "$result"
}
