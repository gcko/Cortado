# shellcheck shell=bash
# @cortado-module network
# @default false
# @args none
# @ttl 0
# @timeout-ms 4000
# @platforms darwin,linux
# @menu system 16
# @description Network info
# @config NETWORK_ICON:string
# @config NETWORK_COMPACT:bool
# =============================================================================
# Network Module - Shows IP address and network info
# =============================================================================
# Configuration options:
#   NETWORK_ICON        - Icon for network (default: 🌐)
#   NETWORK_SHOW_LAN    - Show LAN IP (default: true)
#   NETWORK_SHOW_WAN    - Show WAN IP (default: false)
#   NETWORK_WAN_REDACT  - Redact WAN IP for privacy (default: true)
#                         When true, shows e.g. "203.0.xxx.xxx" instead of full IP
#                         Set to "false" to display full public IP
#   NETWORK_SHOW_SSID   - Show WiFi SSID (default: false)
#   NETWORK_COMPACT     - Compact mode (default: false)
#
# Privacy note: When NETWORK_SHOW_WAN is enabled, this module contacts
# external services (ifconfig.me / icanhazip.com) to determine your
# public IP address. Valid readings are cached for 5 minutes.
# =============================================================================

# IPv4 is the common warm path. Keep its validation in the shell.
_network_ip() {
    local address="$1" octet
    if [[ "$address" =~ ^(0|[1-9][0-9]{0,2})[.](0|[1-9][0-9]{0,2})[.](0|[1-9][0-9]{0,2})[.](0|[1-9][0-9]{0,2})$ ]]; then
        for octet in "${BASH_REMATCH[@]:1}"; do
            [ "$octet" -le 255 ] || return 1
        done
        return 0
    fi
    [[ "$address" =~ ^[0-9a-fA-F:.]{2,45}$ && "$address" = *:* ]] || return 1
    perl -MSocket=AF_INET6,inet_pton -e 'exit !inet_pton(AF_INET6, $ARGV[0])' -- "$address"
}

_wan_ip_probe() (
    set -o pipefail
    local url address
    for url in https://ifconfig.me https://icanhazip.com; do
        if address=$(curl -q -f -s --max-time 2 --proto =https --max-filesize 64 "$url" |
            perl -MSocket=AF_INET,AF_INET6,inet_pton -e '
                my $ip = "";
                while (length($ip) < 65) {
                    defined(my $size = sysread(STDIN, my $chunk, 65 - length($ip))) or exit 1;
                    last unless $size;
                    $ip .= $chunk;
                }
                exit 1 unless length($ip) && length($ip) <= 64;
                $ip =~ s/\r?\n\z//;
                exit 1 if $ip =~ /[\x00\r\n]/;
                exit 1 unless inet_pton(AF_INET, $ip) || inet_pton(AF_INET6, $ip);
                print $ip;
            '); then
            printf '%s\n' "$address"
            return 0
        fi
    done
    return 1
)

_network_local_probe() {
    local os="$1" show_lan="$2" show_ssid="$3" lan_ip="" ssid=""

    # Get LAN IP
    if [ "$show_lan" = "true" ]; then
        local addresses
        if [ "$os" = darwin ]; then
            lan_ip=$(ipconfig getifaddr en0 2>/dev/null) ||
                lan_ip=$(ipconfig getifaddr en1 2>/dev/null) || lan_ip=""
        else
            if addresses=$(hostname -I 2>/dev/null); then
                while IFS=$' \t' read -r lan_ip _; do
                    [ -z "$lan_ip" ] || break
                done <<< "$addresses"
            fi
        fi
        _network_ip "$lan_ip" || lan_ip=""
    fi

    # Get WiFi SSID (macOS). The legacy `airport` CLI was removed in Sonoma+;
    # prefer networksetup / ipconfig getsummary, fall back to airport if present.
    # Capture the full SSID (spaces allowed) — never awk $2 only.
    if [ "$show_ssid" = "true" ] && [ "$os" = darwin ]; then
        local wifi_dev line airport
        wifi_dev=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
        wifi_dev="${wifi_dev:-en0}"

        line=$(networksetup -getairportnetwork "$wifi_dev" 2>/dev/null) || line=""
        case "$line" in
            "Current Wi-Fi Network: "*)
                ssid="${line#Current Wi-Fi Network: }"
                ;;
        esac

        if [ -z "$ssid" ]; then
            if line=$(ipconfig getsummary "$wifi_dev" 2>/dev/null); then
                ssid=$(printf '%s\n' "$line" | sed -n 's/^  SSID : //p' | head -1)
            fi
        fi

        if [ -z "$ssid" ]; then
            for airport in \
                /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport \
                /System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport; do
                if [ -x "$airport" ]; then
                    # Full field after ": " — multi-word SSIDs
                    if line=$("$airport" -I 2>/dev/null); then
                        ssid=$(printf '%s\n' "$line" | sed -n 's/^ *SSID: //p' | head -1)
                    fi
                    break
                fi
            done
        fi

        case "$ssid" in *[[:cntrl:]]*) ssid="" ;; esac
    fi

    [ -n "$lan_ip$ssid" ] || return 1
    if [ "$show_lan" = true ] && [ "$show_ssid" = true ]; then
        printf '%s|%s\n' "$lan_ip" "$ssid"
    else
        printf '%s\n' "$lan_ip$ssid"
    fi
}

