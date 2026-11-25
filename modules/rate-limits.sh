# shellcheck shell=bash
# =============================================================================
# Rate Limits Module - Shows 5-hour and 7-day usage with projections
# Prefers the rate limits Claude Code puts in the statusline payload; otherwise
# reads an owner-only Claude Code credential file. Never accesses macOS Keychain.
# Stale fallback percentages show their cache age (for example, 42%~6h0m).
# A quota cache whose age cannot be established is ignored.
# =============================================================================
# Configuration options:
#   RATE_SHOW_5H            - Show 5-hour rate limit (default: true)
#   RATE_SHOW_7D            - Show 7-day rate limit (default: true)
#   RATE_SHOW_TIME_REMAINING - Show time until reset (default: true)
#   RATE_SHOW_PROJECTION    - Show projection status (default: true)
#   RATE_SHOW_USAGE_STATUS  - Show usage level indicator (default: true)
#   RATE_SHOW_PROGRESS_BAR  - Show visual progress bar (default: false)
#   RATE_PROGRESS_BAR_WIDTH - Progress bar width (default: PROGRESS_BAR_WIDTH)
#   RATE_LOW_THRESHOLD      - Green/yellow boundary (default: 50)
#   RATE_MEDIUM_THRESHOLD   - Yellow/orange boundary (default: 75)
#   RATE_HIGH_THRESHOLD     - Orange/red boundary (default: 95)
#   RATE_WARNING_THRESHOLD  - Yellow warning at % for projections (default: 80)
#   RATE_CRITICAL_THRESHOLD - Red warning at % for projections (default: 100)
#   RATE_COMPACT            - Compact mode (default: false)
#   RATE_5H_LABEL           - Label for 5-hour (default: 5h)
#   RATE_7D_LABEL           - Label for 7-day (default: 7d)
#   RATE_CACHE_TTL          - Cache TTL in seconds (default: 120)
#   RATE_BACKOFF_SECONDS    - Fallback backoff after 429 if no retry-after header (default: 300)
# =============================================================================

# Read OAuth from ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json only.
# The CLI must expose a private credential file; there is no Keychain migration
# or fallback. Owner-only file permissions cannot protect against the same user.
_credentials_file_is_private() {
    local file="$1"
    local mode=""

    # Use the platform stat directly on macOS so a Homebrew GNU stat earlier in
    # PATH cannot reinterpret BSD flags. If mode discovery fails, fail closed.
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        mode=$(/usr/bin/stat -f %Lp "$file" 2>/dev/null) || return 1
    else
        mode=$(stat -c %a "$file" 2>/dev/null) || return 1
    fi

    case "$mode" in
        ""|*[!0-7]*) return 1 ;;
        *00) return 0 ;;
        *) return 1 ;;
    esac
}

