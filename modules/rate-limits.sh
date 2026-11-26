# shellcheck shell=bash
# @cortado-module rate-limits
# @default true
# @args payload
# @ttl 120
# @timeout-ms 5000
# @platforms darwin,linux
# @menu core 10
# @description Rate limits
# @config RATE_SHOW_5H:bool
# @config RATE_SHOW_7D:bool
# @config RATE_SHOW_TIME_REMAINING:bool
# @config RATE_SHOW_PROJECTION:bool
# @config RATE_SHOW_PROGRESS_BAR:bool
# @config RATE_PROGRESS_BAR_WIDTH:int
# @config RATE_WARNING_THRESHOLD:int
# @config RATE_CRITICAL_THRESHOLD:int
# @config RATE_COMPACT:bool
# @config RATE_5H_LABEL:string
# @config RATE_7D_LABEL:string
# @config RATE_LOW_THRESHOLD:int
# @config RATE_MEDIUM_THRESHOLD:int
# @config RATE_HIGH_THRESHOLD:int
# @config RATE_SHOW_USAGE_STATUS:bool
# =============================================================================
# Rate Limits Module - Shows 5-hour and 7-day usage with projections
# Shows gateway spend against its limit when Claude Code reports that reading.
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
#   RATE_SHOW_USAGE_STATUS  - Show usage level indicator for percentages (default: true)
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
            # documents, malformed input and non-string tokens.
            if [ "${CTX_READY:-false}" = true ]; then
                [ "${cortado_json_worker:-false}" = true ] || return 0
                local credentials=
                # A successful read stopped at a raw NUL, which is invalid JSON.
                if IFS= read -r -d '' credentials 2>/dev/null < "$creds_file"; then
                    return 0
                fi
                if [ -n "$credentials" ] && _json_reply credential "$credentials"; then
                    printf '%s\n' "$REPLY"
                fi
            elif file_token=$(_cortado_jq -ers --arg kind credential 2>/dev/null < "$creds_file"); then
                # Standalone callers still check jq's complete exit status.
                printf '%s\n' "$file_token"
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
# Returns 0 for active or unknown cooldown, 1 for expired or absent.
# stdout carries the remaining seconds only when the age is known.
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
    now=$(date +%s 2>/dev/null) || return 0
    case "$now" in
        ''|0*|*[!0-9]*) return 0 ;;
    esac
    [ "$backoff_time" -gt 0 ] && [ "$now" -ge "$backoff_time" ] || return 0
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
            log_debug "rate-limits: backoff marker blocks API call${RATE_BACKOFF_REMAINING:+ (${RATE_BACKOFF_REMAINING}s remaining)}"
            return 1
        fi
    else
        local backoff_remaining
        if backoff_remaining=$(_check_backoff); then
            log_debug "rate-limits: backoff marker blocks API call${backoff_remaining:+ (${backoff_remaining}s remaining)}"
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
_get_projection_status_reply() {
    local projected=$1
    local warn_thresh="${RATE_WARNING_THRESHOLD:-80}"
    local crit_thresh="${RATE_CRITICAL_THRESHOLD:-100}"

    REPLY=
    [ "${RATE_SHOW_PROJECTION:-true}" = "true" ] || return 0
    if ! [ "$projected" -lt "$warn_thresh" ] 2>/dev/null; then
        get_status_reply "$projected" "$warn_thresh" "$crit_thresh"
    fi
}

_get_projection_status() {
    _get_projection_status_reply "$@"
    echo "$REPLY"
}

_project_usage_reply() {
    local LC_ALL=C
    local current first last elapsed="$4" remaining="$5"
    decimal_fixed_reply "$1" || return 1; current=$REPLY
    decimal_fixed_reply "$2" || return 1; first=$REPLY
    decimal_fixed_reply "$3" || return 1; last=$REPLY
    # The history percentage range and the reset cap keep products in range.
    if [ "$first" -gt 1000000000000 ] || [ "$last" -gt 1000000000000 ]; then
        return 1
    fi

    # Keep ten places through the addition before rounding the projection.
    local rate=$(((last - first) / elapsed))
    local total=$((current + rate * remaining)) sign=""
    if [ "$total" -lt 0 ]; then
        sign=-
        total=$((-total))
    fi
    local projected
    printf -v projected '%s%d.%010d' "$sign" "$((total / 10000000000))" "$((total % 10000000000))"
    printf -v REPLY '%.0f' "$projected"
}

