# shellcheck shell=bash
# =============================================================================
# Model Module - Shows current Claude model and output style
# =============================================================================
# Configuration options:
#   MODEL_ICON              - Icon before model name (default: 🤖)
#   MODEL_SHOW_OUTPUT_STYLE - Show output style (default: true)
#   MODEL_COMPACT           - Use abbreviated model names (default: false)
#   MODEL_STYLE             - "model", "style", "both" (default: both)
#   MODEL_SHOW_THINKING     - Show thinking state / reasoning effort (default: false)
#   MODEL_THINKING_ICON     - Icon before thinking segment (default: ✦)
# =============================================================================

# Return the optional thinking segment from the parsed payload.
model_thinking_segment_reply() {
    REPLY=
    [ "${MODEL_SHOW_THINKING:-false}" = "true" ] || return 0

    local thinking_state="${CTX_THINKING:-}" effort="${CTX_EFFORT:-}"
    local text=""
    if [ -n "$thinking_state" ] && [ -n "$effort" ]; then
        text="On · $effort"
    elif [ -n "$thinking_state" ]; then
        text="On"
    elif [ -n "$effort" ]; then
        text="$effort"
    else
        return 0
    fi

    get_icon_reply "${MODEL_THINKING_ICON:-✦}" ""
    REPLY="${REPLY:+$REPLY }$text"
}

module_model() {
    if [ "${CTX_READY:-}" != true ]; then
        with_payload_context module_model <<< "${1:-}"
        return
    fi

    local icon
    get_icon_reply "${MODEL_ICON:-🤖}" "MODEL:"; icon=$REPLY
    local show_style="${MODEL_SHOW_OUTPUT_STYLE:-true}"
    local compact="${MODEL_COMPACT:-false}"
    local style="${MODEL_STYLE:-both}"
    local model_name="${CTX_MODEL_NAME:-Unknown}"
    local output_style="${CTX_OUTPUT_STYLE:-default}"

    # Compact model names
    if [ "$compact" = "true" ] || is_compact; then
        model_name=$(echo "$model_name" | sed 's/Claude //')
    fi

    # Build output based on style
    local result="$icon"

    case "$style" in
        model)
            result="$result $model_name"
            ;;
        style)
            result="$result ($output_style)"
            ;;
        *)  # both (default)
            if [ "$show_style" = "true" ] && [ "$output_style" != "default" ]; then
                result="$result $model_name ($output_style)"
            else
                result="$result $model_name"
            fi
            ;;
    esac

    # Optional thinking segment (hidden unless MODEL_SHOW_THINKING=true and
    # the statusline JSON carries thinking/effort data)
    model_thinking_segment_reply
    if [ -n "$REPLY" ]; then
        result="$result $REPLY"
    fi

    echo "$result"
}