_get_claude_token() {
    local creds_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    if [ -f "$creds_file" ]; then
        if _credentials_file_is_private "$creds_file"; then
            local file_token
            # Parse the entire file before emitting anything. Reject multiple
            # documents, malformed input and non-string tokens, even if jq
            # produced partial output before reporting an error.
            if file_token=$(jq -ers '
                select(length == 1) | .[0] |
                select(type == "object") | .claudeAiOauth |
                select(type == "object") | .accessToken |
                select(type == "string") | select(length > 0)
            ' "$creds_file" 2>/dev/null); then
                printf '%s\n' "$file_token"
                return
            fi
        else
            log_debug "rate-limits: refusing credentials file with group or other permissions"
        fi
    fi

    # Missing, unsafe or unreadable file: ask the user to configure/sign in to
    # the CLI with file-backed credentials instead of touching legacy Keychain.
    return 0
}

# Check if currently in backoff from a 429
# Returns 0 if in backoff (with remaining seconds on stdout), 1 if not
_check_backoff() {
    local backoff_file="$CACHE_DIR/rate_limits_backoff"
    local default_duration="${RATE_BACKOFF_SECONDS:-300}"

    if [ ! -f "$backoff_file" ]; then
        return 1
    fi

    # Read retry-after duration from file (first line), fall back to default.
    # The file is written from an HTTP header or can be corrupted on disk, so
    # only accept a positive integer here: a non-numeric value would raise a
    # shell arithmetic error and a 0 would silently disable the cooldown.
    local stored_duration
    stored_duration=$(head -1 "$backoff_file" 2>/dev/null)
    local duration=""
    stored_duration="${stored_duration//[[:space:]]/}"
    case "$stored_duration" in
        ''|*[!0-9]*) duration="$default_duration" ;;
        0*)          duration="$default_duration" ;;
        *)           duration="$stored_duration" ;;
    esac

    local backoff_time
    backoff_time=$(_file_mtime "$backoff_file")

    local now
    now=$(date +%s)
    local backoff_age=$((now - backoff_time))

    if [ "$backoff_age" -lt "$duration" ]; then
        local remaining=$((duration - backoff_age))
        echo "$remaining"
        return 0
    else
        # A concurrent 429 may have already replaced this marker.
        return 1
    fi
}

