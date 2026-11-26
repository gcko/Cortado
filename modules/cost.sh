# shellcheck shell=bash
# @cortado-module cost
# @default true
# @args payload
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu core 9
# @description Session cost
# @config COST_ICON:string
# @config COST_SHOW_BURN_RATE:bool
# @config COST_SHOW_TPM:bool
# @config COST_TPM_ICON:string
# @config COST_DECIMAL_PLACES:int
# @config COST_COMPACT:bool
# @config COST_MINIMUM_DISPLAY:number
# =============================================================================
# Cost Module - Shows session cost, burn rate, and TPM
# =============================================================================
# Configuration options:
#   COST_ICON           - Icon before cost (default: 💰)
#   COST_SHOW_BURN_RATE - Show burn rate $/hour (default: true)
#   COST_SHOW_TPM       - Show tokens per minute (default: true)
#   COST_TPM_ICON       - Icon for TPM (default: ⚡)
#   COST_DECIMAL_PLACES - Decimal places for cost (default: 2)
#   COST_COMPACT        - Compact mode (default: false)
#   COST_MINIMUM_DISPLAY - Hide if below this amount (default: 0.01)
# =============================================================================

module_cost() {
    if [ "${CTX_READY:-}" != true ]; then
        with_payload_context module_cost <<< "${1:-}"
        return
    fi

    local show_burn="${COST_SHOW_BURN_RATE:-true}"
    local show_tpm="${COST_SHOW_TPM:-true}"
    local tpm_icon="${COST_TPM_ICON:-⚡}"
    local compact="${COST_COMPACT:-false}"
    local min_display="${COST_MINIMUM_DISPLAY:-0.01}"
    [[ "$min_display" =~ ^[0-9]+(\.[0-9]+)?$ ]] || min_display=0.01

    local LC_ALL=C
    local session_cost="${CTX_COST_USD:--}" session_duration_ms cost="" result=""
    decimal_int_reply "${CTX_DURATION_MS:--}" 0; session_duration_ms=$REPLY

    if decimal_fixed_reply "$session_cost"; then
        cost=$REPLY
        if ! decimal_fixed_reply "$min_display" || [ "$cost" -lt "$REPLY" ]; then
            # Positive sub-minimum costs have always hidden the segment.
            # A zero-cost session can still report its token rate.
            [ "$cost" -eq 0 ] || return 0
            cost=
        fi
    fi

    if [ -n "$cost" ]; then
        local decimals cost_fmt icon
        session_cost="${session_cost#-}"  # Normalize signed zero.
        safe_int_reply "${COST_DECIMAL_PLACES:-2}" 2; decimals=$REPLY
        printf -v cost_fmt "%.${decimals}f" "$session_cost" 2>/dev/null || cost_fmt="$session_cost"
        get_icon_reply "${COST_ICON:-💰}" "COST:"; icon=$REPLY
        result="$icon \$${cost_fmt}"

        if [ "$show_burn" = "true" ] && ! is_compact "$compact" &&
            [ "$session_duration_ms" -gt 0 ]; then
            # 3,600,000 ms/hour * 100 cents / 10^10 units = 9/250.
            # Divide first to avoid overflow while retaining truncated cents.
            local whole_units=$((cost / 250)) remainder=$((cost % 250))
            local cents=$(((whole_units * 9 + remainder * 9 / 250) / session_duration_ms))
            if [ "$cents" -gt 0 ]; then
                local burn_rate
                printf -v burn_rate '%d.%02d' "$((cents / 100))" "$((cents % 100))"
                result="$result @\$${burn_rate#0}/h"
            fi
        fi
    fi

    if [ "$show_tpm" = "true" ] && ! is_compact "$compact" &&
        [ "$session_duration_ms" -gt 0 ]; then
        local total_input_tokens total_output_tokens total_tokens tpm_value
        decimal_int_reply "${CTX_TOTAL_IN:--}" 0; total_input_tokens=$REPLY
        decimal_int_reply "${CTX_TOTAL_OUT:--}" 0; total_output_tokens=$REPLY
        total_tokens=$((total_input_tokens + total_output_tokens))
        # Reject a total whose multiplication would exceed Bash's integer range.
        if [ "$total_tokens" -gt 0 ] && [ "$total_tokens" -le 153722867280912 ]; then
            tpm_value=$((total_tokens * 60000 / session_duration_ms))
            if [ "$tpm_value" -gt 0 ]; then
                format_number_reply "$tpm_value"
                result="${result:+$result }${tpm_icon}${REPLY}tpm"
            fi
        fi
    fi

    echo "$result"
}