# jq emits decimal points even in a comma-decimal locale. printf's
# nearest-even rounding matches the existing whole-percent display.
_round_usage_reply() {
    local LC_ALL=C
    printf -v REPLY '%.0f' "$1" 2>/dev/null || REPLY=
}

_spend_limit_part_reply() {
    local LC_ALL=C
    local limit percent percent_part=""
    if [ -n "$CTX_SPEND_PERCENT" ]; then
        _round_usage_reply "$CTX_SPEND_PERCENT"; percent=$REPLY
        if [ -n "$percent" ]; then
            REPLY=
            if [ "$1" = true ]; then
                get_status_4level_reply "$percent" "$2" "$3" "$4"
            fi
            percent_part="${percent}%$REPLY"
        fi
    fi

    REPLY=
    if [ -n "$CTX_SPEND_USED_USD" ] && [ -n "$CTX_SPEND_LIMIT_USD" ] &&
        printf -v limit '%.2f' "$CTX_SPEND_LIMIT_USD" 2>/dev/null &&
        [ "$limit" != 0.00 ] &&
        printf -v REPLY 'spend:$%.2f/$%s' "$CTX_SPEND_USED_USD" "$limit" 2>/dev/null; then
        REPLY="$REPLY${percent_part:+ ($percent_part)}"
    else
        REPLY="${percent_part:+spend:$percent_part}"
    fi
}

# Emit the verified age followed by the cached JSON. When a stale read races
# with a writer, retry once using the fresh TTL.
_read_usage_cache() {
    local file="$1" max_age="$2" retry_max_age="${3:-}"
    local mtime now age data
    while [ -f "$file" ]; do
        mtime=$(_file_mtime "$file")
        now=$(date +%s 2>/dev/null) || return 1
        case "$now" in
            ''|0*|*[!0-9]*) return 1 ;;
        esac
        [ "$mtime" -gt 0 ] && [ "$now" -ge "$mtime" ] || return 1
        age=$((now - mtime))
        [ "$age" -le "$max_age" ] 2>/dev/null || return 1
        data=$(cat "$file" 2>/dev/null) || return 1
        if [ "$mtime" = "$(_file_mtime "$file")" ]; then
            [ -n "$data" ] || return 1
            printf '%s\n%s\n' "$age" "$data"
            return 0
        fi
        [ -n "$retry_max_age" ] || return 1
        max_age="$retry_max_age"
        retry_max_age=""
    done
    return 1
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

# Render the placeholder line shown when no 5-hour or 7-day usage is available.
_render_placeholder() {
    local show_5h="$1"
    local show_7d="$2"
    local label_5h="$3"
    local label_7d="$4"
    local spend_part="${5:-}"
    local result=""
    [ "$show_5h" = "true" ] && result="${label_5h}:--"
    [ "$show_7d" = "true" ] && result="${result:+$result }${label_7d}:--"
    [ -n "$spend_part" ] && result="${result:+$result }$spend_part"
    echo "$result"
}

