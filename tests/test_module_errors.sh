#!/bin/bash
# Render with missing tools and module diagnostics to check stdout and debug logging.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BASE="$(mktemp -d)"
trap 'rm -rf "$TEST_BASE"' EXIT

. "$PROJECT_ROOT/tests/lib/assert.sh" plain-comma
# A controlled PATH keeps the system tools available and omits the selected one.
without_tool() {
    local dest="$1" omit="$2" tool name
    mkdir "$dest"
    for tool in "$(command -v jq)" "$(command -v bc)" /bin/* /usr/bin/* /sbin/* /usr/sbin/*; do
        [ -f "$tool" ] && [ -x "$tool" ] || continue
        name="${tool##*/}"
        [ "$name" != "$omit" ] && [ ! -e "$dest/$name" ] || continue
        ln -s "$tool" "$dest/$name"
    done
}

without_tool "$TEST_BASE/no-grep" grep
without_tool "$TEST_BASE/no-jq" jq
# Supply a battery reading on desktops and on Linux so grep is actually reached.
rm -f "$TEST_BASE/no-grep/pmset"
cat > "$TEST_BASE/no-grep/pmset" <<'EOF'
#!/bin/bash
printf '%s\n' 'Now drawing from AC Power' 'InternalBattery 80%; charging'
EOF
chmod +x "$TEST_BASE/no-grep/pmset"

SOURCE_TREE="$TEST_BASE/source"
mkdir "$SOURCE_TREE"
cp "$PROJECT_ROOT/cortado.sh" "$PROJECT_ROOT/cortado.conf" "$SOURCE_TREE/"
cp -R "$PROJECT_ROOT/modules" "$SOURCE_TREE/"
cp "$SCRIPT_DIR/module-error-fixture.sh" "$SOURCE_TREE/modules/zz-runtime-test.sh" || exit 1
cat > "$SOURCE_TREE/modules/zz-source-test.sh" <<'EOF'
: > "$CLAUDE_CONFIG_DIR/source-ran"
printf '%s\n' 'first source diagnostic' 'second source diagnostic' >&2
if [ "${TEST_MODEL_DIAGNOSTIC:-false}" = true ]; then
    module_model() {
        printf '%s\n' 'model runtime diagnostic' >&2
        printf '%s\n' '🤖 Opus'
    }
fi
if [ "${TEST_MODEL_WAIT:-false}" = true ]; then
    module_model() {
        printf '%s\n' 'diagnostic before interruption' >&2
        : > "$CLAUDE_CONFIG_DIR/module-entered"
        sleep 30
    }
fi
if [ "${TEST_MODEL_FLOOD:-false}" = true ]; then
    module_model() {
        local i
        for ((i = 0; i < 128; i++)); do printf '%16383s\n' 'flood diagnostic' >&2; done
        find "$TMPDIR" -type f -exec wc -c {} \; |
            awk '$1>largest { largest=$1 } END { print largest+0 }' > "$CLAUDE_CONFIG_DIR/capture-size"
        printf '%s\n' '🤖 Opus'
    }
fi
if [ "${TEST_VERSION_PAYLOAD:-false}" = true ]; then
    module_version() {
        if [ "$#" -eq 1 ]; then printf 'payload=%s\n' "$1"; else printf '%s\n' 'payload missing'; fi
    }
fi
EOF
printf '%s\n' 'printf "%s\n" "utils source diagnostic" >&2' >> "$SOURCE_TREE/modules/utils.sh"

PAYLOAD='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'

# Fresh config and cache per render. Keep the two process streams observable.
render() {
    local tree="$1" tool_path="$2" fixture="$3" result tmpdir
    shift 3
    sb="$(mktemp -d "$TEST_BASE/render.XXXXXX")"
    export CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache"
    tmpdir="$sb/tmp"
    if [ "$fixture" = bad-tmpdir ]; then : > "$tmpdir"; else mkdir "$tmpdir"; fi
    case "$fixture" in
        blocked-cache) : > "$CACHE_DIR" ;;
        blocked-log) mkdir "$sb/cortado.log" ;;
        flood) printf '%1048575s\n' 'full generation' > "$sb/cortado.log" ;;
    esac
    printf '%s\n' 'LAYOUT_MODE="none"' 'MODULE_MODEL="true"' "$@" > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf"
    printf '%s' "$PAYLOAD" | PATH="$tool_path" TMPDIR="$tmpdir" /bin/bash "$tree/cortado.sh" \
        > "$sb/stdout" 2> "$sb/stderr"
    result=$?
    out=$(sed $'s/\x1b\\[[0-9;]*m//g' "$sb/stdout")
    err=$(cat "$sb/stderr")
    log=''
    if [ -f "$sb/cortado.log" ]; then log=$(cat "$sb/cortado.log"); fi
    return "$result"
}

