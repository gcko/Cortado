#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" brightness

RENDER_OS=Darwin
cat > "$TEST_BASE/bin/brightness" <<'STUB'
#!/bin/bash
# Force the built-in ioreg fallback even when Homebrew brightness is installed.
if [ "$TEST_SAMPLE" = partial ]; then printf '%s\n' 'display 0: brightness 0.9'; fi
exit 1
STUB
chmod +x "$TEST_BASE/bin/brightness"
cat > "$TEST_BASE/bin/ioreg" <<'STUB'
#!/bin/bash
[ "$*" = "-l" ] || exit 2
case "$TEST_SAMPLE" in
    normal) value=32768 ;;
    zero) value=0 ;;
    *) exit 1 ;;
esac
printf '    "brightness"={"min"=0,"max"=65536,"value"=%s}\n' "$value"
STUB
chmod +x "$TEST_BASE/bin/ioreg"

check_render 'brightness shows the measured percentage' 'BRT: 50%' normal
check_render 'brightness preserves a measured zero' 'BRT: 0%' zero
check_render 'brightness shows absence when both probes fail' 'BRT: --' failed
check_render 'brightness ignores output from a failed probe' 'BRT: --' partial

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
