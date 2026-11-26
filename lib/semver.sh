# shellcheck shell=bash

_version_numeric_component() {
    local value="${1:-}"
    value="${value%%[!0-9]*}"
    printf '%s\n' "${value:-0}"
}

# Compare major, minor and patch numerically. Release suffixes are ignored.
version_lt() {
    local v1="$1"
    local v2="$2"
    local v1_major v1_minor v1_patch v2_major v2_minor v2_patch

    IFS=. read -r v1_major v1_minor v1_patch _ <<< "$v1"
    IFS=. read -r v2_major v2_minor v2_patch _ <<< "$v2"

    v1_major=$(_version_numeric_component "$v1_major")
    v1_minor=$(_version_numeric_component "$v1_minor")
    v1_patch=$(_version_numeric_component "$v1_patch")
    v2_major=$(_version_numeric_component "$v2_major")
    v2_minor=$(_version_numeric_component "$v2_minor")
    v2_patch=$(_version_numeric_component "$v2_patch")

    if [ "$v1_major" -lt "$v2_major" ]; then return 0; fi
    if [ "$v1_major" -gt "$v2_major" ]; then return 1; fi
    if [ "$v1_minor" -lt "$v2_minor" ]; then return 0; fi
    if [ "$v1_minor" -gt "$v2_minor" ]; then return 1; fi
    if [ "$v1_patch" -lt "$v2_patch" ]; then return 0; fi
    return 1
}