module_rate_limits() {
    if [ "${CTX_READY:-}" != true ]; then
        with_payload_context module_rate_limits <<< "${1:-}"
        return
    fi
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
    local spend_part
    _spend_limit_part_reply "$show_usage_status" "$low_thresh" "$medium_thresh" "$high_thresh"
    spend_part=$REPLY

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
    local backoff_remaining=""
    local age_marker=""

    local five_hour seven_day five_hour_reset seven_day_reset
    # Prefer the parsed payload and keep its readings out of the shared API cache.
    if [ "${CTX_HAS_RATES:-false}" = "true" ]; then
        from_payload=true
        five_hour="${CTX_FIVE_HOUR#-}"
        seven_day="${CTX_SEVEN_DAY#-}"
        five_hour_reset="$CTX_FIVE_RESET"
        seven_day_reset="$CTX_SEVEN_RESET"
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
            elif cached_usage=$(_read_usage_cache "$cache_file" 86400 "$cache_ttl"); then
                # API failed — serve the bounded fallback with its age.
                usage_data=${cached_usage#*$'\n'}
                cache_age=${cached_usage%%$'\n'*}
                if [ "$cache_age" -gt "$cache_ttl" ]; then
                    age_marker="~$(format_cooldown "$cache_age")"
                fi
            fi
        fi
    fi

    if [ "$from_payload" = "false" ] && [ -z "$usage_data" ]; then
        # No data at all - show backoff countdown if applicable
        if [ "$in_backoff" = "true" ] && [ -n "$backoff_remaining" ]; then
            local pause_icon=$(get_icon "⏸" "WAIT:")
            echo "${pause_icon} API cooldown $(format_cooldown "$backoff_remaining")${spend_part:+ $spend_part}"
        else
            _render_placeholder "$show_5h" "$show_7d" "$label_5h" "$label_7d" "$spend_part"
        fi
        return
    fi

    if [ "$from_payload" = "false" ]; then
        if ! _json_reply usage "$usage_data" || [ -z "$REPLY" ]; then
            _render_placeholder "$show_5h" "$show_7d" "$label_5h" "$label_7d" "$spend_part"
            return
        fi
        # The decoder supplies four fixed assignment keys with @sh-quoted values.
        eval "$REPLY"
    fi

    local now
    now=$(date +%s 2>/dev/null) || now=
    case "$now" in
        0*|*[!0-9]*) now= ;;
    esac
    if ! [ "$now" -gt 0 ] 2>/dev/null; then
        now=
    fi

    # History rows drive both projections and need two measured percentages.
    if [ -n "$now" ] && [ -n "$five_hour" ] && [ -n "$seven_day" ]; then
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
    if [ -n "$now" ] && [ -n "$five_hour" ] && [ -n "$five_hour_reset" ]; then
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

                if [ "$elapsed" -gt 60 ] &&
                    _project_usage_reply "$five_hour" "$first_util" "$last_util" "$elapsed" "$five_hour_remaining"; then
                    _get_projection_status_reply "$REPLY"
                    five_hour_status=$REPLY
                fi
            fi
        fi
    fi

    # Parse 7-day reset time and calculate projection
    if [ -n "$now" ] && [ -n "$seven_day" ] && [ -n "$seven_day_reset" ]; then
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

                if [ "$elapsed" -gt "$min_elapsed" ] &&
                    _project_usage_reply "$seven_day" "$first_util" "$last_util" "$elapsed" "$seven_day_remaining"; then
                    _get_projection_status_reply "$REPLY"
                    seven_day_status=$REPLY
                fi
            fi
        fi
    fi

    local five_hour_int seven_day_int
    _round_usage_reply "${five_hour:-0}"; five_hour_int=$REPLY
    _round_usage_reply "${seven_day:-0}"; seven_day_int=$REPLY

    local five_hour_part="--"
    local seven_day_part="--"
    if [ -n "$five_hour" ] && [ -n "$five_hour_int" ]; then
        five_hour_part="${five_hour_int}%${age_marker}"
        if [ "$show_bar" = "true" ]; then
            progress_bar_reply "$five_hour_int" "$bar_width"
            five_hour_part="$REPLY $five_hour_part"
        fi
        if [ "$show_usage_status" = "true" ]; then
            get_status_4level_reply "$five_hour_int" "$low_thresh" "$medium_thresh" "$high_thresh"
            five_hour_part="$five_hour_part$REPLY"
        fi
        five_hour_part="$five_hour_part$five_hour_status"
    fi
    if [ -n "$seven_day" ] && [ -n "$seven_day_int" ]; then
        seven_day_part="${seven_day_int}%${age_marker}"
        if [ "$show_bar" = "true" ]; then
            progress_bar_reply "$seven_day_int" "$bar_width"
            seven_day_part="$REPLY $seven_day_part"
        fi
        if [ "$show_usage_status" = "true" ]; then
            get_status_4level_reply "$seven_day_int" "$low_thresh" "$medium_thresh" "$high_thresh"
            seven_day_part="$seven_day_part$REPLY"
        fi
        seven_day_part="$seven_day_part$seven_day_status"
    fi

    # Build output
    local result=""

    # Add a cooldown indicator when showing cached data during API backoff.
    local backoff_marker=""
    if [ "$in_backoff" = "true" ] && [ -n "$backoff_remaining" ] && [ "$fresh_fetch" != "true" ]; then
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

    [ -n "$spend_part" ] && result="${result:+$result }$spend_part"

    # Append backoff indicator at the end
    result="${result}${backoff_marker}"

    echo "$result"
}
