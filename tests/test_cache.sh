#!/bin/bash
# ABOUTME: Tests for the file-cache helpers (init_cache/cache_set/cache_get/cache_clear) in modules/utils.sh
# ABOUTME: Run with: bash tests/test_cache.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/tests/lib/assert.sh" indented

TEST_BASE="$(mktemp -d "${TMPDIR:-/tmp}/cortado-cache-test.XXXXXX")" || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
export TMPDIR="$TEST_BASE/tmp"
mkdir "$TMPDIR"
CLAUDE_CONFIG_DIR="$TEST_BASE"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/modules/utils.sh"
CACHE_DIR="$TEST_BASE/cache"

# init_cache creates an owner-only directory -- cache keys (weather, wan_ip, update_check…)
# must not leak config state to other local users under a permissive umask.
init_cache
assert_eq "init_cache creates the cache dir"           "1"          "$([ -d "$CACHE_DIR" ] && echo 1 || echo 0)"
assert_eq "init_cache restricts the dir to the owner"  "drwx------" "$(ls -ld "$CACHE_DIR" | cut -c1-10)"

# cache_set / cache_get round-trip a value
cache_set "weather" "sunny"
assert_eq "cache_set/cache_get round-trips a value"    "sunny"      "$(cache_get weather)"
assert_eq "a fresh entry is returned within max_age"   "sunny"      "$(cache_get weather 60)"

# an entry older than max_age is a miss (backdate the file well past any TTL)
cache_set "wan_ip" "1.2.3.4"
touch -t 200001010000 "$CACHE_DIR/wan_ip"
assert_eq "an expired entry reads as empty"            ""           "$(cache_get wan_ip 60)"
cache_get wan_ip 60 >/dev/null 2>&1
assert_eq "an expired entry returns non-zero"          "1"          "$?"

# cache_get derives freshness from the file mtime via the shared portable-stat
# helper: a just-written entry must hit, and the same entry must miss once it
# is older than max_age.
cache_set "ttl_probe" "fresh"
assert_eq "a just-written entry is a hit"               "fresh"      "$(cache_get ttl_probe 120)"
touch -t 200001010000 "$CACHE_DIR/ttl_probe"
assert_eq "the same entry is a miss once expired"       ""           "$(cache_get ttl_probe 120)"

# a missing key is a miss
assert_eq "a missing key reads as empty"               ""           "$(cache_get nope)"
cache_get nope >/dev/null 2>&1
assert_eq "a missing key returns non-zero"             "1"          "$?"

# path-traversal keys are rejected -- and must write nothing outside the cache dir
cache_set "../escape" "pwned"
assert_eq "cache_set rejects a traversal key"          "1"          "$?"
assert_eq "cache_set writes no file outside the cache" "1"          "$([ ! -e "$CACHE_DIR/../escape" ] && echo 1 || echo 0)"
cache_get "../escape" >/dev/null 2>&1
assert_eq "cache_get rejects a '..' key"               "1"          "$?"
# A key containing a single "/" but no ".." is a legitimate flat-file name
# inside CACHE_DIR; the guard must NOT reject it.  The call still returns
# 1 because the sub-directory does not exist (file-not-found), but it is
# not rejected by the path-traversal guard.
cache_set "sub/key" "value"
assert_eq "cache_set accepts a key with a slash"       "0"          "$?"
assert_eq "cache_get returns the value for a slash key" "value"     "$(cache_get sub/key)"

echo "=== cache publication respects the caller's shell settings ==="
(
    prior_failures="$FAIL"
    set -C
    cache_set noclobber new
    assert_eq "noclobber allows publishing a fresh entry" 0 "$?"
    assert_eq "the new entry is readable with noclobber enabled" new "$(cache_get noclobber)"
    assert_eq "the caller still has noclobber enabled" yes "$([[ "$-" == *C* ]] && echo yes)"
    [ "$FAIL" -eq "$prior_failures" ]
)
assert_eq "noclobber checks passed" 0 "$?"

cache_set restrictive old
(
    prior_failures="$FAIL"
    umask 0277
    cache_set restrictive new
    assert_eq "a restrictive caller umask allows refreshing an entry" 0 "$?"
    assert_eq "the restrictive caller reads the replacement" new "$(cache_get restrictive)"
    assert_eq "the replacement remains owner-only" '-rw-------' "$(ls -ld "$CACHE_DIR/restrictive" | cut -c1-10)"
    assert_eq "the caller retains its restrictive umask" 0277 "$(umask)"
    [ "$FAIL" -eq "$prior_failures" ]
)
assert_eq "restrictive umask checks passed" 0 "$?"