# Rate limits from the statusline payload. Claude Code sends them after the
# first turn of a session (observed in 2.1.330):
#   rate_limits.five_hour.used_percentage, rate_limits.five_hour.resets_at (Unix s)
#   rate_limits.seven_day.used_percentage, rate_limits.seven_day.resets_at
# Prints them in the usage API's shape ({five_hour:{utilization,resets_at}, ...},
# resets_at as an ISO 8601 UTC string) so the renderer below needs no second path.
# Both window objects and at least one numeric reading are needed to use the
# payload. A missing or invalid percentage stays null if its sibling can render.
# A reset time that is neither a number nor a strict ISO 8601 string is dropped
# (no countdown), because it is written into the comma-separated history file.
_usage_from_payload() {
    local input="$1"
    [ -n "$input" ] || return 0
    printf '%s' "$input" | jq -c '
        def window:
            if type == "object"
            then {utilization: ((.used_percentage | numbers) // null),
                  resets_at: (if (.resets_at | type) == "number"
                              then (.resets_at | floor | todate)
                              elif (.resets_at | type) == "string"
                                   and (.resets_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})?$"))
                              then .resets_at
                              else null end)}
            else null end;
        (.rate_limits // null)
        | select(type == "object")
        | {five_hour: (.five_hour | window), seven_day: (.seven_day | window)}
        | select(.five_hour != null and .seven_day != null)
        | select(.five_hour.utilization != null or .seven_day.utilization != null)
    ' 2>/dev/null
}

# Older versions briefly wrote the bearer config to a fixed path. Remove a
# leftover only after the five-minute grace period for an older render.
_cleanup_legacy_curl_config() {
    local legacy_config="$CACHE_DIR/rate_limits_curlcfg"
    if [ -f "$legacy_config" ]; then
        local mtime now
        now=$(date +%s)
        mtime=$(_file_mtime "$legacy_config")
        if [ "$mtime" -gt 0 ] && [ "$((now - mtime))" -gt 300 ]; then
            rm -f -- "$legacy_config" 2>/dev/null
        fi
    fi
}

# Fetch usage from Anthropic API
_get_claude_usage() (
    # Check if we're in backoff period from a previous 429. Callers that have
    # already probed the backoff state export RATE_BACKOFF_PROBED to reuse it.
    if [ "${RATE_BACKOFF_PROBED:-false}" = "true" ]; then
        if [ "${RATE_BACKOFF_ACTIVE:-false}" = "true" ]; then
            log_debug "rate-limits: in backoff period (${RATE_BACKOFF_REMAINING:-0}s remaining), skipping API call"
            return 1
        fi
    else
        local backoff_remaining
        if backoff_remaining=$(_check_backoff); then
            log_debug "rate-limits: in backoff period (${backoff_remaining}s remaining), skipping API call"
            return 1
        fi
    fi

    local token
    token=$(_get_claude_token)

    # Only bearer-token characters may enter the quoted curl config value.
    local LC_ALL=C
    case "$token" in
        ''|*[!a-zA-Z0-9._~+/=-]*) return 1 ;;
    esac

    # Each request owns its body and headers. A subshell scopes EXIT cleanup
    # and umask to this request, including when called directly.
    init_cache
    umask 077
    local request_dir
    request_dir=$(mktemp -d "$CACHE_DIR/rate_limits_request.XXXXXX" 2>/dev/null) || return 1
    trap 'rm -rf -- "$request_dir" 2>/dev/null' EXIT
    local tmp_file="$request_dir/response"
    local tmp_headers="$request_dir/headers"
    # On Git Bash / MSYS, some mingw curl builds (notably 8.8 shipped with
    # recent Git for Windows) hit libcurl error 43 on this endpoint due to a
    # schannel TLS-renegotiation bug. Windows' system curl.exe works fine.
    local curl_bin="curl"
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            local sys_curl=""
            if command -v cygpath >/dev/null 2>&1 && [ -n "$SYSTEMROOT" ]; then
                sys_curl="$(cygpath -u "$SYSTEMROOT" 2>/dev/null)/System32/curl.exe"
            fi
            [ -x "${sys_curl:-/c/Windows/System32/curl.exe}" ] && \
                curl_bin="${sys_curl:-/c/Windows/System32/curl.exe}"
            ;;
    esac

    local http_code
    # Send authorization only through stdin. Disable the default curl config
    # so its trace options cannot log the header.
    http_code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
        "$curl_bin" -q -s --max-time 5 --proto =https --max-redirs 3 \
            -o "$tmp_file" -D "$tmp_headers" -w "%{http_code}" \
            --config - \
            "https://api.anthropic.com/api/oauth/usage" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "Accept: application/json" 2>/dev/null) || return 1

    case "$http_code" in
        200)
            cat "$tmp_file" 2>/dev/null
            ;;
        429)
            # Parse retry-after header (seconds) from response
            local retry_after
            retry_after=$(grep -i '^retry-after:' "$tmp_headers" 2>/dev/null | tr -d '\r' | awk '{print $2}')
            local backoff_duration="${retry_after:-${RATE_BACKOFF_SECONDS:-300}}"
            log_debug "rate-limits: received 429, backing off for ${backoff_duration}s (retry-after: ${retry_after:-not set})"
            cache_set rate_limits_backoff "$backoff_duration"
            return 1
            ;;
        *)
            log_debug "rate-limits: API returned HTTP $http_code"
            return 1
            ;;
    esac
)

# Emit the next history snapshot for _atomic_write_file.
_write_usage_history() {
    local history_file="$1" now="$2" entry="$3"
    if [ -f "$history_file" ]; then
        # Keep 100 points including the new one. Bound the input more tightly
        # when an older history file has grown past the 50 KB limit.
        local limit=99
        local current_size
        current_size=$(_file_stat %z %s "$history_file")
        if [ "$current_size" -gt 51200 ]; then
            limit=50
        fi
        (
            set -o pipefail
            tail -n "$limit" "$history_file" | awk -F, -v cutoff="$((now - 86400))" '$1 >= cutoff'
        ) || return 1
    fi
    printf '%s\n' "$entry"
}

# Serialize the whole read/trim/append/rename sequence. Keep the lock file
# so waiters always lock the same inode. The descriptor closes on exit,
# including when the writer is killed.
_record_usage_history() (
    local history_file="$1" now="$2" entry="$3"
    umask 077
    exec 9>>"${history_file}-lock" || return 1
    if command -v flock >/dev/null 2>&1; then
        flock -w 5 9
    else
        # macOS and Git Bash ship Perl, which can lock the inherited descriptor.
        perl -MFcntl=:flock -e 'open(my $lock, ">&=9") or exit 1; alarm 5; exit(!flock($lock, LOCK_EX))'
    fi || return 1
    _atomic_write_file "$history_file" _write_usage_history "$history_file" "$now" "$entry"
) 2>/dev/null

