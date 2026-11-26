#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" time

cat > "$TEST_BASE/bin/date" <<'STUB'
#!/bin/bash
case "$*" in
    '+%m/%d'|'+%I:%M %p'|'+%m/%d %I:%M %p') ;;
    *) exec /bin/date "$@" ;;
esac
case "$TEST_SAMPLE:$*" in
    normal:*|date-only:+%m/%d) ;;
    empty:*) exit 0 ;;
    *) exit 1 ;;
esac
case "$*" in
    '+%m/%d') printf '%s\n' 11/25 ;;
    '+%I:%M %p') printf '%s\n' '09:42 AM' ;;
    '+%m/%d %I:%M %p') printf '%s\n' '11/25 09:42 AM' ;;
esac
STUB
chmod +x "$TEST_BASE/bin/date"

check_render 'time shows the measured date and clock' 'DATE: 11/25 TIME: 09:42 AM' normal
check_render 'time shows absence when both date reads fail' 'DATE: -- TIME: --' failed
check_render 'time keeps the date when the clock is unavailable' 'DATE: 11/25 TIME: --' date-only
check_render 'time shows absence when date returns empty output' 'DATE: -- TIME: --' empty
check_render 'time shows one placeholder for a failed compact clock' 'TIME: --' failed '' 'TIME_COMPACT=true'

check_render 'time keeps the rendered label for an echo-style icon' ' 11/25' normal '' \
    'COLOR_THEME=default' 'LAYOUT_MODE=none' 'TIME_DATE_ICON=-n' 'TIME_SHOW_TIME=false'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
