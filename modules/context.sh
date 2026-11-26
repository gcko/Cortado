# shellcheck shell=bash
# @cortado-module context
# @default true
# @args payload
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu core 5
# @description Context usage bar
# @config CONTEXT_ICON:string
# @config CONTEXT_SHOW_PROGRESS_BAR:bool
# @config CONTEXT_SHOW_PERCENTAGE:bool
# @config CONTEXT_SHOW_STATUS:bool
# @config CONTEXT_SHOW_TOKENS_REMAINING:bool
# @config CONTEXT_COMPACT_ICON:string
# @config CONTEXT_WARNING_THRESHOLD:int
# @config CONTEXT_CRITICAL_THRESHOLD:int
# @config CONTEXT_COMPACT_THRESHOLD:int
# =============================================================================
# Context Module - Shows context window usage with progress bar
# Prefers the payload percentage and shows -- until a reading is available.
# =============================================================================
# Configuration options:
#   CONTEXT_ICON                - Icon before context info (default: 📊)
#   CONTEXT_SHOW_PROGRESS_BAR   - Show visual progress bar (default: true)
#   CONTEXT_SHOW_PERCENTAGE     - Show percentage (default: true)
#   CONTEXT_SHOW_STATUS         - Show status indicator (default: true)
#   CONTEXT_SHOW_TOKENS_REMAINING - Show tokens until compact (default: true)
#   CONTEXT_COMPACT_ICON        - Icon for compact indicator (default: ⚡)
#   CONTEXT_WARNING_THRESHOLD   - Yellow warning at % (default: 60)
#   CONTEXT_CRITICAL_THRESHOLD  - Red warning at % (default: 75)
#   CONTEXT_COMPACT_THRESHOLD   - Auto-compact at % (default: 80)
# =============================================================================

module_context() {
    if [ "${CTX_READY:-}" != true ]; then
        with_payload_context module_context <<< "${1:-}"
        return
    fi

    local icon
    get_icon_reply "${CONTEXT_ICON:-📊}" "CTX:"; icon=$REPLY
    local show_bar="${CONTEXT_SHOW_PROGRESS_BAR:-true}"
    local show_pct="${CONTEXT_SHOW_PERCENTAGE:-true}"
    local show_status="${CONTEXT_SHOW_STATUS:-true}"
    local show_tokens="${CONTEXT_SHOW_TOKENS_REMAINING:-true}"
    local compact_icon="${CONTEXT_COMPACT_ICON:-⚡}"
    local warn_thresh crit_thresh compact_thresh
    safe_int_reply "${CONTEXT_WARNING_THRESHOLD:-60}" 60; warn_thresh=$REPLY
    safe_int_reply "${CONTEXT_CRITICAL_THRESHOLD:-75}" 75; crit_thresh=$REPLY
    decimal_int_reply "${CONTEXT_COMPACT_THRESHOLD:-80}" 80; compact_thresh=$REPLY

    local context_percent="${CTX_CONTEXT_PERCENT:--}"
    local context_size="${CTX_CONTEXT_SIZE:--}"
    local current_tokens="${CTX_CURRENT_TOKENS:--}"

    local tokens_until_compact=""
    if [[ "$context_size" =~ ^[1-9][0-9]*$ && "$current_tokens" =~ ^[0-9]+$ ]]; then
        local counted_percent
        safe_percent_reply "$current_tokens" "$context_size"; counted_percent=$REPLY
        if [ "$context_percent" = "-" ]; then
            context_percent="$counted_percent"
        fi
        # Only show the count-derived estimate when it agrees with the percentage.
        if [ "$show_tokens" = "true" ] && [ "$context_percent" = "$counted_percent" ]; then
            tokens_until_compact=$((context_size * compact_thresh / 100 - current_tokens))
            if [ "$tokens_until_compact" -lt 0 ]; then
                tokens_until_compact=0
            fi
        fi
    fi

    if [ -z "$context_percent" ] || [ "$context_percent" = "-" ]; then
        echo "$icon --"
        return
    fi

    local result="$icon"
    if [ "$show_bar" = "true" ]; then
        progress_bar_reply "$context_percent"
        result="$result $REPLY"
    fi
    if [ "$show_pct" = "true" ]; then
        result="$result ${context_percent}%"
    fi
    if [ "$show_status" = "true" ]; then
        get_status_reply "$context_percent" "$warn_thresh" "$crit_thresh"
        result="$result$REPLY"
    fi
    if [ -n "$tokens_until_compact" ]; then
        format_number_reply "$tokens_until_compact"
        result="$result (${REPLY}→${compact_icon})"
    fi

    echo "$result"
}
