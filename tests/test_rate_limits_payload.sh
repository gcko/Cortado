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

# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain

TEST_BASE="$(mktemp -d "${TMPDIR:-/tmp}/cortado-payload-test.XXXXXX")"
trap 'rm -rf "$TEST_BASE"' EXIT

# sandbox <name>: a fresh CLAUDE_CONFIG_DIR with only the rate-limits module on.
sandbox() {
    local sb="$TEST_BASE/$1"
    mkdir -m 700 "$sb" "$sb/cortado-cache" || return 1
    printf '%s\n' 'MODULE_ORDER="rate-limits"' 'MODULE_RATE_LIMITS="true"' \
        'COLOR_THEME="monochrome"' 'RATE_SHOW_USAGE_STATUS="false"' > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf"
    echo "$sb"
}

# render <sandbox> <payload>
render() {
    printf '%s' "$2" | CLAUDE_CONFIG_DIR="$1" CACHE_DIR="$1/cortado-cache" \
        /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
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
echo "=== implausible percentages show absence for their window ==="

for bad in -5 1e30 100.4; do
    sb=$(sandbox "out-of-range-$bad")
    printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":100}}\n' "$bad" \
        > "$sb/cortado-cache/rate_limits_usage"
    invalid_payload=$(printf '{"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":%s}}}' "$bad")
    assert_eq "cached $bad shows absence alongside measured 100%" "5h:-- 7d:100%" "$(render "$sb" "$NO_LIMITS")"
    assert_eq "payload $bad shows absence alongside measured 0%" "5h:0% 7d:--" "$(render "$sb" "$invalid_payload")"
done

for zero in -0 -0.0; do
    sb=$(sandbox "signed-zero-$zero")
    printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":10}}\n' "$zero" \
        > "$sb/cortado-cache/rate_limits_usage"
    signed_zero_payload=$(printf '{"rate_limits":{"five_hour":{"used_percentage":%s},"seven_day":{"used_percentage":10}}}' "$zero")
    assert_eq "cached $zero displays as unsigned zero" "5h:0% 7d:10%" "$(render "$sb" "$NO_LIMITS")"
    assert_eq "payload $zero displays as unsigned zero" "5h:0% 7d:10%" "$(render "$sb" "$signed_zero_payload")"
done

echo ""
echo "=== stale fallback shows the cache age ==="

mkdir "$TEST_BASE/fallback-bin"
cat > "$TEST_BASE/fallback-bin/date" <<'STUB'
#!/bin/bash
if [ "$*" = '+%s' ]; then
    [ "$TEST_NOW" != unavailable ] || exit 1
    printf '%s\n' "$TEST_NOW"
else
    exec /bin/date "$@"
fi
STUB
cat > "$TEST_BASE/fallback-bin/curl" <<'STUB'
#!/bin/bash
printf 'attempt\n' >> "$CLAUDE_CONFIG_DIR/curl.log"
exit 7
STUB
chmod +x "$TEST_BASE/fallback-bin/"*

render_cache() {
    local sb="$1" age="$2" payload="${3:-$NO_LIMITS}"
    printf '%s\n' '{"five_hour":{"utilization":42},"seven_day":{"utilization":10}}' \
        > "$sb/cortado-cache/rate_limits_usage"
    TZ=UTC touch -t 202001010000 "$sb/cortado-cache/rate_limits_usage"
    printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-REDACTED"}}' > "$sb/.credentials.json"
    chmod 600 "$sb/.credentials.json"
    TEST_NOW=$((1577836800 + age)) PATH="$TEST_BASE/fallback-bin:$PATH" render "$sb" "$payload"
}

sb=$(sandbox fresh-cache)
assert_eq "a one-minute-old reading has the original text" "5h:42% 7d:10%" "$(render_cache "$sb" 60)"
assert_eq "a fresh cached reading does not call curl" "" "$(cat "$sb/curl.log" 2>/dev/null)"

sb=$(sandbox stale-cache)
assert_eq "a failed fetch shows the age on both stale readings" "5h:42%~6h0m 7d:10%~6h0m" "$(render_cache "$sb" 21600)"
assert_eq "the stale fallback follows a curl attempt" "attempt" "$(cat "$sb/curl.log" 2>/dev/null)"

for replacement in fresh stale unstable; do
    sb=$(sandbox "cache-replacement-$replacement")
    cat >> "$sb/cortado.conf" <<'CONFIG'
cat() {
    command cat "$@" || return
    if [ "$1" = "$CACHE_DIR/rate_limits_usage" ] && [ -f "$1.new" ]; then
        mv "$1.new" "$1"
        if [ -f "$1.newer" ]; then mv "$1.newer" "$1.new"; fi
    fi
}
CONFIG
    cache_file="$sb/cortado-cache/rate_limits_usage"
    printf '%s\n' '{"five_hour":{"utilization":12},"seven_day":{"utilization":15}}' > "$cache_file.new"
    if [ "$replacement" = stale ]; then
        TZ=UTC touch -t 202001010500 "$cache_file.new"
    else
        TZ=UTC touch -t 202001010600 "$cache_file.new"
    fi
    if [ "$replacement" = unstable ]; then
        printf '%s\n' '{"five_hour":{"utilization":20},"seven_day":{"utilization":25}}' > "$cache_file.newer"
        TZ=UTC touch -t 202001010559 "$cache_file.newer"
    fi
    out=$(render_cache "$sb" 21600)
    case "$replacement" in
        fresh) assert_eq "a fresh replacement after stale bytes were read is used" "5h:12% 7d:15%" "$out" ;;
        stale) assert_eq "a replacement outside the fresh TTL shows absence" "5h:-- 7d:--" "$out" ;;
        unstable)
            assert_eq "a second change during the cache read shows absence" "5h:-- 7d:--" "$out"
            assert_eq "the second change occurred during the retry" "absent" \
                "$([ -e "$cache_file.new" ] && printf present || printf absent)"
            ;;
    esac
