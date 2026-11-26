#!/bin/bash
# Compare stdout byte for byte, including line breaks, separators, and ANSI.
# The PATH fixture supplies the clock and host readings without network access.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GOLDEN="$TEST_DIR/golden"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
unset DOCKER_HOST DOCKER_CONTEXT
export DOCKER_CONFIG="$TEST_BASE/docker-config"
mkdir "$DOCKER_CONFIG"

host_uname=$(command -v uname)
mkdir -p "$TEST_BASE/bin" "$TEST_BASE/home" "$TEST_BASE/workspace"
printf '{"name":"golden-output"}\n' > "$TEST_BASE/workspace/package.json"
cp "$GOLDEN/tool" "$TEST_BASE/bin/stub"
chmod +x "$TEST_BASE/bin/stub"
for tool in brightness curl date df docker git iostat ipconfig networksetup node \
    osx-cpu-temp pgrep pmset ps sysctl uname uptime vm_stat; do
    ln -s stub "$TEST_BASE/bin/$tool"
done
export PATH="$TEST_BASE/bin:$PATH"

# Supported caller overrides must not change a render's fixture settings.
export PROJECT_ICON_NODE=CUSTOM SANDBOX_ICON=CUSTOM RATE_SHOW_USAGE_STATUS=false

payload=$(jq -cn --arg cwd "$TEST_BASE/workspace" '{
    workspace: {current_dir: $cwd},
    session_id: "golden-session",
    model: {display_name: "Opus[1m]"},
    output_style: {name: "concise"},
    context_window: {
        context_window_size: 200000,
        current_usage: {input_tokens: 50000},
        total_input_tokens: 50000, total_output_tokens: 4000
    },
    cost: {total_cost_usd: 0.25, total_duration_ms: 180000},
    rate_limits: {five_hour: {used_percentage: 42}, seven_day: {used_percentage: 10}}
}') || exit 1
version=$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")
PASS=0
FAIL=0

make_sandbox() {
    local sb
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX") || return 1
    mkdir -m 700 "$sb/cortado-cache" &&
        printf '%s\n' "$@" > "$sb/cortado.conf" &&
        chmod 600 "$sb/cortado.conf" &&
        printf '%s\n' "$sb"
}

render() {
    local sb="$1"
    shift
    printf '%s' "$payload" | env -i PATH="$PATH" HOME="$TEST_BASE/home" TMPDIR="$sb" \
        LC_ALL=C.UTF-8 TZ=UTC DOCKER_CONFIG="$DOCKER_CONFIG" CORTADO_GOLDEN_UNAME="$host_uname" \
        CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" "$@" \
        /bin/bash "$PROJECT_ROOT/cortado.sh" > "$sb/actual" 2> "$sb/stderr"
}

assert_output() {
    local label="$1" sb="$2" status=0
    shift 2
    render "$sb" "$@" || status=$?
    if [ "$status" -eq 0 ] && cmp -s "$sb/expected" "$sb/actual" && [ ! -s "$sb/stderr" ]; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (render exit %d)\n' "$label" "$status"
        diff -u "$sb/expected" "$sb/actual"
        cat "$sb/stderr"
    fi
}

# Prime the timed probes through the renderer, then align the fixture mtimes
# with the frozen date used by the stdout comparison.
warm_probes() {
    local sb="$1" keys="$2" key file i
    shift 2
    render "$sb" "$@" || return 1
    for key in $keys; do
        for ((i=0; i<100; i++)); do
            for file in "$sb/cortado-cache"/$key; do
                case "${file##*/}" in *-lock|*-failed|*.*) continue ;; esac
                if [ -s "$file" ]; then
                    TZ=UTC touch -t 202602011200.00 "$file" || return 1
                    break 2
                fi
            done
            sleep 0.05
        done
        if [ "$i" -eq 100 ]; then
            printf 'FAIL: golden probe %s did not publish\n' "$key"
            return 1
        fi
    done
}

assert_render() {
    local fixture="$1" sb
    shift
    sb=$(make_sandbox "$@") || exit 1
    # Expand the fixture's version and ANSI markers for a raw stdout comparison.
    sed -e "s/@VERSION@/$version/" -e $'s/@ESC@/\033/g' "$GOLDEN/$fixture.out" > "$sb/expected"
    if [ "$fixture" = all-modules ]; then
        warm_probes "$sb" 'cpu brightness processes-total docker-v2-true-false* weather-default-u network-local-v2-true-true load node-*' || exit 1
    fi
    assert_output "$fixture renders the golden stdout" "$sb"
}

assert_mac_cpu_uptime() {
    local label="$1" sb
    shift
    sb=$(make_sandbox 'TERMINAL_WIDTH=200' 'MODULE_ORDER=cpu,uptime' 'MODULE_CPU=true' 'MODULE_UPTIME=true') || exit 1
    printf '%s\n' '💻 25% 🟢 | ⏱️ 1d 1h' > "$sb/expected"
    warm_probes "$sb" cpu "$@" || exit 1
    assert_output "macOS renders CPU and uptime with $label" "$sb" "$@"
}

