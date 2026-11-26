#!/bin/bash
# Run the requested suites, or every tests/test_*.sh, in parallel.
#
#   /bin/bash tests/run-suites.sh [suite...]
#
# CORTADO_TEST_JOBS caps the parallel jobs (default: the core count).
# SUITE_TIMEOUT bounds each suite in seconds (default: 300). A suite past its
# limit, or whose run is interrupted, has its whole process group stopped:
# TERM, then KILL after 2 s.
#
# Each suite runs standalone with its own TMPDIR and process group, prints
# one PASS, FAIL or TIMEOUT line as it finishes, and keeps its output in a
# private file. Failing suites' output is printed afterwards, one whole block
# per suite, so parallel output never interleaves. The exit status is non-zero when any suite fails.
# A suite quarantined in tests/flaky.txt is skipped with a "SKIP (flaky)" line
# (CORTADO_RUN_FLAKY=1 runs it anyway).
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
    # The suite leads its own process group (job control is on only for this
    # launch), so a timeout can stop everything it started, and its parent
    # is still this worker. Until the watchdog runs, a stop request (Ctrl-C,
    # a cancelled job) only marks this worker, which then exits.
    interrupted=
    trap 'interrupted=1' INT TERM HUP
    set -m
    TMPDIR="$tmp" /bin/bash "$suite" < /dev/null > "$work/$index.out" 2>&1 &
    pid=$!
    set +m
    # The watchdog stops the suite's group at the time limit or when this
    # worker exits early: TERM, then up to 2 s for the group to exit, then
    # KILL until no member is left. It writes the timeout marker before it
    # stops anything. It starts with INT, TERM and HUP ignored and keeps
    # them ignored, so a stop request cannot kill it before it acts; the
    # request ends this worker instead, and the watchdog sees that.
    # USR1 dismisses it.
    trap '' INT TERM HUP
    # shellcheck disable=SC2016 # Perl source, expanded by perl.
    perl -MTime::HiRes=time -e '
        my ($limit, $group, $marker, $worker) = @ARGV;
        $SIG{$_} = "IGNORE" for qw(INT TERM HUP);
        my $stop = sub {
            $SIG{USR1} = "IGNORE";
            if ($_[0]) { open(my $flag, ">", $marker) and close($flag) }
            kill "TERM", -$group;
            for (1 .. 200) { kill(0, -$group) or last; select(undef, undef, undef, 0.01) }
            for (1 .. 500) { kill("KILL", -$group) or last; select(undef, undef, undef, 0.01) }
            exit 0;
        };
        $SIG{USR1} = sub { exit 0 };
        my $end = time + $limit;
        while (time < $end) {
            $stop->(0) if getppid() != $worker;
            select(undef, undef, undef, 0.25);
        }
        $stop->(1);
    ' "${SUITE_TIMEOUT:-300}" "$pid" "$work/$index.timeout" "$$" < /dev/null > /dev/null 2>&1 &
    watchdog=$!
    trap - INT TERM HUP
    [ -z "$interrupted" ] || exit 1
    wait "$pid" 2>/dev/null || status=$?
    # A watchdog that is already stopping the group ignores USR1 and finishes.
    kill -USR1 "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    elapsed=$((SECONDS - started))
    # Leftovers from a killed suite go with its private TMPDIR.
    rm -rf "$tmp" 2>/dev/null
    if [ -e "$work/$index.timeout" ]; then
        result=TIMEOUT
        line="TIMEOUT: $name (over ${SUITE_TIMEOUT:-300}s)"
    elif [ "$status" -eq 0 ]; then
        result=PASS
        line="PASS: $name (${elapsed}s)"
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

# shellcheck source=tests/lib/flaky.sh
. "$test_dir/lib/flaky.sh"
kept=() skipped=0
for suite in "$@"; do
    if is_flaky "$suite"; then
        printf 'SKIP (flaky): %s\n' "${suite##*/}"
        skipped=$((skipped + 1))
    else
        kept+=("$suite")
    fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/cortado-suites.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
mkdir "$work/tmp" || exit 1

suites=(${kept[@]+"${kept[@]}"})
# Start the largest suites first: size tracks run time well enough that the
# slowest suites do not start last and leave the other jobs idle.
order=$(
    i=0
    for suite in ${suites[@]+"${suites[@]}"}; do
        printf '%s %s\n' "$(wc -c < "$suite" | tr -d ' ')" "$i"
        i=$((i + 1))
    done | sort -k1,1nr -k2,2n | awk '{ print $2 }'
)
started=$SECONDS
# GNU xargs runs its command once even with no input, so skip it when every
# suite was quarantined.
if [ -n "$order" ]; then
    for i in $order; do
        printf '%s\0%s\0' "$i" "${suites[i]}"
    done | xargs -0 -n 2 -P "$jobs" /bin/bash "$runner" --worker "$work"
fi

passed=0 failed=0 timed_out=0
i=0
for suite in ${suites[@]+"${suites[@]}"}; do
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

printf '\nsuites: %s passed, %s failed, %s timed out, %s skipped as flaky, %ss with %s jobs\n' \
    "$passed" "$failed" "$timed_out" "$skipped" "$((SECONDS - started))" "$jobs"
[ "$failed" -eq 0 ] && [ "$timed_out" -eq 0 ]