done

sb=$(sandbox expired-cache)
assert_eq "a reading older than 24 hours is absent" "5h:-- 7d:--" "$(render_cache "$sb" 86401)"

sb=$(sandbox unavailable-cache-clock)
printf '%s\n' 'RATE_SHOW_USAGE_STATUS="true"' >> "$sb/cortado.conf"
printf '%s\n' '{"five_hour":{"utilization":2},"seven_day":{"utilization":3}}' \
    > "$sb/cortado-cache/rate_limits_usage"
TZ=UTC touch -t 202001010000 "$sb/cortado-cache/rate_limits_usage"
out=$(TEST_NOW=unavailable PATH="$TEST_BASE/fallback-bin:$PATH" render "$sb" "$NO_LIMITS")
assert_eq "a quota cache of unknown age shows absence when the clock fails" "5h:-- 7d:--" "$out"

sb=$(sandbox backoff-stale-cache)
printf '300\n' > "$sb/cortado-cache/rate_limits_backoff"
TZ=UTC touch -t 202001010600 "$sb/cortado-cache/rate_limits_backoff"
assert_eq "an active cooldown shows cache age and remaining wait" "5h:42%~6h0m 7d:10%~6h0m WAIT5m" "$(render_cache "$sb" 21600)"
assert_eq "backoff skips curl" "" "$(cat "$sb/curl.log" 2>/dev/null)"

