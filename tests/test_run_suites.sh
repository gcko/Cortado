#!/bin/bash
# The parallel suite runner, and the guard that keeps tests/jq-suites.txt
# complete. Fake suites live in a private directory; no real suite runs here.
# The fake suite bodies are single-quoted on purpose; they expand when run.
# shellcheck disable=SC2016
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
RUNNER="$PROJECT_ROOT/tests/run-suites.sh"
VARIANTS="$PROJECT_ROOT/tests/run-jq-variants.sh"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
export TMPDIR="$TEST_BASE/tmp"
mkdir "$TMPDIR" "$TEST_BASE/suites" "$TEST_BASE/state" || exit 1
export STATE="$TEST_BASE/state"

fake() {
    local name="$1"
    shift
    printf '#!/bin/bash\n%s\n' "$@" > "$TEST_BASE/suites/$name"
}

fake test_pass.sh 'echo pass-output' 'exit 0'
fake test_fail.sh 'for i in 1 2 3 4 5; do echo "fail-line-$i"; sleep 0.02; done' 'exit 1'
fake test_fail_too.sh 'for i in 1 2 3 4 5; do echo "other-line-$i"; sleep 0.02; done' 'exit 3'
fake test_hang.sh 'echo hang-started' 'exec sleep 30'
fake test_tmpdir.sh 'printf "%s\n" "$TMPDIR" > "$STATE/tmpdir-$$"; : > "$TMPDIR/leftover"'
fake test_tmpdir_too.sh 'printf "%s\n" "$TMPDIR" > "$STATE/tmpdir-$$"; : > "$TMPDIR/leftover"'
wait_for='for ((i=0; i<60; i++)); do [ ! -e "$STATE/$1" ] || exit 0; sleep 0.05; done; exit 1'
fake test_meet_a.sh ': > "$STATE/a-started"' "set -- b-started; $wait_for"
fake test_meet_b.sh ': > "$STATE/b-started"' "set -- a-started; $wait_for"
s="$TEST_BASE/suites"

run() {
    status=0
    output=$(/bin/bash "$RUNNER" "$@" 2>&1) || status=$?
}

# --- one failing suite fails on its own and is named -------------------------
CORTADO_TEST_JOBS=4 SUITE_TIMEOUT=1 run "$s/test_pass.sh" "$s/test_fail.sh" "$s/test_fail_too.sh" "$s/test_hang.sh"
assert_eq 'any failing suite makes the runner exit non-zero' 1 "$status"
assert_match 'a passing suite still passes beside failing ones' '^PASS: test_pass\.sh \(' "$output"
assert_match 'a failing suite is named on its FAIL line' '^FAIL: test_fail\.sh \(exit 1, ' "$output"
assert_match 'a second failing suite is named with its own status' '^FAIL: test_fail_too\.sh \(exit 3, ' "$output"
assert_match 'a hung suite is named on a TIMEOUT line' '^TIMEOUT: test_hang\.sh \(over 1s\)$' "$output"
assert_not_contains 'a passing suite keeps its output to itself' 'pass-output' "$output"
assert_contains 'the summary counts every outcome' 'suites: 1 passed, 2 failed, 1 timed out' "$output"

# Each failing suite's output is one contiguous block, in its own order.
block() {
    printf '%s\n' "$output" | awk -v name="$1" -v kind="$2" '
        $0 == "==== " kind ": " name " ====" { on = 1; next }
        $0 == "==== end " name " ====" { on = 0 }
        on'
}
assert_eq 'a failing suite prints its whole output as one block' \
    "$(printf 'fail-line-%s\n' 1 2 3 4 5)" "$(block test_fail.sh FAIL)"
assert_eq 'a second failing block holds only its own suite' \
    "$(printf 'other-line-%s\n' 1 2 3 4 5)" "$(block test_fail_too.sh FAIL)"
assert_eq 'a timed-out suite prints the output it made before the limit' 'hang-started' "$(block test_hang.sh TIMEOUT)"

SUITE_TIMEOUT=1 run "$s/test_hang.sh"
assert_eq 'a timeout alone makes the runner exit non-zero' 1 "$status"

