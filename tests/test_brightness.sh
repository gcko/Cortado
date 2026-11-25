#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" brightness

RENDER_OS=Darwin
cat > "$TEST_BASE/bin/brightness" <<'STUB'
#!/bin/bash
# Force the built-in ioreg fallback except for the fractional CLI fixture.
case "$TEST_SAMPLE" in
    fraction) printf '%s\n' 'display 0: brightness 0.500000'; exit 0 ;;
    partial) printf '%s\n' 'display 0: brightness 0.9' ;;
esac
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
check_render 'brightness rounds a fractional CLI reading' 'BRT: 50%' fraction
comma_locale=$(locale -a | awk 'tolower($0) ~ /^de_de\.utf-?8$/ {print; exit}')
if [ -n "$comma_locale" ]; then
    check_render 'brightness rounds a fractional CLI reading in a comma-decimal locale' \
        'BRT: 50%' fraction '' "export LC_ALL=$comma_locale"
fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
