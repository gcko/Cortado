#!/bin/bash
# =============================================================================
# Rate Limits From The Statusline Payload
# =============================================================================
# Claude Code (2.1.330 and later, observed 2026-11-22) sends the account's rate
# limits in the statusline payload after the first turn of a session:
#   rate_limits.five_hour.used_percentage / resets_at (Unix seconds)
#   rate_limits.seven_day.used_percentage / resets_at
# These tests drive cortado.sh the way Claude Code does, in a sandbox with no
# credential file (the usual state on macOS, where the login lives in the
# Keychain), and assert what the rate-limit segment says.
# Usage: bash tests/test_rate_limits_payload.sh
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *) fail "$desc (missing [$needle] in [$haystack])" ;;
    esac
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) fail "$desc (unexpected [$needle] in [$haystack])" ;;
        *) pass "$desc" ;;
    esac
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc (expected [$expected] got [$actual])"
    fi
}

TEST_BASE="$(mktemp -d "${TMPDIR:-/tmp}/cortado-payload-test.XXXXXX")"
trap 'rm -rf "$TEST_BASE"' EXIT

# sandbox <name>: a fresh CLAUDE_CONFIG_DIR with only the rate-limits module on.
sandbox() {
    local sb="$TEST_BASE/$1"
    mkdir -p "$sb/cortado-cache"
    chmod 700 "$sb/cortado-cache"
    printf '%s\n' 'MODULE_ORDER="rate-limits"' 'MODULE_RATE_LIMITS="true"' \
        'COLOR_THEME="monochrome"' 'RATE_SHOW_USAGE_STATUS="false"' > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf"
    echo "$sb"
}

# render <sandbox> <payload>
render() {
    printf '%s' "$2" | CLAUDE_CONFIG_DIR="$1" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1
}

NOW=$(date +%s)
RESET_5H=$((NOW + 7200))
RESET_7D=$((NOW + 3 * 86400))
WITH_LIMITS=$(printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":65,"resets_at":%s},"seven_day":{"used_percentage":32,"resets_at":%s}}}' "$RESET_5H" "$RESET_7D")
NO_LIMITS='{"model":{"display_name":"Opus"}}'

if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/jq ]; then
    echo "=== bundled jq uses live readings with or without cache ==="
    sb=$(sandbox bundled-jq)
    mkdir "$TEST_BASE/bundled-bin"
    ln -s /usr/bin/jq "$TEST_BASE/bundled-bin/jq"
    bundled_payload='{"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":65}}}'
    out=$(PATH="$TEST_BASE/bundled-bin:$PATH" render "$sb" "$bundled_payload")
    assert_eq "bundled jq renders 42/65 with an empty cache" "5h:42% 7d:65%" "$out"
    printf '%s\n' '{"five_hour":{"utilization":1},"seven_day":{"utilization":2}}' +        > "$sb/cortado-cache/rate_limits_usage"
    out=$(PATH="$TEST_BASE/bundled-bin:$PATH" render "$sb" "$bundled_payload")
    assert_eq "bundled jq prefers 42/65 over cached 1/2" "5h:42% 7d:65%" "$out"
fi

echo "=== a payload with rate limits is shown without any credential ==="

sb=$(sandbox shown)
out=$(render "$sb" "$WITH_LIMITS")
assert_contains "the five-hour window shows the payload's percentage" "5h:65%" "$out"
assert_contains "the seven-day window shows the payload's percentage" "7d:32%" "$out"
assert_not_contains "a payload reading is not a placeholder" "5h:--" "$out"
re_5h='5h:65% +\([12]h [0-9]+m\)'
re_7d='7d:32% +\([23]d [0-9]+h\)'
if [[ "$out" =~ $re_5h ]]; then pass "the five-hour reset counts down from the payload's resets_at"
else fail "the five-hour reset counts down from the payload's resets_at (got [$out])"; fi
if [[ "$out" =~ $re_7d ]]; then pass "the seven-day reset counts down from the payload's resets_at"
else fail "the seven-day reset counts down from the payload's resets_at (got [$out])"; fi

echo ""
echo "=== no rate limits in the payload keeps the stated absence ==="

sb=$(sandbox absent)
out=$(render "$sb" "$NO_LIMITS")
assert_contains "a session before its first turn shows the placeholder" "5h:-- 7d:--" "$out"

sb=$(sandbox partial)
out=$(render "$sb" '{"rate_limits":{"five_hour":{"used_percentage":65,"resets_at":1}}}')
assert_contains "a payload with only one window falls back to the placeholder" "5h:-- 7d:--" "$out"

