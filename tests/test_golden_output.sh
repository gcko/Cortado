#!/bin/bash
# Compare stdout byte for byte, including line breaks, separators, and ANSI.
# The PATH fixture supplies the clock and host readings without network access.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GOLDEN="$TEST_DIR/golden"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT

export LC_ALL=C.UTF-8 TZ=UTC
unset BASH_ENV IN_CLAUDE_CODE APP_SANDBOX_CONTAINER_ID CORTADO_GOLDEN_DARWIN NVM_DIR OSTYPE
export CORTADO_GOLDEN_UNAME
CORTADO_GOLDEN_UNAME=$(command -v uname)
mkdir -p "$TEST_BASE/bin" "$TEST_BASE/workspace"
printf '{"name":"golden-output"}\n' > "$TEST_BASE/workspace/package.json"
cp "$GOLDEN/tool" "$TEST_BASE/bin/stub"
chmod +x "$TEST_BASE/bin/stub"
for tool in brightness curl date df docker git ipconfig networksetup node \
    osx-cpu-temp pgrep pmset ps sysctl top uname uptime vm_stat; do
    ln -s stub "$TEST_BASE/bin/$tool"
done
export PATH="$TEST_BASE/bin:$PATH"

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

assert_render() {
    local fixture="$1" sb
    shift
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
    mkdir -m 700 "$sb/cortado-cache"
    printf '%s\n' "$@" > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf"
    # Expand the fixture's version and ANSI markers for a raw stdout comparison.
    sed -e "s/@VERSION@/$version/" -e $'s/@ESC@/\033/g' "$GOLDEN/$fixture.out" > "$sb/expected"
    if printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" \
        /bin/bash "$PROJECT_ROOT/cortado.sh" > "$sb/actual" 2> "$sb/stderr" &&
        cmp -s "$sb/expected" "$sb/actual" && [ ! -s "$sb/stderr" ]; then
        PASS=$((PASS + 1))
        printf 'PASS: %s renders the golden stdout\n' "$fixture"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s differs from the golden stdout\n' "$fixture"
        diff -u "$sb/expected" "$sb/actual"
        cat "$sb/stderr"
    fi
}

assert_render default 'TERMINAL_WIDTH=200'
assert_render compact 'DISPLAY_MODE=compact' 'TERMINAL_WIDTH=60'
# Exercise the same stubbed hardware everywhere. Set OSTYPE after the real host
# has checked the trusted config's file mode.
assert_render all-modules \
    'export CORTADO_GOLDEN_DARWIN=true APP_SANDBOX_CONTAINER_ID=golden OSTYPE=darwin' \
    'TERMINAL_WIDTH=100' 'STATUS_STYLE=dots' 'NETWORK_SHOW_SSID=true' \
    "SEPARATOR=\$' \033[36m|\033[0m '" "MODEL_ICON=\$'\033[35m🤖\033[0m'" \
    'MODULE_ORDER="sandbox, version, update, directory, context, git, project, model, cost, rate-limits, time, battery, cpu, memory, disk, network, uptime, load, temperature, brightness, processes, docker, node, weather, timezone"' \
    'MODULE_CPU=true MODULE_MEMORY=true MODULE_DISK=true MODULE_NETWORK=true' \
    'MODULE_UPTIME=true MODULE_LOAD=true MODULE_TEMPERATURE=true MODULE_BRIGHTNESS=true' \
    'MODULE_PROCESSES=true MODULE_DOCKER=true MODULE_NODE=true MODULE_WEATHER=true MODULE_TIMEZONE=true'

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
