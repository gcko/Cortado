# shellcheck shell=bash
# Shared payload decoding and numeric helpers for main, standalone modules, and
# incomplete installs. No configuration is loaded here.

# =============================================================================
# SAFE NUMBER HANDLING
# =============================================================================
# Functions to handle null/empty/invalid numeric values safely

# The _reply variants return through REPLY without a command substitution.
# Keep the printing entry points for standalone and optional-module callers.
safe_int_reply() {
    local val="${1%%.*}"
    case "${val#-}" in
        '' | *[!0-9]*) REPLY="${2:-0}" ;;
        *) REPLY="$val" ;;
    esac
}

safe_int() {
    safe_int_reply "$@"
    echo "$REPLY"
}

# Bash defaults to octal for zero-prefixed operands and silently wraps overflow.
# Validate the integer range with test, then read the digits in base ten.
decimal_int_reply() {
    safe_int_reply "$@"
    if ! [ "$REPLY" -ge -9223372036854775808 ] 2>/dev/null; then
        REPLY="${2:-0}"
    fi
    case "$REPLY" in
        -*) REPLY=$((-10#${REPLY#-})) ;;
        *) REPLY=$((10#$REPLY)) ;;
    esac
}

safe_divide_reply() {
    local num denom
    decimal_int_reply "$1" 0; num=$REPLY
    decimal_int_reply "$2" 1; denom=$REPLY
    if [ "$denom" -eq 0 ]; then
        REPLY="${3:-0}"
    else
        REPLY=$((num / denom))
    fi
}

safe_divide() {
    safe_divide_reply "$@"
    echo "$REPLY"
}

safe_percent_reply() {
    local value total
    decimal_int_reply "$1" 0; value=$REPLY
    decimal_int_reply "$2" 1; total=$REPLY
    if [ "$total" -eq 0 ]; then
        REPLY="${3:-0}"
    else
        REPLY=$((value * 100 / total))
    fi
}

safe_percent() {
    safe_percent_reply "$@"
    echo "$REPLY"
}

# Convert a nonnegative decimal to units of 10^-10, truncating excess digits.
# Shift the point in the mantissa directly so exponent notation stays exact.
decimal_fixed_reply() {
    local LC_ALL=C
    local text="${1#-}" exponent=0 exponent_sign=1 fraction='' digits shift places
    local decimal_pattern='^([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$'
    REPLY=
    [[ "$text" =~ $decimal_pattern ]] || return 1
    case "$text" in
        *[eE]*)
            exponent=${text#*[eE]}
            text=${text%%[eE]*}
            case "$exponent" in -*) exponent_sign=-1 ;; esac
            exponent=${exponent#[-+]}
            exponent=${exponent#"${exponent%%[!0]*}"}
            exponent=${exponent:-0}
            ;;
    esac
    case "$text" in *.*) fraction=${text#*.} ;; esac
    digits="${text%%.*}$fraction"
    digits=${digits#"${digits%%[!0]*}"}
    if [ -z "$digits" ]; then REPLY=0; return 0; fi
    [[ "$1" != -* ]] || return 1

    # Beyond this bound the nonzero mantissa must underflow or overflow,
    # regardless of where its point starts. Never expand an unbounded exponent.
    if ! [ "$exponent" -le "$((${#text} + 19))" ] 2>/dev/null; then
        if [ "$exponent_sign" -lt 0 ]; then REPLY=0; return 0; fi
        return 1
    fi
    shift=$((10 - ${#fraction} + exponent_sign * 10#$exponent))
    places=$((${#digits} + shift))
    if [ "$places" -le 0 ]; then REPLY=0; return 0; fi
    [ "$places" -le 19 ] || return 1
    if [ "$shift" -lt 0 ]; then
        digits=${digits:0:places}
    elif [ "$shift" -gt 0 ]; then
        local zeros=0000000000000000000
        digits="$digits${zeros:0:shift}"
    fi
    [ "$digits" -le 9223372036854775807 ] 2>/dev/null || return 1
    REPLY=$((10#$digits))
}

# All JSON documents use the same filters. The streaming mode allows the shell
# to choose a cache, credential or response only when the quota path needs it.
_cortado_jq() {
    local -a jq_command=(jq)
    if [ "$1" = --worker ]; then
        shift
        # Replace the process-substitution shell with jq when it is executable.
        declare -F jq >/dev/null || jq_command=(exec jq)
    fi
    # shellcheck disable=SC2016 # The dollar expressions belong to jq.
    "${jq_command[@]}" "$@" '
        def count:
            (try tonumber catch null)
            | if . != null and . >= 0 and . <= 9007199254740991
              then floor else null end;
        def object_or_empty: if type == "object" then . else {} end;
        def effort_text:
            if type == "string" then .
            elif type == "object" then (.level // .name | strings) // ""
            else "" end;
        def utilization: numbers | select(. >= 0 and . <= 100) | if . == 0 then 0 else . end;
        # Resets can be carried into the comma-separated history. Keep its UTC
        # format for epochs and accept only timestamp-shaped strings.
        def reset_time:
            if type == "number" then (try (floor | todate) catch "")
            elif type == "string"
                 and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})?$")
            then . else "" end;
        def shell_value:
            if type == "string" then gsub("\u0000"; "") | sub("\n+$"; "") else . end
            | @sh;
        def assignments:
            [to_entries[] | .key + "=" + (.value | shell_value)] | join(" ");
        def payload:
            objects
            | (.context_window | object_or_empty) as $context
            | (.cost | object_or_empty) as $cost
            | (.model | object_or_empty) as $model
            | (.thinking | object_or_empty) as $thinking
            | (.rate_limits | object_or_empty) as $rates
            | ($rates.five_hour | object_or_empty) as $five
            | ($rates.seven_day | object_or_empty) as $seven
            | (if (.thinking | type) == "object" then ($thinking.enabled // $thinking.on)
               else (.thinking // $model.thinking) end) as $think
            | {
                CTX_CURRENT_DIR: ((.workspace | object_or_empty | .current_dir | strings | select(length > 0))
                    // (.cwd | strings | select(length > 0)) // ""),
                CTX_CONTEXT_PERCENT: (($context.used_percentage | numbers | count) // "-"),
                CTX_CONTEXT_SIZE: (($context.context_window_size | count) // "-"),
                CTX_CURRENT_TOKENS: (($context.current_usage | objects
                    | [.input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens, .output_tokens]
                    | map(count) | add | count) // "-"),
                CTX_COST_USD: ($cost.total_cost_usd // "-" | tostring),
                CTX_DURATION_MS: ($cost.total_duration_ms // "-" | tostring),
                CTX_TOTAL_IN: ($context.total_input_tokens // "-" | tostring),
                CTX_TOTAL_OUT: ($context.total_output_tokens // "-" | tostring),
                CTX_MODEL_NAME: ($model.display_name // "" | tostring),
                CTX_OUTPUT_STYLE: ((.output_style | object_or_empty | .name) // "" | tostring),
                CTX_THINKING: (if ($think == true or $think == "true" or $think == "on" or $think == "enabled")
                    then "On" else "" end),
                CTX_EFFORT: ([.effort, $thinking.effort, $model.effort, $model.reasoning_effort]
                    | map(effort_text | select(length > 0)) | first // ""),
                CTX_SESSION_ID: ((.session_id | strings | select(length > 0) | @base64
                    | select(length <= 200)) // ""),
                CTX_HAS_RATES: (([$rates.five_hour, $rates.seven_day] | all(type == "object"))
                    and ([$five.used_percentage, $seven.used_percentage] | any(type == "number"))),
                CTX_FIVE_HOUR: (($five.used_percentage | utilization) // "-"),
                CTX_SEVEN_DAY: (($seven.used_percentage | utilization) // "-"),
                CTX_FIVE_RESET: ($five.resets_at | reset_time),
                CTX_SEVEN_RESET: ($seven.resets_at | reset_time)
            }
            | assignments;
        def usage:
            objects
            | (.five_hour // .five_hour_opus // .five_hour_sonnet) as $five
            | (.seven_day // .seven_day_opus // .seven_day_sonnet) as $seven
            | select($five != null and $five != "null" and $seven != null and $seven != "null")
            | {
                five_hour: (($five | object_or_empty | .utilization | utilization) // "" | tostring),
                seven_day: (($seven | object_or_empty | .utilization | utilization) // "" | tostring),
                five_hour_reset: ($five | object_or_empty | .resets_at // "" | tostring),
                seven_day_reset: ($seven | object_or_empty | .resets_at // "" | tostring)
            }
            | assignments;
        def credential:
            objects | .claudeAiOauth | objects | .accessToken | strings
            | select(length > 0 and (explode | all(. != 0)));
        def decode($kind):
            if $kind == "payload" then payload
            elif $kind == "usage" then usage
            elif $kind == "credential" then credential
            else empty end;
        if $kind == "stream" then
            inputs
            | index("\t") as $separator
            | .[:$separator] as $request
            | .[$separator + 1:]
            | ((try (split("\u001e") | join("\n") | fromjson | decode($request)) catch "") // "")
            | . + "\u0000"
        else
            select(length == 1) | .[0] | decode($kind)
        end
    '
}

# One line per request. Raw record separators are invalid JSON, so reject them
# before using that byte to preserve literal newlines in multi-line documents.
# Replies end in NUL because @sh may carry newlines in a quoted string.
_json_reply() {
    REPLY=
    [ "${cortado_json_worker:-false}" = true ] || return 1
    local document="$2"
    case "$document" in *$'\036'*) document= ;; esac
    # A failing jq may close its input before the first write. Contain SIGPIPE
    # to the writer and keep the callback's normal shell and signal behavior.
    (trap '' PIPE; printf '%s\t%s\n' "$1" "${document//$'\n'/$'\036'}") >&7 2>/dev/null || return 1
    IFS= read -r -d '' REPLY <&6
}

# Read the input here-string used by main and independently sourced modules.
# Scope the pipe descriptors to the callback. The FIFO is just a rendezvous
# for Bash 3.2, which has no coproc. Once open, both ends live in the kernel.
with_payload_context() {
    local payload_json parser_dir
    if IFS= read -r -d '' payload_json; then payload_json=; fi
    if parser_dir=$(mktemp -d "${TMPDIR:-/tmp}/cortado-json.XXXXXX" 2>/dev/null) ||
        parser_dir=$(mktemp -d "${CLAUDE_CONFIG_DIR:-/tmp}/cortado-json.XXXXXX" 2>/dev/null); then
        if mkfifo "$parser_dir/input" 2>/dev/null; then
            # The two opens intentionally rendezvous on the private FIFO.
            # shellcheck disable=SC2094
            _with_json_worker "$parser_dir" "$payload_json" "$@" \
                6< <(_cortado_jq --worker -nRj --unbuffered --arg kind stream < "$parser_dir/input" 2>/dev/null) \
                7>"$parser_dir/input"
            return
        fi
        rm -rf -- "$parser_dir"
    fi

    # Keep local payload readings available when a private pipe cannot be made.
    local -r cortado_json_worker=false
    local assignments
    assignments=$(_cortado_jq -rs --arg kind payload <<< "$payload_json" 2>/dev/null) || assignments=
    _with_payload_fields "$assignments" "$@"
}

_with_json_worker() {
    local parser_dir="$1" payload_json="$2"
    shift 2
    rm -rf -- "$parser_dir"
    local -r cortado_json_worker=true
    local assignments=
    if _json_reply payload "$payload_json"; then assignments=$REPLY; fi
    _with_payload_fields "$assignments" "$@"
}

# Parse into defaults, then freeze the same fields even when jq fails.
# The assignment keys are fixed in the jq filter and @sh quotes every value.
_with_payload_fields() {
    local assignments="$1"; shift
    local CTX_CURRENT_DIR='' CTX_CONTEXT_PERCENT='-' CTX_CONTEXT_SIZE='-' CTX_CURRENT_TOKENS='-'
    local CTX_COST_USD='-' CTX_DURATION_MS='-' CTX_TOTAL_IN='-' CTX_TOTAL_OUT='-'
    local CTX_MODEL_NAME='' CTX_OUTPUT_STYLE='' CTX_THINKING='' CTX_EFFORT='' CTX_SESSION_ID=''
    local CTX_HAS_RATES=false CTX_FIVE_HOUR='-' CTX_SEVEN_DAY='-' CTX_FIVE_RESET='' CTX_SEVEN_RESET=''
    local -r CTX_READY=true
    if [ -n "$assignments" ]; then eval "$assignments"; fi
    readonly CTX_CURRENT_DIR CTX_CONTEXT_PERCENT CTX_CONTEXT_SIZE CTX_CURRENT_TOKENS \
        CTX_COST_USD CTX_DURATION_MS CTX_TOTAL_IN CTX_TOTAL_OUT CTX_MODEL_NAME \
        CTX_OUTPUT_STYLE CTX_THINKING CTX_EFFORT CTX_SESSION_ID CTX_HAS_RATES \
        CTX_FIVE_HOUR CTX_SEVEN_DAY CTX_FIVE_RESET CTX_SEVEN_RESET
    "$@"
}
