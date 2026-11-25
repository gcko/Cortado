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
    partial) printf '%s\n' '/dev/fixture 20G 15G 5G 75% /'; exit 1 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/df"

check_render 'disk shows measured usage and its warning' 'DISK: 75% [WARN]' normal
check_render 'disk shows absence when df fails' 'DISK: --' failed
check_render 'disk shows absence when df has no data row' 'DISK: --' header
check_render 'disk ignores rows printed by a failed df' 'DISK: --' partial
check_render 'disk preserves measured zero usage' 'DISK: 0% [OK]' zero

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
