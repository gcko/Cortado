#!/bin/bash
# Render context readings through the statusline, including a startup payload.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain-comma

render() (
    sb=$(mktemp -d)
    trap 'rm -rf "$sb"' EXIT
    payload="$1"
    shift
    printf '%s\n' 'MODULE_ORDER="context"' 'MODULE_CONTEXT="true"' \
        'COLOR_THEME="monochrome"' 'TERMINAL_WIDTH=200' "$@" > "$sb/cortado.conf"
    printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$sb" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1
)

check() {
    local desc="$1" expected="$2" actual
    shift 2
    actual=$(render "$@")
    assert_eq "$desc" "$expected" "$actual"
}

check "usage without a window size shows absence" "CTX: --" \
    '{"cwd":"/nonexistent","model":{"display_name":"Opus[1m]"},"context_window":{"current_usage":{"input_tokens":500000}}}'
check "a million-token window keeps the computed reading" "CTX: ████░░░░ 50% [OK] (300k→⚡)" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":500000}}}'
check "a 200k window still totals all token counters" "CTX: ██░░░░░░ 25% [OK] (110k→⚡)" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":20000,"output_tokens":5000,"cache_read_input_tokens":15000,"cache_creation_input_tokens":10000}}}'
check "usage with a null window size shows absence" "CTX: --" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":null,"current_usage":{"input_tokens":500000}}}'
check "usage with a zero window size shows absence" "CTX: --" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":0,"current_usage":{"input_tokens":500000}}}'
check "startup with no current usage shows absence" "CTX: --" \
    '{"session_id":"fixture-start","workspace":{"current_dir":"/nonexistent"},"model":{"display_name":"Opus[1m]"},"context_window":{"context_window_size":1000000},"effort":{"level":"high"},"thinking":{"enabled":true}}'
check "null current usage and null percentage show absence" "CTX: --" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":null,"used_percentage":null}}'
check "empty token counters show absence" "CTX: --" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":null}}}'
check "null percentage falls back to the token-derived reading" "CTX: ████░░░░ 50% [OK] (300k→⚡)" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":500000},"used_percentage":null}}'
check "a conflicting payload percentage hides the count-derived estimate" "CTX: ████░░░░ 62% [WARN]" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":100000},"used_percentage":62}}'
check "authoritative usage over the compaction threshold hides a conflicting estimate" "CTX: ███████░ 90% [CRIT]" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":100000},"used_percentage":90}}'
check "agreement at display precision keeps the count-derived estimate" "CTX: ████░░░░ 50% [OK] (300k→⚡)" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":500000},"used_percentage":50.9}}'
check "an explicit percentage works without token counts or size" "CTX: ████░░░░ 62% [WARN]" \
    '{"cwd":"/nonexistent","context_window":{"used_percentage":62.5}}'
check "a measured zero percentage shows zero" "CTX: ░░░░░░░░ 0% [OK]" \
    '{"cwd":"/nonexistent","context_window":{"used_percentage":0}}'
check "a measured zero token count shows zero" "CTX: ░░░░░░░░ 0% [OK] (800k→⚡)" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":0}}}'

small_usage='{"cwd":"/nonexistent","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":10000}}}'
check "a zero-padded compaction threshold uses decimal arithmetic" "CTX: ░░░░░░░░ 5% [OK] (6k→⚡)" \
    "$small_usage" 'CONTEXT_COMPACT_THRESHOLD=08'
check "a signed zero-padded compaction threshold still clamps the estimate" "CTX: ░░░░░░░░ 5% [OK] (0→⚡)" \
    "$small_usage" 'CONTEXT_COMPACT_THRESHOLD=-08'
check "a malformed compaction threshold keeps the default estimate" "CTX: ░░░░░░░░ 5% [OK] (150k→⚡)" \
    "$small_usage" 'CONTEXT_COMPACT_THRESHOLD=abc'

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
