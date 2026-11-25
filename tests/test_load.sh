#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" load

RENDER_OS=Darwin
cat > "$TEST_BASE/bin/sysctl" <<'STUB'
#!/bin/bash
[ "$*" = "-n hw.ncpu" ] || exit 2
printf '%s\n' 4
STUB
chmod +x "$TEST_BASE/bin/sysctl"
cat > "$TEST_BASE/bin/uptime" <<'STUB'
#!/bin/bash
case "$TEST_SAMPLE" in
    normal) printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1.25 0.75 0.50' ;;
    malformed) printf '%s\n' '10:00  up 1 day, 1 user, load averages: n/a' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/uptime"

check_render 'load shows the measured averages and status' 'LOAD: 1.25 0.75 0.50 [OK]' \
    normal '' 'LOAD_SHOW_ALL="true"'
check_render 'load shows absence when uptime fails' 'LOAD: --' failed '' 'LOAD_SHOW_ALL="true"'
check_render 'load shows absence for an unusable reading' 'LOAD: --' malformed

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