for debug in false true; do
    render "$PROJECT_ROOT" "$TEST_BASE/no-grep" clean 'MODULE_ORDER="battery,model"' \
        'MODULE_BATTERY="true"' "DEBUG_MODE=$debug"
    assert_eq "Missing grep leaves the model reading intact (debug $debug)" '🤖 Opus' "$out"
    assert_eq "Missing grep keeps process stderr quiet (debug $debug)" '' "$err"
    if [ "$debug" = true ]; then
        assert_contains 'Debug logs the missing grep error under battery' 'battery: ' "$log"
        assert_contains 'The log records the shell diagnostic' 'grep: command not found' "$log"
    else
        assert_eq 'Ordinary mode creates no log' '' "$log"
    fi
done

render "$SOURCE_TREE" "$TEST_BASE/no-jq" clean 'MODULE_ORDER="model"'
assert_eq 'Missing jq exits successfully' 0 "$?"
printf '%s\n' 'cortado: jq missing' > "$sb/expected"
if cmp -s "$sb/expected" "$sb/stdout"; then
    pass 'Missing jq prints exactly one line naming the dependency'
else
    fail "Missing jq prints exactly one line naming the dependency (got $(wc -c < "$sb/stdout") bytes)"
fi
assert_eq 'Missing jq keeps process stderr quiet' '' "$err"
if [ -e "$sb/source-ran" ]; then fail 'The jq check runs before sourcing modules'
else pass 'The jq check runs before sourcing modules'
fi

for debug in false true; do
    render "$SOURCE_TREE" "$PATH" clean 'MODULE_ORDER="model"' "DEBUG_MODE=$debug"
    assert_eq "Sourcing keeps the model reading intact (debug $debug)" '🤖 Opus' "$out"
    assert_eq "Sourcing keeps process stderr quiet (debug $debug)" '' "$err"
    if [ "$debug" = true ]; then
        assert_contains 'Debug logs the utility source diagnostic' 'utils: utils source diagnostic' "$log"
        assert_contains 'Debug prefixes every module source diagnostic' \
            $'zz-source-test: first source diagnostic\nzz-source-test: second source diagnostic' "$log"
    else
        assert_eq 'Ordinary mode discards source diagnostics' '' "$log"
    fi
done

render "$SOURCE_TREE" "$PATH" clean 'MODULE_ORDER="uptime,model"' \
    'MODULE_UPTIME=true' 'DEBUG_MODE=true' 'TEST_CACHE_WRITE=true'
assert_eq 'The fixture writes its value through cache_set with a usable cache' \
    'fixture value' "$(cat "$CACHE_DIR/routing-probe" 2>/dev/null)"

render "$SOURCE_TREE" "$PATH" blocked-cache 'MODULE_ORDER="uptime,model"' \
    'MODULE_UPTIME=true' 'DEBUG_MODE=true' 'TEST_CACHE_WRITE=true'
assert_eq 'An unwritable cache leaves both readings intact' 'Fixture reading | 🤖 Opus' "$out"
assert_eq 'An unwritable cache keeps process stderr quiet' '' "$err"
assert_contains 'Debug logs the cache_set failure and path under the calling module' \
    "uptime: cache_set failed for $CACHE_DIR/routing-probe" "$log"

render "$PROJECT_ROOT" "$PATH" clean 'MODULE_ORDER="context,model"' \
    'MODULE_CONTEXT="true"' 'PROGRESS_BAR_WIDTH="abc"' 'DEBUG_MODE="true"'
assert_eq 'A malformed progress-bar width leaves both readings intact' '📊  25% 🟢 (110k→⚡) | 🤖 Opus' "$out"
assert_eq 'A malformed width keeps process stderr quiet' '' "$err"
assert_contains 'Debug logs a utils helper error under its calling module' 'context: ' "$log"
assert_contains 'Debug retains the invalid-integer diagnostic' 'abc: integer expression expected' "$log"

render "$SOURCE_TREE" "$PATH" blocked-log 'MODULE_ORDER="model"' 'DEBUG_MODE="true"'
assert_eq 'An unwritable log leaves the statusline intact' '🤖 Opus' "$out"
assert_eq 'An unwritable log keeps process stderr quiet' '' "$err"

render "$SOURCE_TREE" "$PATH" clean 'MODULE_ORDER="model"' 'DEBUG_MODE=true' \
    'TEST_MODEL_DIAGNOSTIC=true' 'set -C'
printf '%s\n' '🤖 Opus' > "$sb/expected"
if cmp -s "$sb/expected" "$sb/stdout"; then
    pass 'Noclobber leaves the exact model line intact'
else
    fail "Noclobber leaves the exact model line intact (got [$out])"
