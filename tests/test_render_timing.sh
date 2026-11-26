#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain-comma

fixture=$(mktemp -d) || exit 1
trap 'rm -rf "$fixture"' EXIT
timing_script="$PROJECT_ROOT/tests/render_timing.sh"

# shellcheck source=tests/render_timing.sh
. "$timing_script"

printf '0.%03d\n' {20..1} > "$fixture/samples"
printf '%s\n' 'Default render (n=20): p50=0.010s p95=0.019s' > "$fixture/expected"
report_percentiles 20 "$fixture/samples" > "$fixture/report" 2>&1
assert_eq "the percentile calculation accepts twenty reversed samples" 0 "$?"
if cmp -s "$fixture/expected" "$fixture/report"; then
    pass "the timing report contains exactly the expected p50 and p95 line"
else
    fail "the timing report contains exactly the expected p50 and p95 line"
    cat "$fixture/report"
fi

printf '%s\n' 0.150 > "$fixture/samples"
out=$(report_percentiles 1 "$fixture/samples" 150 2>&1)
assert_eq "the p95 gate accepts exactly 150 ms" 0 "$?"
printf '%s\n' 0.151 > "$fixture/samples"
out=$(report_percentiles 1 "$fixture/samples" 150 2>&1)
assert_eq "the p95 gate blocks at 151 ms" 1 "$?"
assert_contains "the p95 gate reports the exceeded limit" 'p95 exceeds 150 ms' "$out"

printf '%s\n' 0.251 > "$fixture/samples"
out=$(report_percentiles 1 "$fixture/samples" 250 'Stalled weather render' 2>&1)
assert_eq "a labelled series uses the same p95 gate" 1 "$?"
assert_contains "a labelled series names itself in its report" \
    'Stalled weather render (n=1): p50=0.251s p95=0.251s' "$out"
assert_contains "a labelled series names itself in its gate" 'Stalled weather render p95 exceeds 250 ms' "$out"

printf '%s\n' '0.020' 'bad reading' > "$fixture/samples"
out=$(report_percentiles 2 "$fixture/samples" 2>&1)
assert_eq "a malformed measurement fails the report" 1 "$?"
assert_eq "a malformed measurement produces only an error" 'Could not measure every default render' "$out"

out=$(/bin/bash "$timing_script" 0 2>&1)
assert_eq "a zero sample count exits with a usage error" 2 "$?"
assert_eq "the usage error explains the sample count" \
    'Usage: render_timing.sh [sample-count (1-999)] [base-tree]' "$out"

mkdir "$fixture/tests" || exit 1
cp "$timing_script" "$fixture/tests/" || exit 1
printf '%s\n' '#!/bin/bash' 'echo "synthetic render failure" >&2' 'exit 1' > "$fixture/cortado.sh"
out=$(/bin/bash "$fixture/tests/render_timing.sh" 1 2>&1)
assert_eq "a failed stub render exits without percentiles" 1 "$?"
assert_contains "the timing report identifies the failed render" 'Default render 1 failed' "$out"
assert_not_contains "a failed render has no p50" 'p50=' "$out"

# The warm all-modules timing is informational: a slow first Node start is
# waited for, and a Node that never publishes is reported, not fatal.
warm_script="$PROJECT_ROOT/tests/all_modules_timing.sh"
mkdir "$fixture/slow-node" "$fixture/broken-node" || exit 1
printf '%s\n' '#!/bin/bash' 'sleep 4' 'echo v20.11.1' > "$fixture/slow-node/node"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$fixture/broken-node/node"
chmod 700 "$fixture/slow-node/node" "$fixture/broken-node/node"
out=$(PATH="$fixture/slow-node:$PATH" CORTADO_ALL_MODULES_SAMPLES=2 /bin/bash "$warm_script" 2>&1)
assert_eq "the warm timing waits for a Node that takes 4 s to start" 0 "$?"
assert_not_contains "a slow Node still publishes its version" 'Node did not publish' "$out"
assert_contains "the warm timing reports its series after a slow Node" 'Warm all-modules render (n=2)' "$out"
out=$(PATH="$fixture/broken-node:$PATH" CORTADO_ALL_MODULES_SAMPLES=2 NODE_WAIT_SECONDS=3 /bin/bash "$warm_script" 2>&1)
assert_eq "a Node that never publishes does not fail the warm timing" 0 "$?"
assert_contains "a Node that never publishes is reported" 'Node did not publish its version' "$out"
assert_contains "the warm timing still reports its series without Node" 'Warm all-modules render (n=2)' "$out"

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
