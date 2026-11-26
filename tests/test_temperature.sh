#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" temperature

RENDER_OS=darwin
cat > "$TEST_BASE/bin/osx-cpu-temp" <<'STUB'
#!/bin/bash
case "$TEST_SAMPLE" in
    normal) printf '%s\n' '72.5°C' ;;
    zero) printf '%s\n' '0.0°C' ;;
    hot) printf '%s\n' '90.0°C' ;;
    diagnostic) printf '%s\n' 'sensor 0: unavailable' ;;
    malformed) printf '%s\n' '.°C' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/osx-cpu-temp"

check_render 'temperature shows the measured reading and warning' 'TEMP: 72°C [WARN]' normal
check_render 'temperature shows absence when its probe fails' 'TEMP: --' failed
check_render 'temperature shows absence for an unusable reading' 'TEMP: --' malformed
check_render 'temperature rejects a sensor diagnostic containing a number' 'TEMP: --' diagnostic
check_render 'temperature preserves a measured zero' 'TEMP: 0°C [OK]' zero
comma_locale=$(locale -a | awk 'tolower($0) ~ /^de_de\.utf-?8$/ {print; exit}')
if [ -n "$comma_locale" ]; then
    check_render 'temperature rounds a fractional Celsius reading in a comma-decimal locale' \
        'TEMP: 72°C [WARN]' normal '' "export LC_ALL=$comma_locale"
fi
check_render 'temperature shows the converted Fahrenheit reading and status' 'TEMP: 194°F [CRIT]' \
    hot '' 'TEMP_UNITS=F'
check_render 'temperature shows absence when Fahrenheit conversion fails' 'TEMP: --' \
    hot '' 'TEMP_UNITS=F' 'bc() { return 1; }'
# The variables expand inside the sandbox config's bc function.
# shellcheck disable=SC2016
check_render 'temperature keeps Fahrenheit when a status threshold conversion fails' 'TEMP: 194°F' \
    hot '' 'TEMP_UNITS=F' 'bc() {
        local calculation
        IFS= read -r calculation
        case "$calculation" in *"(70 "*) return 1 ;; esac
        printf "%s\n" "$calculation" | command bc "$@"
    }'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
