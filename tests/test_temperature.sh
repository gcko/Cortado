#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" temperature

RENDER_OS=Darwin
cat > "$TEST_BASE/bin/osx-cpu-temp" <<'STUB'
#!/bin/bash
case "$TEST_SAMPLE" in
    normal) printf '%s\n' '72.5°C' ;;
    malformed) printf '%s\n' '.°C' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/osx-cpu-temp"

check_render 'temperature shows the measured reading and warning' 'TEMP: 72°C [WARN]' normal
check_render 'temperature shows absence when its probe fails' 'TEMP: --' failed
check_render 'temperature shows absence for an unusable reading' 'TEMP: --' malformed

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