# Get projection status indicator (only shown at warning/critical levels)
_get_projection_status() {
    local projected=$1
    local warn_thresh="${RATE_WARNING_THRESHOLD:-80}"
    local crit_thresh="${RATE_CRITICAL_THRESHOLD:-100}"

    if [ "${RATE_SHOW_PROJECTION:-true}" != "true" ]; then
        echo ""
        return
    fi

    # Only show projection indicator when it's warning or critical
    if [ "$projected" -lt "$warn_thresh" ] 2>/dev/null; then
        echo ""
        return
    fi

    get_status "$projected" "$warn_thresh" "$crit_thresh"
}

# jq can emit exponent notation, which bc does not accept. Older history
# entries can contain it too. Keep ordinary decimal strings as written.
_projection_decimal() {
    case "$1" in
        *[eE]*) LC_ALL=C printf '%.20f' "$1" 2>/dev/null ;;
        *) printf '%s' "$1" ;;
    esac
}

# Emit the verified age followed by the cached JSON.
_read_usage_cache() {
    local file="$1" max_age="$2" mtime now age data
    [ -f "$file" ] || return 1
    mtime=$(_file_mtime "$file")
    now=$(date +%s 2>/dev/null) || return 1
    case "$now" in
        ''|0*|*[!0-9]*) return 1 ;;
    esac
    [ "$mtime" -gt 0 ] && [ "$now" -ge "$mtime" ] || return 1
    age=$((now - mtime))
    [ "$age" -le "$max_age" ] 2>/dev/null || return 1
    data=$(cat "$file" 2>/dev/null) || return 1
    # A concurrent fetch can publish a new file while this reader checks it.
    [ -n "$data" ] && [ "$mtime" = "$(_file_mtime "$file")" ] || return 1
    printf '%s\n%s\n' "$age" "$data"
}

# Parse an ISO-8601 resets_at timestamp (UTC, fractional seconds stripped by the
# caller) to epoch seconds. `date -j -f` is BSD/macOS-only; GNU date (Linux,
# Git Bash on Windows) needs -d. Try both so time-remaining works everywhere.
_parse_reset_epoch() {
    local ts="$1"
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null || \
        date -u -d "$ts" +%s 2>/dev/null || \
        echo 0
}

# Render the placeholder line shown when no usage data is available
_render_placeholder() {
    local show_5h="$1"
    local show_7d="$2"
    local label_5h="$3"
    local label_7d="$4"
    local result=""
    [ "$show_5h" = "true" ] && result="${label_5h}:--"
    [ "$show_7d" = "true" ] && result="${result:+$result }${label_7d}:--"
    echo "$result"
}

