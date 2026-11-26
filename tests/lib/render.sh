# shellcheck shell=bash
# Shared statusline harness for standalone module suites.
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
RENDER_MODULE="$1"
RENDER_OS=
RENDER_FLAG="MODULE_$(printf '%s' "$RENDER_MODULE" | tr '[:lower:]' '[:upper:]')"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir "$TEST_BASE/bin" || exit 1

# render <sample> [payload] [config lines...]
# RENDER_CONFIG_DIR names a config directory that outlives the render, so a
# test can watch its cache. Config files are data (#33), so a config line
# cannot move CLAUDE_CONFIG_DIR.
render() (
    set -o pipefail
    local sb sample="$1" payload="${2:-'{"cwd":"/nonexistent"}'}"
    shift
    if [ "$#" -gt 0 ]; then shift; fi
    if [ -n "${RENDER_CONFIG_DIR:-}" ]; then
        sb="$RENDER_CONFIG_DIR"
        [ -d "$sb/cortado-cache" ] || mkdir -m 700 "$sb/cortado-cache" || exit 1
    else
        sb=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
        trap 'rm -rf "$sb"' EXIT
        mkdir -m 700 "$sb/cortado-cache" || exit 1
    fi
    printf '%s\n' "MODULE_ORDER=$RENDER_MODULE" "$RENDER_FLAG=true" \
        'COLOR_THEME="monochrome"' 'DISPLAY_MODE="normal"' 'TERMINAL_WIDTH=200' \
        "$@" > "$sb/cortado.conf" || exit 1
    if [ -n "${RENDER_OS:-}" ]; then
        # Force the module platform (darwin or linux); file checks stay on the host.
        printf 'CORTADO_OS=%s\n' "$RENDER_OS" >> "$sb/cortado.conf" || exit 1
    fi
    chmod 600 "$sb/cortado.conf" || exit 1
    cd "$TEST_BASE" || exit 1
    printf '%s' "$payload" |
        LC_ALL=C PATH="$TEST_BASE/bin:$PATH" TEST_SAMPLE="$sample" \
        CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1 |
        sed $'s/\x1b\\[[0-9;]*m//g'
)

check_render() {
    local desc="$1" expected="$2" actual
    shift 2
    if actual=$(render "$@"); then
        assert_eq "$desc" "$expected" "$actual"
    else
        fail "$desc (render failed: [$actual])"
    fi
}
