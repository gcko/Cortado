#!/bin/bash
# Render with missing tools and module diagnostics to check stdout and debug logging.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BASE="$(mktemp -d)"
trap 'rm -rf "$TEST_BASE"' EXIT

# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain-comma
# A controlled PATH keeps the system tools available and omits the selected one.
without_tool() {
    local dest="$1" omit="$2" tool name names=:
    local links=()
    mkdir "$dest"
    for tool in "$(command -v jq)" "$(command -v bc)" /bin/* /usr/bin/* /sbin/* /usr/sbin/*; do
        if [ ! -f "$tool" ] || [ ! -x "$tool" ]; then continue; fi
        name="${tool##*/}"
        [ "$name" != "$omit" ] || continue
        case "$names" in *":$name:"*) continue ;; esac
        names="$names$name:"
        links+=("$tool")
    done
    ln -s "${links[@]}" "$dest"
}

without_tool "$TEST_BASE/no-grep" grep
without_tool "$TEST_BASE/no-dd" dd
if [ ! -x "$TEST_BASE/no-dd/python3" ]; then
    ln -s "$(command -v python3)" "$TEST_BASE/no-dd/python3" || exit 1
fi
without_tool "$TEST_BASE/no-jq" jq
# Supply a battery reading even on hosts without pmset. The battery render pins
# darwin, because battery is a macOS-only module and is skipped on Linux.
rm -f "$TEST_BASE/no-grep/pmset"
cat > "$TEST_BASE/no-grep/pmset" <<'EOF'
#!/bin/bash
printf '%s\n' 'Now drawing from AC Power' 'InternalBattery 80%; charging'
EOF
chmod +x "$TEST_BASE/no-grep/pmset"

SOURCE_TREE="$TEST_BASE/source"
mkdir -m 700 "$SOURCE_TREE"
cp "$PROJECT_ROOT/cortado.sh" "$PROJECT_ROOT/cortado.conf" "$SOURCE_TREE/"
cp -R "$PROJECT_ROOT/modules" "$PROJECT_ROOT/lib" "$SOURCE_TREE/"
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
if [ "${TEST_MODEL_MISSING_GREP:-false}" = true ]; then
    module_model() {
        grep -q . /dev/null
        printf '%s\n' '🤖 Opus'
    }
fi
if [ "${TEST_MODEL_WAIT:-false}" = true ]; then
    module_model() {
        printf '%s\n' 'diagnostic before interruption' >&2
        : > "$CLAUDE_CONFIG_DIR/module-entered"
        # The test holds the FIFO open without sending data.
        local release
        read -r -t 30 release <&8
    }
fi
if [ "${TEST_MODEL_FLOOD:-false}" = true ]; then
    module_model() {
        local i
        printf '%16383s\n' 'first flood diagnostic' >&2
        for ((i = 1; i < 128; i++)); do printf '%16383s\n' 'flood diagnostic' >&2; done
        find "$TMPDIR" -type f -exec wc -c {} \; |
            awk '$1>largest { largest=$1 } END { print largest+0 }' > "$CLAUDE_CONFIG_DIR/capture-size"
        printf '%s\n' '🤖 Opus'
    }
