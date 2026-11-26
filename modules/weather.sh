# shellcheck shell=bash
# @cortado-module weather
# @default false
# @args none
# @ttl 1800
# @timeout-ms 3000
# @platforms darwin,linux
# @menu extra 24
# @description Weather (wttr.in)
# @config WEATHER_SHOW_TEMP:bool
# @config WEATHER_SHOW_COND:bool
# @config WEATHER_COMPACT:bool
# =============================================================================
# Weather Module - Shows current weather (uses wttr.in)
# =============================================================================
# Configuration options:
#   WEATHER_LOCATION   - Location in user config (default: auto-detect)
#   WEATHER_UNITS      - User config units: "m" (metric), "u" (US), "M" (metric wind) (default: u)
#   WEATHER_SHOW_TEMP  - Show temperature (default: true)
#   WEATHER_SHOW_COND  - Show condition icon (default: true)
#   WEATHER_COMPACT    - Compact mode (default: false)
#   WEATHER_CACHE_TTL  - User config cache duration in seconds (default: 1800)
# Project config can set the display options above or set MODULE_WEATHER=false.
# =============================================================================

module_weather() {
    local location="${WEATHER_LOCATION:-}"
    local units="${WEATHER_UNITS:-u}"
    # Restrict to wttr.in's documented unit flags so a config value can't inject extra URL params
    case "$units" in
        m|u|M) ;;
        *) units="u" ;;
    esac
    local show_temp="${WEATHER_SHOW_TEMP:-true}"
    local show_cond="${WEATHER_SHOW_COND:-true}"
    local compact="${WEATHER_COMPACT:-false}"
    local cache_ttl="${WEATHER_CACHE_TTL:-1800}"
    # Use a numeric TTL for the cache age comparison.
    case "$cache_ttl" in
        ''|*[!0-9]*) cache_ttl=1800 ;;
    esac

    local weather_data=""

    # Use private cache directory instead of world-readable /tmp
    local weather_cache_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cortado-cache"
    mkdir -p "$weather_cache_dir" 2>/dev/null
    chmod 700 "$weather_cache_dir" 2>/dev/null
    local cache_file="$weather_cache_dir/weather"

    # Check cache
    if [ -f "$cache_file" ]; then
        local cache_age=$(( $(date +%s) - $(_file_mtime "$cache_file") ))
        if [ "$cache_age" -lt "$cache_ttl" ]; then
            weather_data=$(cat "$cache_file")
        fi
    fi

    # Fetch fresh data if needed
    if [ -z "$weather_data" ]; then
        # Keep metacharacters, whitespace and query delimiters out of the location.
        case "$location" in
            *\`*|*\$\(*|*\;*|*\|*|*\&*|*\>*|*\<*|*\'*|*\"*|*\\*|*'?'*|*'#'*|*' '*|*[[:cntrl:]]*)
                log_debug "weather: rejected unsafe WEATHER_LOCATION value"
                return
                ;;
        esac
        local url="https://wttr.in/${location}?format=%c%t&${units}"
        weather_data=$(curl -s --max-time 3 --proto =https --max-redirs 3 "$url" 2>/dev/null)
        if [ -n "$weather_data" ] && [ "$weather_data" != "Unknown location" ]; then
            printf '%s' "$weather_data" > "$cache_file" 2>/dev/null
            chmod 600 "$cache_file" 2>/dev/null
        else
            weather_data=""
        fi
    fi

    if [ -z "$weather_data" ]; then
        return
    fi

    # Parse weather data (format: icon+temp like "☀️+72°F")
    local cond_icon=$(echo "$weather_data" | sed 's/[+].*//')
    local temp=$(echo "$weather_data" | sed 's/.*[+]//')

    local result=""

    if [ "$show_cond" = "true" ] && [ -n "$cond_icon" ]; then
        result="$cond_icon"
    fi

    if [ "$show_temp" = "true" ] && [ -n "$temp" ]; then
        if [ -n "$result" ]; then
            result="${result} ${temp}"
        else
            result="${temp}"
        fi
    fi

    # Trim whitespace
    result=$(echo "$result" | sed 's/^ *//;s/ *$//')

    echo "$result"
}
