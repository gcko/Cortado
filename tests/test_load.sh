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
    normal)
        if [ "$LC_ALL" = C ]; then
            printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1.25 0.75 0.50'
        else
            printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1,25 0,75 0,50'
        fi ;;
    high) printf '%s\n' '10:00  up 1 day, 1 user, load averages: 16.00 12.00 10.00' ;;
    malformed) printf '%s\n' '10:00  up 1 day, 1 user, load averages: n/a' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/uptime"

check_render 'load shows the measured averages and status' 'LOAD: 1.25 0.75 0.50 [OK]' \
    normal '' 'LOAD_SHOW_ALL="true"'
check_render 'load shows absence when uptime fails' 'LOAD: --' failed '' 'LOAD_SHOW_ALL="true"'
check_render 'load shows absence for an unusable reading' 'LOAD: --' malformed
# POSIX is always available. The fixture uses commas for any caller locale other than C.
check_render 'load reads dot decimals independently of the caller locale' 'LOAD: 1.25 0.75 0.50 [OK]' \
    normal '' 'LOAD_SHOW_ALL=true' 'export LC_ALL=POSIX'
check_render 'load keeps the measured average when the status calculation fails' 'LOAD: 16.00' \
    high '' 'bc() { return 1; }'
check_render 'load omits status when bc succeeds without a usable number' 'LOAD: 16.00' \
    high '' 'bc() { printf "%s\n" unavailable; }'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