sb=$(sandbox nonnumeric)
out=$(render "$sb" '{"rate_limits":{"five_hour":{"used_percentage":null,"resets_at":1},"seven_day":{"used_percentage":"32","resets_at":1}}}')
assert_contains "a non-numeric percentage is not rendered as a reading" "5h:-- 7d:--" "$out"
assert_not_contains "a null percentage is not rendered as zero" "5h:0%" "$out"

echo ""
echo "=== the payload is current, so it beats older state on disk ==="

sb=$(sandbox beats-cache)
printf '{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2099-01-01T00:00:00Z"}}' \
    > "$sb/cortado-cache/rate_limits_usage"
out=$(render "$sb" "$WITH_LIMITS")
assert_contains "the payload's reading wins over a cached API reading" "5h:65%" "$out"
assert_not_contains "the cached reading is not shown" "5h:42%" "$out"

sb=$(sandbox no-cooldown)
echo 300 > "$sb/cortado-cache/rate_limits_backoff"
out=$(render "$sb" "$WITH_LIMITS")
assert_contains "a 429 backoff does not hide a payload reading" "5h:65%" "$out"
assert_not_contains "a payload reading carries no API cooldown marker" "WAIT" "$out"

echo ""
echo "=== a payload reading does not become tomorrow's stale fallback ==="

sb=$(sandbox no-fallback)
render "$sb" "$WITH_LIMITS" >/dev/null
out=$(render "$sb" "$NO_LIMITS")
assert_contains "the next session's start still shows the placeholder" "5h:-- 7d:--" "$out"
assert_not_contains "the previous payload reading is not replayed as current" "5h:65%" "$out"

echo ""
echo "=== projections get one history point per cache interval ==="

sb=$(sandbox history)
render "$sb" "$WITH_LIMITS" >/dev/null
render "$sb" "$WITH_LIMITS" >/dev/null
render "$sb" "$WITH_LIMITS" >/dev/null
lines=$(wc -l < "$sb/.usage_history" 2>/dev/null | tr -d ' ')
assert_eq "three renders inside one cache interval record one history point" "1" "${lines:-0}"
assert_contains "the history point carries the payload's percentages" ",65,32," "$(cat "$sb/.usage_history" 2>/dev/null)"

echo ""
echo "=== a malformed reset time cannot corrupt the history file ==="

sb=$(sandbox bad-reset)
BAD='{"rate_limits":{"five_hour":{"used_percentage":65,"resets_at":"x,1,2\\n9,9"},"seven_day":{"used_percentage":32,"resets_at":"2099-01-01T00:00:00Z"}}}'
out=$(render "$sb" "$BAD")
assert_contains "a reading with a malformed reset time still shows its percentage" "5h:65%" "$out"
fields=$(awk -F',' '{print NF}' "$sb/.usage_history" 2>/dev/null | sort -u | tr '\n' ' ')
assert_eq "every history line keeps its five fields" "5 " "$fields"
lines=$(wc -l < "$sb/.usage_history" 2>/dev/null | tr -d ' ')
assert_eq "a malformed reset time adds one history line, not several" "1" "${lines:-0}"

echo ""
echo "=== missing percentages leave the sibling reading visible ==="

sb=$(sandbox no-payload-readings)
both_null='{"rate_limits":{"five_hour":{"used_percentage":null},"seven_day":{"used_percentage":null}}}'
null_missing='{"rate_limits":{"five_hour":{"used_percentage":null},"seven_day":{}}}'
zero_null='{"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":null}}}'
assert_eq "both-null quota without a fallback shows absence" "5h:-- 7d:--" "$(render "$sb" "$both_null")"
printf '%s\n' '{"five_hour":{"utilization":42},"seven_day":{"utilization":10}}' \
    > "$sb/cortado-cache/rate_limits_usage"
assert_eq "both-null quota uses cached readings" "5h:42% 7d:10%" "$(render "$sb" "$both_null")"
assert_eq "null and missing quota use cached readings" "5h:42% 7d:10%" "$(render "$sb" "$null_missing")"
assert_eq "a payload with one measured zero is used without merging sources" "5h:0% 7d:--" "$(render "$sb" "$zero_null")"

sb=$(sandbox missing-utilization)
printf '%s\n' 'RATE_SHOW_TIME_REMAINING="false"' 'RATE_SHOW_PROGRESS_BAR="false"' \
    >> "$sb/cortado.conf"
