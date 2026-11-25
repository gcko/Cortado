#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" time

cat > "$TEST_BASE/bin/date" <<'STUB'
#!/bin/bash
case "$*" in
    '+%m/%d'|'+%I:%M %p') ;;
    *) exec /bin/date "$@" ;;
esac
[ "$TEST_SAMPLE" = normal ] || exit 1
case "$*" in
    '+%m/%d') printf '%s\n' 11/25 ;;
    '+%I:%M %p') printf '%s\n' '09:42 AM' ;;
esac
STUB
chmod +x "$TEST_BASE/bin/date"

check_render 'time shows the measured date and clock' 'DATE: 11/25 TIME: 09:42 AM' normal
check_render_gap 'time shows absence when both date reads fail' 'DATE: -- TIME: --' 'DATE:  TIME: ' failed

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
