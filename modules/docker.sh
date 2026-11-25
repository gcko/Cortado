# shellcheck shell=bash
# @cortado-module docker
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu dev 22
# @description Docker status
# @config DOCKER_ICON:string
# @config DOCKER_SHOW_RUNNING:bool
# @config DOCKER_SHOW_TOTAL:bool
# @config DOCKER_SHOW_STATUS:bool
# @config DOCKER_COMPACT:bool
# =============================================================================
# Docker Module - Shows Docker container status
# =============================================================================
# Configuration options:
#   DOCKER_ICON            - Icon for Docker (default: 🐳)
#   DOCKER_SHOW_RUNNING    - Show running count (default: true)
#   DOCKER_SHOW_TOTAL      - Show total count (default: false)
#   DOCKER_SHOW_STATUS     - Show status indicator (default: true)
#   DOCKER_COMPACT         - Compact mode (default: false)
# =============================================================================

_docker_probe() {
    local need_running="$1" need_total="$2" running=-- total=-- ids count
    if [ "$need_running" = true ]; then
        if ids=$(docker ps -q) &&
           count=$(awk 'NF {count++} END {print count+0}' <<< "$ids") &&
           [[ "$count" =~ ^[0-9]+$ ]]; then
            running="$count"
        fi
    fi
    if [ "$need_total" = true ]; then
        if ids=$(docker ps -aq) &&
           count=$(awk 'NF {count++} END {print count+0}' <<< "$ids") &&
           [[ "$count" =~ ^[0-9]+$ ]]; then
            total="$count"
        fi
    fi
    [ "$running" != -- ] || [ "$total" != -- ] || return 1
    printf '%s %s\n' "$running" "$total"
}

module_docker() {
    get_icon_reply "${DOCKER_ICON:-🐳}" "DOCKER:"
    local icon="$REPLY"
    local show_running="${DOCKER_SHOW_RUNNING:-true}"
    local show_total="${DOCKER_SHOW_TOTAL:-false}"
    local show_status="${DOCKER_SHOW_STATUS:-true}"
    local compact="${DOCKER_COMPACT:-false}"

    if [ "$show_running" != "true" ] && [ "$show_total" != "true" ] && [ "$show_status" != "true" ]; then
        echo "$icon"
        return
    fi

    local need_running=false need_total=false
    if [ "$show_running" = true ] || [ "$show_status" = true ]; then need_running=true; fi
    if [ "$show_total" = true ]; then need_total=true; fi
    local key="docker-$need_running-$need_total" context_hash
    if [ -n "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}${DOCKER_CONFIG:-}" ]; then
        if ! context_hash=$(perl -MDigest::SHA=sha256_hex -e '
                print sha256_hex(join "\0", map { $ENV{$_} // "" } qw(DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG))
            '); then
            printf '%s --\n' "$icon"
            return
        fi
        key="$key-$context_hash"
    fi
    cached_probe "$key" 15 5 "${BASH_SOURCE[0]}" _docker_probe "$need_running" "$need_total"
    local running total
    IFS=' ' read -r running total <<< "$REPLY"
    if ! [[ "$running" =~ ^([0-9]+|--)$ && "$total" =~ ^([0-9]+|--)$ ]]; then
        printf '%s --\n' "$icon"
        return
    fi

    local result="$icon"

    if [ "$show_running" = "true" ] && [ "$show_total" = "true" ]; then
        if is_compact "$compact"; then
            result="$result ${running}/${total}"
        else
            result="$result ${running} running / ${total} total"
        fi
    elif [ "$show_running" = "true" ]; then
        if is_compact "$compact"; then
            result="$result $running"
        else
            result="$result $running running"
        fi
    elif [ "$show_total" = "true" ]; then
        result="$result $total"
    fi

    if [ "$show_status" = "true" ] && [ "$running" != "--" ]; then
        if [ "$running" -gt 0 ]; then
            get_icon_reply '🟢' '[OK]'
        else
            get_icon_reply '⚪' '[-]'
        fi
        result="$result $REPLY"
    fi

    echo "$result"
}
