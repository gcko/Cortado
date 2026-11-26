#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" memory

RENDER_OS=Darwin
cat > "$TEST_BASE/bin/vm_stat" <<'STUB'
#!/bin/bash
case "$TEST_SAMPLE" in
    normal|zero|bad-total|bad-page|oversized|partial|failed-snapshot|failed-size)
        page_size=4096
        [ "$TEST_SAMPLE" != bad-page ] || page_size=0
        printf '%s\n' "Mach Virtual Memory Statistics: (page size of $page_size bytes)" 'Pages free: 80.'
        case "$TEST_SAMPLE" in
            zero|bad-total) printf '%s\n' 'Pages active: 0.' 'Pages wired down: 0.' ;;
            oversized) printf '%s\n' 'Pages active: 999999999999.' 'Pages wired down: 10.' ;;
            partial) printf '%s\n' 'Pages active: 10.' ;;
            *) printf '%s\n' 'Pages active: 10.' 'Pages wired down: 10.' ;;
        esac
        [ "$TEST_SAMPLE" != failed-snapshot ]
        ;;
    *) exit 1 ;;
esac
STUB
cat > "$TEST_BASE/bin/sysctl" <<'STUB'
#!/bin/bash
[ "$*" = '-n hw.memsize' ] || exit 2
if [ "$TEST_SAMPLE" = bad-total ]; then
    printf '%s\n' 0
else
    printf '%s\n' 327680
fi
[ "$TEST_SAMPLE" != failed-size ]
STUB
chmod 700 "$TEST_BASE/bin/vm_stat" "$TEST_BASE/bin/sysctl"

check_render 'memory uses the page size and both counters from vm_stat' 'MEM: 25% [OK]' normal
check_render 'memory shows a measured zero' 'MEM: 0% [OK]' zero
check_render 'memory shows absence when vm_stat fails' 'MEM: --' failed
check_render 'memory ignores a complete snapshot from a failed tool' 'MEM: --' failed-snapshot
check_render 'memory shows absence for a partial snapshot' 'MEM: --' partial
check_render 'memory shows absence for a zero hardware total' 'MEM: --' bad-total
check_render 'memory shows absence for a zero page size' 'MEM: --' bad-page
check_render 'memory ignores a size from a failed sysctl' 'MEM: --' failed-size
check_render 'memory shows absence when counted pages exceed physical memory' 'MEM: --' oversized

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
