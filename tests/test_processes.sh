#!/bin/bash
# Render process counts from controlled ps and procfs fixtures.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir "$TEST_BASE/bin" "$TEST_BASE/proc"
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
    local sb platform="${2:-Darwin}"
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX")
    # The fixture must also work with a group-writable default umask.
    umask 002
    printf '%s\n' 'MODULE_ORDER="processes"' 'MODULE_PROCESSES="true"' \
        'COLOR_THEME="monochrome"' 'PROC_SHOW_RUNNING="true"' 'PROC_SHOW_STATUS="true"' \
        'TERMINAL_WIDTH=200' > "$sb/cortado.conf"
    # Select the process probe without changing the platform for config loading.
    cat >> "$sb/cortado.conf" <<'CONFIG'
uname() {
    if [ "${FUNCNAME[1]:-}" = module_processes ]; then
        printf '%s\n' "$TEST_OS"
    else
        command uname "$@"
    fi
}
CONFIG
    if [ "$platform" = Linux ]; then
        # Redirect both the directory check and the reads away from the host's /proc.
        cat >> "$sb/cortado.conf" <<'CONFIG'
function [ {
    if [[ "${FUNCNAME[1]:-}" == module_processes && $# == 3 &&
          "$1" == -d && "$2" == /proc ]]; then
        builtin [ -d "$TEST_PROC" ]
    else
        builtin [ "$@"
    fi
}

ls() {
    if [[ "$1" == -d && "${2:-}" == /proc/* ]]; then
        command ls -d "$TEST_PROC"/[0-9]*
    else
        command ls "$@"
    fi
}

grep() {
    if [[ ( "$1" == -lE || "$1" == -cE ) && "${3:-}" == /proc/*/status ]]; then
        local status
        for status in "${@:3}"; do
            case "$status" in
                '/proc/*/status'|/proc/self/status|/proc/thread-self/status)
                    command grep "$1" "$2" "$TEST_PROC"/*/status
                    return ;;
            esac
        done
        command grep "$1" "$2" "$TEST_PROC"/[0-9]*/status
    else
        command grep "$@"
    fi
}
CONFIG
    fi
    chmod 600 "$sb/cortado.conf" || exit 1
    printf '%s' '{"cwd":"/nonexistent"}' | PATH="$TEST_BASE/bin:$PATH" TEST_PS="$1" \
        TEST_OS="$platform" TEST_PROC="$TEST_BASE/proc" \
        CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1
)

check() {
    local desc="$1" expected="$2" platform="${4:-Darwin}" actual
    actual=$(render "$3" "$platform")
    if [ "$platform" = Linux ]; then
        # BSD wc pads the running and total counts in the procfs branch.
        actual=$(printf '%s\n' "$actual" | sed -E 's@^PROC: +([0-9]+|--)/ *([0-9]+) @PROC: \1/\2 @')
    fi
    assert_eq "$desc" "$expected" "$actual"
}

check "failing ps shows absence" "PROC: --" failed
check "successful but silent ps shows absence" "PROC: --" empty
check "partial output from failing ps shows absence" "PROC: --" partial
check "a header-only snapshot shows absence" "PROC: --" header
check "a sleeping process is a measured zero running" "PROC: 0/1 [OK]" sleeping
check "a measured process count still shows running and total" "PROC: 1/2 [OK]" present

# Both procfs cases have a working ps fallback that would show 1/2.
check "empty Linux procfs shows absence" "PROC: --" present Linux
mkdir "$TEST_BASE/proc/1"
printf 'State:\tR (running)\n' > "$TEST_BASE/proc/1/status"
check "Linux procfs shows one running PID and one total" "PROC: 1/1 [OK]" present Linux
ln -s 1 "$TEST_BASE/proc/self"
ln -s 1 "$TEST_BASE/proc/thread-self"
check "Linux procfs ignores self aliases when counting PIDs" "PROC: 1/1 [OK]" present Linux
rm "$TEST_BASE/proc/self" "$TEST_BASE/proc/thread-self"
printf 'State:\tS (sleeping)\n' > "$TEST_BASE/proc/1/status"
check "Linux procfs shows measured zero running" "PROC: 0/1 [OK]" present Linux

rm "$TEST_BASE/proc/1/status"
# A directory in place of the status file forces a read error even as root.
mkdir "$TEST_BASE/proc/1/status"
check "an unreadable PID status makes the Linux running count unknown" "PROC: --/1 [OK]" present Linux
mkdir "$TEST_BASE/proc/2"
printf 'State:\tR (running)\n' > "$TEST_BASE/proc/2/status"
check "a partial read with a running match still shows unknown" "PROC: --/2 [OK]" present Linux
rmdir "$TEST_BASE/proc/1/status"
check "a vanished PID status makes the Linux running count unknown" "PROC: --/2 [OK]" present Linux

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
