#!/bin/bash
# Render a session's version notice against a clock controlled by the test.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir "$TEST_BASE/bin"
cat > "$TEST_BASE/bin/date" <<'STUB'
#!/bin/bash
if [ "$*" = "+%s" ]; then
    if [ -n "${TEST_SECOND_READY:-}" ]; then
        touch "$TEST_SECOND_READY"
    fi
    printf '%s\n' "$TEST_NOW"
else
    /bin/date "$@"
fi
STUB
chmod +x "$TEST_BASE/bin/date"

new_sandbox() {
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
    printf '%s\n' 'MODULE_ORDER="version"' 'MODULE_VERSION="true"' \
        'COLOR_THEME="monochrome"' 'TERMINAL_WIDTH=200' "VERSION_SHOW_DURATION=$1" > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf" || exit 1
}

new_sandbox 10
version="Cortado v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
now=$(/bin/date +%s)

render() {
    printf '%s' "$1" | PATH="$TEST_BASE/bin:$PATH" TEST_NOW="$((now + $2))" \
        CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1
}

check() {
    assert_eq "$1" "$2" "$(render "$3" "$4")"
}

session_payload() {
    printf '{"cwd":"/nonexistent","session_id":"%s"}' "$1"
}

a='{"cwd":"/nonexistent","session_id":"fixture-a"}'
b='{"cwd":"/nonexistent","session_id":"fixture-b"}'
check "no session ID keeps the version hidden" "" '{"cwd":"/nonexistent"}' 0
check "a null session ID keeps the version hidden" "" '{"cwd":"/nonexistent","session_id":null}' 0
check "a numeric session ID keeps the version hidden" "" '{"cwd":"/nonexistent","session_id":0}' 0
check "the first session opens with the version notice" "$version" "$a" 0
check "the same session shows the notice during its window" "$version" "$a" 9
check "rolling the clock back before session start hides the notice" "" "$a" -5
check "the first session hides the notice at expiry" "" "$a" 10
check "the second session gets its own notice" "$version" "$b" 11
check "returning to the first session does not restart its notice" "" "$a" 12
check "the second session keeps its own expiry" "$version" "$b" 20
check "the second session expires even with interleaved renders" "" "$b" 21

printf '%s\n' 'VERSION_SHOW_DURATION=abc' >> "$sb/cortado.conf"
c='{"cwd":"/nonexistent","session_id":"fixture-c"}'
check "invalid duration uses the default without printing a diagnostic" "$version" "$c" 30
check "default duration expires after 120 seconds" "" "$c" 150

new_sandbox 0
check "zero duration hides the notice at session start" "" "$a" 0
check "zero duration still hides the notice after clock rollback" "" "$a" -5
for id in b c d e; do
    check "zero duration hides a new session's notice ($id)" "" \
        "{\"cwd\":\"/nonexistent\",\"session_id\":\"disabled-$id\"}" 0
done
assert_eq "zero duration leaves no version cache files after five sessions" "0" \
    "$(find "$sb" -type f -name 'version*' | awk 'END { print NR }')"

new_sandbox 10
mixed_a=$(session_payload aAa)
mixed_b=$(session_payload aAG)
check "aAa gets its initial notice" "$version" "$mixed_a" 0
check "aAa expires" "" "$mixed_a" 10
check "aAG gets its own notice on a case-insensitive filesystem" "$version" "$mixed_b" 11
check "rendering aAG does not restart aAa" "" "$mixed_a" 12
check "aAG retains its own expiry" "" "$mixed_b" 21

new_sandbox 10
for ((i=1; i<=80; i++)); do
    out=$(render "$(session_payload "fixture-$i")" "$i")
    if [ "$out" != "$version" ]; then
        assert_eq "a new ID gets a notice while filling the cache (fixture-$i)" "$version" "$out"
        break
    fi
done
assert_eq "80 sessions retain at most one version data file and its lock" yes \
    "$([ "$(find "$sb/cortado-cache" -type f | awk 'END { print NR }')" -le 2 ] && echo yes)"
assert_eq "80 sessions leave exactly 32 recent records" 32 \
    "$(jq 'length' "$sb/cortado-cache/version_sessions" 2>/dev/null)"
check "the latest session still has its original window" "$version" "$(session_payload fixture-80)" 81
check "the previous session still has its original window" "$version" "$(session_payload fixture-79)" 83
check "the previous session expires on time" "" "$(session_payload fixture-79)" 89
check "the latest session expires on time" "" "$(session_payload fixture-80)" 90
check "the oldest retained session remains expired" "" "$(session_payload fixture-49)" 100
check "an evicted session can open a fresh window" "$version" "$(session_payload fixture-48)" 100

