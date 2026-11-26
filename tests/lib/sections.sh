# shellcheck shell=bash
# Run a suite's independent sections as parallel copies of the suite.
#
# Source tests/lib/assert.sh first, then this file, then, before the suite's
# own setup:
#
#   section="${MY_TEST_SECTION:-all}"
#   if [ "$section" = all ]; then
#       run_sections MY_TEST_SECTION "${MY_TEST_JOBS:-4}" "${BASH_SOURCE[0]}" slowest ... fastest
#   fi
#
# Guard each block of the suite with `if section_is <name>; then`, and end the
# suite with `section_results`. run_sections starts every listed section as its
# own copy of the suite, with <variable>=<name> and its own temporary files,
# in <jobs> lanes; each lane takes the next unclaimed section in list order, so
# list the slowest first. It prints each section's output in list order, then
# one combined Results line, and exits non-zero when any assertion failed or
# when a section
#   - is guarded in the file but missing from the list (it would never run),
#   - is listed but guarded nowhere in the file,
#   - ran zero assertions, or
#   - printed no Results line or exited non-zero.
# Bash 3.2 compatible.

# shellcheck disable=SC2154 # The sourcing suite sets $section, as above.
section_is() {
    [ "$section" = "$1" ]
}

# Print the Results line run_sections reads, and fail a section that ran nothing.
section_results() {
    [ $((PASS + FAIL)) -gt 0 ] || fail "section $section runs at least one assertion"
    printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}

run_sections() {
    local variable="$1" jobs="$2" suite="$3"
    shift 3
    local sections=" $* " found name lane results status work
    work=$(mktemp -d "${TMPDIR:-/tmp}/sections.XXXXXX") || exit 1
    _sections_work="$work"
    trap 'rm -rf "$_sections_work"' EXIT

    # Every name a `section_is` guard tests, whatever else is on its line.
    found=" $(grep -oE 'section_is [A-Za-z0-9_-]+' "$suite" | sed 's/^section_is //' |
        sort -u | tr '\n' ' ')"
    for name in $found; do
        case "$sections" in
            *" $name "*) ;;
            *) fail "section $name is scheduled to run" ;;
        esac
    done
    for name in $sections; do
        case "$found" in
            *" $name "*) ;;
            *) fail "scheduled section $name exists in this file" ;;
        esac
    done

    case "$jobs" in ''|*[!0-9]*|0*) jobs=4 ;; esac
    lane=0
    while [ "$lane" -lt "$jobs" ] && [ "$lane" -lt "$#" ]; do
        (
            for name in $sections; do
                # mkdir is atomic, so exactly one lane claims each section.
                mkdir "$work/$name.claim" 2>/dev/null || continue
                env "$variable=$name" /bin/bash "$suite" < /dev/null > "$work/$name.out" 2>&1
                printf '%s\n' "$?" > "$work/$name.status"
            done
        ) &
        lane=$((lane + 1))
    done
    wait

    for name in $sections; do
        printf '== %s\n' "$name"
        cat "$work/$name.out" 2>/dev/null
        results=$(sed -nE 's/^Results: ([0-9]+) passed, ([0-9]+) failed$/\1 \2/p' "$work/$name.out" 2>/dev/null |
            tail -n 1)
        status=$(cat "$work/$name.status" 2>/dev/null)
        if [ -n "$results" ]; then
            PASS=$((PASS + ${results% *}))
            FAIL=$((FAIL + ${results#* }))
            [ "${results% *}" -gt 0 ] || fail "section $name runs at least one assertion"
        fi
        if [ -z "$results" ] || [ "$status" != 0 ]; then
            fail "section $name reports its results and exits cleanly"
        fi
    done
    printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
    exit
}
