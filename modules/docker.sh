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

# Return the selected context and a digest of the inputs that select it.
# config.json is needed only when there is no environment override.
# shellcheck disable=SC2016
_docker_selection_source='
    sub docker_selection {
        my $config = $ENV{DOCKER_CONFIG} || "$ENV{HOME}/.docker";
        my $context = $ENV{DOCKER_CONTEXT} // "";
        my $host = $ENV{DOCKER_HOST} // "";
        my $selected = "";
        if (length $context) {
            $host = "";
        } elsif (!length $host) {
            my $path = "$config/config.json";
            if (-f $path) {
                require JSON::PP;
                if (open(my $file, "<", $path)) {
                    local $/;
                    my $settings = eval { JSON::PP::decode_json(<$file>) };
                    if (ref($settings) eq "HASH" && !ref($settings->{currentContext})) {
                        $selected = $settings->{currentContext} // "";
                    }
                }
            }
            $selected ||= "default";
            return unless $selected =~ /\A[0-9A-Za-z_.-]+\z/;
        }
        require Digest::SHA;
        return (Digest::SHA::sha256_hex(join "\0", $config, $context, $host, $selected), $selected);
    }
'

_docker_selection() {
    if [ -n "${_probe_docker_selection:-}" ]; then
        REPLY=$_probe_docker_selection
    else
        REPLY=$(perl -e "$_docker_selection_source" -e '
            my ($digest, $selected) = docker_selection();
            exit 1 unless defined $digest;
            print "$digest $selected";
        ') || return 1
    fi
}

_docker_probe() {
    local need_running="$1" need_total="$2" selected="$3" running=-- total=-- ids count
    # Hold the on-disk selection sampled by the renderer across both reads.
    if [ -n "$selected" ]; then
        local DOCKER_CONTEXT="$selected"
        export DOCKER_CONTEXT
    fi
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
    if ! _docker_selection; then
        printf '%s --\n' "$icon"
        return
    fi
    local context_hash selected
    IFS=' ' read -r context_hash selected <<< "$REPLY"
    cached_probe "docker-v2-$need_running-$need_total-$context_hash" 15 5 "${BASH_SOURCE[0]}" \
        _docker_probe "$need_running" "$need_total" "$selected"
    local running total
    IFS=' ' read -r running total <<< "$REPLY"
    if ! [[ "$running" =~ ^([0-9]{1,18}|--)$ && "$total" =~ ^([0-9]{1,18}|--)$ ]] ||
        { [ "$running" = -- ] && { [ "$need_total" = false ] || [ "$total" = -- ]; }; } ||
        { [ "$total" = -- ] && [ "$need_running" = false ]; }; then
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
