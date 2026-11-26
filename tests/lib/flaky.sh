# shellcheck shell=bash
# Read tests/flaky.txt, the quarantine list of checks that fail intermittently.
#
#   flaky_entries          prints the first field of every entry
#   is_flaky <suite> [section]
#                          succeeds when the whole suite, or that section of
#                          it, is quarantined and CORTADO_RUN_FLAKY is not 1
#
# CORTADO_FLAKY_FILE overrides the list (tests use it). Bash 3.2 compatible.

_flaky_file() {
    printf '%s\n' "${CORTADO_FLAKY_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/flaky.txt}"
}

flaky_entries() {
    local file
    file=$(_flaky_file)
    [ -r "$file" ] || return 0
    awk '$1 !~ /^#/ && NF { print $1 }' "$file"
}

is_flaky() {
    local name="${1##*/}" section="${2:-}" entry
    [ "${CORTADO_RUN_FLAKY:-}" != 1 ] || return 1
    while IFS= read -r entry; do
        if [ -n "$section" ]; then
            [ "$entry" = "$name:$section" ] && return 0
        else
            [ "$entry" = "$name" ] && return 0
        fi
    done <<EOF
$(flaky_entries)
EOF
    return 1
}
