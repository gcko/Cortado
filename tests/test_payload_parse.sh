#!/bin/bash
# Render through the shipped entry point with a counted jq and a failing bc.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain-dash

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/workspace"
export REAL_JQ
REAL_JQ=$(command -v jq) || exit 1
cat > "$scratch/bin/jq" <<'SHIM'
#!/bin/bash
printf '%s\n' jq >> "$CLAUDE_CONFIG_DIR/jq.calls"
[ "${FAIL_JQ:-false}" != true ] || exit 1
exec "$REAL_JQ" "$@"
SHIM
cat > "$scratch/bin/bc" <<'SHIM'
#!/bin/bash
printf '%s\n' bc >> "$CLAUDE_CONFIG_DIR/bc.calls"
exit 1
SHIM
chmod 700 "$scratch/bin/jq" "$scratch/bin/bc"

render() {
    local payload="$1"
    shift
    sandbox=$(mktemp -d "$scratch/render.XXXXXX") || exit 1
    printf '%s\n' "$@" > "$sandbox/cortado.conf"
    chmod 600 "$sandbox/cortado.conf"
    if [ -n "${history_seed:-}" ]; then
        mkdir -m 700 "$sandbox/cortado-cache"
        printf '%s\n' "$history_seed" > "$sandbox/.usage_history"
        printf '%s\n' "$now" > "$sandbox/cortado-cache/rate_limits_payload_recorded"
    fi
    rendered=$(cd "$scratch/workspace" &&
        printf '%s' "$payload" | PATH="$scratch/bin:$PATH" CLAUDE_CONFIG_DIR="$sandbox" \
            CACHE_DIR="$sandbox/cortado-cache" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>"$sandbox/stderr")
    assert_eq "the renderer emits no diagnostics" "" "$(cat "$sandbox/stderr")"
}

render '{}'
assert_eq "the default startup render launches exactly one jq process" \
    '1' "$(awk 'END {print NR}' "$sandbox/jq.calls")"
assert_contains "missing context usage reads as absent" '📊 --' "$rendered"
assert_contains "missing quota readings read as absent" '5h:-- 7d:--' "$rendered"

render '{"model":{"display_name":"Claude Opus"},"cost":{"total_cost_usd":0.5234,"total_duration_ms":12345},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000},"total_input_tokens":150000,"total_output_tokens":25000},"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":10}}}'
assert_eq "the default post-turn render launches exactly one jq process" \
    '1' "$(awk 'END {print NR}' "$sandbox/jq.calls")"
assert_eq "cost rendering launches no bc process" '0' "$(awk 'END {print NR}' "$sandbox/bc.calls" 2>/dev/null || printf 0)"
assert_contains "fixed-point cost retains cent truncation and integer TPM" "\$0.52 @\$152.63/h ⚡850ktpm" "$rendered"
assert_contains "the parsed context token count still drives the estimate" '25% 🟢 (110k→⚡)' "$rendered"

# shellcheck disable=SC2016
render '{"model":{"display_name":"Model \u0027quoted\u0027 $(printf expanded)"},"context_window":{"used_percentage":0},"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":null}}}'
assert_contains "quoted shell punctuation is displayed literally" "Model 'quoted' \$(printf expanded)" "$rendered"
assert_contains "a measured zero differs from an absent context reading" '0% 🟢' "$rendered"
assert_contains "measured zero and null quota render separately" '5h:0% 🟢 7d:--' "$rendered"

render '{"context_window":{"current_usage":null,"used_percentage":null},"rate_limits":{"five_hour":{"used_percentage":null},"seven_day":{"used_percentage":null}}}'
assert_contains "null context usage reads as absent" '📊 --' "$rendered"
assert_contains "null quota readings read as absent" '5h:-- 7d:--' "$rendered"

render '{"context_window":{"used_percentage":99.5},"rate_limits":{"five_hour":{"used_percentage":0.5},"seven_day":{"used_percentage":99.5}}}'
assert_contains "fractional context continues to floor" '99% 🔴' "$rendered"
assert_contains "fractional quota retains nearest-even rounding" '5h:0% 🟢 7d:100% 🔴' "$rendered"
render '{"context_window":{"used_percentage":100},"rate_limits":{"five_hour":{"used_percentage":100},"seven_day":{"used_percentage":101}}}'
assert_contains "a full context keeps the full bar" '████████ 100% 🔴' "$rendered"
assert_contains "an out-of-range quota is absent" '5h:100% 🔴 7d:--' "$rendered"

now=$(date +%s)
history_seed="$((now - 1000)),10,10,2099-01-01T00:00:00,"$'\n'"$((now - 500)),49.9,10,2099-01-01T00:00:00,"
render '{"rate_limits":{"five_hour":{"used_percentage":70,"resets_at":"2099-01-01T00:00:00"},"seven_day":{"used_percentage":10}}}' \
    'RATE_SHOW_TIME_REMAINING="false"'
unset history_seed
assert_contains "the projected five-hour limit still shows a critical indicator" '5h:70% 🟡 🔴' "$rendered"
assert_eq "projection rendering launches no bc process" '0' "$(awk 'END {print NR}' "$sandbox/bc.calls" 2>/dev/null || printf 0)"

export FAIL_JQ=true
render '{"context_window":{"used_percentage":0}}'
assert_contains "a failing jq does not turn unread context into zero" '📊 --' "$rendered"
assert_contains "a failing jq does not turn unread quota into zero" '5h:-- 7d:--' "$rendered"

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
