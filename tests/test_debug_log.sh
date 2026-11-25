#!/bin/bash
# Debug log tests cover repeated rotation, file modes and simultaneous renders.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BASE="$(mktemp -d)"
trap 'rm -rf "$TEST_BASE"' EXIT

. "$PROJECT_ROOT/tests/lib/assert.sh" plain
assert_log_size() {
    local desc="$1" file="$2" lower="$3" upper="$4"
    local size=0
    if [ -f "$file" ]; then size=$(wc -c < "$file"); fi
    if [ "$size" -ge "$lower" ] && [ "$size" -le "$upper" ]; then
        pass "$desc"
    else
        fail "$desc (expected $lower through $upper bytes, got $((size)))"
    fi
}

assert_private() {
    local file="$1" mode=''
    if [ -f "$file" ]; then
        if [ "$(uname)" = Darwin ]; then
            mode=$(/usr/bin/stat -f '%Lp' "$file")
        else
            mode=$(stat -c '%a' "$file")
        fi
    fi
    if [ "$mode" = 600 ]; then pass "${file##*/} is owner-only"
    else fail "${file##*/} is owner-only (got [${mode:-missing}])"
    fi
}

export CLAUDE_CONFIG_DIR="$(mktemp -d "$TEST_BASE/rotation.XXXXXX")"
export CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
DEBUG_MODE=true
# shellcheck source=/dev/null
. "$PROJECT_ROOT/modules/utils.sh"

cap=1048576
log="$CLAUDE_CONFIG_DIR/cortado.log"
umask 022
printf -v chunk '%270000s' ''
log_debug "first archive marker$chunk"
chmod 644 "$log"
for n in 2 3 4 5 6 7 8 9 10; do
    log_debug "record $n$chunk"
done
assert_log_size 'The current log contains the latest batch within 1 MiB' "$log" 270000 "$cap"
assert_log_size 'The previous batch is kept within 1 MiB' "$log.1" 810000 "$cap"
assert_private "$log"
assert_private "$log.1"
if grep -q 'record 10' "$log" && grep -q 'record 9' "$log.1"; then
    pass 'Both generations contain their expected entries'
else
    fail 'Both generations contain their expected entries'
fi
if [ -f "$log.1" ] && ! grep -q 'first archive marker' "$log.1" && [ ! -e "$log.2" ]; then
    pass 'A later rotation replaces the older archive'
else
    fail 'A later rotation replaces the older archive'
fi

# Two real statusline calls share a nearly-full log. Distinct marker values
# identify the diagnostics so the test can detect either writer being lost.
RUNTIME_TREE="$TEST_BASE/runtime"
mkdir "$RUNTIME_TREE"
cp "$PROJECT_ROOT/cortado.sh" "$PROJECT_ROOT/cortado.conf" "$RUNTIME_TREE/"
cp -R "$PROJECT_ROOT/modules" "$RUNTIME_TREE/"
cp "$SCRIPT_DIR/module-error-fixture.sh" "$RUNTIME_TREE/modules/zz-runtime-test.sh" || exit 1
export CLAUDE_CONFIG_DIR="$(mktemp -d "$TEST_BASE/concurrent.XXXXXX")"
export CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
log="$CLAUDE_CONFIG_DIR/cortado.log"
printf '%1048572s\n' 'previous generation' > "$log"
cat > "$CLAUDE_CONFIG_DIR/cortado.conf" <<'EOF'
DEBUG_MODE="true"
MODULE_ORDER="uptime,model"
MODULE_UPTIME="true"
MODULE_MODEL="true"
LAYOUT_MODE="none"
EOF
chmod 600 "$CLAUDE_CONFIG_DIR/cortado.conf"
payload='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"}}'
for id in one two; do
    printf '%s' "$payload" | TEST_RUNTIME_DIAGNOSTIC="concurrent diagnostic $id" /bin/bash "$RUNTIME_TREE/cortado.sh" \
        > "$TEST_BASE/$id.out" 2> "$TEST_BASE/$id.err" &
    if [ "$id" = one ]; then first_pid=$!; else second_pid=$!; fi
done
wait "$first_pid"
first_status=$?
wait "$second_pid"
second_status=$?
if [ "$first_status" -eq 0 ] && [ "$second_status" -eq 0 ]; then pass 'Both concurrent renders exit successfully'
else fail 'Both concurrent renders exit successfully'
fi
for id in one two; do
    out=$(cat "$TEST_BASE/$id.out")
    case "$out" in
        'Fixture reading | 🤖 Opus')
            if [ ! -s "$TEST_BASE/$id.err" ]; then
                pass "Concurrent render $id keeps diagnostics out of the line"
            else
                fail "Concurrent render $id keeps diagnostics out of the line"
            fi
            ;;
        *) fail "Concurrent render $id keeps both readings (got [$out])" ;;
    esac
    if [ "$(grep -c "uptime: concurrent diagnostic $id$" "$log")" -eq 1 ]; then
        pass "Concurrent render $id appends its diagnostic to the current log"
    else
        fail "Concurrent render $id appends its diagnostic to the current log"
    fi
