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

# --- a timed-out suite stops everything it started ---------------------------
# Three children: one that dies on TERM, one that records TERM before it
# exits, and one that ignores TERM, so only a KILL stops it.
fake test_hang_kids.sh \
    'sleep 30 & echo "$!" > "$STATE/kid-plain.pid"' \
    '(trap "" TERM; exec sleep 30) & echo "$!" > "$STATE/kid-deaf.pid"' \
    '(trap "echo term > \"\$STATE/kid-termed\"; exit 0" TERM; while :; do sleep 0.1; done) 2> /dev/null & echo "$!" > "$STATE/kid-polite.pid"' \
    'echo kids-started' \
    'exec sleep 30'
# pids_alive <pid files...>: the recorded pids that are still running.
pids_alive() {
    local file pid
    for file in "$@"; do
        pid=$(cat "$file" 2>/dev/null) || continue
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s ' "${file##*/}"
    done
}
# alive_after <seconds> <pid files...>: what is still running after a grace.
alive_after() {
    local stop=$((SECONDS + $1)) alive
    shift
    while :; do
        alive=$(pids_alive "$@")
        [ -n "$alive" ] && [ "$SECONDS" -lt "$stop" ] || break
        sleep 0.1
    done
    printf '%s' "$alive"
}
# Leave nothing behind even when an assertion above failed.
kill_recorded() {
    local file
    for file in "$@"; do
        [ ! -s "$file" ] || kill -KILL "$(cat "$file")" 2>/dev/null
    done
}
trap 'kill_recorded "$STATE"/kid-*.pid; rm -rf "$TEST_BASE"' EXIT
SUITE_TIMEOUT=1 run "$s/test_hang_kids.sh"
assert_match 'a suite with children that hangs is named on a TIMEOUT line' \
    '^TIMEOUT: test_hang_kids\.sh \(over 1s\)$' "$output"
assert_eq 'no child of a timed-out suite outlives the runner' '' \
    "$(pids_alive "$STATE"/kid-plain.pid "$STATE"/kid-deaf.pid "$STATE"/kid-polite.pid)"
assert_eq 'a timed-out suite gets TERM before KILL' 'term' "$(cat "$STATE/kid-termed" 2>/dev/null)"
assert_eq 'a timed-out suite prints its output and no job notices' \
    "$(printf '%s\n' 'TIMEOUT: test_hang_kids.sh (over 1s)' '' '==== TIMEOUT: test_hang_kids.sh ====' \
        kids-started '==== end test_hang_kids.sh ====' '' \
        'suites: 0 passed, 0 failed, 1 timed out, 0 skipped as flaky, ')" \
    "$(printf '%s\n' "$output" | sed 's/skipped as flaky, .*/skipped as flaky, /')"
kill_recorded "$STATE"/kid-*.pid
rm -f "$STATE"/kid-*

# A worker that dies, or a runner that is interrupted, still stops its suites.
fake test_orphan.sh 'sleep 30 & echo "$!" > "$STATE/kid-orphan.pid"' 'kill -KILL "$PPID"' 'exec sleep 30'
SUITE_TIMEOUT=60 run "$s/test_orphan.sh"
assert_match 'a suite whose worker died is named' '^FAIL: test_orphan\.sh \(no result recorded\)$' "$output"
assert_eq 'a suite whose worker died is stopped' '' "$(alive_after 5 "$STATE/kid-orphan.pid")"
kill_recorded "$STATE/kid-orphan.pid"

# Ctrl-C sends INT to the runner's process group; a cancelled job sends TERM.
# The suites lead their own groups, so neither reaches them directly.
fake test_interrupted.sh 'sleep 30 & echo "$!" > "$STATE/kid-interrupted.pid"' 'exec sleep 30'
for signal in INT TERM; do
    rm -f "$STATE/kid-interrupted.pid"
    (
        set -m
        SUITE_TIMEOUT=60 /bin/bash "$RUNNER" "$s/test_interrupted.sh" > /dev/null 2>&1 &
        runner_group=$!
        for ((i = 0; i < 100; i++)); do
            [ ! -s "$STATE/kid-interrupted.pid" ] || break
            sleep 0.05
        done
        kill "-$signal" -- "-$runner_group" 2>/dev/null
        wait "$runner_group" 2>/dev/null
        :
    )
    assert_eq "a runner stopped with $signal stops the suites it started" '' \
        "$(alive_after 5 "$STATE/kid-interrupted.pid")"
    kill_recorded "$STATE/kid-interrupted.pid"
