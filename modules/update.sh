# shellcheck shell=bash
# =============================================================================
# Update Module - Check for Cortado releases
# =============================================================================
# Checks GitHub for a newer release and shows a notice if one is found.
# Unavailable checks show "--" and are cached for half the successful interval,
# capped at one hour.
#
# Configuration options:
#   UPDATE_CHECK_INTERVAL   - Successful cache lifetime in seconds (default: 86400 = 24h)
#   UPDATE_REPO             - GitHub repo to check (default: gcko/Cortado)
#   UPDATE_ICON             - Icon for update notification (default: arrow up)
# =============================================================================

_check_cortado_update() {
    local repo="${UPDATE_REPO:-gcko/Cortado}"
    local cache_key="update_check"
    local check_interval="${UPDATE_CHECK_INTERVAL:-86400}"
    local version_pattern='[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?'

    # Validate repo format (owner/name) to prevent URL injection
    case "$repo" in
        *[!A-Za-z0-9_./-]*)
            log_debug "update: rejected unsafe UPDATE_REPO value"
            printf '%s\n' unknown
            return
            ;;
    esac

    # Require decimal seconds in Bash's integer range before using arithmetic.
    if [[ ! "$check_interval" =~ ^[0-9]+$ ]] || ! [ "$check_interval" -ge 0 ] 2>/dev/null; then
        check_interval=86400
    fi
    local failure_interval=$((10#$check_interval / 2))
    if [ "$failure_interval" -gt 3600 ]; then
        failure_interval=3600
    fi

    # Older "current" entries could represent failed checks, and older
    # "available:" entries could contain malformed versions.
    local cached
    cached=$(cache_get "$cache_key" "$check_interval")
    case "$cached" in
        checked-current)
            printf '%s\n' "$cached"
            return
            ;;
        available:*)
            if [[ "${cached#available:}" =~ ^${version_pattern}$ ]]; then
                printf '%s\n' "$cached"
                return
            fi
            ;;
        unknown)
            if [ "$(cache_get "$cache_key" "$failure_interval")" = "unknown" ]; then
                printf '%s\n' "$cached"
                return
            fi
            ;;
    esac

    # Read local version
    local local_version=""
    local version_file="$SCRIPT_DIR/VERSION"
    if [ -f "$version_file" ]; then
        local_version=$(cat "$version_file" 2>/dev/null | tr -d '[:space:]')
    fi

    local remote_version result="unknown"
    if [ -n "$local_version" ] && remote_version=$(_fetch_cortado_release "$repo" "$version_pattern"); then
        result="checked-current"
        if [ "$remote_version" != "$local_version" ] && _version_gt "$remote_version" "$local_version"; then
            result="available:$remote_version"
        fi
    fi

    cache_set "$cache_key" "$result"
    printf '%s\n' "$result"
}

_fetch_cortado_release() {
    local repo="$1" version_pattern="$2"

    # Fetch latest release tag from GitHub API (unauthenticated, low rate limit)
    local response http_code body tag
    if ! response=$(curl -s --max-time 5 --proto =https --max-redirs 3 -w "\n%{http_code}" \
        "https://api.github.com/repos/${repo}/releases/latest" \
        -H "Accept: application/vnd.github+json" 2>/dev/null); then
        log_debug "update: GitHub API request failed"
        return 1
    fi

    http_code=$(printf '%s\n' "$response" | tail -1)
    body=$(printf '%s\n' "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log_debug "update: GitHub API returned HTTP $http_code"
        return 1
    fi

    local release_pattern="\Av?${version_pattern}\z"
    tag=$(printf '%s\n' "$body" | jq -ers --arg pattern "$release_pattern" \
        'select(length == 1) | .[0] | objects | .tag_name | strings | select(test($pattern))' 2>/dev/null) || return 1
    printf '%s\n' "${tag#v}"
}

# Return the leading numeric portion of a semantic-version component.
# Release tags can include suffixes such as "0-rc1"; keeping only the leading
# digits makes the numeric comparison safe without trying to order prereleases.
_version_numeric_component() {
    local value="${1:-}"
    value="${value%%[!0-9]*}"
    printf '%s\n' "${value:-0}"
}

# Compare two semver strings: returns 0 if $1 > $2
_version_gt() {
    local v1="$1" v2="$2"
    # Split on dots and compare the numeric prefix of each component. Bash's
    # arithmetic parser rejects values such as "0-rc1", so sanitize first.
    local v1_major v1_minor v1_patch v2_major v2_minor v2_patch
    IFS=. read -r v1_major v1_minor v1_patch _ <<< "$v1"
    IFS=. read -r v2_major v2_minor v2_patch _ <<< "$v2"

    v1_major=$(_version_numeric_component "$v1_major")
    v1_minor=$(_version_numeric_component "$v1_minor")
    v1_patch=$(_version_numeric_component "$v1_patch")
    v2_major=$(_version_numeric_component "$v2_major")
    v2_minor=$(_version_numeric_component "$v2_minor")
    v2_patch=$(_version_numeric_component "$v2_patch")

    if [ "$v1_major" -gt "$v2_major" ]; then return 0; fi
    if [ "$v1_major" -lt "$v2_major" ]; then return 1; fi
    if [ "$v1_minor" -gt "$v2_minor" ]; then return 0; fi
    if [ "$v1_minor" -lt "$v2_minor" ]; then return 1; fi
    if [ "$v1_patch" -gt "$v2_patch" ]; then return 0; fi
    return 1
}

module_update() {
    local result reading icon
    result=$(_check_cortado_update)

    case "$result" in
        available:*) reading="v${result#available:}" ;;
        unknown) reading="--" ;;
        *) return 0 ;;
    esac

    icon=$(get_icon "${UPDATE_ICON:-⬆}" "UPD:")
    printf '%s %s\n' "$icon" "$reading"
}
