# shellcheck shell=bash
# Load after the shipped modules in a temporary tree. Uptime provides the
# registry slot; the fixture owns the reading and its diagnostic.
module_uptime() {
    if [ "${TEST_CACHE_WRITE:-false}" = true ]; then
        # cache_set reports a failed write by exit status and suppresses stderr.
        cache_set routing-probe 'fixture value' ||
            printf 'cache_set failed for %s/routing-probe\n' "$CACHE_DIR" >&2
    else
        printf '%s\n' "$TEST_RUNTIME_DIAGNOSTIC" >&2
    fi
    printf '%s\n' 'Fixture reading'
}
