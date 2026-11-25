#!/bin/bash
# Render context readings through the statusline, including a startup payload.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

render() (
    sb=$(mktemp -d)
    trap 'rm -rf "$sb"' EXIT
    printf '%s\n' 'MODULE_ORDER="context"' 'MODULE_CONTEXT="true"' \
        'COLOR_THEME="monochrome"' 'TERMINAL_WIDTH=200' > "$sb/cortado.conf"
    printf '%s' "$1" | CLAUDE_CONFIG_DIR="$sb" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1
)

check() {
    local desc="$1" expected="$2" actual
    actual=$(render "$3")
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (expected [%s] got [%s])\n' "$desc" "$expected" "$actual"
    fi
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
check "an explicit payload percentage wins over the token-derived percentage" "CTX: ████░░░░ 62% [WARN] (700k→⚡)" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":100000},"used_percentage":62}}'
check "an explicit percentage works without token counts or size" "CTX: ████░░░░ 62% [WARN]" \
    '{"cwd":"/nonexistent","context_window":{"used_percentage":62.5}}'
check "a measured zero percentage shows zero" "CTX: ░░░░░░░░ 0% [OK]" \
    '{"cwd":"/nonexistent","context_window":{"used_percentage":0}}'
check "a measured zero token count shows zero" "CTX: ░░░░░░░░ 0% [OK] (800k→⚡)" \
    '{"cwd":"/nonexistent","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":0}}}'

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
