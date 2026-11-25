#!/bin/bash
# Render process counts from a ps snapshot controlled by the test.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain-comma
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir "$TEST_BASE/bin"
cat > "$TEST_BASE/bin/ps" <<'STUB'
#!/bin/bash
case "$TEST_PS" in
    empty) exit 0 ;;
    failed) exit 1 ;;
esac
printf 'USER PID %%CPU %%MEM VSZ RSS TT STAT STARTED TIME COMMAND\n'
case "$TEST_PS" in
    partial) exit 1 ;;
    sleeping) printf '%s\n' 'user 1 0 0 0 0 ?? S 0 0 mock' ;;
    present)
        printf '%s\n' 'user 1 0 0 0 0 ?? R 0 0 mock' 'user 2 0 0 0 0 ?? S 0 0 mock'
        ;;
esac
STUB
chmod +x "$TEST_BASE/bin/"*

render() (
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX")
    # The fixture must also work with a group-writable default umask.
    umask 002
    printf '%s\n' 'MODULE_ORDER="processes"' 'MODULE_PROCESSES="true"' \
        'COLOR_THEME="monochrome"' 'PROC_SHOW_RUNNING="true"' 'PROC_SHOW_STATUS="true"' \
        'TERMINAL_WIDTH=200' > "$sb/cortado.conf"
    # Select the ps path without changing the platform used for config loading.
    cat >> "$sb/cortado.conf" <<'CONFIG'
uname() {
    if [ "${FUNCNAME[1]:-}" = module_processes ]; then
        printf '%s\n' Darwin
    else
        command uname "$@"
    fi
}
CONFIG
    chmod 600 "$sb/cortado.conf" || exit 1
    printf '%s' '{"cwd":"/nonexistent"}' | PATH="$TEST_BASE/bin:$PATH" TEST_PS="$1" \
        CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1
)

check() {
    local desc="$1" expected="$2" actual
    actual=$(render "$3")
    assert_eq "$desc" "$expected" "$actual"
}

check "failing ps shows absence" "PROC: --" failed
check "successful but silent ps shows absence" "PROC: --" empty
check "partial output from failing ps shows absence" "PROC: --" partial
check "a header-only snapshot shows absence" "PROC: --" header
check "a sleeping process is a measured zero running" "PROC: 0/1 [OK]" sleeping
check "a measured process count still shows running and total" "PROC: 1/2 [OK]" present

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
