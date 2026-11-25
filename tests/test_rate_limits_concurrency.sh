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
    local i=0 attempts="${2:-100}"
    while [ ! -f "$1" ] && [ "$i" -lt "$attempts" ]; do
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

[ -p /dev/stdin ] && touch "$STUB_STATE/$REQUEST_ID.pipe"
if [ "$config" = - ] && [ "$(cat)" = 'header = "Authorization: Bearer test-token-REDACTED"' ]; then
    touch "$STUB_STATE/$REQUEST_ID.stdin"
fi
# Scan staging and temp directories while the request is active. The original
# synthetic credential fixture lives outside both directories.
if grep -r -l -F -- 'test-token-REDACTED' "$CLAUDE_CONFIG_DIR/cortado-cache" "$TMPDIR" >/dev/null 2>&1; then
    touch "$STUB_STATE/$REQUEST_ID.token-on-disk"
fi

if [ -n "$output" ] && [ -n "$headers" ]; then
    case "$REQUEST_ID" in
        second|history-second) five=78; seven=91 ;;
        *) five=42; seven=10 ;;
    esac
    printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s}}' "$five" "$seven" > "$output"
    printf 'Retry-After: 180\r\n' > "$headers"
    if [ "$(ls -ld "$output" "$headers" | cut -c1-10 | sort -u)" = '-rw-------' ]; then
        touch "$STUB_STATE/$REQUEST_ID.private"
    fi
    if [ "$(ls -ld "${output%/*}" | cut -c1-10)" = 'drwx------' ]; then
        touch "$STUB_STATE/$REQUEST_ID.private-dir"
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
    assert_eq "$request curl config stdin is a pipe" yes "$([ -f "$STUB_STATE/$request.pipe" ] && echo yes)"
    assert_eq "$request curl received the bearer config on stdin" yes "$([ -f "$STUB_STATE/$request.stdin" ] && echo yes)"
    assert_eq "$request curl skips user curl configuration" yes "$([ -f "$STUB_STATE/$request.no-default-config" ] && echo yes)"
    assert_eq "$request curl found no token in cache or temp directories" no "$([ -f "$STUB_STATE/$request.token-on-disk" ] && echo yes || echo no)"
    assert_eq "$request curl output files are owner-only" yes "$([ -f "$STUB_STATE/$request.private" ] && echo yes)"
    assert_eq "$request curl request directory is owner-only" yes "$([ -f "$STUB_STATE/$request.private-dir" ] && echo yes)"
done
assert_eq "concurrent requests leave no request temps" '' "$(find "$sb/cortado-cache" -name 'rate_limits_request.*' -print)"
assert_eq "published usage cache is owner-only" '-rw-------' "$(ls -ld "$sb/cortado-cache/rate_limits_usage" | cut -c1-10)"

export REAL_MV_FOR_TEST
REAL_MV_FOR_TEST=$(command -v mv)
cat > "$TEST_BASE/bin/mv" <<'STUB'
#!/bin/bash
pause_publication() {
    local name="$1" i=0
    touch "$STUB_STATE/$name-at-rename"
    until [ -f "$STUB_STATE/$name-release" ] || [ "$i" -ge 100 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    [ -f "$STUB_STATE/$name-release" ] || exit 1
}

if [ "${!#}" = "$CLAUDE_CONFIG_DIR/.usage_history" ]; then
    case "${HISTORY_FAULT:-}" in
        pause)
            args=("$@")
            printf '%s\n' "${args[${#args[@]}-2]}" > "$STUB_STATE/history-stage-path"
            pause_publication history
            ;;
        kill-at-rename)
            touch "$STUB_STATE/history-killed"
            kill -KILL "$PPID"
            exit 1
            ;;
    esac
fi
if [ "${REQUEST_ID:-}" = cooldown ] && [ "${!#}" = "$CLAUDE_CONFIG_DIR/cortado-cache/rate_limits_backoff" ]; then
    pause_publication cooldown
fi
exec "$REAL_MV_FOR_TEST" "$@"
STUB
chmod +x "$TEST_BASE/bin/mv"

echo "=== overlapping history writers retain both observations ==="
sb=$(sandbox)
write_credentials "$sb"
history_payload='{"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":10}}}'
HISTORY_FAULT=pause render "$sb" "$history_payload" > "$STUB_STATE/history-first.render" &
first_pid=$!
assert_eq "the first snapshot is staged before the second render starts" 0 \
    "$(await_file "$STUB_STATE/history-at-rename"; echo "$?")"
history_stage=$(cat "$STUB_STATE/history-stage-path" 2>/dev/null)
assert_eq "history staging is beside .usage_history" "$sb" "${history_stage%/*}"
assert_eq "the history stage exists and is owner-only during publication" '-rw-------' \
    "$(ls -ld "$history_stage" 2>/dev/null | cut -c1-10)"
(
    REQUEST_ID=history-second render "$sb" '{}' > "$STUB_STATE/history-second.render"
    touch "$STUB_STATE/history-second.done"
) &
second_pid=$!
assert_eq "the second render fetches while history publication is paused" 0 \
    "$(await_file "$STUB_STATE/history-second.ready"; echo "$?")"
# Without serialization B finishes before A can publish its stale snapshot.
# A serialized B can only finish after A is released, so bound this wait.
await_file "$STUB_STATE/history-second.done" 25 || :
touch "$STUB_STATE/history-release"
wait "$first_pid"
wait "$second_pid"
assert_eq "the first history writer renders its own reading" '5h:42%  7d:10% ' "$(cat "$STUB_STATE/history-first.render")"
assert_eq "the second history writer renders its own reading" '5h:78%  7d:91% ' "$(cat "$STUB_STATE/history-second.render")"
assert_eq "history retains exactly one complete row per reading" $'42,10,,\n78,91,,' \
    "$(awk -F, 'NF != 5 || $1 !~ /^[0-9]+$/ { print "invalid row" } { sub(/^[^,]*,/, ""); print }' \
        "$sb/.usage_history" | sort)"

sb=$(sandbox)
previous="$(date +%s),19,28,,"
printf '%s\n' "$previous" > "$sb/.usage_history"
HISTORY_FAULT=kill-at-rename render "$sb" "$history_payload" >/dev/null
assert_eq "the history writer was killed at publication" yes "$([ -f "$STUB_STATE/history-killed" ] && echo yes)"
assert_eq "KILL at history publication leaves the old row readable" "$previous" "$(cat "$sb/.usage_history")"
write_credentials "$sb"
assert_eq "a later render displays fresh data after a history writer is killed" '5h:78%  7d:91% ' \
    "$(REQUEST_ID=history-second render "$sb" '{}')"
assert_eq "a later writer can append after KILL" $'19,28,,\n78,91,,' "$(cut -d, -f2- "$sb/.usage_history")"

sb=$(sandbox)
printf '%s\n' "$previous" > "$sb/.usage_history"
mkdir "$sb/.usage_history-lock"
failed_open_render=$(
    # A failed lock open must never reuse the caller's unrelated descriptor.
    exec 9>>"$TEST_BASE/unrelated-lock"
    render "$sb" "$history_payload"
)
assert_eq "a failed lock open still displays the reading" '5h:42%  7d:10% ' "$failed_open_render"
assert_eq "a failed lock open leaves history intact" "$previous" "$(cat "$sb/.usage_history")"

sb=$(sandbox)
printf '%s\n' "$previous" > "$sb/.usage_history"
cat > "$TEST_BASE/bin/flock" <<'STUB'
#!/bin/bash
exit 75
STUB
chmod +x "$TEST_BASE/bin/flock"
assert_eq "a denied history lock still displays the reading" '5h:42%  7d:10% ' "$(render "$sb" "$history_payload")"
assert_eq "a denied history lock leaves history intact" "$previous" "$(cat "$sb/.usage_history")"
assert_eq "the lock file is owner-only under a permissive umask" '-rw-------' \
    "$(ls -ld "$sb/.usage_history-lock" | cut -c1-10)"
rm -f "$TEST_BASE/bin/flock"

echo "=== legacy curl config cleanup during a render ==="
sb=$(sandbox)
legacy_config="$sb/cortado-cache/rate_limits_curlcfg"
printf '%s\n' 'legacy curl config fixture' > "$legacy_config"
touch -t 200001010000 "$legacy_config"
assert_eq "cleanup still displays the payload reading" '5h:42%  7d:10% ' "$(render "$sb" "$history_payload")"
assert_eq "a render removes an old legacy curl config" no "$([ -f "$legacy_config" ] && echo yes || echo no)"

sb=$(sandbox)
legacy_config="$sb/cortado-cache/rate_limits_curlcfg"
printf '%s\n' 'legacy curl config fixture' > "$legacy_config"
assert_eq "a recently written legacy config supplies no reading" '5h:-- 7d:--' "$(render "$sb" '{}')"
assert_eq "a render retains a recently written legacy curl config" yes "$([ -f "$legacy_config" ] && echo yes)"

(
    CLAUDE_CONFIG_DIR="$sb"
    # shellcheck source=/dev/null
    . "$PROJECT_ROOT/modules/utils.sh"
    # shellcheck source=/dev/null
    . "$PROJECT_ROOT/modules/rate-limits.sh"
    # Exercise stat failure and the exact grace-period boundary deterministically.
    # shellcheck disable=SC2329
    date() { echo 1000; }
    # shellcheck disable=SC2329
    _file_mtime() { echo "$fixture_mtime"; }
    for fixture_mtime in 0 700; do
        _cleanup_legacy_curl_config
        [ -f "$legacy_config" ] || exit 1
    done
)
assert_eq "a legacy config is kept at exactly five minutes or when its age is unknown" 0 "$?"
rm -f "$legacy_config"
mkdir "$legacy_config"
(
    CLAUDE_CONFIG_DIR="$sb"
    # shellcheck source=/dev/null
    . "$PROJECT_ROOT/modules/utils.sh"
    # shellcheck source=/dev/null
    . "$PROJECT_ROOT/modules/rate-limits.sh"
    # shellcheck disable=SC2329
    _file_mtime() { echo 1; }
    _cleanup_legacy_curl_config
)
assert_eq "cleanup ignores a directory at the legacy config path" 0 "$?"

echo "=== curl failure and 429 ==="
sb=$(sandbox)
write_credentials "$sb"
assert_eq "failed transfer with HTTP 200 shows absence" '5h:-- 7d:--' "$(REQUEST_ID=network-failure render "$sb" '{}')"
assert_eq "failed transfer leaves no request files or cached usage" '' "$(ls -A "$sb/cortado-cache")"

sb=$(sandbox)
write_credentials "$sb" '"'
assert_eq "a token with a config delimiter shows absence" '5h:-- 7d:--' "$(REQUEST_ID=unsafe-token render "$sb" '{}')"
assert_eq "a token with a config delimiter makes no request" no "$([ -f "$STUB_STATE/unsafe-token.ready" ] && echo yes || echo no)"

# Some Bash builds put an accented character inside [a-z] in a UTF-8
# locale. Only exercise this contrast when the test shell actually does.
accent=$'\303\251'
if LC_ALL=en_US.UTF-8 /bin/bash -c '[[ "$1" == [a-z] ]]' _ "$accent" 2>/dev/null; then
    sb=$(sandbox)
    write_credentials "$sb" "$accent"
    assert_eq "an accented token shows absence under a collation-sensitive locale" '5h:-- 7d:--' \
        "$(LC_ALL=en_US.UTF-8 REQUEST_ID=accented-token render "$sb" '{}')"
    assert_eq "an accented token makes no request under a collation-sensitive locale" no \
        "$([ -f "$STUB_STATE/accented-token.ready" ] && echo yes || echo no)"
fi

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
REQUEST_ID=cooldown render "$sb" '{}' > "$STUB_STATE/cooldown.render" &
cooldown_pid=$!
assert_eq "the 429 replacement is staged before publication" 0 "$(await_file "$STUB_STATE/cooldown-at-rename"; echo "$?")"
assert_eq "readers see the complete previous marker before rename" 120 "$(cat "$sb/cortado-cache/rate_limits_backoff")"
touch "$STUB_STATE/cooldown-release"
wait "$cooldown_pid"
assert_eq "first 429 render shows absence" '5h:-- 7d:--' "$(cat "$STUB_STATE/cooldown.render")"
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
