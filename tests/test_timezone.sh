#!/bin/bash
# Render timezone clocks from controlled date output.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" timezone

touch "$TEST_BASE/AAA" "$TEST_BASE/BBB"
PAYLOAD=$(jq -cn --arg dir "$TEST_BASE" '{workspace:{current_dir:$dir}}') || exit 1
cat > "$TEST_BASE/bin/date" <<'STUB'
#!/bin/bash
[ "$*" = '+%H:%M' ] || exec /bin/date "$@"
[ "$TEST_SAMPLE" != failed ] || exit 1
case "$TZ" in
    UTC|'*') printf '%s\n' '09:42' ;;
    Asia/Tokyo) printf '%s\n' '18:42' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/date"

check_render 'a wildcard zone renders literally without expanding filenames' 'UTC: 09:42 | *: 09:42' \
    normal "$PAYLOAD" 'TIMEZONE_ZONES="UTC,*"'
check_render 'two named zones render their measured clocks in order' 'UTC: 09:42 | TOK: 18:42' \
    normal "$PAYLOAD" 'TIMEZONE_ZONES="UTC, Asia/Tokyo"'
check_render 'a wildcard custom label stays literal' '*: 09:42 | Tokyo: 18:42' \
    normal "$PAYLOAD" 'TIMEZONE_ZONES="UTC, Asia/Tokyo"' 'TIMEZONE_LABELS="*,Tokyo"'
check_render 'blank zones and omitted labels preserve clock order' 'UTC: 09:42 | Tokyo: 18:42' \
    normal "$PAYLOAD" 'TIMEZONE_ZONES=", UTC, , Asia/Tokyo, "' 'TIMEZONE_LABELS=",Tokyo"'
check_render 'timezone shows absence when its clock fails' 'UTC: --' failed "$PAYLOAD" 'TIMEZONE_ZONES="UTC"'
check_render 'timezone keeps labels aligned when the first clock fails' 'Local: -- | Tokyo: 18:42' \
    normal "$PAYLOAD" 'TIMEZONE_ZONES="Missing, Asia/Tokyo"' 'TIMEZONE_LABELS="Local,Tokyo"'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
