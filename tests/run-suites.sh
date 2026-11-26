#!/bin/bash
# Run the requested suites, or every tests/test_*.sh, in parallel.
#
#   /bin/bash tests/run-suites.sh [suite...]
#
# CORTADO_TEST_JOBS caps the parallel jobs (default: the core count).
# SUITE_TIMEOUT bounds each suite in seconds (default: 300).
#
# Each suite runs standalone with its own TMPDIR, prints one PASS, FAIL or
# TIMEOUT line as it finishes, and keeps its output in a private file. Failing
# suites' output is printed afterwards, one whole block per suite, so parallel
# output never interleaves. The exit status is non-zero when any suite fails.
# Bash 3.2 (macOS /bin/bash) and BSD or GNU xargs.
set -u

if [ "${1:-}" = --worker ]; then
    # xargs calls back here once per suite: --worker <work dir> <index> <suite>
    work="$2" index="$3" suite="$4"
    name="${suite##*/}"
    tmp="$work/tmp/$index"
    mkdir -p "$tmp" || exit 1
    started=$SECONDS
    status=0
    # perl's alarm survives the exec, so a hang ends as SIGALRM (status 142).
    TMPDIR="$tmp" perl -e 'alarm shift; exec @ARGV' "${SUITE_TIMEOUT:-300}" \
        /bin/bash "$suite" < /dev/null > "$work/$index.out" 2>&1 || status=$?
    elapsed=$((SECONDS - started))
    # Leftovers from a killed suite go with its private TMPDIR.
    rm -rf "$tmp" 2>/dev/null
    if [ "$status" -eq 0 ]; then
        result=PASS
        line="PASS: $name (${elapsed}s)"
    elif [ "$status" -eq 142 ]; then
        result=TIMEOUT
        line="TIMEOUT: $name (over ${SUITE_TIMEOUT:-300}s)"
    else
        result=FAIL
        line="FAIL: $name (exit $status, ${elapsed}s)"
    fi
    printf '%s\n' "$result" > "$work/$index.result"
    # One short write per line, so concurrent result lines stay whole.
    printf '%s\n' "$line"
    exit 0
fi

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="$test_dir/run-suites.sh"
if [ "$#" -eq 0 ]; then
    set -- "$test_dir"/test_*.sh
fi
for suite in "$@"; do
    if [ ! -f "$suite" ]; then
        printf 'run-suites: no such suite: %s\n' "$suite" >&2
        exit 2
    fi
done

cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null) || cores=1
jobs="${CORTADO_TEST_JOBS:-$cores}"
case "$jobs" in
    ''|*[!0-9]*|0*)
        printf 'run-suites: CORTADO_TEST_JOBS must be a positive integer, got [%s]\n' "$jobs" >&2
        exit 2 ;;
esac
case "${SUITE_TIMEOUT:-300}" in
    ''|*[!0-9]*|0*)
        printf 'run-suites: SUITE_TIMEOUT must be a positive integer, got [%s]\n' "${SUITE_TIMEOUT:-}" >&2
        exit 2 ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/cortado-suites.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
mkdir "$work/tmp" || exit 1

suites=("$@")
# Start the largest suites first: size tracks run time well enough that the
# slowest suites do not start last and leave the other jobs idle.
order=$(
    i=0
    for suite in "${suites[@]}"; do
        printf '%s %s\n' "$(wc -c < "$suite" | tr -d ' ')" "$i"
        i=$((i + 1))
    done | sort -k1,1nr -k2,2n | awk '{ print $2 }'
)
started=$SECONDS
for i in $order; do
    printf '%s\0%s\0' "$i" "${suites[i]}"
done | xargs -0 -n 2 -P "$jobs" /bin/bash "$runner" --worker "$work"

passed=0 failed=0 timed_out=0
i=0
for suite in "${suites[@]}"; do
    result=$(cat "$work/$i.result" 2>/dev/null) || result=
    case "$result" in
        PASS) passed=$((passed + 1)) ;;
        TIMEOUT|FAIL)
            if [ "$result" = TIMEOUT ]; then timed_out=$((timed_out + 1)); else failed=$((failed + 1)); fi
            printf '\n==== %s: %s ====\n' "$result" "${suite##*/}"
            cat "$work/$i.out" 2>/dev/null
            # Keep the end marker on its own line after an unterminated last line.
            [ -z "$(tail -c 1 "$work/$i.out" 2>/dev/null)" ] || printf '\n'
            printf '==== end %s ====\n' "${suite##*/}" ;;
        *)
            # The worker never reported, so its suite cannot count as a pass.
            failed=$((failed + 1))
            printf 'FAIL: %s (no result recorded)\n' "${suite##*/}" ;;
    esac
    i=$((i + 1))
done

printf '\nsuites: %s passed, %s failed, %s timed out, %ss with %s jobs\n' \
    "$passed" "$failed" "$timed_out" "$((SECONDS - started))" "$jobs"
[ "$failed" -eq 0 ] && [ "$timed_out" -eq 0 ]
