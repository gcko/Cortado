#!/bin/bash
# Render CPU usage from controlled macOS and Linux probe output.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir "$TEST_BASE/bin"
cat > "$TEST_BASE/bin/top" <<'STUB'
#!/bin/bash
case "$TEST_SAMPLE" in
    failed) exit 1 ;;
    missing) echo 'CPU usage:' ;;
    invalid) echo 'CPU usage: -- user, -- sys, -- idle' ;;
    fractional) echo 'CPU usage: 12.34% user, 5.20% sys, 82.46% idle' ;;
    zero|partial) echo 'CPU usage: 0.00% user, 0.00% sys, 100.00% idle' ;;
esac
[ "$TEST_SAMPLE" != partial ]
STUB
cat > "$TEST_BASE/bin/grep" <<'STUB'
#!/bin/bash
if [ "${2:-}" = /proc/stat ]; then
    exec /usr/bin/grep "$1" "$TEST_PROC_STAT"
fi
exec /usr/bin/grep "$@"
STUB
chmod +x "$TEST_BASE/bin/"*

render() (
    local sb
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX")
    mkdir "$sb/cortado-cache"
    chmod 700 "$sb/cortado-cache"
    # Force render-OS detection through uname while keeping config checks on the host OS.
    printf '%s\n' 'MODULE_ORDER="cpu"' 'MODULE_CPU="true"' 'OSTYPE=fixture' \
        "COLOR_THEME=${3:-monochrome}" 'TERMINAL_WIDTH=200' > "$sb/cortado.conf"
    cat >> "$sb/cortado.conf" <<'CONFIG'
uname() {
    if [ "${FUNCNAME[1]:-}" = main ] && [ "${1:-}" = -s ]; then
        printf '%s\n' "$TEST_OS"
    else
        command uname "$@"
    fi
}
CONFIG
    chmod 600 "$sb/cortado.conf" || exit 1
    : > "$sb/proc-stat"
    case "$2" in
        linux-first|linux-zero|linux-empty-baseline|linux-truncated-baseline)
            printf 'cpu 10 0 4 30\n' > "$sb/proc-stat"
            ;;
        linux-truncated-current) printf 'cpu 20\n' > "$sb/proc-stat" ;;
    esac
    case "$2" in
        linux-zero) printf 'cpu 10 0 4 20\n' > "$sb/cortado-cache/cpu_stat" ;;
        linux-empty-baseline) : > "$sb/cortado-cache/cpu_stat" ;;
        linux-truncated-baseline) printf 'cpu 1 0\n' > "$sb/cortado-cache/cpu_stat" ;;
        linux-truncated-current) printf 'cpu 10 0 4 0\n' > "$sb/cortado-cache/cpu_stat" ;;
    esac
    export PATH="$TEST_BASE/bin:$PATH" TEST_OS="$1" TEST_SAMPLE="$2"
    export TEST_PROC_STAT="$sb/proc-stat" CLAUDE_CONFIG_DIR="$sb"
    export CACHE_DIR="$sb/cortado-cache"
    render_sample
    case "$2" in
        linux-*-baseline|linux-truncated-current)
            printf 'cpu 10 0 4 40\n' > "$sb/proc-stat"
            render_sample
            ;;
    esac
)

render_sample() {
    printf '%s' '{"cwd":"/nonexistent"}' | /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1
}

check() {
    local desc="$1" expected="$2" actual
    actual=$(render "$3" "$4" "${5:-monochrome}")
    assert_eq "$desc" "$expected" "$actual"
}

check "failing top shows absence" "CPU: --" Darwin failed
check "empty top output shows absence" "CPU: --" Darwin empty
check "a partial sample from failing top shows absence" "CPU: --" Darwin partial
check "a CPU line with missing numbers shows absence" "CPU: --" Darwin missing
check "non-numeric CPU readings show themed absence" "💻 --" Darwin invalid default
check "a measured zero from top stays zero" "CPU: 0% [OK]" Darwin zero
LC_ALL=C check "fractional top readings round in the C locale" "CPU: 18% [OK]" Darwin fractional
comma_locale=$(
    locale -a | while IFS= read -r candidate; do
        if [ "$(LC_ALL="$candidate" locale decimal_point 2>/dev/null)" = "," ]; then
            printf '%s\n' "$candidate"
            break
        fi
    done
)
if [ -n "$comma_locale" ]; then
    LC_ALL="$comma_locale" check "fractional top readings round in a comma-decimal locale" \
        "CPU: 18% [OK]" Darwin fractional
else
    printf 'SKIP: no installed comma-decimal locale\n'
fi
check "empty Linux procfs shows absence" "CPU: --" Linux linux-empty
check "the first Linux CPU sample shows absence" "CPU: --" Linux linux-first
check "a measured zero Linux CPU delta stays zero" "CPU: 0% [OK]" Linux linux-zero
recovered=$'CPU: --\nCPU: 0% [OK]'
check "an empty baseline shows absence then a measured zero" "$recovered" Linux linux-empty-baseline
check "a truncated baseline shows absence then a measured zero" "$recovered" Linux linux-truncated-baseline
check "a truncated current sample shows absence and preserves the baseline" "$recovered" Linux linux-truncated-current

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
