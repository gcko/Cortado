# shellcheck shell=bash
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
    local input="$1"
    local icon=$(get_icon "${CONTEXT_ICON:-📊}" "CTX:")
    local show_bar="${CONTEXT_SHOW_PROGRESS_BAR:-true}"
    local show_pct="${CONTEXT_SHOW_PERCENTAGE:-true}"
    local show_status="${CONTEXT_SHOW_STATUS:-true}"
    local show_tokens="${CONTEXT_SHOW_TOKENS_REMAINING:-true}"
    local compact_icon="${CONTEXT_COMPACT_ICON:-⚡}"
    local warn_thresh=$(safe_int "${CONTEXT_WARNING_THRESHOLD:-60}" 60)
    local crit_thresh=$(safe_int "${CONTEXT_CRITICAL_THRESHOLD:-75}" 75)
    local compact_thresh=$(safe_int "${CONTEXT_COMPACT_THRESHOLD:-80}" 80)

    local readings context_percent context_size current_tokens
    readings=$(printf '%s' "$input" | jq -r '
        def count:
            (try tonumber catch null)
            | if . != null and . >= 0 and . <= 9007199254740991
              then floor else null end;
        .context_window | objects
        | [(.used_percentage | numbers | count) // null,
           (.context_window_size | count),
           ((.current_usage | objects
             | [.input_tokens, .cache_creation_input_tokens,
                .cache_read_input_tokens, .output_tokens]
             | map(count) | map(select(. != null)) | add | count) // null)]
        | map(. // "-") | join(" ")
    ' 2>/dev/null)
    IFS=' ' read -r context_percent context_size current_tokens <<< "$readings"

    local tokens_until_compact=""
    if [[ "$context_size" =~ ^[1-9][0-9]*$ && "$current_tokens" =~ ^[0-9]+$ ]]; then
        local counted_percent=$(safe_percent "$current_tokens" "$context_size")
        if [ "$context_percent" = "-" ]; then
            context_percent="$counted_percent"
        fi
        # Only show the count-derived estimate when it agrees with the percentage.
        if [ "$show_tokens" = "true" ] && [ "$context_percent" = "$counted_percent" ]; then
            # Bash arithmetic treats a leading zero as octal by default.
            if [[ "$compact_thresh" == -* ]]; then
                compact_thresh=$((-10#${compact_thresh#-}))
            else
                compact_thresh=$((10#$compact_thresh))
            fi
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
        result="$result $(progress_bar "$context_percent")"
    fi
    if [ "$show_pct" = "true" ]; then
        result="$result ${context_percent}%"
    fi
    if [ "$show_status" = "true" ]; then
        result="$result$(get_status "$context_percent" "$warn_thresh" "$crit_thresh")"
    fi
    if [ -n "$tokens_until_compact" ]; then
        result="$result ($(format_number "$tokens_until_compact")→${compact_icon})"
    fi

    echo "$result"
}