# A worker that dies without recording a result cannot count as a pass.
fake test_lost.sh 'kill -KILL "$PPID"'
run "$s/test_lost.sh"
assert_eq 'a suite with no recorded result makes the runner exit non-zero' 1 "$status"
assert_match 'a suite with no recorded result is named' '^FAIL: test_lost\.sh \(no result recorded\)$' "$output"

# --- suites run in parallel, capped by CORTADO_TEST_JOBS ---------------------
# Each meeting suite passes only while the other one is running.
CORTADO_TEST_JOBS=2 run "$s/test_meet_a.sh" "$s/test_meet_b.sh"
assert_eq 'two jobs run two suites at once' 0 "$status"
assert_contains 'all passing suites give a clean summary' 'suites: 2 passed, 0 failed, 0 timed out' "$output"
rm -f "$STATE"/*-started
CORTADO_TEST_JOBS=1 run "$s/test_meet_a.sh" "$s/test_meet_b.sh"
assert_match 'one job runs one suite at a time' '^FAIL: test_meet_a\.sh ' "$output"

# The largest suite starts first; results still come back for every suite.
fake test_small.sh 'exit 0'
fake test_large.sh "# $(printf '%0200d' 0)" 'exit 0'
CORTADO_TEST_JOBS=1 run "$s/test_small.sh" "$s/test_large.sh"
assert_eq 'one job starts the largest suite first' 'PASS: test_large.sh' \
    "$(printf '%s\n' "$output" | sed -n 's/ (.*//; /^PASS: /{p;q;}')"

# --- each suite gets a private TMPDIR, removed when it ends ------------------
CORTADO_TEST_JOBS=2 run "$s/test_tmpdir.sh" "$s/test_tmpdir_too.sh"
assert_eq 'the TMPDIR suites pass' 0 "$status"
tmpdirs=$(cat "$STATE"/tmpdir-* | sort -u)
assert_eq 'two suites never share a TMPDIR' 2 "$(printf '%s\n' "$tmpdirs" | awk 'NF' | wc -l | tr -d ' ')"
assert_not_contains 'a suite TMPDIR is never the caller TMPDIR' "$TMPDIR"$'\n' "$tmpdirs"$'\n'
leftovers=$(while IFS= read -r dir; do [ ! -e "$dir" ] || printf '%s\n' "$dir"; done <<< "$tmpdirs")
assert_eq 'a suite TMPDIR is removed after the suite' '' "$leftovers"
assert_eq 'the runner leaves nothing in the caller TMPDIR' '' "$(ls -A "$TMPDIR")"

# --- bad input ---------------------------------------------------------------
for jobs in 0 -1 abc 2x 07; do
    CORTADO_TEST_JOBS="$jobs" run "$s/test_pass.sh"
    assert_eq "CORTADO_TEST_JOBS=[$jobs] is refused" 2 "$status"
done
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)
for jobs in unset ''; do
    if [ "$jobs" = unset ]; then
        (unset CORTADO_TEST_JOBS; run "$s/test_pass.sh"; printf '%s' "$output") > "$STATE/jobs-output"
    else
        CORTADO_TEST_JOBS='' run "$s/test_pass.sh"
        printf '%s' "$output" > "$STATE/jobs-output"
    fi
    assert_contains "CORTADO_TEST_JOBS ${jobs:-empty} defaults to the core count" "with $cores jobs" "$(cat "$STATE/jobs-output")"
done
run "$s/test_missing.sh"
assert_eq 'a missing suite is refused' 2 "$status"
assert_contains 'a missing suite is named' 'test_missing.sh' "$output"

# --- the jq suite list --------------------------------------------------------
# A suite depends on how jq parses JSON when it calls jq, uses the JSON
# helpers, loads the payload-reading modules, or feeds a payload field that
# modules read. Such a suite must be listed, or excluded with a reason.
JSON_PATTERN='(^|[^[:alnum:]_-])jq([^[:alnum:]_-]|$)|json_get|payload\.sh|rate-limits\.sh|context\.sh|cost\.sh|model\.sh|context_window|rate_limits|current_dir|"cwd"|[{,]cwd:|total_cost_usd|display_name|output_style|session_id|five_hour|seven_day|spend_limit|claudeAiOauth'

