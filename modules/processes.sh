# shellcheck shell=bash
# @cortado-module processes
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu system 21
# @description Process count
# @config PROC_ICON:string
# @config PROC_SHOW_TOTAL:bool
# @config PROC_SHOW_RUNNING:bool
# @config PROC_WARNING_THRESHOLD:int
# @config PROC_CRITICAL_THRESHOLD:int
# @config PROC_SHOW_STATUS:bool
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

_processes_probe() {
    local os="$1" show_running="$2"
    local total_procs=""
    local running_procs=""

    if [ "$os" != Darwin ] && [ -d /proc ]; then
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
        snapshot=$(LC_ALL=C ps -A -o state=) || return 1
        counts=$(LC_ALL=C awk '
            NF == 1 && $1 ~ /^[?DIRSTUWXZt][+<>AELNSsVWX]*$/ {
                total++; if ($1 ~ /^R/) running++
            }
            END { if (total) print total, running+0 }
        ' <<< "$snapshot") || return 1
        IFS=' ' read -r total_procs running_procs <<< "$counts"
    fi
    [ "${total_procs:-0}" -gt 0 ] || return 1
    printf '%s %s\n' "$total_procs" "${running_procs:---}"
}

module_processes() {
    get_icon_reply "${PROC_ICON:-🔄}" "PROC:"
    local icon="$REPLY"
    local show_total="${PROC_SHOW_TOTAL:-true}"
    local show_running="${PROC_SHOW_RUNNING:-false}"
    local warn_thresh="${PROC_WARNING_THRESHOLD:-300}"
    local crit_thresh="${PROC_CRITICAL_THRESHOLD:-500}"
    local show_status="${PROC_SHOW_STATUS:-false}"

    local os="${render_os-$(uname)}" mode=total
    if [ "$show_running" = true ]; then mode=running; fi
    cached_probe "processes-$mode" 10 5 "${BASH_SOURCE[0]}" _processes_probe "$os" "$show_running"

    local total_procs running_procs
    IFS=' ' read -r total_procs running_procs <<< "$REPLY"
    # Accept only what the probe can publish: a positive total, and a running
    # count no larger than it. Ten digits keep the arithmetic in range.
    if ! [[ "$total_procs" =~ ^[1-9][0-9]{0,9}$ && "$running_procs" =~ ^(0|[1-9][0-9]{0,9}|--)$ ]] ||
        { [ "$running_procs" != -- ] && [ "$running_procs" -gt "$total_procs" ]; } ||
        { [ "$show_total" != true ] && [ "$show_running" = true ] && [ "$running_procs" = -- ]; }; then
        printf '%s --\n' "$icon"
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
        get_status_reply "$total_procs" "$warn_thresh" "$crit_thresh"
        result="$result$REPLY"
    fi

    echo "$result"
}
