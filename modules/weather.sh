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
#   WEATHER_CACHE_TTL  - User config cache duration in seconds (default: 1800, minimum: 1)
# Project config can set the display options above or set MODULE_WEATHER=false.
# =============================================================================

_weather_fields() {
    local LC_ALL=C
    local pattern='^([^[:alnum:][:space:][:cntrl:]+-]+)[[:blank:]]*([+-]?[0-9]{1,3}°[CF])$'
    [[ "$1" =~ $pattern ]]
}

_weather_probe() (
    set -o pipefail
    local data
    data=$(curl -q -f -s --globoff --max-time 3 --proto =https --max-filesize 1024 "$1" |
        head -c 1025) && _weather_fields "$data" || return 1
    printf '%s\n' "$data"
)

module_weather() {
    local location="${WEATHER_LOCATION:-}" units="${WEATHER_UNITS:-u}"
    local show_temp="${WEATHER_SHOW_TEMP:-true}" show_cond="${WEATHER_SHOW_COND:-true}"
    local cache_ttl="${WEATHER_CACHE_TTL:-1800}" key=weather
    [ "$show_temp" = true ] || [ "$show_cond" = true ] || return 0

    case "$units" in m|u|M) ;; *) units=u ;; esac
    if ! [[ "$cache_ttl" =~ ^[0-9]{1,10}$ ]]; then cache_ttl=1800; fi
    cache_ttl=$((10#$cache_ttl))
    if [ "$cache_ttl" -eq 0 ]; then cache_ttl=1; fi

    # Prevent query injection and keep distinct requests in distinct caches.
    case "$location" in
        *\`*|*\$\(*|*\;*|*\|*|*\&*|*\>*|*\<*|*\'*|*\"*|*\\*|*'?'*|*'#'*|*' '*|*[[:cntrl:]]*)
            log_debug "weather: rejected unsafe WEATHER_LOCATION value"
            printf '%s\n' --
            return ;;
    esac
    if [ -n "$location" ] || [ "$units" != u ]; then
        local request_hash
        if ! request_hash=$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex(join "\0", @ARGV)' "$location" "$units"); then
            printf '%s\n' --
            return
        fi
        key="weather-$request_hash"
    fi

    cached_probe "$key" "$cache_ttl" 15 "${BASH_SOURCE[0]}" _weather_probe \
        "https://wttr.in/${location}?format=%c%t&${units}"
    if ! _weather_fields "$REPLY"; then
        printf '%s\n' --
        return
    fi

    local cond="${BASH_REMATCH[1]}" temp="${BASH_REMATCH[2]#+}"
    if [ "$show_temp" = true ] && [ "$show_cond" = true ]; then
        printf '%s %s\n' "$cond" "$temp"
    elif [ "$show_temp" = true ]; then
        printf '%s\n' "$temp"
    else
        printf '%s\n' "$cond"
    fi
}