# Hold the first writer immediately before publication so a second render
# must wait for that snapshot before updating the shared cache.
cat > "$TEST_BASE/bin/mv" <<'STUB'
#!/bin/bash
# Report whether this publishing process holds a descriptor for the session lock.
if [ -n "${TEST_VERSION_LOCK_PROBE:-}" ] &&
    [ "${!#}" = "$CLAUDE_CONFIG_DIR/cortado-cache/version_sessions" ]; then
    perl -e '
        my @target = stat($ARGV[0]) or exit;
        for my $fd (3..32) {
            open(my $fh, "<&", $fd) or open($fh, ">&", $fd) or next;
            my @file = stat($fh);
            if (@file && $file[0] == $target[0] && $file[1] == $target[1]) {
                print "inherited\n";
                last;
            }
        }
    ' "$CLAUDE_CONFIG_DIR/cortado-cache/version_sessions-lock" > "$TEST_VERSION_LOCK_PROBE"
fi
if [ -n "${TEST_PAUSE_VERSION_WRITE:-}" ] &&
    [ "${!#}" = "$CLAUDE_CONFIG_DIR/cortado-cache/version_sessions" ]; then
    touch "$TEST_PAUSE_VERSION_WRITE/staged"
    for ((i=0; i<100; i++)); do
        [ ! -f "$TEST_PAUSE_VERSION_WRITE/release" ] || break
        sleep 0.05
    done
fi
exec /bin/mv "$@"
STUB
chmod +x "$TEST_BASE/bin/mv"

await_file() {
    local i
    for ((i=0; i<$2; i++)); do
        [ ! -f "$1" ] || return 0
        sleep 0.05
    done
    [ -f "$1" ]
}

new_sandbox 10
TEST_PAUSE_VERSION_WRITE="$TEST_BASE" render "$a" 100 > "$TEST_BASE/first.out" &
first_pid=$!
assert_eq "the first session stages its state before the other writer starts" yes \
    "$(await_file "$TEST_BASE/staged" 60 && echo yes)"
(
    TEST_SECOND_READY="$TEST_BASE/second.ready" render "$b" 102 > "$TEST_BASE/second.out"
    touch "$TEST_BASE/second.done"
) &
second_pid=$!
assert_eq "a second render overlaps the first writer" yes \
    "$(await_file "$TEST_BASE/second.ready" 20 && echo yes)"
await_file "$TEST_BASE/second.done" 20 || :
touch "$TEST_BASE/release"
wait "$first_pid"
wait "$second_pid"
assert_eq "the first overlapping render shows its version" "$version" "$(cat "$TEST_BASE/first.out")"
assert_eq "the second overlapping render shows its version" "$version" "$(cat "$TEST_BASE/second.out")"
check "the first overlapping session expires on time" "" "$a" 110
check "the second overlapping session remains visible while in its window" "$version" "$b" 111
check "the second overlapping session expires on time" "" "$b" 112

new_sandbox 10
TEST_VERSION_LOCK_PROBE="$TEST_BASE/lock.probe" render "$a" 0 > /dev/null
assert_eq "the session list is published by a process holding its lock" inherited \
    "$(cat "$TEST_BASE/lock.probe" 2>/dev/null)"

# A symlinked cache directory is refused, whatever its target's mode.
for target_mode in 755 700; do
    new_sandbox 10
    mkdir -m "$target_mode" "$sb/outside"
    ln -s "$sb/outside" "$sb/cortado-cache"
    check "a symlinked cache directory to a $target_mode target hides the notice" "" "$a" 0
    assert_eq "a symlinked cache directory leaves its $target_mode target alone" "$target_mode:" \
        "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$sb/outside"):$(ls -A "$sb/outside")"
done

# A symlinked session list is neither read nor written through. The planted
# list says fixture-a started long ago, in the stored (base64 ID) form.
new_sandbox 10
mkdir -m 700 "$sb/cortado-cache"
planted=$(jq -cn --arg id fixture-a --argjson seen "$((now - 1000))" '[{id: ($id | @base64), first_seen: $seen}]')
printf '%s\n' "$planted" > "$TEST_BASE/planted-sessions"
ln -s "$TEST_BASE/planted-sessions" "$sb/cortado-cache/version_sessions"
check "a symlinked session list cannot end a new session's notice" "$version" "$a" 0
assert_eq "a symlinked session list's target is unchanged" "$planted" "$(cat "$TEST_BASE/planted-sessions")"

REAL_JQ=$(command -v jq) || exit 1
export REAL_JQ
export JQ_CALLS="$TEST_BASE/jq.calls"
cat > "$TEST_BASE/bin/jq" <<'STUB'
#!/bin/bash
printf '%s\n' jq >> "$JQ_CALLS"
exec "$REAL_JQ" "$@"
STUB
chmod 700 "$TEST_BASE/bin/jq"
new_sandbox 10
check 'a fresh Unicode session shows its version' "$version" "$(session_payload '☕ café')" 0
assert_eq 'a new session uses only the payload jq process' 1 "$(wc -l < "$JQ_CALLS" | tr -d ' ')"
: > "$JQ_CALLS"
check 'a Unicode session keeps its window' "$version" "$(session_payload '☕ café')" 9
assert_eq 'a warm session uses only the payload jq process' 1 "$(wc -l < "$JQ_CALLS" | tr -d ' ')"
check 'a Unicode session expires at its original deadline' "" "$(session_payload '☕ café')" 10

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
