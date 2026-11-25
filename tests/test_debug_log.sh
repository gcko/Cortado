#!/bin/bash
# Debug log tests cover repeated rotation, file modes and simultaneous renders.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BASE="$(mktemp -d)"
trap 'rm -rf "$TEST_BASE"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

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
        mode=$(stat -f %Lp "$file" 2>/dev/null) || mode=$(stat -c %a "$file")
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

# Two real statusline calls share a nearly-full log. Distinct config values
# identify the diagnostics so the test can detect either writer being lost.
export CLAUDE_CONFIG_DIR="$(mktemp -d "$TEST_BASE/concurrent.XXXXXX")"
export CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
log="$CLAUDE_CONFIG_DIR/cortado.log"
printf '%1048572s\n' 'previous generation' > "$log"
cat > "$CLAUDE_CONFIG_DIR/cortado.conf" <<'EOF'
DEBUG_MODE="true"
MODULE_ORDER="version,model"
MODULE_VERSION="true"
MODULE_MODEL="true"
VERSION_SHOW_DURATION="${TEST_DURATION:-120}"
LAYOUT_MODE="none"
EOF
chmod 600 "$CLAUDE_CONFIG_DIR/cortado.conf"
payload='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"}}'
for id in one two; do
    printf '%s' "$payload" | TEST_DURATION="abc-$id" /bin/bash "$PROJECT_ROOT/cortado.sh" \
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
        '☕ v'*' | 🤖 Opus')
            if [ ! -s "$TEST_BASE/$id.err" ] && [[ "$out" != *'integer expression expected'* ]]; then
                pass "Concurrent render $id keeps diagnostics out of the line"
            else
                fail "Concurrent render $id keeps diagnostics out of the line"
            fi
            ;;
        *) fail "Concurrent render $id keeps both readings (got [$out])" ;;
    esac
    if grep -q "version: .*abc-$id: integer expression expected" "$log"; then
        pass "Concurrent render $id appends its diagnostic to the current log"
    else
        fail "Concurrent render $id appends its diagnostic to the current log"
    fi
done
assert_log_size 'The concurrent rotation preserves the full previous generation' "$log.1" 1048573 1048573
assert_log_size 'The current log is small after concurrent rotation' "$log" 1 4096
assert_private "$log"
assert_private "$log.1"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
