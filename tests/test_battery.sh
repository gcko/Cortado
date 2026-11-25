#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" battery

RENDER_OS=Darwin
cat > "$TEST_BASE/bin/pmset" <<'STUB'
#!/bin/bash
[ "$*" = "-g batt" ] || exit 2
case "$TEST_SAMPLE" in
    normal) percentage=64 ;;
    zero) percentage=0 ;;
    *) exit 1 ;;
esac
printf "Now drawing from 'AC Power'\n -InternalBattery-0 %s%%; charging\n" "$percentage"
STUB
chmod +x "$TEST_BASE/bin/pmset"

check_render 'battery shows its measured charge and charging state' 'BAT: 64% ⚡' normal
check_render 'battery preserves a measured zero' 'CRIT: 0% ⚡' zero
check_render_gap 'battery shows absence when pmset fails' 'BAT: --' '' failed

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