out=$(render "$sb" '{"rate_limits":{"five_hour":{},"seven_day":{"used_percentage":42}}}')
assert_eq "a missing payload percentage leaves the other window visible" "5h:-- 7d:42%" "$out"
out=$(render "$sb" '{"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":null}}}')
assert_eq "payload zero stays zero while a null sibling shows absence" "5h:0% 7d:--" "$out"
assert_eq "partial payloads do not invent history values" "" "$(cat "$sb/.usage_history" 2>/dev/null)"

printf '%s\n' '{"five_hour":{},"seven_day":{"utilization":42}}' > "$sb/cortado-cache/rate_limits_usage"
out=$(render "$sb" "$NO_LIMITS")
assert_eq "cached API data with missing utilization shows absence" "5h:-- 7d:42%" "$out"
printf '%s\n' '{"five_hour":{"utilization":0},"seven_day":{"utilization":null}}' > "$sb/cortado-cache/rate_limits_usage"
out=$(render "$sb" "$NO_LIMITS")
assert_eq "cached API zero stays zero while null utilization shows absence" "5h:0% 7d:--" "$out"

echo ""
echo "=== quota indicator spacing follows display mode ==="

sb=$(sandbox indicator-spacing)
printf '%s\n' 'COLOR_THEME="default"' 'RATE_SHOW_USAGE_STATUS="true"' \
    'RATE_SHOW_TIME_REMAINING="false"' 'TERMINAL_WIDTH=200' >> "$sb/cortado.conf"

low='{"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":65}}}'
high='{"rate_limits":{"five_hour":{"used_percentage":80},"seven_day":{"used_percentage":97}}}'
assert_eq "normal emoji indicators have one space at the lower bands" "5h:42% 🟢 7d:65% 🟡" "$(render "$sb" "$low")"
assert_eq "normal emoji indicators have one space at the upper bands" "5h:80% 🟠 7d:97% 🔴" "$(render "$sb" "$high")"

printf '%s\n' 'STATUS_STYLE="ascii"' >> "$sb/cortado.conf"
assert_eq "normal ASCII indicators have one space at the lower bands" "5h:42% [OK] 7d:65% [MED]" "$(render "$sb" "$low")"
assert_eq "normal ASCII indicators have one space at the upper bands" "5h:80% [HIGH] 7d:97% [CRIT]" "$(render "$sb" "$high")"

printf '%s\n' 'STATUS_STYLE="dots"' >> "$sb/cortado.conf"
assert_eq "normal dots have one space" "5h:42% ● 7d:65% ●" "$(render "$sb" "$low")"

printf '%s\n' 'STATUS_STYLE="emoji"' 'STATUS_GREEN="g"' 'STATUS_YELLOW="y"' \
    'DISPLAY_MODE="compact"' >> "$sb/cortado.conf"
assert_eq "compact custom indicators attach directly to percentages" "5h:42%g 7d:65%y" "$(render "$sb" "$low")"

echo ""
echo "=== decimal percentages round consistently across locales ==="

sb=$(sandbox decimal-usage)
printf '%s\n' 'RATE_SHOW_USAGE_STATUS="true"' 'RATE_SHOW_TIME_REMAINING="false"' \
    >> "$sb/cortado.conf"
decimal_payload='{"rate_limits":{"five_hour":{"used_percentage":97.5},"seven_day":{"used_percentage":82.4}}}'
printf '%s\n' '{"five_hour":{"utilization":97.5},"seven_day":{"utilization":82.4}}' \
    > "$sb/cortado-cache/rate_limits_usage"
rounded='5h:98% [CRIT] 7d:82% [HIGH]'
assert_eq "C locale rounds decimal payload readings" "$rounded" "$(LC_ALL=C render "$sb" "$decimal_payload")"
assert_eq "C locale rounds decimal cached readings" "$rounded" "$(LC_ALL=C render "$sb" "$NO_LIMITS")"
comma_locale=$(
    locale -a | while IFS= read -r candidate; do
        if [ "$(LC_ALL="$candidate" locale decimal_point 2>/dev/null)" = "," ]; then
            printf '%s\n' "$candidate"
            break
        fi
    done
)
if [ -n "$comma_locale" ]; then
    assert_eq "comma-decimal locale rounds payload readings" "$rounded" \
        "$(LC_ALL="$comma_locale" render "$sb" "$decimal_payload")"
    assert_eq "comma-decimal locale rounds cached readings" "$rounded" \
        "$(LC_ALL="$comma_locale" render "$sb" "$NO_LIMITS")"
fi
assert_contains "history keeps the unrounded payload percentages" ",97.5,82.4," \
    "$(cat "$sb/.usage_history" 2>/dev/null)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