for contents in marker-only marker-and-cache; do
    sb=$(sandbox "unknown-backoff-$contents")
    marker="$sb/cortado-cache/rate_limits_backoff"
    printf '300\n' > "$marker"
    TZ=UTC touch -t 202001010000 "$marker"
    printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-REDACTED"}}' > "$sb/.credentials.json"
    chmod 600 "$sb/.credentials.json"
    if [ "$contents" = marker-and-cache ]; then
        printf '%s\n' '{"five_hour":{"utilization":2},"seven_day":{"utilization":3}}' \
            > "$sb/cortado-cache/rate_limits_usage"
        TZ=UTC touch -t 202001010000 "$sb/cortado-cache/rate_limits_usage"
    fi
    out=$(TEST_NOW=unavailable PATH="$TEST_BASE/fallback-bin:$PATH" render "$sb" "$NO_LIMITS")
    assert_eq "an unmeasurable cooldown shows quota absence ($contents)" "5h:-- 7d:--" "$out"
    assert_eq "an unmeasurable cooldown skips curl ($contents)" "" "$(cat "$sb/curl.log" 2>/dev/null)"
    assert_eq "an unmeasurable cooldown keeps the marker ($contents)" "300" "$(cat "$marker" 2>/dev/null)"
    TEST_NOW=1577923201 PATH="$TEST_BASE/fallback-bin:$PATH" render "$sb" "$NO_LIMITS" >/dev/null
    assert_eq "an expired cooldown permits a fetch once the clock recovers ($contents)" "attempt" \
        "$(cat "$sb/curl.log" 2>/dev/null)"
done

sb=$(sandbox payload-over-stale-cache)
live_payload='{"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":100}}}'
assert_eq "payload readings carry no cache age" "5h:0% 7d:100%" "$(render_cache "$sb" 21600 "$live_payload")"

echo ""
echo "=== scientific notation preserves the projection indicator ==="

reset=$(jq -nr --argjson ts "$RESET_5H" '$ts | todate')
for utilization in 100 1e2; do
    sb=$(sandbox "projection-$utilization")
    printf '%s\n' 'RATE_SHOW_TIME_REMAINING="false"' 'RATE_SHOW_PROJECTION="true"' >> "$sb/cortado.conf"
    printf '{"five_hour":{"utilization":%s,"resets_at":"%s"},"seven_day":{"utilization":10}}\n' \
        "$utilization" "$reset" > "$sb/cortado-cache/rate_limits_usage"
    printf '%s,100,10,%s,\n' "$((NOW - 300))" "$reset" > "$sb/.usage_history"
    assert_eq "a quota of $utilization keeps its critical projection" "5h:100% [CRIT] 7d:10%" \
        "$(render "$sb" "$NO_LIMITS")"
done

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
assert_contains "history keeps the unrounded payload percentages" ",97.5,82.4," \
    "$(cat "$sb/.usage_history" 2>/dev/null)"
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

    for utilization in 1e2 100.00000000000000000000; do
        for window in five_hour seven_day; do
            sb=$(sandbox "comma-$window-$utilization")
            printf '%s\n' 'RATE_SHOW_TIME_REMAINING="false"' 'RATE_SHOW_PROJECTION="true"' >> "$sb/cortado.conf"
            # A single, old history point gives a zero slope in either window.
            printf '%s,100,100,%s,%s\n' "$((NOW - 86400))" "$reset" "$reset" > "$sb/.usage_history"
            case "$window" in
                five_hour) sibling=seven_day; expected='5h:100% [CRIT] 7d:10%' ;;
                seven_day) sibling=five_hour; expected='5h:10% 7d:100% [CRIT]' ;;
            esac
            printf '{"%s":{"utilization":%s,"resets_at":"%s"},"%s":{"utilization":10}}\n' \
                "$window" "$utilization" "$reset" "$sibling" > "$sb/cortado-cache/rate_limits_usage"
            assert_eq "a comma locale keeps the $window critical projection for $utilization" "$expected" \
                "$(LC_ALL="$comma_locale" render "$sb" "$NO_LIMITS")"
        done
    done

    sb=$(sandbox comma-exponent-payload)
    exponent_payload='{"rate_limits":{"five_hour":{"used_percentage":1e2},"seven_day":{"used_percentage":10}}}'
    assert_eq "a fresh exponent payload keeps both readings in a comma locale" "5h:100% 7d:10%" \
        "$(LC_ALL="$comma_locale" render "$sb" "$exponent_payload")"
    assert_eq "an exponent history row keeps five fields and its seven-day percentage" "5 10" \
        "$(awk -F, '{print NF, $3}' "$sb/.usage_history")"

    sb=$(sandbox comma-seven-day-exponent)
    exponent_payload='{"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":5e1}}}'
    assert_eq "a fresh seven-day exponent payload keeps both readings in a comma locale" "5h:10% 7d:50%" \
        "$(LC_ALL="$comma_locale" render "$sb" "$exponent_payload")"
