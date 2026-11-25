#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain-comma

out=$(/bin/bash "$PROJECT_ROOT/tests/render_timing.sh" 3 2>&1)
assert_eq "three default renders complete successfully" 0 "$?"
if printf '%s\n' "$out" | awk '
    /^Default render \(n=3\): p50=[0-9]+\.[0-9][0-9][0-9]s p95=[0-9]+\.[0-9][0-9][0-9]s$/ {
        split($4, median, "=")
        split($5, tail, "=")
        valid = (median[2] + 0 <= tail[2] + 0)
    }
    END { exit !valid }
'; then
    reported=yes
else
    reported=no
fi
assert_eq "the timing report includes ordered p50 and p95 in seconds" yes "$reported"

out=$(/bin/bash "$PROJECT_ROOT/tests/render_timing.sh" 0 2>&1)
assert_eq "a zero sample count exits with a usage error" 2 "$?"
assert_eq "the usage error explains the sample count" \
    'Usage: render_timing.sh [sample-count (1-999)]' "$out"

stub_bin=$(mktemp -d) || exit 1
trap 'rm -rf "$stub_bin"' EXIT
printf '%s\n' '#!/bin/bash' 'exit 1' > "$stub_bin/jq"
chmod +x "$stub_bin/jq"
out=$(PATH="$stub_bin:$PATH" /bin/bash "$PROJECT_ROOT/tests/render_timing.sh" 1 2>&1)
assert_eq "a render with a failing jq exits without percentiles" 1 "$?"
assert_contains "the timing report identifies the failed render" 'Default render 1 failed' "$out"
assert_not_contains "a failed render has no p50" 'p50=' "$out"

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
