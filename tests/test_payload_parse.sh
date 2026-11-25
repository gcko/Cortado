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
cat > "$scratch/bin/curl" <<'SHIM'
#!/bin/bash
[ "${FIXTURE_FETCH:-false}" = true ] || exit 7
body=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then body=$2; shift; fi
    shift
done
IFS= read -r auth
[ "$auth" = 'header = "Authorization: Bearer test-token-REDACTED"' ] || exit 7
[ -n "$body" ] || exit 7
printf '%s\n' '{"five_hour":{"utilization":42},"seven_day":{"utilization":10}}' > "$body"
printf 200
SHIM
chmod 700 "$scratch/bin/jq" "$scratch/bin/bc" "$scratch/bin/curl"

render() {
    local payload="$1"
    shift
    sandbox=$(mktemp -d "$scratch/render.XXXXXX") || exit 1
    printf '%s\n' "$@" > "$sandbox/cortado.conf"
    chmod 600 "$sandbox/cortado.conf"
    if [ -n "${usage_seed:-}" ]; then
        mkdir -m 700 "$sandbox/cortado-cache"
        printf '%s\n' "$usage_seed" > "$sandbox/cortado-cache/rate_limits_usage"
    fi
    if [ "${FIXTURE_FETCH:-false}" = true ]; then
        (
            umask 077
            {
                printf '%s\n' '{' '  "claudeAiOauth":{"accessToken":"test-token-REDACTED"}' '}'
                printf '%b' "${credential_suffix:-}"
            } > "$sandbox/.credentials.json"
        )
        chmod 600 "$sandbox/.credentials.json"
    fi
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
assert_not_contains "an absent spend limit adds no text" 'spend:' "$rendered"

usage_seed='{"five_hour_opus":{"utilization":42},"seven_day_sonnet":{"utilization":10}}' render '{}'
assert_eq "the default render with a fresh quota cache launches exactly one jq process" \
    '1' "$(awk 'END {print NR}' "$sandbox/jq.calls")"
assert_contains "fresh quota cache shows both readings, including aliases" '5h:42% 🟢 7d:10% 🟢' "$rendered"

FIXTURE_FETCH=true render '{}'
assert_eq "the default render with a successful quota fetch launches exactly one jq process" \
    '1' "$(awk 'END {print NR}' "$sandbox/jq.calls")"
assert_contains "the fetched quota shows both readings" '5h:42% 🟢 7d:10% 🟢' "$rendered"

for credential_suffix in '{}' '\000'; do
    FIXTURE_FETCH=true render '{}'
    assert_contains "a credential file with trailing data cannot reach the quota API" '5h:-- 7d:--' "$rendered"
    assert_eq "rejecting bad credentials still uses exactly one jq process" \
        '1' "$(awk 'END {print NR}' "$sandbox/jq.calls")"
done
unset credential_suffix

render '{"model":{"display_name":"Claude Opus"},"cost":{"total_cost_usd":0.5234,"total_duration_ms":12345},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000},"total_input_tokens":150000,"total_output_tokens":25000},"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":10},"spend_limit":{"used_percentage":25,"used_usd":12.4,"limit_usd":50,"period":"monthly","resets_at":1740787200}}}'
assert_eq "the default post-turn render with a spend limit launches exactly one jq process" \
    '1' "$(awk 'END {print NR}' "$sandbox/jq.calls")"
assert_eq "cost rendering launches no bc process" '0' "$(awk 'END {print NR}' "$sandbox/bc.calls" 2>/dev/null || printf 0)"
assert_contains "fixed-point cost retains cent truncation and integer TPM" "\$0.52 @\$152.63/h ⚡850ktpm" "$rendered"
assert_contains "the parsed context token count still drives the estimate" '25% 🟢 (110k→⚡)' "$rendered"
assert_contains "spend shows estimated dollars against the budget next to the other quotas" \
    "5h:42% 🟢 7d:10% 🟢 spend:\$12.40/\$50.00" "$rendered"

spend_config=('MODULE_ORDER="rate-limits"' 'COLOR_THEME="monochrome"')
render '{"rate_limits":{"spend_limit":{"used_percentage":124.6}}}' "${spend_config[@]}"
assert_contains "spend above the limit stays above 100 percent when USD is missing" \
    '5h:-- 7d:-- spend:125% [CRIT]' "$rendered"
render '{"rate_limits":{"spend_limit":{"used_percentage":0,"used_usd":null,"limit_usd":50}}}' "${spend_config[@]}"
assert_contains "a measured zero percentage survives null dollar usage" 'spend:0% [OK]' "$rendered"
render '{"rate_limits":{"spend_limit":{"used_usd":0,"limit_usd":50}}}' "${spend_config[@]}" \
    'RATE_SHOW_5H="false"' 'RATE_SHOW_7D="false"'
assert_eq "spend has its own reading even when both quota windows are hidden" "spend:\$0.00/\$50.00" "$rendered"
render '{"rate_limits":{"spend_limit":{"used_percentage":25,"used_usd":"12.4","limit_usd":50}}}' \
    "${spend_config[@]}" 'RATE_SHOW_USAGE_STATUS="false"'
assert_eq "non-numeric dollars fall back to the measured percentage with indicators off" \
    '5h:-- 7d:-- spend:25%' "$rendered"

for spend in null '{}' '"invalid"' '{"used_percentage":null}' '{"used_percentage":"25"}' \
    '{"used_percentage":-1}' '{"used_usd":-1,"limit_usd":50}' \
    '{"used_usd":12.4,"limit_usd":0}' '{"used_usd":12.4,"limit_usd":-50}'; do
    render "{\"rate_limits\":{\"spend_limit\":$spend}}" "${spend_config[@]}"
    assert_eq "unusable spend leaves just the quota placeholders ($spend)" '5h:-- 7d:--' "$rendered"
done

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

inspect_context() {
    local variable declaration flags readonly_count=0
    for variable in CTX_CURRENT_DIR CTX_CONTEXT_PERCENT CTX_CONTEXT_SIZE CTX_CURRENT_TOKENS \
        CTX_COST_USD CTX_DURATION_MS CTX_TOTAL_IN CTX_TOTAL_OUT CTX_MODEL_NAME \
        CTX_OUTPUT_STYLE CTX_THINKING CTX_EFFORT CTX_SESSION_ID CTX_HAS_RATES \
        CTX_FIVE_HOUR CTX_SEVEN_DAY CTX_FIVE_RESET CTX_SEVEN_RESET \
        CTX_SPEND_PERCENT CTX_SPEND_USED_USD CTX_SPEND_LIMIT_USD; do
        declaration=$(declare -p "$variable") || continue
        flags=${declaration#declare -}
        case "${flags%% *}" in *r*) readonly_count=$((readonly_count + 1));; esac
    done
    printf '%s readonly fields, context: %s, cost: %s, quotas: %s/%s\n' \
        "$readonly_count" "$CTX_CONTEXT_PERCENT" "$CTX_COST_USD" "$CTX_FIVE_HOUR" "$CTX_SEVEN_DAY"
}

inspect_payload() (
    # shellcheck source=modules/utils.sh
    . "$PROJECT_ROOT/modules/utils.sh"
    PATH="$scratch/bin:$PATH" CLAUDE_CONFIG_DIR="$sandbox" \
        with_payload_context inspect_context <<< "$1"
)

readonly_missing='21 readonly fields, context: -, cost: -, quotas: -/-'
assert_eq "empty payload freezes the absence sentinels" "$readonly_missing" "$(inspect_payload '{}')"
assert_eq "malformed payload freezes the absence sentinels" "$readonly_missing" "$(inspect_payload 'invalid JSON')"
assert_eq "measured zero is a readonly reading" '21 readonly fields, context: 0, cost: 0, quotas: 0/-' \
    "$(inspect_payload '{"cost":{"total_cost_usd":0},"context_window":{"used_percentage":0},"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{}}}')"

export FAIL_JQ=true
assert_eq "failed jq freezes the absence sentinels" "$readonly_missing" "$(inspect_payload '{}')"
render '{"context_window":{"used_percentage":0},"rate_limits":{"spend_limit":{"used_percentage":12}}}'
assert_contains "a failing jq does not turn unread context into zero" '📊 --' "$rendered"
assert_contains "a failing jq does not turn unread quota into zero" '5h:-- 7d:--' "$rendered"
assert_not_contains "a failing jq leaves unread spend hidden" 'spend:' "$rendered"

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