module_rate_limits() {
    local input="${1:-}"
    local show_5h="${RATE_SHOW_5H:-true}"
    local show_7d="${RATE_SHOW_7D:-true}"
    local show_time="${RATE_SHOW_TIME_REMAINING:-true}"
    local show_usage_status="${RATE_SHOW_USAGE_STATUS:-true}"
    local show_bar="${RATE_SHOW_PROGRESS_BAR:-false}"
    local bar_width="${RATE_PROGRESS_BAR_WIDTH:-}"
    local compact="${RATE_COMPACT:-false}"
    local label_5h="${RATE_5H_LABEL:-5h}"
    local label_7d="${RATE_7D_LABEL:-7d}"

    _cleanup_legacy_curl_config

    # 4-level usage thresholds: green -> yellow -> orange -> red
    local low_thresh="${RATE_LOW_THRESHOLD:-50}"
    local medium_thresh="${RATE_MEDIUM_THRESHOLD:-75}"
    local high_thresh="${RATE_HIGH_THRESHOLD:-95}"

    local cache_key="rate_limits_usage"
    local cache_ttl="${RATE_CACHE_TTL:-120}"
    # Reject non-numeric TTL so an untrusted .cortado.conf can't break cache_get
    case "$cache_ttl" in
        ''|*[!0-9]*) cache_ttl=120 ;;
    esac
    local history_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.usage_history"
    local usage_data=""
    local from_payload=false
    local fresh_fetch=false
    local in_backoff=false
    local backoff_remaining=0
    local age_marker=""

    # Prefer the payload: it is current, needs no credential, and costs no
    # request. It is deliberately not written to the shared usage cache, which is
    # served for up to 24 hours when a fetch fails; a payload reading replayed at
    # the next session's start would read as current when it is not.
    usage_data=$(_usage_from_payload "$input")
    if [ -n "$usage_data" ]; then
        from_payload=true
    else
        # Check if we're in API backoff (429 cooldown). The probe result is shared
        # with _get_claude_usage so it does not repeat the check in this process.
        if backoff_remaining=$(_check_backoff); then
            in_backoff=true
            export RATE_BACKOFF_PROBED=true RATE_BACKOFF_ACTIVE=true
            export RATE_BACKOFF_REMAINING="$backoff_remaining"
        fi

        local cache_file="$CACHE_DIR/$cache_key" cached_usage cache_age
        if cached_usage=$(_read_usage_cache "$cache_file" "$cache_ttl"); then
            usage_data=${cached_usage#*$'\n'}
        fi

        # Fetch fresh data if cache miss
        if [ -z "$usage_data" ]; then
            usage_data=$(_get_claude_usage)
            if [ -n "$usage_data" ]; then
                cache_set "$cache_key" "$usage_data"
                fresh_fetch=true
            elif cached_usage=$(_read_usage_cache "$cache_file" 86400); then
                # API failed — serve the bounded fallback with its age.
                usage_data=${cached_usage#*$'\n'}
                cache_age=${cached_usage%%$'\n'*}
                if [ "$cache_age" -gt "$cache_ttl" ]; then
                    age_marker="~$(format_cooldown "$cache_age")"
                fi
            fi
        fi
    fi

    if [ -z "$usage_data" ]; then
        # No data at all - show backoff countdown if applicable
        if [ "$in_backoff" = "true" ]; then
            local pause_icon=$(get_icon "⏸" "WAIT:")
            echo "${pause_icon} API cooldown $(format_cooldown "$backoff_remaining")"
        else
            _render_placeholder "$show_5h" "$show_7d" "$label_5h" "$label_7d"
        fi
        return
    fi

    local five_hour_obj=$(echo "$usage_data" | jq -r '.five_hour // .five_hour_opus // .five_hour_sonnet // "null"' 2>/dev/null)
    local seven_day_obj=$(echo "$usage_data" | jq -r '.seven_day // .seven_day_opus // .seven_day_sonnet // "null"' 2>/dev/null)

    if [ "$five_hour_obj" = "null" ] || [ "$seven_day_obj" = "null" ]; then
        _render_placeholder "$show_5h" "$show_7d" "$label_5h" "$label_7d"
        return
    fi

    local utilization_filter='.utilization | numbers | select(. >= 0 and . <= 100) | if . == 0 then 0 else . end'
    local five_hour=$(printf '%s' "$five_hour_obj" | jq -r "$utilization_filter" 2>/dev/null)
    local seven_day=$(printf '%s' "$seven_day_obj" | jq -r "$utilization_filter" 2>/dev/null)
    case "$five_hour,$seven_day" in
        *[eE]*)
            five_hour=$(_projection_decimal "$five_hour")
            seven_day=$(_projection_decimal "$seven_day")
            ;;
    esac
    local five_hour_reset=$(echo "$five_hour_obj" | jq -r '.resets_at // empty' 2>/dev/null)
    local seven_day_reset=$(echo "$seven_day_obj" | jq -r '.resets_at // empty' 2>/dev/null)

    local now=$(date +%s)

    # History rows drive both projections and need two measured percentages.
    if [ -n "$five_hour" ] && [ -n "$seven_day" ]; then
        if [ "$from_payload" = "true" ] && ! cache_get "rate_limits_payload_recorded" "$cache_ttl" >/dev/null; then
            cache_set "rate_limits_payload_recorded" "$now"
            fresh_fetch=true
        fi
        if [ "$fresh_fetch" = "true" ]; then
            _record_usage_history "$history_file" "$now" \
                "$now,$five_hour,$seven_day,$five_hour_reset,$seven_day_reset"
        fi
    fi

    local five_hour_status=""
    local seven_day_status=""
    local five_hour_remaining=0
    local seven_day_remaining=0

    # Parse 5-hour reset time and calculate projection
    if [ -n "$five_hour" ] && [ -n "$five_hour_reset" ]; then
        local five_hour_reset_epoch=$(_parse_reset_epoch "${five_hour_reset%%.*}")
        five_hour_remaining=$((five_hour_reset_epoch - now))
        if [ "$five_hour_remaining" -gt 18000 ]; then
            five_hour_remaining=18000
        fi

        # 5-hour projection
        if [ -f "$history_file" ] && [ "$five_hour_remaining" -gt 0 ]; then
            local current_window_data=$(grep -F "$five_hour_reset" "$history_file" 2>/dev/null | tail -10)
            if [ -n "$current_window_data" ]; then
                local first_entry=$(echo "$current_window_data" | head -1)
                local last_entry=$(echo "$current_window_data" | tail -1)
                local first_ts=$(echo "$first_entry" | cut -d',' -f1)
                local first_util=$(echo "$first_entry" | cut -d',' -f2)
                local last_util=$(echo "$last_entry" | cut -d',' -f2)
                local elapsed=$((now - first_ts))

                if [ "$elapsed" -gt 60 ]; then
                    local usage_delta=$(echo "$(_projection_decimal "$last_util") - $(_projection_decimal "$first_util")" | bc -l 2>/dev/null || echo "0")
                    local rate=$(echo "scale=10; $usage_delta / $elapsed" | bc -l 2>/dev/null || echo "0")
                    local projected_additional=$(echo "scale=2; $rate * $five_hour_remaining" | bc -l 2>/dev/null || echo "0")
                    local projected_total=$(echo "scale=2; $five_hour + $projected_additional" | bc -l 2>/dev/null || echo "$five_hour")
                    local projected_int=$(printf "%.0f" "$projected_total" 2>/dev/null || echo "0")

                    five_hour_status=$(_get_projection_status "$projected_int")
                fi
            fi
        fi
    fi

    # Parse 7-day reset time and calculate projection
    if [ -n "$seven_day" ] && [ -n "$seven_day_reset" ]; then
        local seven_day_reset_epoch=$(_parse_reset_epoch "${seven_day_reset%%.*}")
        seven_day_remaining=$((seven_day_reset_epoch - now))
        if [ "$seven_day_remaining" -gt 604800 ]; then
            seven_day_remaining=604800
        fi

        # 7-day projection (needs 12h of data)
        if [ -f "$history_file" ] && [ "$seven_day_remaining" -gt 0 ]; then
            local current_window_data=$(grep -F "$seven_day_reset" "$history_file" 2>/dev/null | tail -50)
            if [ -n "$current_window_data" ]; then
                local first_entry=$(echo "$current_window_data" | head -1)
                local last_entry=$(echo "$current_window_data" | tail -1)
                local first_ts=$(echo "$first_entry" | cut -d',' -f1)
                local first_util=$(echo "$first_entry" | cut -d',' -f3)
                local last_util=$(echo "$last_entry" | cut -d',' -f3)
                local elapsed=$((now - first_ts))
                local min_elapsed=$((12 * 3600))

                if [ "$elapsed" -gt "$min_elapsed" ]; then
                    local usage_delta=$(echo "$(_projection_decimal "$last_util") - $(_projection_decimal "$first_util")" | bc -l 2>/dev/null || echo "0")
                    local rate=$(echo "scale=10; $usage_delta / $elapsed" | bc -l 2>/dev/null || echo "0")
                    local projected_additional=$(echo "scale=2; $rate * $seven_day_remaining" | bc -l 2>/dev/null || echo "0")
                    local projected_total=$(echo "scale=2; $seven_day + $projected_additional" | bc -l 2>/dev/null || echo "$seven_day")
                    local projected_int=$(printf "%.0f" "$projected_total" 2>/dev/null || echo "0")

                    seven_day_status=$(_get_projection_status "$projected_int")
                fi
            fi
        fi
    fi

    local five_hour_int seven_day_int
    # jq emits a decimal point regardless of the user's locale. Clear any
    # partial output printf emits before reporting a conversion error.
    five_hour_int=$(
        LC_ALL=C
        printf "%.0f" "${five_hour:-0}" 2>/dev/null
    ) || five_hour_int=""
    seven_day_int=$(
        LC_ALL=C
        printf "%.0f" "${seven_day:-0}" 2>/dev/null
    ) || seven_day_int=""

    local five_hour_part="--"
    local seven_day_part="--"
    if [ -n "$five_hour" ] && [ -n "$five_hour_int" ]; then
        five_hour_part="${five_hour_int}%${age_marker}"
        if [ "$show_bar" = "true" ]; then
            five_hour_part="$(progress_bar "$five_hour_int" "$bar_width") $five_hour_part"
        fi
        if [ "$show_usage_status" = "true" ]; then
            five_hour_part="$five_hour_part$(get_status_4level "$five_hour_int" "$low_thresh" "$medium_thresh" "$high_thresh")"
        fi
        five_hour_part="$five_hour_part$five_hour_status"
    fi
    if [ -n "$seven_day" ] && [ -n "$seven_day_int" ]; then
        seven_day_part="${seven_day_int}%${age_marker}"
        if [ "$show_bar" = "true" ]; then
            seven_day_part="$(progress_bar "$seven_day_int" "$bar_width") $seven_day_part"
        fi
        if [ "$show_usage_status" = "true" ]; then
            seven_day_part="$seven_day_part$(get_status_4level "$seven_day_int" "$low_thresh" "$medium_thresh" "$high_thresh")"
        fi
        seven_day_part="$seven_day_part$seven_day_status"
    fi

    # Build output
    local result=""

    # Add a cooldown indicator when showing cached data during API backoff.
    local backoff_marker=""
    if [ "$in_backoff" = "true" ] && [ "$fresh_fetch" != "true" ]; then
        backoff_marker=" $(get_icon '⏸' 'WAIT')$(format_cooldown "$backoff_remaining")"
    fi

    if [ "$show_5h" = "true" ]; then
        result="${label_5h}:${five_hour_part}"
        if [ "$show_time" = "true" ] && [ "$five_hour_remaining" -gt 0 ] 2>/dev/null && ! is_compact "$compact"; then
            result="${result} ($(format_time_remaining "$five_hour_remaining"))"
        fi
    fi

    if [ "$show_7d" = "true" ]; then
        result="${result:+$result }${label_7d}:${seven_day_part}"
        if [ "$show_time" = "true" ] && [ "$seven_day_remaining" -gt 0 ] 2>/dev/null && ! is_compact "$compact"; then
            result="${result} ($(format_time_remaining "$seven_day_remaining"))"
        fi
    fi

    # Append backoff indicator at the end
    result="${result}${backoff_marker}"

    echo "$result"
}
