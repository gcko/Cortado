#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" network

RENDER_OS=linux
cat > "$TEST_BASE/bin/hostname" <<'STUB'
#!/bin/bash
[ "$*" = "-I" ] || exit 2
case "$TEST_SAMPLE" in
    bad-lan) printf '%s\n' not-an-ip ;;
    bad-v4) printf '%s\n' 999.0.0.7 ;;
    bad-v6) printf '%s\n' 1234:::abcd ;;
    normal|partial|lan-only) printf '%s\n' '192.0.2.8 192.0.2.9' ;;
esac
[[ "$TEST_SAMPLE" != failed && "$TEST_SAMPLE" != partial ]]
STUB
chmod +x "$TEST_BASE/bin/hostname"
cat > "$TEST_BASE/bin/curl" <<'STUB'
#!/bin/bash
case "${!#}" in
    https://ifconfig.me|https://icanhazip.com) ;;
    *) exit 2 ;;
esac
[ "$TEST_SAMPLE" = normal ] || exit 1
printf '%s\n' 203.0.113.9
STUB
chmod +x "$TEST_BASE/bin/curl"

# A cold render schedules the probe. Observe its result in the same cache.
check_probe() {
    local desc="$1" expected="$2" sample="$3" keys="$4" sb i key
    shift 4
    sb=$(mktemp -d "$TEST_BASE/probe.XXXXXX") || exit 1
    RENDER_CONFIG_DIR="$sb" render "$sample" '' "$@" >/dev/null || { fail "$desc (cold render failed)"; return; }
    for key in $keys; do
        for ((i=0; i<60; i++)); do
            if [ -s "$sb/cortado-cache/$key" ] || [ -s "$sb/cortado-cache/$key-failed" ]; then break; fi
            sleep 0.05
        done
        [ "$i" -lt 60 ] || { fail "$desc ($key did not publish)"; return; }
    done
    RENDER_CONFIG_DIR="$sb" check_render "$desc" "$expected" "$sample" '' "$@"
}

check_probe 'network shows LAN and redacted WAN readings' 'NET: 192.0.2.8 | 203.0.xxx.xxx' \
    normal 'network-local-true-false network_wan' 'NETWORK_SHOW_WAN="true"'
check_probe 'network shows absence when LAN and WAN lookups fail' 'NET: --' \
    failed 'network-local-true-false network_wan' 'NETWORK_SHOW_WAN="true"'
check_probe 'network marks missing WAN beside a valid LAN address' 'NET: 192.0.2.8 | --' \
    lan-only 'network-local-true-false network_wan' 'NETWORK_SHOW_WAN="true"'
check_probe 'network ignores an address from a failed LAN lookup' 'NET: --' partial 'network-local-true-false'
check_render 'network shows absence when only SSID is requested on Linux' 'NET: --' \
    normal '' 'NETWORK_SHOW_LAN=false' 'NETWORK_SHOW_SSID=true'
check_probe 'network keeps the LAN address when SSID is unavailable on Linux' 'NET: 192.0.2.8' \
    normal 'network-local-true-false' 'NETWORK_SHOW_SSID=true'
check_render 'network is empty when every field is disabled' '' \
    normal '' 'NETWORK_SHOW_LAN=false' 'NETWORK_SHOW_WAN=false' 'NETWORK_SHOW_SSID=false'

check_probe 'a malformed LAN tool response shows absence' 'NET: --' bad-lan 'network-local-true-false'
check_probe 'an out-of-range IPv4 LAN address shows absence' 'NET: --' bad-v4 'network-local-true-false'
check_probe 'a malformed IPv6 LAN address shows absence' 'NET: --' bad-v6 'network-local-true-false'
sb=$(mktemp -d "$TEST_BASE/corrupt.XXXXXX") || exit 1
mkdir -m 700 "$sb/cortado-cache"
(umask 077; printf '%s\n' not-an-ip > "$sb/cortado-cache/network-local-true-false"
printf '%s\n' '403:error' > "$sb/cortado-cache/network_wan")
RENDER_CONFIG_DIR="$sb" check_render 'a malformed LAN cache shows absence' 'NET: --' failed ''
for redact in true false; do
    RENDER_CONFIG_DIR="$sb" check_render "a malformed WAN cache shows absence (redact $redact)" 'NET: --' failed '' \
        'NETWORK_SHOW_LAN=false' 'NETWORK_SHOW_WAN=true' "NETWORK_WAN_REDACT=$redact"
