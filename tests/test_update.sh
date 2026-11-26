#!/bin/bash
# ABOUTME: Tests for update-check rendering, cache lifetimes, and numeric version comparison.
# ABOUTME: Run with: bash tests/test_update.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/tests/lib/assert.sh" indented

# Load the module under test. version_lt is pure and performs no external I/O.
. "$SCRIPT_DIR/modules/update.sh"

# version_lt <v2> <v1> -> rc 0 when v1 > v2, rc 1 otherwise.
assert_gt() {
    local desc="$1" v1="$2" v2="$3" expected_rc="$4"
    version_lt "$v2" "$v1"
    assert_eq "$desc" "$expected_rc" "$?"
}

# Major precedence
assert_gt "major: 2.0.0 > 1.9.9"                 "2.0.0"  "1.9.9"  "0"
assert_gt "major: 1.0.0 is not > 2.0.0"          "1.0.0"  "2.0.0"  "1"
# Minor compared NUMERICALLY (a string compare would rank 1.10.0 below 1.9.0 and fail these)
assert_gt "minor numeric: 1.10.0 > 1.9.0"        "1.10.0" "1.9.0"  "0"
assert_gt "minor numeric: 1.9.0 is not > 1.10.0" "1.9.0"  "1.10.0" "1"
# Patch precedence, also numeric
assert_gt "patch: 1.7.1 > 1.7.0"                 "1.7.1"  "1.7.0"  "0"
assert_gt "patch numeric: 1.0.10 > 1.0.9"        "1.0.10" "1.0.9"  "0"
assert_gt "patch: 1.7.0 is not > 1.7.1"          "1.7.0"  "1.7.1"  "1"
# Equal versions are NOT greater (so the update prompt does not fire on an equal remote)
assert_gt "equal is not greater: 1.7.0 vs 1.7.0" "1.7.0"  "1.7.0"  "1"
# Prerelease/build suffixes must never reach Bash's arithmetic parser. The
# comparator intentionally compares only the numeric major/minor/patch tuple.
assert_gt "prerelease patch compares safely above older release" "1.8.0-rc1" "1.7.9" "0"
assert_gt "prerelease suffix is equal to its numeric release"     "1.8.0-rc1" "1.8.0" "1"
assert_gt "build metadata does not change numeric precedence"     "2.1.3+45"  "2.1.3" "1"
assert_gt "nonnumeric patch is treated as zero"                   "1.8.x"     "1.7.9" "0"

# The module finds lib/semver.sh however it is named when sourced, including
# by its bare filename from its own directory.
for source_name in update.sh ./update.sh "$SCRIPT_DIR/modules/update.sh"; do
    sourced=$(cd "$SCRIPT_DIR/modules" && PATH=/usr/bin:/bin /bin/bash -c '. "$1" && type -t version_lt' _ "$source_name" 2>&1)
    assert_eq "sourcing update.sh as $source_name from modules/ defines version_lt" function "$sourced"
done

# --- Render through cortado.sh using a stubbed release API ---
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/bin/bash
printf 'call\n' >> "$RELEASE_CALL_LOG"
printf '%s\n%s\n' "$RELEASE_BODY" "$RELEASE_HTTP"
exit "$RELEASE_CURL_STATUS"
STUB
chmod +x "$TEST_DIR/bin/curl"

render_update() {
    local http="$1" body="$2" curl_status="${3:-0}"
    render_output=$(printf '%s\n' "$payload" |
        CLAUDE_CONFIG_DIR="$sandbox" CACHE_DIR="$cache_dir" PATH="$TEST_DIR/bin:$PATH" \
        RELEASE_CALL_LOG="$call_log" \
        RELEASE_HTTP="$http" RELEASE_BODY="$body" RELEASE_CURL_STATUS="$curl_status" \
        /bin/bash "$SCRIPT_DIR/cortado.sh")
}

new_sandbox() {
    sandbox=$(mktemp -d "$TEST_DIR/config.XXXXXX")
    payload=$(jq -n --arg dir "$sandbox" '{workspace:{current_dir:$dir},model:{display_name:"Fixture"}}')
    cache_dir="$sandbox/cortado-cache"
    cache_file="$cache_dir/update_check"
    call_log="$sandbox/curl-calls"
    : > "$call_log"
    printf '%s\n' 'MODULE_ORDER="model,update"' 'MODULE_MODEL="true"' 'MODULE_UPDATE="true"' \
        'COLOR_THEME="monochrome"' > "$sandbox/cortado.conf"
    chmod 600 "$sandbox/cortado.conf"
}

release_calls() {
    awk 'END {print NR}' "$call_log"
}

assert_unavailable() {
    local desc="$1"
    shift
    new_sandbox
    render_update "$@"
    assert_eq "$desc renders an unavailable reading" 'MODEL: Fixture | UPD: --' "$render_output"
    assert_eq "$desc caches an unknown result" 'unknown' "$(cat "$cache_file" 2>/dev/null)"
}

installed_version=$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")
installed_release="{\"tag_name\":\"v$installed_version\"}"
assert_unavailable "HTTP 404" 404 '{"message":"Not Found"}'
assert_unavailable "HTTP 404 carrying the installed tag" 404 "$installed_release"
assert_unavailable "an empty body" 200 ''
assert_unavailable "a missing tag" 200 '{}'
assert_unavailable "a null tag" 200 '{"tag_name":null}'
assert_unavailable "a zero tag" 200 '{"tag_name":0}'
assert_unavailable "malformed JSON" 200 '{"tag_name":"v9.9.9"'
assert_unavailable "two JSON documents" 200 "{} $installed_release"
assert_unavailable "an escaped trailing newline in the tag" 200 "{\"tag_name\":\"v$installed_version\\n\"}"
assert_unavailable "an invalid release tag" 200 '{"tag_name":"v9.9.9invalid"}'
assert_unavailable "a failed curl" 000 '' 28
assert_unavailable "a failed curl with partial output" 200 '{"tag_name":"v9.9.9"}' 28

