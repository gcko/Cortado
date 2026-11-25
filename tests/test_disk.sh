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
if [ "$TEST_SAMPLE" = normal ]; then
    printf '%s\n' '/dev/fixture 20G 15G 5G 75% /'
fi
STUB
chmod +x "$TEST_BASE/bin/df"

check_render 'disk shows measured usage and its warning' 'DISK: 75% [WARN]' normal
check_render_gap 'disk shows absence when df fails' 'DISK: --' '' failed
check_render_gap 'disk shows absence when df has no data row' 'DISK: --' 'DISK: Capacity% [OK]' header

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
