# shellcheck shell=bash
# @cortado-module node
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu dev 23
# @description Node.js version
# @config NODE_ICON:string
# @config NODE_SHOW_NVM:bool
# @config NODE_COMPACT:bool
# =============================================================================
# Node Module - Shows Node.js version and npm info
# =============================================================================
# Configuration options:
#   NODE_ICON          - Icon for Node (default: ⬢)
#   NODE_SHOW_VERSION  - Show Node version (default: true)
#   NODE_SHOW_NPM      - Show npm version (default: false)
#   NODE_SHOW_NVM      - Show if using nvm (default: false)
#   NODE_COMPACT       - Compact mode (default: false)
# =============================================================================

_node_version_probe() {
    local tool="$1" version
    version=$("$tool" --version) || return 1
    [ "${2:-}" != node ] || version=${version#v}
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][[:alnum:].+-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

_cached_node_version() {
    local tool="$1" executable identity digest
    REPLY=
    if declare -F "$tool" >/dev/null; then
        # Trusted config can supply a shell function instead of an executable.
        identity=$(declare -f "$tool")
        export -f "${tool?}"
        executable=$tool
    else
        executable=$(type -P "$tool") || return 0
        [ -n "$executable" ] || return 0
    fi
    # Runtime shims can resolve a different version when PATH or the working
    # directory changes, even if the selected executable has the same path.
    digest=$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex(join "\0", @ARGV)' \
        "$executable" "$identity" "$PWD" "$PATH") || return 0
    cached_probe "$tool-$digest" 30 5 "${BASH_SOURCE[0]}" _node_version_probe "$executable" "$tool"
}

module_node() {
    get_icon_reply "${NODE_ICON:-⬢}" "NODE:"
    local icon="$REPLY"
    local show_version="${NODE_SHOW_VERSION:-true}"
    local show_npm="${NODE_SHOW_NPM:-false}"
    local show_nvm="${NODE_SHOW_NVM:-false}"
    local compact="${NODE_COMPACT:-false}"

    local parts=""
    local version_number='^[0-9]+\.[0-9]+\.[0-9]+([+-][[:alnum:].+-]+)?$'

    if [ "$show_version" = "true" ]; then
        local node_version
        _cached_node_version node
        node_version="$REPLY"
        if [[ "$node_version" =~ $version_number ]]; then
            if is_compact "$compact"; then
                # Just major.minor in compact
                local rest="${node_version#*.}"
                parts="${node_version%%.*}.${rest%%.*}"
            else
                parts="$node_version"
            fi
        fi
    fi

    if [ "$show_npm" = "true" ]; then
        local npm_version
        _cached_node_version npm
        npm_version="$REPLY"
        if [[ "$npm_version" =~ $version_number ]]; then
            if is_compact "$compact"; then
                local npm_rest="${npm_version#*.}"
                npm_version="${npm_version%%.*}.${npm_rest%%.*}"
            fi
            if [ -n "$parts" ]; then
                parts="$parts/npm:$npm_version"
            else
                parts="npm:$npm_version"
            fi
        fi
    fi

    if [ "$show_nvm" = "true" ]; then
        if [ -n "${NVM_DIR:-}" ] && [ -d "$NVM_DIR" ]; then
            parts="${parts:+$parts }(nvm)"
        fi
    fi

    if [ -n "$parts" ]; then
        echo "$icon $parts"
    elif [ "$show_version" = "true" ] || [ "$show_npm" = "true" ] || [ "$show_nvm" = "true" ]; then
        echo "$icon --"
    fi
}