two_hours_ago=$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S)
thirty_minutes_ago=$(date -v-30M +%Y%m%d%H%M.%S 2>/dev/null || date -d '30 minutes ago' +%Y%m%d%H%M.%S)
new_release='{"tag_name":"v9.9.9"}'
new_notice='MODEL: Fixture | UPD: v9.9.9'

new_sandbox
render_update 404 '{"message":"Not Found"}'
touch -t "$thirty_minutes_ago" "$cache_file"
render_update 200 "$new_release"
assert_eq "a thirty-minute-old failure keeps its unavailable reading" 'MODEL: Fixture | UPD: --' "$render_output"
touch -t "$two_hours_ago" "$cache_file"
render_update 200 "$new_release"
assert_eq "a two-hour-old failure retries and shows the newer release" "$new_notice" "$render_output"
assert_eq "a newer release replaces the failed result in cache" 'available:9.9.9' \
    "$(cat "$cache_file" 2>/dev/null)"
touch -t "$two_hours_ago" "$cache_file"
render_update 404 '{"message":"Not Found"}'
assert_eq "a successful newer notice stays cached after two hours" "$new_notice" "$render_output"

new_sandbox
render_update 200 "$installed_release"
assert_eq "a successful current check has no update notice" 'MODEL: Fixture' "$render_output"
assert_eq "a successful current check has its own cache result" 'checked-current' \
    "$(cat "$cache_file" 2>/dev/null)"
touch -t "$two_hours_ago" "$cache_file"
render_update 200 "$new_release"
assert_eq "a successful current result stays cached after two hours" 'MODEL: Fixture' "$render_output"

new_sandbox
printf '%s\n' 'UPDATE_CHECK_INTERVAL=60' >> "$sandbox/cortado.conf"
render_update 404 '{"message":"Not Found"}'
touch -t "$thirty_minutes_ago" "$cache_file"
render_update 200 "$new_release"
assert_eq "a custom shorter interval also allows retrying the failed check" "$new_notice" "$render_output"

twenty_nine_minutes_ago=$(date -v-29M +%Y%m%d%H%M.%S 2>/dev/null || date -d '29 minutes ago' +%Y%m%d%H%M.%S)
new_sandbox
printf '%s\n' 'UPDATE_CHECK_INTERVAL=1800' >> "$sandbox/cortado.conf"
render_update 404 '{"message":"Not Found"}'
touch -t "$twenty_nine_minutes_ago" "$cache_file"
render_update 200 "$new_release"
assert_eq "a 29-minute-old failure retries with a 30-minute interval" '2' "$(release_calls)"
assert_eq "the retry shows the newly available release" "$new_notice" "$render_output"

new_sandbox
printf '%s\n' 'UPDATE_CHECK_INTERVAL=1800' >> "$sandbox/cortado.conf"
render_update 200 "$installed_release"
touch -t "$twenty_nine_minutes_ago" "$cache_file"
render_update 200 "$new_release"
assert_eq "a 29-minute-old successful check keeps its 30-minute interval" '1' "$(release_calls)"
assert_eq "the cached current check stays silent" 'MODEL: Fixture' "$render_output"

new_sandbox
printf '%s\n' 'UPDATE_CHECK_INTERVAL=abc' > "$sandbox/.cortado.conf"
for attempt in 1 2 3; do
    render_update 404 '{"message":"Not Found"}'
done
assert_eq "a malformed project interval still caches a failed check" '1' "$(release_calls)"
assert_eq "the cached failure shows an unavailable reading" 'MODEL: Fixture | UPD: --' "$render_output"

new_sandbox
mkdir -p "$cache_dir"
printf '%s\n' current > "$cache_file"
render_update 404 '{"message":"Not Found"}'
assert_eq "an ambiguous cache from an older install is checked again" 'MODEL: Fixture | UPD: --' "$render_output"

new_sandbox
mkdir -p "$cache_dir"
printf '%s\n' 'available:9.9.9invalid' > "$cache_file"
render_update 404 '{"message":"Not Found"}'
assert_eq "a malformed legacy update notice is checked again" '1' "$(release_calls)"
assert_eq "a malformed legacy notice is replaced by an unavailable reading" 'MODEL: Fixture | UPD: --' "$render_output"
assert_eq "a failed refresh replaces the malformed cache entry" 'unknown' "$(cat "$cache_file")"

new_sandbox
mkdir -p "$cache_dir"
printf '%s\n' 'available:9.9.9' > "$cache_file"
render_update 404 '{"message":"Not Found"}'
assert_eq "a valid legacy update notice is reused without a fetch" '0' "$(release_calls)"
assert_eq "a valid legacy update notice stays visible" "$new_notice" "$render_output"

new_sandbox
printf '%s\n' 'UPDATE_REPO="bad repo"' >> "$sandbox/cortado.conf"
render_update 200 "$new_release"
assert_eq "a rejected repository shows an unavailable reading" 'MODEL: Fixture | UPD: --' "$render_output"
assert_eq "a rejected repository makes no request" '0' "$(release_calls)"
assert_eq "a rejected repository creates no cache entry" '1' "$([ -e "$cache_file" ]; printf '%s' "$?")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
