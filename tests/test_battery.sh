#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" battery

RENDER_OS=darwin
cat > "$TEST_BASE/bin/pmset" <<'STUB'
#!/bin/bash
[ "$*" = "-g batt" ] || exit 2
case "$TEST_SAMPLE" in
    normal) percentage=64 ;;
    zero) percentage=0 ;;
    low) percentage=15 ;;
    malformed) printf '%s\n' 'battery: %'; exit 0 ;;
    *) exit 1 ;;
esac
printf "Now drawing from 'AC Power'\n -InternalBattery-0 %s%%; charging\n" "$percentage"
STUB
chmod +x "$TEST_BASE/bin/pmset"

check_render 'battery shows its measured charge and charging state' 'BAT: 64% ⚡' normal
check_render 'battery preserves a measured zero' 'CRIT: 0% ⚡' zero
# The parser refuses a mistyped int and says so (#33); only a config sourced
# under the opt-in still hands the module a non-numeric threshold to coerce.
check_render 'battery reports a mistyped low threshold and keeps the default' \
    'Config partly read: run cortado config --show | LOW: 15% ⚡' low '' 'BATTERY_LOW_THRESHOLD=20abc'
CORTADO_CONF_ALLOW_BASH=1 check_render 'battery coerces a non-numeric low threshold to its number' 'LOW: 15% ⚡' low '' \
    'BATTERY_LOW_THRESHOLD=20abc'
check_render 'battery shows absence when pmset fails' 'BAT: --' failed
check_render 'battery shows absence when the percentage is missing' 'BAT: --' malformed

# Exercise standalone module calls with the stdout wrapper disabled.
standalone=$(export PATH="$TEST_BASE/bin:$PATH" TEST_SAMPLE=zero USE_ICONS=false
    # shellcheck source=modules/utils.sh
    . "$PROJECT_ROOT/modules/utils.sh"
    # shellcheck source=modules/battery.sh
    . "$PROJECT_ROOT/modules/battery.sh"
    # Older ShellCheck (CI's Ubuntu) reports this indirectly called body as unreachable (SC2317).
    # shellcheck disable=SC2317,SC2329 # This replaces a helper called by the sourced module.
    safe_int() { return 1; }
    module_battery
)
assert_eq 'standalone battery uses the reply helper for critical charge' 'CRIT: 0% ⚡' "$standalone"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
