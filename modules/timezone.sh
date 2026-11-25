# shellcheck shell=bash
# =============================================================================
# Timezone Module - Shows time in different timezones
# =============================================================================
# Configuration options:
#   TIMEZONE_ZONES     - Comma-separated list of timezones (default: UTC)
#   TIMEZONE_FORMAT    - Time format (default: %H:%M)
#   TIMEZONE_SHOW_LABEL - Show timezone label (default: true)
#   TIMEZONE_LABELS    - Custom labels comma-separated (default: zone abbreviation)
#   TIMEZONE_COMPACT   - Compact mode (default: false)
# =============================================================================

module_timezone() {
    # Add a delimiter so the last field can be consumed like any other.
    local zones="${TIMEZONE_ZONES:-UTC},"
    local format="${TIMEZONE_FORMAT:-%H:%M}"
    local show_label="${TIMEZONE_SHOW_LABEL:-true}"
    local labels="${TIMEZONE_LABELS:+$TIMEZONE_LABELS,}"
    local compact="${TIMEZONE_COMPACT:-false}"

    local result=""
    local zone time_str label part

    while [ -n "$zones" ]; do
        zone="${zones%%,*}"
        zones="${zones#*,}"

        # Trim whitespace
        zone=$(echo "$zone" | sed 's/^ *//;s/ *$//')

        if [ -z "$zone" ]; then
            continue
        fi

        if ! time_str=$(TZ="$zone" date +"$format" 2>/dev/null) ||
           [[ "$time_str" != *[![:space:]]* ]]; then
            time_str=--
        fi

        label=""
        if [ "$show_label" = "true" ]; then
            if [ -n "$labels" ]; then
                # Consume one label for every configured nonblank zone.
                label=$(echo "${labels%%,*}" | sed 's/^ *//;s/ *$//')
                labels="${labels#*,}"
            fi

            if [ -z "$label" ]; then
                # Derive label from zone name
                label=$(echo "$zone" | sed 's|.*/||' | cut -c1-3 | tr '[:lower:]' '[:upper:]')
            fi
        fi

        if [ -n "$label" ]; then
            if is_compact "$compact"; then
                part="${label}:${time_str}"
            else
                part="${label}: ${time_str}"
            fi
        else
            part="$time_str"
        fi

        if [ -n "$result" ]; then
            result="$result | $part"
        else
            result="$part"
        fi
    done

    echo "$result"
}
