#!/bin/bash
# ABOUTME: Tests for the file-cache helpers (init_cache/cache_set/cache_get/cache_clear) in modules/utils.sh
# ABOUTME: Run with: bash tests/test_cache.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

TEST_BASE="$(mktemp -d "${TMPDIR:-/tmp}/cortado-cache-test.XXXXXX")"
trap 'rm -rf "$TEST_BASE"' EXIT
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

# cache_clear refuses to operate on an empty CACHE_DIR (never rm an unset path)
( CACHE_DIR=""; cache_clear )
assert_eq "cache_clear refuses an empty CACHE_DIR"     "1"          "$?"

rm -rf "$TEST_BASE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
