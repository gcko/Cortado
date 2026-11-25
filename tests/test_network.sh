#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" network

RENDER_OS=Linux
cat > "$TEST_BASE/bin/hostname" <<'STUB'
#!/bin/bash
[ "$*" = "-I" ] || exit 2
[ "$TEST_SAMPLE" = normal ] || exit 1
printf '%s\n' '192.0.2.8 192.0.2.9'
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

check_render 'network shows LAN and redacted WAN readings' 'NET: 192.0.2.8 | 203.0.xxx.xxx' \
    normal '' 'NETWORK_SHOW_WAN="true"'
check_render_gap 'network shows absence when LAN and WAN lookups fail' 'NET: --' '' \
    failed '' 'NETWORK_SHOW_WAN="true"'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
