#!/bin/bash
# Render CPU usage from controlled macOS and Linux probe output.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir "$TEST_BASE/bin"
cat > "$TEST_BASE/bin/iostat" <<'STUB'
#!/bin/bash
[ "$*" = '-d -C -n 0 -c 2 -w 1' ] || exit 2
case "$TEST_SAMPLE" in
    failed) exit 1 ;;
    empty) exit 0 ;;
esac
# The since-boot reading is deliberately different from the live reading.
printf '%s\n' 'cpu' 'us sy id' '50 25 25'
case "$TEST_SAMPLE" in
    missing) exit 0 ;;
    invalid) printf '%s\n' '-- -- --' ;;
    zero-interval) printf '%s\n' '0 0 0' ;;
    invalid-busy) printf '%s\n' '101 0 0' ;;
    excess-total) printf '%s\n' '1 1 100' ;;
    invalid-idle) printf '%s\n' '0 0 101' ;;
    rounded) printf '%s\n' '12 5 82' ;;
    normal) printf '%s\n' '13 5 82' ;;
    zero|partial) printf '%s\n' '0 0 100' ;;
esac
[ "$TEST_SAMPLE" != partial ]
STUB
cat > "$TEST_BASE/bin/grep" <<'STUB'
#!/bin/bash
if [ "${2:-}" = /proc/stat ]; then
    if [ -f "$CLAUDE_CONFIG_DIR/first-read" ]; then
        exec /usr/bin/grep "$1" "$CLAUDE_CONFIG_DIR/stat-after"
    fi
    : > "$CLAUDE_CONFIG_DIR/first-read"
    exec /usr/bin/grep "$1" "$CLAUDE_CONFIG_DIR/stat-before"
fi
exec /usr/bin/grep "$@"
STUB
cat > "$TEST_BASE/bin/sleep" <<'STUB'
#!/bin/bash
if [ "${TEST_OS:-}" = Linux ] && [ "$*" = 1 ]; then exit 0; fi
exec /bin/sleep "$@"
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
    case "$2" in
        linux-empty) : > "$sb/stat-before" ;;
        linux-truncated-first) printf 'cpu 1 0\n' > "$sb/stat-before" ;;
        *) printf 'cpu 10 0 4 20\n' > "$sb/stat-before" ;;
    esac
    case "$2" in
        linux-truncated-second) printf 'cpu 1 0\n' > "$sb/stat-after" ;;
        linux-backwards) printf 'cpu 9 0 6 40\n' > "$sb/stat-after" ;;
        linux-no-delta) cp "$sb/stat-before" "$sb/stat-after" ;;
        *) printf 'cpu 10 0 4 40\n' > "$sb/stat-after" ;;
    esac
    export PATH="$TEST_BASE/bin:$PATH" TEST_OS="$1" TEST_SAMPLE="$2"
    export CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache"
    local i
    if [ "$2" = corrupt ]; then (umask 077; printf '999\n' > "$CACHE_DIR/cpu"); fi
    render_sample >/dev/null || return 1
    for ((i=0; i<60; i++)); do
        if [ -s "$CACHE_DIR/cpu" ] || [ -s "$CACHE_DIR/cpu-failed" ]; then break; fi
        sleep 0.05
    done
    [ "$i" -lt 60 ] || return 1
    if [ "$2" = invalid-busy ] && [ -s "$CACHE_DIR/cpu" ]; then
        cp "$CACHE_DIR/cpu" "$TEST_BASE/invalid-busy.cache"
    fi
    render_sample
)

render_sample() {
    printf '%s' '{"cwd":"/nonexistent"}' | /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1
}

check() {
    local desc="$1" expected="$2" actual
    actual=$(render "$3" "$4" "${5:-monochrome}") || { fail "$desc (refresh failed)"; return; }
    assert_eq "$desc" "$expected" "$actual"
}

check "failing iostat shows absence" "CPU: --" Darwin failed
check "empty iostat output shows absence" "CPU: --" Darwin empty
check "a partial sample from failing iostat shows absence" "CPU: --" Darwin partial
check "a CPU line with missing numbers shows absence" "CPU: --" Darwin missing
check "non-numeric CPU readings show themed absence" "💻 --" Darwin invalid default
check "a measured zero from iostat stays zero" "CPU: 0% [OK]" Darwin zero
LC_ALL=C check "the interval sample is used in the C locale" "CPU: 18% [OK]" Darwin normal
comma_locale=$(
    locale -a | while IFS= read -r candidate; do
        if [ "$(LC_ALL="$candidate" locale decimal_point 2>/dev/null)" = "," ]; then
            printf '%s\n' "$candidate"
            break
        fi
    done
)
if [ -n "$comma_locale" ]; then
    LC_ALL="$comma_locale" check "the interval sample is used in a comma-decimal locale" \
        "CPU: 18% [OK]" Darwin normal
else
    printf 'SKIP: no installed comma-decimal locale\n'
fi
check "empty Linux procfs shows absence" "CPU: --" Linux linux-empty
check "a measured zero Linux CPU delta stays zero" "CPU: 0% [OK]" Linux linux-zero
check "a truncated first Linux sample shows absence" "CPU: --" Linux linux-truncated-first
check "a truncated second Linux sample shows absence" "CPU: --" Linux linux-truncated-second
check "a counter reset does not produce a reassuring zero" "CPU: --" Linux linux-backwards
check "no change in Linux counters shows absence" "CPU: --" Linux linux-no-delta

check 'unaccounted iostat CPU time does not report a healthy zero' 'CPU: --' Darwin zero-interval
check 'an out of range busy total invalidates the interval' 'CPU: --' Darwin invalid-busy
assert_eq 'an out of range busy total cannot populate the cache' '' "$(cat "$TEST_BASE/invalid-busy.cache" 2>/dev/null)"
check 'an excessive sum invalidates the interval' 'CPU: --' Darwin excess-total
check 'an out of range idle column invalidates the interval' 'CPU: --' Darwin invalid-idle
check 'integer rounding in an iostat interval preserves the reading' 'CPU: 17% [OK]' Darwin rounded
check 'a corrupt cached CPU percentage does not display' 'CPU: --' Darwin corrupt
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