done
assert_log_size 'The concurrent rotation preserves the full previous generation' "$log.1" 1048573 1048573
assert_log_size 'The current log is small after concurrent rotation' "$log" 1 4096
assert_private "$log"
assert_private "$log.1"

# Mark the critical section before suspending a writer so the contender
# cannot start too early. Each background writer gets its own process group.
check_blocked_writers() (
    set -m
    local holder contender marker
    local sync="$TEST_BASE/lock-sync"
    mkdir "$sync"
    local log="$sync/cortado.log"
    CLAUDE_CONFIG_DIR="$sync" log_debug seed

    paused_writer() (
        # Invoked by log_debug while it holds the lock.
        # shellcheck disable=SC2329
        chmod() {
            : > "$sync/inside"
            while [ ! -f "$sync/release" ]; do /bin/sleep 0.02; done
            command chmod "$@"
        }
        log_debug "$1"
    )
    await_holder() {
        local retry
        for ((retry = 0; retry < 250; retry++)); do
            [ ! -f "$sync/inside" ] || return 0
            /bin/sleep 0.02
        done
        return 1
    }

    CLAUDE_CONFIG_DIR="$sync" paused_writer holder &
    holder=$!
    trap 'kill -KILL -- "-$holder" 2>/dev/null || :' EXIT
    await_holder || return 1
    CLAUDE_CONFIG_DIR="$sync" log_debug contender &
    contender=$!
    /bin/sleep 1.5
    : > "$sync/release"
    wait "$holder" && wait "$contender" || return 1

    rm -f "$sync/inside" "$sync/release"
    CLAUDE_CONFIG_DIR="$sync" paused_writer killed &
    holder=$!
    await_holder || return 1
    kill -KILL -- "-$holder"
    wait "$holder" 2>/dev/null || :
    CLAUDE_CONFIG_DIR="$sync" log_debug recovery-one
    CLAUDE_CONFIG_DIR="$sync" log_debug recovery-two

    local count failed=0
    for marker in holder contender recovery-one recovery-two; do
        count=$(cat "$log" "$log.1" 2>/dev/null | grep -c "] $marker$")
        if [ "$count" -ne 1 ]; then
            printf '  %s appears %s times\n' "$marker" "$count"
            failed=1
        fi
    done
    return "$failed"
)
if check_blocked_writers; then
    pass 'A live contender and both writes after SIGKILL survive exactly once'
else
    fail 'A live contender and both writes after SIGKILL survive exactly once'
fi

(
    # The old log_debug called sleep even when opening the lock could never succeed.
    # shellcheck disable=SC2329
    sleep() { : > "$TEST_BASE/unusable-parent-slept"; }
    CLAUDE_CONFIG_DIR="$TEST_BASE/nonexistent/config" log_debug 'unwritable parent'
) 2> "$TEST_BASE/unusable-parent.err"
if [ ! -e "$TEST_BASE/unusable-parent-slept" ] && [ ! -s "$TEST_BASE/unusable-parent.err" ]; then
    pass 'An unusable parent fails quietly without contention sleeps'
else
    fail 'An unusable parent fails quietly without contention sleeps'
fi

export CLAUDE_CONFIG_DIR="$(mktemp -d "$TEST_BASE/size.XXXXXX")"
log="$CLAUDE_CONFIG_DIR/cortado.log"
printf '%1048575s\n' 'full generation' > "$log"
(
    OSTYPE=linux-gnu
    # Exercise the GNU stat failure path of the earlier implementation.
    # shellcheck disable=SC2329
    stat() { return 1; }
    log_debug 'rotate without stat'
)
assert_log_size 'Rotation works when stat cannot read a full generation' "$log.1" "$cap" "$cap"
assert_log_size 'An append without stat still fits the cap' "$log" 1 "$cap"
if grep -q 'rotate without stat' "$log"; then pass 'The new generation contains the marker'
else fail 'The new generation contains the marker'
fi

(
    # Invoked by log_debug when checking the current log.
    # shellcheck disable=SC2329
    wc() { return 1; }
    log_debug 'skip unknown size'
) 2> "$TEST_BASE/unknown-size.err"
if ! grep -q 'skip unknown size' "$log" && [ ! -s "$TEST_BASE/unknown-size.err" ]; then
    pass 'A byte-count failure skips the append quietly'
else
    fail 'A byte-count failure skips the append quietly'
fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
