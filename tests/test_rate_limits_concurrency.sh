#!/bin/bash
# ABOUTME: Overlapping rate-limit requests, atomic history and request cleanup.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
umask 000
export TMPDIR="$TEST_BASE/tmp"
export STUB_STATE="$TEST_BASE/state"
mkdir -p "$TMPDIR" "$STUB_STATE" "$TEST_BASE/bin"
export PATH="$TEST_BASE/bin:$PATH"
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (expected [$expected], got [$actual])"
        FAIL=$((FAIL + 1))
    fi
}

sandbox() {
    local sb
    sb=$(mktemp -d "$TEST_BASE/config.XXXXXX") || return 1
    mkdir -p "$sb/cortado-cache"
    printf '%s\n' 'MODULE_ORDER="rate-limits"' 'MODULE_RATE_LIMITS="true"' \
        'COLOR_THEME="monochrome"' 'RATE_SHOW_USAGE_STATUS="false"' \
        'RATE_SHOW_TIME_REMAINING="false"' > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf"
    echo "$sb"
}

render() {
    printf '%s' "$2" | CLAUDE_CONFIG_DIR="$1" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1 \
        | sed $'s/\x1b\\[[0-9;]*m//g'
}

write_credentials() {
    (umask 077; jq -n --arg token "test-token-REDACTED${2:-}" '{claudeAiOauth:{accessToken:$token}}' > "$1/.credentials.json")
}

# Bounded polling allows both writers to finish even when an assertion fails.
await_file() {
    local i=0
    while [ ! -f "$1" ] && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    [ -f "$1" ]
}

cat > "$TEST_BASE/bin/curl" <<'STUB'
#!/bin/bash
output= headers= config=
[ "$1" = -q ] && touch "$STUB_STATE/$REQUEST_ID.no-default-config"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        -D) headers="$2"; shift 2 ;;
        --config) config="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ "$config" = - ] && [ "$(cat)" = 'header = "Authorization: Bearer test-token-REDACTED"' ]; then
    touch "$STUB_STATE/$REQUEST_ID.stdin"
fi
# Scan staging and temp directories while the request is active. The original
# synthetic credential fixture lives outside both directories.
if grep -r -l -F -- 'test-token-REDACTED' "$CLAUDE_CONFIG_DIR/cortado-cache" "$TMPDIR" >/dev/null 2>&1; then
    touch "$STUB_STATE/$REQUEST_ID.token-on-disk"
fi

if [ -n "$output" ] && [ -n "$headers" ]; then
    if [ "$REQUEST_ID" = second ]; then five=78; seven=91; else five=42; seven=10; fi
    printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s}}' "$five" "$seven" > "$output"
    printf 'Retry-After: 180\r\n' > "$headers"
    if [ "$(ls -ld "$output" "$headers" | cut -c1-10 | sort -u)" = '-rw-------' ]; then
        touch "$STUB_STATE/$REQUEST_ID.private"
    fi
    printf '%s\n' "$output" > "$STUB_STATE/$REQUEST_ID.body-path"
    printf '%s\n' "$headers" > "$STUB_STATE/$REQUEST_ID.headers-path"
fi
touch "$STUB_STATE/$REQUEST_ID.ready"

if [ "$REQUEST_ID" = first ] || [ "$REQUEST_ID" = second ]; then
    i=0
    until [ -f "$STUB_STATE/$REQUEST_ID.release" ] || [ "$i" -ge 100 ]; do
        sleep 0.05
        i=$((i + 1))
    done
fi
case "$REQUEST_ID" in
    network-failure) printf '200'; exit 18 ;;
    cooldown) printf '429' ;;
    *) printf '200' ;;
esac
STUB
# Keep platform selection deterministic, including on Git Bash.
cat > "$TEST_BASE/bin/uname" <<'STUB'
#!/bin/bash
echo CortadoConcurrencyTest
STUB
chmod +x "$TEST_BASE/bin/curl" "$TEST_BASE/bin/uname"

