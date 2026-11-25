#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" disk

cat > "$TEST_BASE/bin/df" <<'STUB'
#!/bin/bash
case "$*" in
    '-h -- /'|'-h /') ;;
    *) exit 2 ;;
esac
[ "$TEST_SAMPLE" != failed ] || exit 1
printf '%s\n' 'Filesystem Size Used Avail Capacity Mounted on'
case "$TEST_SAMPLE" in
    normal) printf '%s\n' '/dev/fixture 20G 15G 5G 75% /' ;;
    zero) printf '%s\n' '/dev/fixture 20G 0G 20G 0% /' ;;
    no-capacity) printf '%s\n' 'proc 0 0 0 - /proc' ;;
    no-free) printf '%s\n' '/dev/fixture 20G 15G - 75% /' ;;
    partial) printf '%s\n' '/dev/fixture 20G 15G 5G 75% /'; exit 1 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/df"

check_render 'disk shows measured usage and its warning' 'DISK: 75% [WARN]' normal
check_render 'disk shows absence when df fails' 'DISK: --' failed
check_render 'disk shows absence when df has no data row' 'DISK: --' header
check_render 'disk ignores rows printed by a failed df' 'DISK: --' partial
check_render 'disk preserves measured zero usage' 'DISK: 0% [OK]' zero
check_render 'disk preserves measured zero free space without capacity or status' 'DISK: 0 free' \
    no-capacity '' 'DISK_SHOW_FREE=true' 'DISK_SHOW_STATUS=false'
check_render 'disk preserves measured zero free space and omits unknown status' 'DISK: 0 free' \
    no-capacity '' 'DISK_SHOW_FREE=true' 'DISK_SHOW_STATUS=true'
check_render 'disk shows absence when the requested percentage is unknown' 'DISK: --' no-capacity
check_render 'disk can show a percentage without a free-space reading' 'DISK: 75% [WARN]' no-free
check_render 'disk shows absence when the requested free space is unknown' 'DISK: --' \
    no-free '' 'DISK_SHOW_FREE=true'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
