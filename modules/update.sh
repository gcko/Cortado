# shellcheck shell=bash
# =============================================================================
# Update Module - Daily check for Cortado updates
# =============================================================================
# Checks GitHub for a newer release and shows a notice if one is found.
# Unavailable checks show "--" and are cached for at most one hour.
#
# Configuration options:
#   UPDATE_CHECK_INTERVAL   - Cache lifetime in seconds (default: 86400 = 24h)
#   UPDATE_REPO             - GitHub repo to check (default: gcko/Cortado)
#   UPDATE_ICON             - Icon for update notification (default: arrow up)
# =============================================================================

_check_cortado_update() {
    local repo="${UPDATE_REPO:-gcko/Cortado}"
    local cache_key="update_check"
    local check_interval="${UPDATE_CHECK_INTERVAL:-86400}"

    # Validate repo format (owner/name) to prevent URL injection
    case "$repo" in
        *[!A-Za-z0-9_./-]*)
            log_debug "update: rejected unsafe UPDATE_REPO value"
            return
            ;;
    esac

    # Older "current" entries could represent a failed check. Refresh them.
    local cached
    cached=$(cache_get "$cache_key" "$check_interval")
    case "$cached" in
        checked-current|available:*)
            printf '%s\n' "$cached"
            return
            ;;
        unknown)
            if [ "$(cache_get "$cache_key" 3600)" = "unknown" ]; then
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
    if [ -n "$local_version" ] && remote_version=$(_fetch_cortado_release "$repo"); then
        result="checked-current"
        if [ "$remote_version" != "$local_version" ] && _version_gt "$remote_version" "$local_version"; then
            result="available:$remote_version"
        fi
    fi

    cache_set "$cache_key" "$result"
    printf '%s\n' "$result"
}

_fetch_cortado_release() {
    local repo="$1"

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

    local release_pattern='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?$'
    tag=$(printf '%s\n' "$body" | jq -er '.tag_name | strings' 2>/dev/null) || return 1
    [[ "$tag" =~ $release_pattern ]] || return 1
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