echo "=== concurrent sessions display their own usage ==="
sb=$(sandbox)
write_credentials "$sb"
REQUEST_ID=first render "$sb" '{}' > "$STUB_STATE/first.render" &
first_pid=$!
assert_eq "first curl started before the second" 0 "$(await_file "$STUB_STATE/first.ready"; echo "$?")"
REQUEST_ID=second render "$sb" '{}' > "$STUB_STATE/second.render" &
second_pid=$!
assert_eq "second curl started before the first finished" 0 "$(await_file "$STUB_STATE/second.ready"; echo "$?")"
touch "$STUB_STATE/first.release"
wait "$first_pid"
touch "$STUB_STATE/second.release"
wait "$second_pid"
assert_eq "first concurrent render shows its own reading" '5h:42%  7d:10% ' "$(cat "$STUB_STATE/first.render")"
assert_eq "second concurrent render shows its own reading" '5h:78%  7d:91% ' "$(cat "$STUB_STATE/second.render")"
for kind in body headers; do
    assert_eq "the concurrent requests use different $kind paths" yes \
        "$([ "$(cat "$STUB_STATE/first.$kind-path")" != "$(cat "$STUB_STATE/second.$kind-path")" ] && echo yes)"
done
for request in first second; do
    assert_eq "$request curl received the bearer config on stdin" yes "$([ -f "$STUB_STATE/$request.stdin" ] && echo yes)"
    assert_eq "$request curl skips user curl configuration" yes "$([ -f "$STUB_STATE/$request.no-default-config" ] && echo yes)"
    assert_eq "$request curl found no token in cache or temp directories" no "$([ -f "$STUB_STATE/$request.token-on-disk" ] && echo yes || echo no)"
    assert_eq "$request curl output files are owner-only" yes "$([ -f "$STUB_STATE/$request.private" ] && echo yes)"
done
assert_eq "concurrent requests leave no request temps" '' "$(find "$sb/cortado-cache" -name 'rate_limits_request.*' -print)"
assert_eq "published usage cache is owner-only" '-rw-------' "$(ls -ld "$sb/cortado-cache/rate_limits_usage" | cut -c1-10)"

echo "=== curl failure and 429 ==="
sb=$(sandbox)
write_credentials "$sb"
assert_eq "failed transfer with HTTP 200 shows absence" '5h:-- 7d:--' "$(REQUEST_ID=network-failure render "$sb" '{}')"
assert_eq "failed transfer leaves no request files or cached usage" '' "$(ls -A "$sb/cortado-cache")"

sb=$(sandbox)
write_credentials "$sb" '"'
assert_eq "a token with a config delimiter shows absence" '5h:-- 7d:--' "$(REQUEST_ID=unsafe-token render "$sb" '{}')"
assert_eq "a token with a config delimiter makes no request" no "$([ -f "$STUB_STATE/unsafe-token.ready" ] && echo yes || echo no)"

sb=$(sandbox)
write_credentials "$sb"
cat > "$TEST_BASE/bin/mktemp" <<'STUB'
#!/bin/bash
printf '%s\n' "$CLAUDE_CONFIG_DIR/cortado-cache/incomplete-request"
exit 1
STUB
chmod +x "$TEST_BASE/bin/mktemp"
assert_eq "failed request staging shows absence" '5h:-- 7d:--' "$(REQUEST_ID=staging-failure render "$sb" '{}')"
assert_eq "failed request staging makes no request" no "$([ -f "$STUB_STATE/staging-failure.ready" ] && echo yes || echo no)"
rm -f "$TEST_BASE/bin/mktemp"

sb=$(sandbox)
write_credentials "$sb"
printf '120\n' > "$sb/cortado-cache/rate_limits_backoff"
chmod 644 "$sb/cortado-cache/rate_limits_backoff"
touch -t 200001010000 "$sb/cortado-cache/rate_limits_backoff"
assert_eq "first 429 render shows absence" '5h:-- 7d:--' "$(REQUEST_ID=cooldown render "$sb" '{}')"
assert_eq "429 publishes its own Retry-After value" '180' "$(cat "$sb/cortado-cache/rate_limits_backoff")"
assert_eq "429 leaves only the owner-only backoff marker" 'rate_limits_backoff' "$(ls -A "$sb/cortado-cache")"
assert_eq "backoff marker is owner-only" '-rw-------' "$(ls -ld "$sb/cortado-cache/rate_limits_backoff" | cut -c1-10)"
assert_eq "an expired cooldown cannot delete a concurrent 429 marker" 180 "$(
    CLAUDE_CONFIG_DIR="$sb"
    # shellcheck source=/dev/null
    . "$PROJECT_ROOT/modules/utils.sh"
    # shellcheck source=/dev/null
    . "$PROJECT_ROOT/modules/rate-limits.sh"
    # Called by the sourced backoff helper.
    # shellcheck disable=SC2329
    _file_mtime() {
        cache_set rate_limits_backoff 180
        echo 1
    }
    _check_backoff
    cat "$CACHE_DIR/rate_limits_backoff" 2>/dev/null
)"

