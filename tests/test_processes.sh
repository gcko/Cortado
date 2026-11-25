#!/bin/bash
# Render process counts from controlled ps and procfs fixtures.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir "$TEST_BASE/bin" "$TEST_BASE/proc" "$TEST_BASE/runtime"
cp -R "$PROJECT_ROOT/modules" "$PROJECT_ROOT/lib" "$PROJECT_ROOT/cortado.sh" \
    "$PROJECT_ROOT/cortado.conf" "$PROJECT_ROOT/VERSION" "$TEST_BASE/runtime/"
# Redirect only the procfs root. Let Bash expand real paths in the fixture.
# shellcheck disable=SC2016
sed -e 's|"/proc"|"$TEST_PROC"|g' -e 's|/proc\([/ ]\)|"$TEST_PROC"\1|g' \
    "$PROJECT_ROOT/modules/processes.sh" > "$TEST_BASE/runtime/modules/processes.sh"
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
        cat >> "$sb/cortado.conf" <<'CONFIG'
ls() {
    if [[ "${FUNCNAME[1]:-}" == module_processes && "$1" == -d ]]; then
        case "$TEST_PS" in
            transient)
                mkdir "$TEST_PROC/2"
                printf 'State:\tS (sleeping)\n' > "$TEST_PROC/2/status"
                command ls "$@" "$TEST_PROC/2"
                return ;;
            newcomer)
                command ls "$@"
                add_newcomer
                return ;;
        esac
    fi
    command ls "$@"
}

wc() {
    command wc "$@"
    if [[ "${FUNCNAME[1]:-}" == module_processes && "$TEST_PS" == transient ]]; then
        rm "$TEST_PROC/2/status"
        rmdir "$TEST_PROC/2"
    fi
}

add_newcomer() {
    mkdir "$TEST_PROC/3"
    printf 'State:\tS (sleeping)\n' > "$TEST_PROC/3/status"
}

grep() {
    if [[ "${FUNCNAME[1]:-}" == module_processes && "$TEST_PS" == newcomer && ! -d "$TEST_PROC/3" ]]; then
        add_newcomer
    fi
    command grep "$@"
}
CONFIG
    fi
    if [ "${3:-}" = running-only ]; then
        printf '%s\n' 'PROC_SHOW_TOTAL="false"' >> "$sb/cortado.conf"
    fi
    chmod 600 "$sb/cortado.conf" || exit 1
    printf '%s' '{"cwd":"/nonexistent"}' | PATH="$TEST_BASE/bin:$PATH" TEST_PS="$1" \
        TEST_OS="$platform" TEST_PROC="$TEST_BASE/proc" \
        CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" /bin/bash "$TEST_BASE/runtime/cortado.sh" 2>&1 \
        | sed $'s/\x1b\[[0-9;]*m//g'
)

check() {
    local desc="$1" expected="$2" platform="${4:-Darwin}" actual
    actual=$(render "$3" "$platform" "${5:-}")
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
check "the count pipeline adds no transient PID to the total" "PROC: 1/1 [OK]" transient Linux
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
check "an unknown running-only count shows absence without a badge" "PROC: --" present Linux running-only
mkdir "$TEST_BASE/proc/2"
printf 'State:\tR (running)\n' > "$TEST_BASE/proc/2/status"
check "a partial read with a running match still shows unknown" "PROC: --/2 [OK]" present Linux
rmdir "$TEST_BASE/proc/1/status"
check "a vanished PID status makes the Linux running count unknown" "PROC: --/2 [OK]" present Linux

printf 'State:\tS (sleeping)\n' > "$TEST_BASE/proc/2/status"
check "a later arrival cannot replace an unreadable PID in the snapshot" "PROC: --/2 [OK]" newcomer Linux

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