done

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
# helpers, loads the payload-reading modules, feeds a payload field that
# modules read, or holds any JSON object literal ({"key" or {\"key\"), since
# modules/payload.sh parses more fields than this pattern names. Such a suite
# must be listed, or excluded with a reason.
JSON_PATTERN='(^|[^[:alnum:]_-])jq([^[:alnum:]_-]|$)|json_get|payload\.sh|rate-limits\.sh|context\.sh|cost\.sh|model\.sh|context_window|rate_limits|current_dir|"cwd"|[{,]cwd:|total_cost_usd|display_name|output_style|session_id|five_hour|seven_day|spend_limit|claudeAiOauth|\{\\?"[A-Za-z_]+\\?"'

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

# Any JSON object literal counts, so a payload field the pattern never names
# (effort, thinking, total_duration_ms, ...) still needs a listing.
literal="$TEST_BASE/guard-literal"
mkdir "$literal"
printf '%s\n' '#!/bin/bash' "render normal '{\"effort\":{\"level\":\"high\"}}'" > "$literal/test_new_effort.sh"
printf '%s\n' '#!/bin/bash' "render verbose '{\"thinking\":{\"enabled\":true},\"cost\":{\"total_duration_ms\":5}}'" \
    > "$literal/test_new_thinking.sh"
printf '%s\n' '#!/bin/bash' 'echo "{\"effort\":{}}" | cortado' > "$literal/test_new_escaped.sh"
printf '%s\n' '#!/bin/bash' 'echo "{ plain braces }"' > "$literal/test_plain_braces.sh"
: > "$literal/list"
assert_eq 'the guard names a new suite that renders any JSON object' \
    "$(printf 'unlisted JSON suite: %s\n' test_new_effort.sh test_new_escaped.sh test_new_thinking.sh)" \
    "$(jq_list_problems "$literal" "$literal/list")"

# run-jq-variants refuses a missing suite in every mode, before any filtering.
for args in '--variant apple' '--variant path' '--list apple' '--list path'; do
    status=0
    # shellcheck disable=SC2086 # $args is two words on purpose.
    output=$(/bin/bash "$VARIANTS" $args "$TEST_BASE/test_no_such_suite.sh" 2>&1) || status=$?
    assert_eq "run-jq-variants $args refuses a missing suite" 2 "$status"
    assert_contains "run-jq-variants $args names the missing suite" \
        "no such suite: $TEST_BASE/test_no_such_suite.sh" "$output"
done

# --- the flaky quarantine (tests/flaky.txt) ---------------------------------
# flaky_problems <tests dir> <list file> <workflow file>: one line per entry
# that names no suite, no section of its suite, or no CI check.
flaky_problems() {
    local dir="$1" list="$2" workflow="$3" entry suite section
    awk '$1 !~ /^#/ && NF { print $1 }' "$list" | while IFS= read -r entry; do
        case "$entry" in
            ci:*)
                grep -Fq "$entry" "$workflow" ||
                    printf 'quarantined CI check is not in the workflow: %s\n' "$entry" ;;
            *:*)
                suite="${entry%%:*}" section="${entry#*:}"
                if [ ! -f "$dir/$suite" ]; then
                    printf 'quarantined suite does not exist: %s\n' "$entry"
                elif ! grep -Eq "(section_is |\"\\\$section\" = )$section([^A-Za-z0-9_-]|\$)" "$dir/$suite"; then
                    printf 'quarantined section does not exist: %s\n' "$entry"
                fi ;;
            *)
                [ -f "$dir/$entry" ] || printf 'quarantined suite does not exist: %s\n' "$entry" ;;
        esac
    done
}

assert_eq 'every tests/flaky.txt entry names a suite, section or CI check that exists' '' \
    "$(flaky_problems "$PROJECT_ROOT/tests" "$PROJECT_ROOT/tests/flaky.txt" "$PROJECT_ROOT/.github/workflows/ci.yml")"

flaky="$TEST_BASE/flaky"
mkdir "$flaky"
printf '#!/bin/bash\nif section_is alpha; then :; fi\n' > "$flaky/test_sectioned.sh"
printf '#!/bin/bash\nif [[ "$section" = all || "$section" = beta ]]; then :; fi\n' > "$flaky/test_own.sh"
printf '%s\n' 'run: echo ci:real-check' > "$flaky/ci.yml"
printf '%s\n' '# comment' 'test_sectioned.sh:alpha  2026-01-01  run 1  symptom' \
    'test_own.sh:beta  2026-01-01  run 2  symptom' 'test_own.sh  2026-01-01  run 3  symptom' \
    'ci:real-check  2026-01-01  run 4  symptom' > "$flaky/list"