echo "=== overlapping writes use distinct private siblings of the destination ==="
wait_for_cache_file() {
    local i=0
    while [ ! -f "$1" ] && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    [ -f "$1" ]
}

staged_cache_set() {
    local writer="$1" value="$2"
    # Check before the write command returns, so a later chmod can't hide a
    # staging file that was readable by others during the write.
    # shellcheck disable=SC2329
    printf() {
        local path
        builtin printf "$@"
        for path in "$CACHE_DIR"/nested/*; do
            if [ -f "$path" ] && [ "$(cat "$path")" = "$value" ]; then
                ls -ld "$path" | cut -c1-10 > "$TEST_BASE/$writer.write-mode"
                break
            fi
        done
    }
    # shellcheck disable=SC2329
    mv() {
        local args=("$@") staging
        staging="${args[${#args[@]}-2]}"
        builtin printf '%s\n' "$staging" > "$TEST_BASE/$writer.path"
        : > "$TEST_BASE/$writer.ready"
        wait_for_cache_file "$TEST_BASE/$writer.release" || return 1
        command mv "$@"
    }
    umask 000
    cache_set nested/key "$value"
}

cache_set nested/key original
staged_cache_set first first &
first_pid=$!
staged_cache_set second second &
second_pid=$!
for writer in first second; do
    wait_for_cache_file "$TEST_BASE/$writer.ready"
    assert_eq "$writer reached atomic publication" 0 "$?"
    staging=$(cat "$TEST_BASE/$writer.path" 2>/dev/null)
    assert_eq "$writer staged in the nested destination directory" "$CACHE_DIR/nested" "${staging%/*}"
    assert_eq "$writer's staging file is owner-only during the write" '-rw-------' "$(cat "$TEST_BASE/$writer.write-mode" 2>/dev/null)"
    assert_eq "$writer's staging file is already owner-only" '-rw-------' "$(ls -ld "$staging" 2>/dev/null | cut -c1-10)"
done
first_staging=$(cat "$TEST_BASE/first.path" 2>/dev/null)
second_staging=$(cat "$TEST_BASE/second.path" 2>/dev/null)
assert_eq "the two staging paths differ" yes "$([ "$first_staging" != "$second_staging" ] && echo yes)"
assert_eq "the old value is still readable before either rename" original "$(cache_get nested/key)"
: > "$TEST_BASE/first.release"
wait "$first_pid"
assert_eq "the first write completes" 0 "$?"
assert_eq "the first write publishes its value" first "$(cache_get nested/key)"
assert_eq "the first writer leaves the second's staging file intact" second "$(cat "$second_staging" 2>/dev/null)"
: > "$TEST_BASE/second.release"
wait "$second_pid"
assert_eq "the second write completes" 0 "$?"
assert_eq "the second write publishes its value" second "$(cache_get nested/key)"

cache_set literal -n
assert_eq "a value of -n round-trips literally" -n "$(cache_get literal)"

echo "=== interrupted or failed cache writes keep the previous entry ==="
cache_set atomic original
{ (
    # The pre-fix writer uses echo. The staged writer uses printf.
    # shellcheck disable=SC2329
    interrupt_write() {
        builtin printf '%s' partial
        : > "$TEST_BASE/writing"
        /bin/sh -c 'kill -KILL "$PPID"'
        return 1
    }
    # shellcheck disable=SC2329
    echo() { interrupt_write; }
    # shellcheck disable=SC2329
    printf() { interrupt_write; }
    cache_set atomic replacement
); } 2>/dev/null
assert_eq "the writer was interrupted after emitting bytes" "yes" "$([ -f "$TEST_BASE/writing" ] && echo yes)"
assert_eq "a killed writer leaves the previous cache entry readable" "original" "$(cache_get atomic)"

# Remove the temp left by the uncatchable signal before testing cleanup.
for staging in "$CACHE_DIR"/atomic.*; do
    [ -f "$staging" ] && rm -f "$staging"
done
(
    trap ': > "$TEST_BASE/caller-exit"' EXIT
    trap ': > "$TEST_BASE/caller-term"' TERM
    # shellcheck disable=SC2329
    printf() {
        builtin printf '%s' partial
        : > "$TEST_BASE/term-writing"
        /bin/sh -c 'kill -TERM "$PPID"'
        return 1
    }
    cache_set atomic replacement
    write_status=$?
    /bin/sh -c 'kill -TERM "$PPID"'
    exit "$write_status"
) 2>/dev/null
cancel_status=$?
assert_eq "the TERM-cancelled write returns nonzero" yes "$([ "$cancel_status" -ne 0 ] && echo yes)"
assert_eq "TERM reached the writer after it emitted bytes" yes "$([ -f "$TEST_BASE/term-writing" ] && echo yes)"
assert_eq "TERM leaves the previous cache entry readable" original "$(cache_get atomic)"
assert_eq "TERM cleans the writer's staging file" '' "$(find "$CACHE_DIR" -name 'atomic.*' -print)"
assert_eq "TERM cancellation preserves the caller's EXIT trap" yes "$([ -f "$TEST_BASE/caller-exit" ] && echo yes)"
assert_eq "TERM cancellation preserves the caller's TERM trap" yes "$([ -f "$TEST_BASE/caller-term" ] && echo yes)"
cache_set atomic retry
assert_eq "cache publication succeeds after cancellation" 0 "$?"
assert_eq "the retry is readable after cancellation" retry "$(cache_get atomic)"

cache_set atomic original
for fault in mktemp write mv; do
    (
        # These stubs are invoked through the sourced cache helpers.
        # shellcheck disable=SC2329
        fail_write() { builtin printf '%s' partial; return 1; }
        # shellcheck disable=SC2329
        case "$fault" in
            mktemp) mktemp() { builtin printf '%s\n' "$CACHE_DIR/atomic.failed"; return 1; } ;;
            write) echo() { fail_write; }; printf() { fail_write; } ;;
            mv) mv() { return 1; } ;;
        esac
        cache_set atomic replacement
    )
    assert_eq "$fault failure is reported" "1" "$?"
    assert_eq "$fault failure keeps the previous entry" "original" "$(cache_get atomic)"
    assert_eq "$fault failure leaves no staging file" "" "$(find "$CACHE_DIR" -name 'atomic.*' -print)"
done

(
    umask 000
    cache_set private replacement
)
assert_eq "a replacement cache file is owner-only" "-rw-------" "$(ls -ld "$CACHE_DIR/private" | cut -c1-10)"

mkdir "$CACHE_DIR/directory"
chmod 700 "$CACHE_DIR/directory"
cache_set directory replacement 2>/dev/null
assert_eq "a directory at the cache destination rejects the write" "1" "$?"
assert_eq "a directory destination keeps its mode" "drwx------" "$(ls -ld "$CACHE_DIR/directory" | cut -c1-10)"
chmod 700 "$CACHE_DIR/directory"
assert_eq "a directory destination acquires no staged entry" "" "$(ls -A "$CACHE_DIR/directory")"

# cache_clear removes a single named key
cache_set "update_check" "v1"
cache_clear "update_check"
assert_eq "cache_clear removes the named key"          ""           "$(cache_get update_check 999)"

# cache_clear never removes a lock by name: locks outlive every clear
cache_set "foo" "v1"
: > "$CACHE_DIR/foo-lock"
cache_clear "foo-lock"
assert_eq "cache_clear refuses a lock key"             "1"          "$?"
assert_eq "a refused lock key keeps its file"          "1"          "$([ -f "$CACHE_DIR/foo-lock" ] && echo 1 || echo 0)"

# cache_clear refuses to operate on an empty CACHE_DIR (never rm an unset path)
( CACHE_DIR=""; cache_clear )
assert_eq "cache_clear refuses an empty CACHE_DIR"     "1"          "$?"

# cache_clear refuses a symlinked or shared cache directory and leaves it intact
mkdir -m 700 "$TEST_BASE/outside"
printf 'keep\n' > "$TEST_BASE/outside/keep"
ln -s "$TEST_BASE/outside" "$TEST_BASE/linked"
mkdir -m 755 "$TEST_BASE/shared"
printf 'keep\n' > "$TEST_BASE/shared/keep"
for dir in linked shared; do
    CACHE_DIR="$TEST_BASE/$dir" cache_clear
    assert_eq "cache_clear refuses a $dir cache dir"     "1"          "$?"
    CACHE_DIR="$TEST_BASE/$dir" cache_clear keep
    assert_eq "cache_clear refuses a key in a $dir cache dir" "1"     "$?"
    assert_eq "a refused $dir cache dir keeps its entry" "keep"       "$(cat "$TEST_BASE/$dir/keep" 2>/dev/null)"
done
assert_eq "a refused shared cache dir keeps its mode"   "drwxr-xr-x" "$(ls -ld "$TEST_BASE/shared" | cut -c1-10)"

rm -rf "$TEST_BASE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