fi

echo ""
echo "=== sub-percent growth can trigger a projected warning ==="
for theme in default monochrome; do
    sb=$(sandbox "projection-$theme")
    printf '%s\n' "COLOR_THEME=$theme" 'RATE_SHOW_TIME_REMAINING=false' 'TERMINAL_WIDTH=200' \
        'date() { if [ "$*" = +%s ]; then echo 1800000000; else /bin/date "$@"; fi; }' \
        >> "$sb/cortado.conf"
    printf '%s\n' 1800000000 > "$sb/cortado-cache/rate_limits_payload_recorded"
    TZ=UTC touch -t 202701150800 "$sb/cortado-cache/rate_limits_payload_recorded"
    if [ "$theme" = default ]; then
        printf '%s\n' 'RATE_SHOW_USAGE_STATUS=true' >> "$sb/cortado.conf"
        reset=2027-01-15T11:20:00
        printf '%s\n' "1799998000,79.494,10,$reset," "1799999900,79.495,10,$reset," > "$sb/.usage_history"
        used=79.495
        expected='5h:79% 🟠 🟡 7d:10% 🟢'
    else
        reset=2027-01-15T08:16:40
        printf '%s\n' "1799999000,0,10,$reset," "1799999500,0.005,10,$reset," > "$sb/.usage_history"
        used=79.499
        expected='5h:79% [WARN] 7d:10%'
    fi
    projection_payload=$(printf '{"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":"%s"},"seven_day":{"used_percentage":10}}}' \
        "$used" "$reset")
    assert_eq "$theme keeps the projected warning when growth is below 0.01%" "$expected" \
        "$(render "$sb" "$projection_payload")"
done

echo ""
echo "=== fresh quota without a usable live clock ==="
for clock in 'return 1' 'echo invalid' 'echo 0'; do
    sb=$(sandbox "clock-$clock")
    printf '%s\n' RATE_SHOW_TIME_REMAINING=true \
        "date() { if [ \"\$*\" = '+%s' ]; then $clock; else /bin/date \"\$@\"; fi; }" >> "$sb/cortado.conf"
    assert_eq "measured payload percentages survive an unavailable clock ($clock)" '5h:65% 7d:32%' \
        "$(render "$sb" "$WITH_LIMITS")"
    assert_eq "an unavailable clock does not add a payload history row ($clock)" '' \
        "$(cat "$sb/.usage_history" 2>/dev/null)"
    assert_eq "an unavailable clock does not throttle the next payload history write ($clock)" '' \
        "$(cat "$sb/cortado-cache/rate_limits_payload_recorded" 2>/dev/null)"
done

sb=$(sandbox no-clock-api)
printf '%s\n' RATE_SHOW_TIME_REMAINING=true \
    'date() { if [ "$*" = +%s ]; then return 1; else /bin/date "$@"; fi; }' >> "$sb/cortado.conf"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-REDACTED"}}' > "$sb/.credentials.json"
chmod 600 "$sb/.credentials.json"
jq -nc --argjson reset "$((NOW + 3600))" \
    '{five_hour:{utilization:0,resets_at:($reset|todate)},seven_day:{utilization:3}}' > "$sb/response.json"
mkdir "$sb/bin"
cat > "$sb/bin/curl" <<'STUB'
#!/bin/bash
while [ "$#" -gt 1 ]; do
    if [ "$1" = -o ]; then
        cp "$CLAUDE_CONFIG_DIR/response.json" "$2" || exit 1
        printf '%s\n' 200
        exit 0
    fi
    shift
done
exit 1
STUB
chmod +x "$sb/bin/curl"
assert_eq "fresh API percentages survive an unavailable clock" '5h:0% 7d:3%' \
    "$(PATH="$sb/bin:$PATH" render "$sb" "$NO_LIMITS")"
assert_eq "an unavailable clock does not add an API history row" '' \
    "$(cat "$sb/.usage_history" 2>/dev/null)"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