module_network() {
    get_icon_reply "${NETWORK_ICON:-🌐}" "NET:"
    local icon="$REPLY"
    local show_lan="${NETWORK_SHOW_LAN:-true}"
    local show_wan="${NETWORK_SHOW_WAN:-false}"
    local wan_redact="${NETWORK_WAN_REDACT:-true}"
    local show_ssid="${NETWORK_SHOW_SSID:-false}"
    local compact="${NETWORK_COMPACT:-false}"

    # Each enabled part without a reading keeps its place as "--" (#74); a
    # segment with no reading at all shows a single "--".
    local parts=""
    local attempted=false
    local have_reading=false

    if [ "$show_lan" = true ] || [ "$show_ssid" = true ]; then
        attempted=true
        local os="${CORTADO_OS:-}"
        [ "$show_lan" = true ] || show_lan=false
        if [ "$show_ssid" != true ] || [ "$os" != darwin ]; then show_ssid=false; fi
        if [ "$show_lan" = true ] || [ "$show_ssid" = true ]; then
            local key="network-local-$show_lan-$show_ssid" lan ssid
            if [ "$show_lan" = true ] && [ "$show_ssid" = true ]; then
                key=network-local-v2-true-true
            fi
            cached_probe "$key" 10 5 "${BASH_SOURCE[0]}" _network_local_probe "$os" "$show_lan" "$show_ssid"
            if [ "$show_lan" = true ]; then
                lan="$REPLY"
                if [ "$show_ssid" = true ]; then lan=${lan%%|*}; fi
                if _network_ip "$lan"; then
                    parts="$lan"
                    have_reading=true
                else
                    parts=--
                fi
                if [ "$show_ssid" = true ] && [[ "$REPLY" = *'|'* ]]; then
                    ssid=${REPLY#*|}
                    if [ -n "$ssid" ] && [[ "$ssid" != *[[:cntrl:]]* ]]; then
                        parts="$parts ($ssid)"
                        have_reading=true
                    fi
                fi
            elif [ -n "$REPLY" ] && [[ "$REPLY" != *[[:cntrl:]]* ]]; then
                parts="$REPLY"
                have_reading=true
            fi
        fi
    fi

    # WAN lookup is opt-in because it contacts a third-party service.
    if [ "$show_wan" = "true" ] && ! is_compact "$compact"; then
        attempted=true
        cached_probe network_wan 300 15 "${BASH_SOURCE[0]}" _wan_ip_probe
        local wan_ip="$REPLY" first rest
        if ! _network_ip "$wan_ip"; then
            wan_ip=--
        elif [ "$wan_redact" = true ]; then
            case "$wan_ip" in
                *:*)
                    first=${wan_ip%%:*}
                    rest=${wan_ip#*:}
                    wan_ip="$first:${rest%%:*}:xxxx:xxxx" ;;
                *.*)
                    first=${wan_ip%%.*}
                    rest=${wan_ip#*.}
                    wan_ip="$first.${rest%%.*}.xxx.xxx" ;;
            esac
        fi
        [ "$wan_ip" = -- ] || have_reading=true
        if [ -n "$parts" ]; then
            parts="$parts | $wan_ip"
        else
            parts="$wan_ip"
        fi
    fi

    if [ "$have_reading" = true ]; then
        echo "$icon $parts"
    elif [ "$attempted" = true ]; then
        echo "$icon --"
    fi
}