fi
assert_eq 'Noclobber keeps process stderr quiet' '' "$err"
assert_contains 'Noclobber logs the utility source error' 'utils: utils source diagnostic' "$log"
assert_contains 'Noclobber logs the module source error' 'zz-source-test: first source diagnostic' "$log"
assert_contains 'Noclobber logs the module runtime error' 'model: model runtime diagnostic' "$log"

render "$SOURCE_TREE" "$PATH" bad-tmpdir 'MODULE_ORDER="uptime,model"' \
    'MODULE_UPTIME=true' 'DEBUG_MODE=true' 'TEST_RUNTIME_DIAGNOSTIC="TMPDIR diagnostic"'
assert_eq 'Unusable TMPDIR leaves both readings intact' 'Fixture reading | 🤖 Opus' "$out"
assert_eq 'Unusable TMPDIR keeps process stderr quiet' '' "$err"
assert_contains 'Unusable TMPDIR still logs the prefixed runtime diagnostic' \
    'uptime: TMPDIR diagnostic' "$log"

check_capture_cleanup() (
    set -m
    local signal="$1" location="$2" expected="$3" dir config tmp pid retry rc=0
    dir=$(mktemp -d "$TEST_BASE/signals.XXXXXX") || return 1
    config=$(mktemp -d "$dir/config.XXXXXX") || return 1
    tmp="$dir/tmp"
    if [ "$location" = tmp ]; then mkdir "$tmp"; else : > "$tmp"; fi
    printf '%s\n' MODULE_ORDER=model MODULE_MODEL=true DEBUG_MODE=true TEST_MODEL_WAIT=true \
        > "$config/cortado.conf"
    printf '%s' "$PAYLOAD" > "$dir/payload"
    CLAUDE_CONFIG_DIR="$config" CACHE_DIR="$config/cache" TMPDIR="$tmp" \
        /bin/bash "$SOURCE_TREE/cortado.sh" < "$dir/payload" > "$dir/stdout" 2> "$dir/stderr" &
    pid=$!
    trap 'kill -KILL -- "-$pid" 2>/dev/null || :' EXIT
    for ((retry = 0; retry < 250; retry++)); do
        [ ! -f "$config/module-entered" ] || break
        /bin/sleep 0.02
    done
    [ -f "$config/module-entered" ] || return 1
    kill "-$signal" -- "-$pid" || return 1
    wait "$pid" 2>/dev/null || rc=$?
    [ "$rc" -eq "$expected" ] || return 1
    local captures
    captures=$(find "$dir" -name 'cortado-stderr.*' -print)
    if [ -n "$captures" ]; then
        printf '  capture remains in %s\n' "$location"
        return 1
    fi
)
for scenario in 'TERM tmp 143' 'TERM config 143' 'INT tmp 130' 'HUP tmp 129'; do
    read -r signal location expected <<< "$scenario"
    if check_capture_cleanup "$signal" "$location" "$expected"; then
        pass "$signal removes the capture from $location"
    else
        fail "$signal removes the capture from $location"
    fi
done

render "$SOURCE_TREE" "$PATH" flood 'MODULE_ORDER=model' 'DEBUG_MODE=true' 'TEST_MODEL_FLOOD=true'
assert_eq 'Two MiB of stderr leaves the model reading intact' '🤖 Opus' "$out"
assert_eq 'Two MiB of stderr leaves process stderr quiet' '' "$err"
capture_size=$(cat "$sb/capture-size")
if [ "$capture_size" -gt 0 ] && [ "$capture_size" -le 65536 ]; then
    pass 'The live temporary capture fits in 64 KiB'
else
    fail "The live temporary capture fits in 64 KiB (got $capture_size bytes)"
fi
if grep -qFx 'model: [truncated 2031616 bytes]' "$sb/cortado.log" &&
    grep -qF 'flood diagnostic' "$sb/cortado.log"; then
    pass 'The log keeps the start and reports the exact omitted byte count'
else
    fail 'The log keeps the start and reports the exact omitted byte count'
fi
for generation in "$sb/cortado.log" "$sb/cortado.log.1"; do
    size=$(wc -c < "$generation")
    if [ "$size" -gt 0 ] && [ "$size" -le 1048576 ]; then
        pass "${generation##*/} fits in 1 MiB after the flood"
    else
        fail "${generation##*/} fits in 1 MiB after the flood (got $size bytes)"
    fi
done
assert_eq 'A completed render removes all temporary captures' '' "$(ls -A "$sb/tmp")"

render "$SOURCE_TREE" "$PATH" clean 'MODULE_ORDER=version' 'MODULE_VERSION=true' 'TEST_VERSION_PAYLOAD=true'
assert_eq 'Version receives the original payload as its only argument' "payload=$PAYLOAD" "$out"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