assert_eq 'live suites, sections and CI checks satisfy the stale-entry guard' '' \
    "$(flaky_problems "$flaky" "$flaky/list" "$flaky/ci.yml")"
printf '%s\n' 'test_gone.sh  d  e  s' 'test_sectioned.sh:gamma  d  e  s' 'test_gone.sh:alpha  d  e  s' \
    'ci:gone-check  d  e  s' 'test_sectioned.sh:alph  d  e  s' > "$flaky/list"
assert_eq 'the guard names each stale suite, section and CI entry' \
    "$(printf '%s\n' 'quarantined suite does not exist: test_gone.sh' \
        'quarantined section does not exist: test_sectioned.sh:gamma' \
        'quarantined suite does not exist: test_gone.sh:alpha' \
        'quarantined CI check is not in the workflow: ci:gone-check' \
        'quarantined section does not exist: test_sectioned.sh:alph')" \
    "$(flaky_problems "$flaky" "$flaky/list" "$flaky/ci.yml")"

# The runner skips a quarantined suite, and runs it with CORTADO_RUN_FLAKY=1.
fake test_flaky.sh ': > "$STATE/flaky-ran"' 'exit 1'
printf '%s\n' 'test_flaky.sh  2026-01-01  run 1  fails sometimes' > "$flaky/runner-list"
CORTADO_FLAKY_FILE="$flaky/runner-list" run "$s/test_pass.sh" "$s/test_flaky.sh"
assert_eq 'a quarantined failing suite does not fail the run' 0 "$status"
assert_match 'a quarantined suite prints a SKIP line' '^SKIP \(flaky\): test_flaky\.sh$' "$output"
assert_eq 'a quarantined suite never runs' no "$([ -e "$STATE/flaky-ran" ] && echo yes || echo no)"
assert_contains 'the summary counts skipped suites' 'suites: 1 passed, 0 failed, 0 timed out, 1 skipped as flaky' "$output"
CORTADO_FLAKY_FILE="$flaky/runner-list" run "$s/test_flaky.sh"
assert_eq 'a run with every suite quarantined passes' 0 "$status"
assert_contains 'a run with every suite quarantined starts none' 'suites: 0 passed, 0 failed, 0 timed out, 1 skipped' "$output"
CORTADO_RUN_FLAKY=1 CORTADO_FLAKY_FILE="$flaky/runner-list" run "$s/test_flaky.sh"
assert_eq 'CORTADO_RUN_FLAKY=1 runs a quarantined suite' 1 "$status"
assert_match 'CORTADO_RUN_FLAKY=1 reports the quarantined suite' '^FAIL: test_flaky\.sh ' "$output"

# tests/lib/sections.sh skips a quarantined section without failing its guard.
cat > "$flaky/test_split.sh" <<SUITE
#!/bin/bash
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
. "$PROJECT_ROOT/tests/lib/sections.sh"
section="\${SPLIT_SECTION:-all}"
if [ "\$section" = all ]; then
    run_sections SPLIT_SECTION 2 "\${BASH_SOURCE[0]}" steady shaky
fi
if section_is steady; then pass 'steady holds'; fi
if section_is shaky; then : > "\$STATE/shaky-ran"; fail 'shaky breaks'; fi
section_results
SUITE
printf '%s\n' 'test_split.sh:shaky  2026-01-01  run 1  fails sometimes' > "$flaky/section-list"
status=0
output=$(CORTADO_FLAKY_FILE="$flaky/section-list" /bin/bash "$flaky/test_split.sh" 2>&1) || status=$?
assert_eq 'a quarantined failing section does not fail its suite' 0 "$status"
assert_match 'a quarantined section prints a SKIP line' '^SKIP \(flaky\): test_split\.sh:shaky$' "$output"
assert_eq 'a quarantined section never runs' no "$([ -e "$STATE/shaky-ran" ] && echo yes || echo no)"
assert_contains 'the other sections still run' 'PASS: steady holds' "$output"
status=0
output=$(CORTADO_RUN_FLAKY=1 CORTADO_FLAKY_FILE="$flaky/section-list" /bin/bash "$flaky/test_split.sh" 2>&1) || status=$?
assert_eq 'CORTADO_RUN_FLAKY=1 runs a quarantined section' 1 "$status"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
