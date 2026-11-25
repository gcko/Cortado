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
render() (
    set -o pipefail
    local sb sample="$1" payload="${2:-'{"cwd":"/nonexistent"}'}"
    shift
    if [ "$#" -gt 0 ]; then shift; fi
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
    trap 'rm -rf "$sb"' EXIT
    mkdir -m 700 "$sb/cortado-cache" || exit 1
    printf '%s\n' "MODULE_ORDER=$RENDER_MODULE" "$RENDER_FLAG=true" \
        'COLOR_THEME="monochrome"' 'DISPLAY_MODE="normal"' 'TERMINAL_WIDTH=200' \
        "$@" > "$sb/cortado.conf" || exit 1
    if [ -n "${RENDER_OS:-}" ]; then
        # Force main's probe while keeping config permission checks on the real OS.
        cat >> "$sb/cortado.conf" <<'CONFIG'
OSTYPE=fixture
uname() {
    if [ "${FUNCNAME[1]:-}" = main ] && [ "${1:-}" = -s ]; then
        printf '%s\n' "$TEST_OS"
    else
        command uname "$@"
    fi
}
CONFIG
    fi
    chmod 600 "$sb/cortado.conf" || exit 1
    cd "$TEST_BASE" || exit 1
    printf '%s' "$payload" |
        LC_ALL=C PATH="$TEST_BASE/bin:$PATH" TEST_OS="${RENDER_OS:-}" TEST_SAMPLE="$sample" \
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

# Allow only the observed output for a known product defect.
check_render_gap() {
    local desc="$1" expected="$2" known="$3" actual
    shift 3
    if ! actual=$(render "$@"); then
        fail "$desc (render failed: [$actual])"
    elif [ "$actual" = "$known" ]; then
        printf 'KNOWN-GAP: %s (expected [%s] got [%s])\n' "$desc" "$expected" "$actual"
    else
        assert_eq "$desc" "$expected" "$actual"
    fi
}