fi
if [ -n "${TEST_OMITTED_BYTES:-}" ]; then
    module_model() {
        # Write 4097 bytes first, including a two-byte character and a newline.
        printf '%4094s%s\n' 'first uneven diagnostic' 'é' >&2
        # Wait for the short write to drain from this module's FIFO. The reused
        # data file can still contain old diagnostics or be awaiting a flush.
        python3 - "$CORTADO_STDERR_CAPTURE/pipe" "$TEST_OMITTED_BYTES" <<'FIFO' || return 1
import array
import fcntl
import os
import sys
import termios
import time

# On macOS FIONREAD must query the read end. Opening it here does not read data.
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
if not os.path.samestat(os.fstat(fd), os.fstat(2)):
    raise SystemExit("uneven stderr fixture did not open the module's FIFO")

def wait_until_drained():
    unread = array.array("i", [0])
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        fcntl.ioctl(fd, termios.FIONREAD, unread, True)
        if unread[0] == 0:
            return
        time.sleep(0.005)
    raise SystemExit("uneven stderr fixture timed out waiting for the FIFO to drain")

omitted = int(sys.argv[2])
wait_until_drained()
with os.fdopen(os.dup(2), "wb") as stderr:
    # Fill through byte 65,535, then deliver the cutoff newline and the first
    # omitted byte together. This forces the faulty reader to see both bytes.
    stderr.write(b"last retained diagnostic".rjust(61438))
    stderr.flush()
    wait_until_drained()
    os.write(2, b"\nX" if omitted else b"\n")
    if omitted > 1:
        stderr.write(b"omitted tail".rjust(omitted - 2) + b"\n")
FIFO
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
        'CORTADO_OS=darwin' 'MODULE_BATTERY="true"' "DEBUG_MODE=$debug"
    assert_eq "Missing grep keeps both battery and model readings (debug $debug)" '🔋 80% ⚡ | 🤖 Opus' "$out"
    assert_eq "Missing grep keeps process stderr quiet (debug $debug)" '' "$err"
    if [ "$debug" = true ]; then
        assert_not_contains 'Battery needs no grep diagnostic' 'battery: ' "$log"
    else
        assert_eq 'Ordinary mode creates no log' '' "$log"
    fi
done

render "$SOURCE_TREE" "$TEST_BASE/no-grep" clean 'MODULE_ORDER=model' 'DEBUG_MODE=true' 'TEST_MODEL_MISSING_GREP=true'
assert_eq 'A missing command keeps the surviving reading intact' '🤖 Opus' "$out"
assert_eq 'A missing command keeps process stderr quiet' '' "$err"
assert_contains 'Debug logs the missing command under its module' 'model: ' "$log"
assert_contains 'Debug retains the missing-command diagnostic' 'grep: command not found' "$log"

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

render "$SOURCE_TREE" "$TEST_BASE/no-dd" clean 'MODULE_ORDER=model' 'DEBUG_MODE=true' 'TEST_MODEL_DIAGNOSTIC=true'
assert_eq 'Missing dd leaves the model reading intact' '🤖 Opus' "$out"
assert_eq 'Missing dd keeps process stderr quiet' '' "$err"
assert_contains 'Missing dd still logs the prefixed module diagnostic' 'model: model runtime diagnostic' "$log"

render "$SOURCE_TREE" "$TEST_BASE/no-dd" clean 'MODULE_ORDER=model' 'DEBUG_MODE=true' 'TEST_OMITTED_BYTES=1'
assert_eq 'Missing dd still renders after the capture fills' '🤖 Opus' "$out"
assert_file_contains 'Missing dd still logs the exact number of omitted bytes' \
    'model: [truncated 1 bytes]' "$sb/cortado.log"

check_capture_cleanup() (
    set -m
    local signal="$1" location="$2" expected="$3" dir config tmp capture_root pid retry rc=0
    dir=$(mktemp -d "$TEST_BASE/signals.XXXXXX") || return 1
    config=$(mktemp -d "$dir/config.XXXXXX") || return 1
    tmp="$dir/tmp"
    if [ "$location" = tmp ]; then
        mkdir "$tmp" || return 1
        capture_root="$tmp"
    else
        : > "$tmp"
        capture_root="$config"
    fi
    mkfifo "$dir/module-hold" || return 1
    printf '%s\n' MODULE_ORDER=model MODULE_MODEL=true DEBUG_MODE=true TEST_MODEL_WAIT=true \
        > "$config/cortado.conf"
    chmod 600 "$config/cortado.conf" || return 1
    printf '%s' "$PAYLOAD" > "$dir/payload"
    local launcher=(/bin/bash)
    if [ "$signal" = HUP ]; then
        # Bash cannot trap HUP if it starts with SIG_IGN. Force that inheritance
        # and reset it in a fresh process before launching the Bash under test.
        launcher=(/bin/bash -c 'trap "" HUP; exec "$@"' -- python3 -c '
import os
import signal
import sys

signal.signal(signal.SIGHUP, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
' /bin/bash)
    fi
    CLAUDE_CONFIG_DIR="$config" CACHE_DIR="$config/cache" TMPDIR="$tmp" \
        "${launcher[@]}" "$SOURCE_TREE/cortado.sh" < "$dir/payload" > "$dir/stdout" 2> "$dir/stderr" \
        8<> "$dir/module-hold" &
    pid=$!
    trap 'kill -KILL -- "-$pid" 2>/dev/null || :' EXIT
    for ((retry = 0; retry < 250; retry++)); do
        [ ! -f "$config/module-entered" ] || break
        /bin/sleep 0.02
    done
    if [ ! -f "$config/module-entered" ]; then
        printf '  model did not enter the signal fixture\n'
        return 1
    fi
    set -- "$capture_root"/cortado-stderr.*
    if [ "$#" -ne 1 ] || [ ! -p "$1/pipe" ]; then
        printf '  expected one live capture in %s before %s\n' "$location" "$signal"
        return 1
    fi
    kill "-$signal" -- "-$pid" || return 1
    # Cortado's EXIT trap removes the capture before this child can be reaped.
    wait "$pid" 2>/dev/null || rc=$?
    if [ "$rc" -ne "$expected" ]; then
        printf '  expected exit status %s, got %s\n' "$expected" "$rc"
        return 1
    fi
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
marker_count=0
first_line_kept=false
for generation in "$sb/cortado.log" "$sb/cortado.log.1"; do
    size=0
    if [ -f "$generation" ]; then
        size=$(wc -c < "$generation")
        matches=$(grep -cFx 'model: [truncated 2031616 bytes]' "$generation")
        marker_count=$((marker_count + matches))
        if [ "$matches" -gt 0 ] &&
            grep -qE 'model: +first flood diagnostic$' "$generation"; then
            first_line_kept=true
        fi
    fi
    if [ "$size" -gt 0 ] && [ "$size" -le 1048576 ]; then
        pass "${generation##*/} fits in 1 MiB after the flood"
    else
        fail "${generation##*/} fits in 1 MiB after the flood (got $size bytes)"
    fi
done
if [ "$marker_count" -eq 1 ] && [ "$first_line_kept" = true ]; then
    pass 'The log keeps the start and reports the exact omitted byte count'
else
    fail "The log keeps the start and reports the exact omitted byte count (markers: $marker_count, first line kept with marker: $first_line_kept)"
fi
assert_eq 'A completed render removes all temporary captures' '' "$(ls -A "$sb/tmp")"

for omitted in 2031616 0 1; do
    bytes=$((65536 + omitted))
    render "$SOURCE_TREE" "$PATH" clean 'MODULE_ORDER=model' 'DEBUG_MODE=true' "TEST_OMITTED_BYTES=$omitted"
    assert_eq "$bytes stderr bytes leave the model reading intact" '🤖 Opus' "$out"
    assert_eq "$bytes stderr bytes leave process stderr quiet" '' "$err"
    if grep -qE 'model: +first uneven diagnosticé$' "$sb/cortado.log" &&
        grep -qE 'model: +last retained diagnostic$' "$sb/cortado.log"; then
        pass "$bytes stderr bytes retain the start and the cap boundary"
    else
        fail "$bytes stderr bytes retain the start and the cap boundary"
    fi
    expected_marker=''
    if [ "$omitted" -gt 0 ]; then expected_marker="model: [truncated $omitted bytes]"; fi
    assert_eq "$bytes stderr bytes report the exact omitted byte count" "$expected_marker" \
        "$(sed -n '/^model: \[truncated .* bytes\]$/p' "$sb/cortado.log")"
done

render "$SOURCE_TREE" "$PATH" clean 'MODULE_ORDER=version' 'MODULE_VERSION=true' 'TEST_VERSION_PAYLOAD=true'
assert_eq 'Version receives the original payload as its only argument' "payload=$PAYLOAD" "$out"

INCOMPLETE_TREE="$TEST_BASE/incomplete"
mkdir -m 700 "$INCOMPLETE_TREE"
cp "$PROJECT_ROOT/cortado.sh" "$PROJECT_ROOT/cortado.conf" "$INCOMPLETE_TREE/" || exit 1
cp -R "$PROJECT_ROOT/modules" "$PROJECT_ROOT/lib" "$INCOMPLETE_TREE/" || exit 1
rm "$INCOMPLETE_TREE/modules/utils.sh" || exit 1
# Observe the regular module diagnostics when the utility logger is absent.
cat > "$INCOMPLETE_TREE/modules/zz-observe.sh" <<'EOF'
log_debug() { printf '%s\n' "$1" >> "$CLAUDE_CONFIG_DIR/cortado.log"; }
EOF
PAYLOAD='{"model":{"display_name":"Claude Sonnet"},"context_window":{"used_percentage":25},"cost":{"total_cost_usd":0.5,"total_duration_ms":10000},"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":10}}}'
render "$INCOMPLETE_TREE" "$PATH" clean 'MODULE_ORDER=model'
assert_eq 'A missing utils file leaves the exact model name visible' '🤖 Claude Sonnet' "$out"
# shellcheck disable=SC2016
render "$INCOMPLETE_TREE" "$PATH" clean 'MODULE_ORDER=context,cost,rate-limits,memory' \
    'MODULE_MEMORY=true' 'DEBUG_MODE=true' 'TERMINAL_WIDTH=200' \
    'vm_stat() { printf "%s\n" "Pages free: 10." "Pages active: 10." "Pages wired down: 10."; }' \
    'sysctl() { case "$2" in hw.pagesize) echo 4096;; hw.memsize) echo 327680;; esac; }' \
    'grep() { case "$*" in "MemTotal /proc/meminfo") echo "MemTotal: 16777216";; "MemAvailable /proc/meminfo") echo "MemAvailable: 12582912";; *) command grep "$@";; esac; }'
assert_contains 'A missing utils file leaves context visible' '25%' "$out"
assert_contains 'A missing utils file leaves cost and burn rate visible' "💰 \$0.50 @\$180.00/h" "$out"
assert_contains 'A missing utils file leaves quota readings visible' '5h:42% 7d:10%' "$out"
assert_contains 'A missing utils file leaves memory usage visible' '🧠 25%' "$out"
assert_eq 'A missing utils file keeps process stderr quiet' '' "$err"
assert_not_contains 'The shared helpers resolve in the incomplete install' 'command not found' "$log"

render "$INCOMPLETE_TREE" "$PATH" clean 'MODULE_ORDER=network,cpu,weather' 'DEBUG_MODE=true' \
    'MODULE_NETWORK=true MODULE_CPU=true MODULE_WEATHER=true NETWORK_SHOW_WAN=true'
assert_eq 'A missing utils file still shows one absence for each probe module' '🌐 -- | 💻 -- | --' "$out"
assert_not_contains 'An incomplete install has a cached probe fallback' 'command not found' "$log"

# A debug capture whose write end cannot be opened must not hang the render.
# bash 3.2 fails the open when a child exits meanwhile (EINTR); mode 400 makes
# it fail the same way every time, while the next reader still blocks in its
# open. The render must finish, load every module and keep stderr quiet.
LOCKED_TREE="$TEST_BASE/locked-capture"
mkdir -m 700 "$LOCKED_TREE"
cp "$PROJECT_ROOT/cortado.sh" "$PROJECT_ROOT/cortado.conf" "$LOCKED_TREE/" || exit 1
cp -R "$PROJECT_ROOT/modules" "$PROJECT_ROOT/lib" "$LOCKED_TREE/" || exit 1
# shellcheck disable=SC2016
printf '%s\n' 'chmod 400 "$CORTADO_STDERR_CAPTURE/pipe" 2>/dev/null' \
    > "$LOCKED_TREE/modules/aaa-lock-capture.sh" || exit 1
# A module that fails while the capture is locked must not leak a job notice
# for the killed reader onto the render's stderr.
printf '%s\n' '# @cortado-module failmod' '# @default true' '# @args none' '# @platforms darwin,linux' \
    'module_failmod() { return 7; }' > "$LOCKED_TREE/modules/failmod.sh" || exit 1
locked_config="$(mktemp -d "$TEST_BASE/locked.XXXXXX")"
printf '%s\n' 'LAYOUT_MODE="none"' 'MODULE_ORDER="failmod,model"' 'DEBUG_MODE=true' > "$locked_config/cortado.conf"
chmod 600 "$locked_config/cortado.conf" || exit 1
locked_rc=0
printf '%s' '{"model":{"display_name":"Opus"}}' > "$locked_config/payload"
CLAUDE_CONFIG_DIR="$locked_config" CACHE_DIR="$locked_config/cache" TMPDIR="$locked_config" \
    perl -e 'alarm shift; exec @ARGV' 30 /bin/bash "$LOCKED_TREE/cortado.sh" < "$locked_config/payload" \
    > "$locked_config/stdout" 2> "$locked_config/stderr" || locked_rc=$?
locked_out=$(sed $'s/\x1b\\[[0-9;]*m//g' "$locked_config/stdout")
assert_eq 'A capture that cannot be opened does not hang the debug render' 0 "$locked_rc"
assert_eq 'A capture that cannot be opened still loads and runs the module' '🤖 Opus' "$locked_out"
assert_eq 'A capture that cannot be opened keeps the render stderr quiet' '' "$(cat "$locked_config/stderr")"

# A failing module's stderr and its exit status both reach the debug log.
FAILING_TREE="$TEST_BASE/failing-module"
mkdir -m 700 "$FAILING_TREE"
cp "$PROJECT_ROOT/cortado.sh" "$PROJECT_ROOT/cortado.conf" "$FAILING_TREE/" || exit 1
cp -R "$PROJECT_ROOT/modules" "$PROJECT_ROOT/lib" "$FAILING_TREE/" || exit 1
printf '%s\n' '# @cortado-module failmod' '# @default true' '# @args none' '# @platforms darwin,linux' \
    'module_failmod() { printf "%s\n" boom >&2; return 7; }' > "$FAILING_TREE/modules/failmod.sh" || exit 1
render "$FAILING_TREE" "$PATH" clean 'MODULE_ORDER="failmod,model"' 'DEBUG_MODE=true'
assert_eq 'A failing module leaves the next reading visible' '🤖 Claude Sonnet' "$out"
assert_contains 'Debug logs a failing module stderr' 'failmod: boom' "$log"
assert_contains 'Debug logs a failing module exit status' 'Module failmod failed with exit code 7' "$log"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