echo "=== a cancelled history writer preserves the previous reading ==="
sb=$(sandbox)
now=$(date +%s)
previous="$now,19,28,,"
printf '%s\n' "$previous" > "$sb/.usage_history"
payload='{"rate_limits":{"five_hour":{"used_percentage":65},"seven_day":{"used_percentage":32}}}'
real_awk=$(command -v awk)
export REAL_AWK_FOR_TEST="$real_awk"
cat > "$TEST_BASE/bin/awk" <<'STUB'
#!/bin/bash
if [ "$1" = '-F,' ] && [ -n "${HISTORY_FAULT:-}" ]; then
    printf '%s' partial
    touch "$STUB_STATE/history-writing"
    if [ "$HISTORY_FAULT" = interrupt ]; then
        kill -KILL "$PPID"
    fi
    exit 1
fi
exec "$REAL_AWK_FOR_TEST" "$@"
STUB
chmod +x "$TEST_BASE/bin/awk"
HISTORY_FAULT=interrupt render "$sb" "$payload" >/dev/null
assert_eq "history writer was interrupted after emitting bytes" yes "$([ -f "$STUB_STATE/history-writing" ] && echo yes)"
assert_eq "killed writer leaves the previous history snapshot readable" "$previous" "$(cat "$sb/.usage_history")"

sb=$(sandbox)
printf '%s\n' "$previous" > "$sb/.usage_history"
assert_eq "history rewrite failure still displays the current reading" '5h:65%  7d:32% ' "$(HISTORY_FAULT=fail render "$sb" "$payload")"
assert_eq "failed history rewrite keeps the previous snapshot" "$previous" "$(cat "$sb/.usage_history")"
assert_eq "failed history rewrite cleans its staging file" '' "$(find "$sb" -name '.usage_history.*' -print)"

sb=$(sandbox)
printf '%s\n' "$previous" > "$sb/.usage_history"
cat > "$TEST_BASE/bin/tail" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$TEST_BASE/bin/tail"
render "$sb" "$payload" >/dev/null
assert_eq "failed history read keeps the previous snapshot" "$previous" "$(cat "$sb/.usage_history")"
rm -f "$TEST_BASE/bin/tail"

sb=$(sandbox)
assert_eq "successful history update displays the current reading" '5h:65%  7d:32% ' "$(render "$sb" "$payload")"
assert_eq "history snapshot is owner-only" '-rw-------' "$(ls -ld "$sb/.usage_history" | cut -c1-10)"

sb=$(sandbox)
awk -v now="$now" 'BEGIN {
    for (i = 1; i <= 110; i++) print (i == 100 ? now - 90000 : now) "," i ",0,,"
}' > "$sb/.usage_history"
render "$sb" "$payload" >/dev/null
assert_eq "history keeps at most the last 100 points and drops expired points" 99 "$(awk 'END {print NR}' "$sb/.usage_history")"
assert_eq "trimmed history starts with the oldest retained point" 12 "$(head -1 "$sb/.usage_history" | cut -d, -f2)"

sb=$(sandbox)
awk -v now="$now" 'BEGIN {
    for (i = 1; i <= 100; i++) printf "%s,%s,0,%0600d,\n", now, i, 0
}' > "$sb/.usage_history"
render "$sb" "$payload" >/dev/null
assert_eq "oversized history retains 50 prior points and the new one" 51 "$(awk 'END {print NR}' "$sb/.usage_history")"

echo "=== a direct request preserves the caller's EXIT trap ==="
sb=$(sandbox)
write_credentials "$sb"
(
    trap 'touch "$STUB_STATE/caller-exit"' EXIT
    CLAUDE_CONFIG_DIR="$sb"
    # shellcheck source=/dev/null
    . "$PROJECT_ROOT/modules/utils.sh"
    # shellcheck source=/dev/null
    . "$PROJECT_ROOT/modules/rate-limits.sh"
    CLAUDE_CONFIG_DIR="$sb" REQUEST_ID=direct _get_claude_usage >/dev/null
)
assert_eq "direct call leaves the caller's EXIT trap in place" yes "$([ -f "$STUB_STATE/caller-exit" ] && echo yes)"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