# jq_list_problems <tests dir> <list file>: one line per problem.
jq_list_problems() {
    local dir="$1" list="$2" suite name selected excluded
    selected=" $(CORTADO_JQ_SUITES_FILE="$list" /bin/bash "$VARIANTS" --list apple "$dir"/test_*.sh | tr '\n' ' ')"
    excluded=" $(awk '$1 ~ /^!/ { print substr($1, 2) }' "$list" | tr '\n' ' ')"
    for suite in "$dir"/test_*.sh; do
        name="${suite##*/}"
        case "$selected$excluded" in *" $name "*) continue ;; esac
        if grep -Eq "$JSON_PATTERN" "$suite"; then
            printf 'unlisted JSON suite: %s\n' "$name"
        fi
    done
    awk '$1 !~ /^#/ && NF { name = $1; sub(/^!/, "", name); print name }' "$list" |
        while IFS= read -r name; do
            [ -f "$dir/$name" ] || printf 'listed suite does not exist: %s\n' "$name"
        done
    awk '$1 ~ /^!/ && (NF < 2 || $2 ~ /^#?$/) { print "exclusion without a reason: " substr($1, 2) }' "$list"
}

assert_eq 'every JSON suite is in tests/jq-suites.txt or excluded with a reason' '' \
    "$(jq_list_problems "$PROJECT_ROOT/tests" "$PROJECT_ROOT/tests/jq-suites.txt")"
assert_eq 'the path variant runs every suite' \
    "$(cd "$PROJECT_ROOT/tests" && printf '%s\n' test_*.sh)" \
    "$(/bin/bash "$VARIANTS" --list path)"
assert_contains 'the apple variant runs the payload suite' 'test_payload_parse.sh' \
    "$(/bin/bash "$VARIANTS" --list apple)"
assert_not_contains 'the apple variant skips a suite that never reads JSON' 'test_battery.sh' \
    "$(/bin/bash "$VARIANTS" --list apple)"
assert_eq 'the apple variant keeps only the requested JSON suites' 'test_cost.sh' \
    "$(/bin/bash "$VARIANTS" --list apple "$PROJECT_ROOT/tests/test_cost.sh" "$PROJECT_ROOT/tests/test_battery.sh")"

# The guard itself catches a new suite that uses jq, and stale entries.
guard="$TEST_BASE/guard"
mkdir "$guard"
printf '#!/bin/bash\npayload=$(jq -nc "{}")\n' > "$guard/test_new_json.sh"
printf '#!/bin/bash\necho "{\\"context_window\\":{}}" | cortado\n' > "$guard/test_new_payload.sh"
printf '#!/bin/bash\necho plain\n' > "$guard/test_plain.sh"
: > "$guard/list"
assert_eq 'the guard names a new suite that calls jq or renders a payload' \
    "$(printf 'unlisted JSON suite: %s\n' test_new_json.sh test_new_payload.sh)" \
    "$(jq_list_problems "$guard" "$guard/list")"
printf '%s\n' '# comment' test_new_json.sh '!test_new_payload.sh  only proves a module ignores it' > "$guard/list"
assert_eq 'a listed suite and a reasoned exclusion satisfy the guard' '' "$(jq_list_problems "$guard" "$guard/list")"
assert_eq 'an exclusion never runs on the apple variant' 'test_new_json.sh' \
    "$(CORTADO_JQ_SUITES_FILE="$guard/list" /bin/bash "$VARIANTS" --list apple "$guard"/test_*.sh)"
printf '%s\n' test_new_json.sh '!test_new_payload.sh' test_gone.sh > "$guard/list"
assert_eq 'the guard names an unreasoned exclusion and a stale entry' \
    "$(printf '%s\n' 'listed suite does not exist: test_gone.sh' 'exclusion without a reason: test_new_payload.sh')" \
    "$(jq_list_problems "$guard" "$guard/list")"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
