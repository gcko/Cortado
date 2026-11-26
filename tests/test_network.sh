#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" network

RENDER_OS=Linux
cat > "$TEST_BASE/bin/hostname" <<'STUB'
#!/bin/bash
[ "$*" = "-I" ] || exit 2
case "$TEST_SAMPLE" in
    bad-lan) printf '%s\n' not-an-ip ;;
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
    render "$sample" '' "CLAUDE_CONFIG_DIR='$sb'" "$@" >/dev/null || { fail "$desc (cold render failed)"; return; }
    for key in $keys; do
        for ((i=0; i<60; i++)); do
            if [ -s "$sb/cortado-cache/$key" ] || [ -s "$sb/cortado-cache/$key-failed" ]; then break; fi
            sleep 0.05
        done
        [ "$i" -lt 60 ] || { fail "$desc ($key did not publish)"; return; }
    done
    check_render "$desc" "$expected" "$sample" '' "CLAUDE_CONFIG_DIR='$sb'" "$@"
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
sb=$(mktemp -d "$TEST_BASE/corrupt.XXXXXX") || exit 1
mkdir -m 700 "$sb/cortado-cache"
(umask 077; printf '%s\n' not-an-ip > "$sb/cortado-cache/network-local-true-false"
printf '%s\n' '403:error' > "$sb/cortado-cache/network_wan")
check_render 'a malformed LAN cache shows absence' 'NET: --' failed '' "CLAUDE_CONFIG_DIR='$sb'"
for redact in true false; do
    check_render "a malformed WAN cache shows absence (redact $redact)" 'NET: --' failed '' \
        "CLAUDE_CONFIG_DIR='$sb'" 'NETWORK_SHOW_LAN=false NETWORK_SHOW_WAN=true' "NETWORK_WAN_REDACT=$redact"
done
(umask 077; printf '%s\n' '2001:db8::1' > "$sb/cortado-cache/network_wan")
check_render 'a valid IPv6 cache can display in full' 'NET: 2001:db8::1' failed '' \
    "CLAUDE_CONFIG_DIR='$sb'" 'NETWORK_SHOW_LAN=false NETWORK_SHOW_WAN=true NETWORK_WAN_REDACT=false'
RENDER_OS=Darwin
(umask 077; printf '%s\n' '192.0.2.9|Private Wi-Fi' > "$sb/cortado-cache/network-local-v2-true-true")
check_render 'a valid LAN and multi-word SSID both display' 'NET: 192.0.2.9 (Private Wi-Fi)' failed '' \
    "CLAUDE_CONFIG_DIR='$sb'" 'NETWORK_SHOW_SSID=true'
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
