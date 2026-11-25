#!/bin/bash
# =============================================================================
# Status Indicator Render Tests
# =============================================================================
# Drives cortado.sh the way Claude Code does (a JSON payload on stdin, a
# sandboxed CLAUDE_CONFIG_DIR) and asserts the rendered line shows exactly one
# status indicator per segment. get_status is correct in isolation; these tests
# exist because the module loop once ran modules with IFS=',', which made every
# indicator print all of its glyphs at once ("25% 🟢 🟡 🔴").
# Usage: bash tests/test_status_render.sh
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain

TEST_BASE="$(mktemp -d "${TMPDIR:-/tmp}/cortado-render-test.XXXXXX")"
trap 'rm -rf "$TEST_BASE"' EXIT

# render <name> <payload> [config lines...]: one fresh sandbox per render, so a
# cache planted for one scenario never leaks into the next.
render() {
    local name="$1" payload="$2"
    shift 2
    local sb="$TEST_BASE/$name"
    mkdir -p "$sb/cortado-cache"
    chmod 700 "$sb/cortado-cache"
    printf '%s\n' "$@" > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf"
    if [ -n "${SEED_RATE_LIMITS:-}" ]; then
        printf '%s' "$SEED_RATE_LIMITS" > "$sb/cortado-cache/rate_limits_usage"
    fi
    printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$sb" bash "$PROJECT_ROOT/cortado.sh" 2>&1
}

CONTEXT_25='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'

echo "=== a context reading shows one three-level indicator ==="

out=$(render ctx-mono "$CONTEXT_25" \
    'MODULE_ORDER="context,model"' 'MODULE_CONTEXT="true"' 'MODULE_MODEL="true"' \
    'COLOR_THEME="monochrome"')
assert_contains "a 25% context reading reads OK in monochrome" "25% [OK]" "$out"
assert_not_contains "a 25% context reading does not also claim WARN" "[WARN]" "$out"
assert_not_contains "a 25% context reading does not also claim CRIT" "[CRIT]" "$out"

out=$(render ctx-emoji "$CONTEXT_25" \
    'MODULE_ORDER="context,model"' 'MODULE_CONTEXT="true"' 'MODULE_MODEL="true"')
assert_contains "a 25% context reading is green in emoji" "25% 🟢" "$out"
assert_not_contains "a 25% context reading shows no yellow beside the green" "🟡" "$out"
assert_not_contains "a 25% context reading shows no red beside the green" "🔴" "$out"

echo ""
echo "=== a rate-limit reading shows one four-level indicator ==="

RESET="2099-01-01T00:00:00Z"
SEED_RATE_LIMITS=$(printf '{"five_hour":{"utilization":42,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"%s"}}' "$RESET" "$RESET")
export SEED_RATE_LIMITS
out=$(render rate-mono "$CONTEXT_25" \
    'MODULE_ORDER="rate-limits"' 'MODULE_RATE_LIMITS="true"' 'COLOR_THEME="monochrome"')
unset SEED_RATE_LIMITS
assert_contains "a 42% five-hour reading reads OK in monochrome" "5h:42%" "$out"
assert_not_contains "a 42% five-hour reading does not also claim MED" "[MED]" "$out"
assert_not_contains "a 42% five-hour reading does not also claim HIGH" "[HIGH]" "$out"
assert_not_contains "a 42% five-hour reading does not also claim CRIT" "[CRIT]" "$out"

echo ""
echo "=== module order still applies after the split ==="

out=$(render order "$CONTEXT_25" \
    'MODULE_ORDER="model, context"' 'MODULE_CONTEXT="true"' 'MODULE_MODEL="true"' \
    'COLOR_THEME="monochrome"')
first_line=$(printf '%s\n' "$out" | head -1)
case "$first_line" in
    MODEL:*CTX:*) pass "modules render in MODULE_ORDER, spaces after commas ignored" ;;
    *) fail "modules render in MODULE_ORDER (got [$first_line])" ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