done
for address in 999.0.0.7 1234:::abcd; do
    (umask 077; printf '%s\n' "$address" > "$sb/cortado-cache/network-local-true-false"
    printf '%s\n' "$address" > "$sb/cortado-cache/network_wan")
    RENDER_CONFIG_DIR="$sb" check_render "a cached address $address shows absence" 'NET: --' failed '' \
        'NETWORK_SHOW_WAN=true' 'NETWORK_WAN_REDACT=false'
done
(umask 077; printf '%s\n' '2001:db8::1' > "$sb/cortado-cache/network_wan")
RENDER_CONFIG_DIR="$sb" check_render 'a valid IPv6 cache can display in full' 'NET: 2001:db8::1' failed '' \
    'NETWORK_SHOW_LAN=false' 'NETWORK_SHOW_WAN=true' 'NETWORK_WAN_REDACT=false'
RENDER_OS=darwin
(umask 077; printf '%s\n' '192.0.2.9|Private Wi-Fi' > "$sb/cortado-cache/network-local-v2-true-true")
RENDER_CONFIG_DIR="$sb" check_render 'a valid LAN and multi-word SSID both display' 'NET: 192.0.2.9 (Private Wi-Fi)' failed '' \
    'NETWORK_SHOW_SSID=true'
for ssid in $'Cafe\rNet' $'\033[31mCafe'; do
    (umask 077; printf '%s|%s\n' 192.0.2.9 "$ssid" > "$sb/cortado-cache/network-local-v2-true-true")
    RENDER_CONFIG_DIR="$sb" check_render "a cached Wi-Fi name with a control character is dropped ($(printf '%q' "$ssid"))" \
        'NET: 192.0.2.9' failed '' 'NETWORK_SHOW_SSID=true'
done

# The macOS probe drops a Wi-Fi name with a control character before caching it.
cat > "$TEST_BASE/bin/ipconfig" <<'STUB'
#!/bin/bash
[ "$*" = 'getifaddr en0' ] || exit 1
printf '%s\n' 192.0.2.9
STUB
cat > "$TEST_BASE/bin/networksetup" <<'STUB'
#!/bin/bash
case "$*" in
    -listallhardwareports) printf '%s\n' 'Hardware Port: Wi-Fi' 'Device: en0' ;;
    '-getairportnetwork en0')
        case "$TEST_SAMPLE" in
            ssid-cr) printf 'Current Wi-Fi Network: Cafe\rNet\n' ;;
            ssid-esc) printf 'Current Wi-Fi Network: \033[31mCafe\n' ;;
        esac ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/ipconfig" "$TEST_BASE/bin/networksetup"
for sample in ssid-cr ssid-esc; do
    sb=$(mktemp -d "$TEST_BASE/ssid.XXXXXX") || exit 1
    RENDER_CONFIG_DIR="$sb" render "$sample" '' 'NETWORK_SHOW_SSID=true' >/dev/null
    for ((i=0; i<60; i++)); do
        [ ! -s "$sb/cortado-cache/network-local-v2-true-true" ] || break
        sleep 0.05
    done
    assert_eq "the probe caches no Wi-Fi name with a control character ($sample)" '192.0.2.9|' \
        "$(cat "$sb/cortado-cache/network-local-v2-true-true" 2>/dev/null)"
    RENDER_CONFIG_DIR="$sb" check_render "the LAN address still displays without the Wi-Fi name ($sample)" 'NET: 192.0.2.9' \
        "$sample" '' 'NETWORK_SHOW_SSID=true'
done
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