assert_mac_memory() {
    local off on off_calls on_calls
    mkdir "$TEST_BASE/count-bin"
    cat > "$TEST_BASE/count-bin/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_CONFIG_DIR/uname.calls"
exec "${0%/*}/../bin/uname" "$@"
STUB
    chmod +x "$TEST_BASE/count-bin/uname"

    off=$(make_sandbox 'MODULE_ORDER=memory' 'MODULE_MEMORY=false' 'TERMINAL_WIDTH=200') || exit 1
    on=$(make_sandbox 'MODULE_ORDER=memory' 'MODULE_MEMORY=true' 'TERMINAL_WIDTH=200') || exit 1
    : > "$off/uname.calls"
    : > "$on/uname.calls"
    printf '\n' > "$off/expected"
    printf '%s\n' '🧠 25% 🟢' > "$on/expected"
    PATH="$TEST_BASE/count-bin:$PATH" assert_output 'macOS omits disabled memory' "$off"
    PATH="$TEST_BASE/count-bin:$PATH" assert_output 'macOS renders the memory reading' "$on"

    off_calls=$(wc -l < "$off/uname.calls")
    on_calls=$(wc -l < "$on/uname.calls")
    # CORTADO_OS comes from the host triple, so a render never asks uname.
    if [ "$on_calls" -eq 0 ] && [ "$off_calls" -eq 0 ]; then
        PASS=$((PASS + 1))
        printf 'PASS: a render makes no uname calls, with memory off or on\n'
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: a render called uname (%d with memory off, %d on)\n' "$off_calls" "$on_calls"
    fi
}

assert_debug_warning() {
    local order='MODULE_ORDER=" unknown_mod , model "' on off warning_count=0
    on=$(make_sandbox "$order" 'DEBUG_MODE=true' 'TERMINAL_WIDTH=200') || exit 1
    off=$(make_sandbox "$order" 'DEBUG_MODE=false' 'TERMINAL_WIDTH=200') || exit 1
    printf '%s\n' '🤖 Opus[1m] (concise)' > "$on/expected"
    cp "$on/expected" "$off/expected"
    assert_output 'debug mode renders the model beside an unknown module' "$on"
    assert_output 'normal mode renders the model beside an unknown module' "$off"

    if [ -f "$on/cortado.log" ]; then
        warning_count=$(grep -c 'Warning: Unknown module in MODULE_ORDER: unknown_mod$' "$on/cortado.log")
    fi
    if [ "$warning_count" -eq 1 ] && [ ! -e "$off/cortado.log" ]; then
        PASS=$((PASS + 1))
        printf 'PASS: only debug mode logs one unknown module warning\n'
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: expected one unknown module warning in debug mode, found %d\n' "$warning_count"
        if [ -e "$off/cortado.log" ]; then
            printf 'FAIL: normal mode created a log\n'
        fi
    fi
}

# The default and compact fixtures show the macOS battery, so pin darwin on every host.
assert_render default 'CORTADO_OS=darwin' 'TERMINAL_WIDTH=200'
assert_render compact 'CORTADO_OS=darwin' 'DISPLAY_MODE=compact' 'TERMINAL_WIDTH=60'
# Exercise the same stubbed macOS hardware on every host.
assert_render all-modules \
    'export APP_SANDBOX_CONTAINER_ID=golden' 'CORTADO_OS=darwin' \
    'TERMINAL_WIDTH=100' 'STATUS_STYLE=dots' 'NETWORK_SHOW_SSID=true' \
    "SEPARATOR=\$' \033[36m|\033[0m '" "MODEL_ICON=\$'\033[35m🤖\033[0m'" \
    'MODULE_ORDER="sandbox, version, update, directory, context, git, project, model, cost, rate-limits, time, battery, cpu, memory, disk, network, uptime, load, temperature, brightness, processes, docker, node, weather, timezone"' \
    'MODULE_CPU=true MODULE_MEMORY=true MODULE_DISK=true MODULE_NETWORK=true' \
    'MODULE_UPTIME=true MODULE_LOAD=true MODULE_TEMPERATURE=true MODULE_BRIGHTNESS=true' \
    'MODULE_PROCESSES=true MODULE_DOCKER=true MODULE_NODE=true MODULE_WEATHER=true MODULE_TIMEZONE=true'

if [ "$("$host_uname" -s)" = Darwin ]; then
    assert_mac_cpu_uptime 'native OSTYPE'
    assert_mac_cpu_uptime 'empty OSTYPE' OSTYPE=
    assert_mac_cpu_uptime 'Linux OSTYPE' OSTYPE=linux-gnu
    assert_mac_memory
fi
assert_debug_warning

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
