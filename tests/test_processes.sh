#!/bin/bash
# Render process counts from controlled ps and procfs fixtures.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir -m 700 "$TEST_BASE/bin" "$TEST_BASE/proc" "$TEST_BASE/runtime"
cp -R "$PROJECT_ROOT/modules" "$PROJECT_ROOT/lib" "$PROJECT_ROOT/cortado.sh" \
    "$PROJECT_ROOT/cortado.conf" "$PROJECT_ROOT/VERSION" "$TEST_BASE/runtime/"
# Redirect only the procfs root. Let Bash expand real paths in the fixture.
# shellcheck disable=SC2016
sed -e 's|"/proc"|"$TEST_PROC"|g' -e 's|/proc\([/ ]\)|"$TEST_PROC"\1|g' \
    "$PROJECT_ROOT/modules/processes.sh" > "$TEST_BASE/runtime/modules/processes.sh"
cat > "$TEST_BASE/bin/ps" <<'STUB'
#!/bin/bash
[ "$*" = '-A -o state=' ] || exit 2
case "$TEST_PS" in
    empty) exit 0 ;;
    failed) exit 1 ;;
    partial) printf '%s\n' R; exit 1 ;;
    header) printf '%s\n' STATE ;;
    sleeping) printf '%s\n' S ;;
    unclassified) printf '%s\n' '?+' R S ;;
    present) printf '%s\n' R S ;;
esac
STUB
cat > "$TEST_BASE/bin/grep" <<'STUB'
#!/bin/bash
if [ "$TEST_PS" = newcomer ] && [ ! -d "$TEST_PROC/3" ]; then
    mkdir "$TEST_PROC/3"
    printf 'State:\tS (sleeping)\n' > "$TEST_PROC/3/status"
fi
exec /usr/bin/grep "$@"
STUB
chmod +x "$TEST_BASE/bin/"*

render() (
    local sb platform="${2:-darwin}"
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX")
    # The fixture must also work with a group-writable default umask.
    umask 002
    printf '%s\n' 'MODULE_ORDER="processes"' 'MODULE_PROCESSES="true"' \
        'COLOR_THEME="monochrome"' 'PROC_SHOW_RUNNING="true"' 'PROC_SHOW_STATUS="true"' \
        'TERMINAL_WIDTH=200' > "$sb/cortado.conf"
    # Select the process probe; config permission checks stay on the host OS.
    printf 'CORTADO_OS=%s\n' "$platform" >> "$sb/cortado.conf"
    if [ "${3:-}" = running-only ]; then
        printf '%s\n' 'PROC_SHOW_TOTAL="false"' >> "$sb/cortado.conf"
    fi
    chmod 600 "$sb/cortado.conf" || exit 1
    local i
    export PATH="$TEST_BASE/bin:$PATH" TEST_PS="$1" TEST_PROC="$TEST_BASE/proc"
    export CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache"
    render_sample >/dev/null || return 1
    for ((i=0; i<60; i++)); do
        if [ -s "$CACHE_DIR/processes-running" ] || [ -s "$CACHE_DIR/processes-running-failed" ]; then break; fi
        sleep 0.05
    done
    [ "$i" -lt 60 ] || return 1
    render_sample
)

render_sample() {
    set -o pipefail
    printf '%s' '{"cwd":"/nonexistent"}' | /bin/bash "$TEST_BASE/runtime/cortado.sh" 2>&1 |
        sed $'s/\x1b\\[[0-9;]*m//g'
}

check() {
    local desc="$1" expected="$2" platform="${4:-darwin}" actual
    actual=$(render "$3" "$platform" "${5:-}") || { fail "$desc (refresh failed)"; return; }
    assert_eq "$desc" "$expected" "$actual"
}

check "failing ps shows absence" "PROC: --" failed
check "successful but silent ps shows absence" "PROC: --" empty
check "partial output from failing ps shows absence" "PROC: --" partial
check "a snapshot with no process states shows absence" "PROC: --" header
check "a sleeping process is a measured zero running" "PROC: 0/1 [OK]" sleeping
check "a measured process count still shows running and total" "PROC: 1/2 [OK]" present

# Both procfs cases have a working ps fallback that would show 1/2.
check "empty Linux procfs shows absence" "PROC: --" present linux
mkdir "$TEST_BASE/proc/1"
printf 'State:\tR (running)\n' > "$TEST_BASE/proc/1/status"
check "Linux procfs shows one running PID and one total" "PROC: 1/1 [OK]" present linux
check "the count pipeline adds no transient PID to the total" "PROC: 1/1 [OK]" transient linux
ln -s 1 "$TEST_BASE/proc/self"
ln -s 1 "$TEST_BASE/proc/thread-self"
check "Linux procfs ignores self aliases when counting PIDs" "PROC: 1/1 [OK]" present linux
rm "$TEST_BASE/proc/self" "$TEST_BASE/proc/thread-self"
printf 'State:\tS (sleeping)\n' > "$TEST_BASE/proc/1/status"
check "Linux procfs shows measured zero running" "PROC: 0/1 [OK]" present linux

rm "$TEST_BASE/proc/1/status"
# A directory in place of the status file forces a read error even as root.
mkdir "$TEST_BASE/proc/1/status"
check "an unreadable PID status makes the Linux running count unknown" "PROC: --/1 [OK]" present linux
check "an unknown running-only count shows absence without a badge" "PROC: --" present linux running-only
mkdir "$TEST_BASE/proc/2"
printf 'State:\tR (running)\n' > "$TEST_BASE/proc/2/status"
check "a partial read with a running match still shows unknown" "PROC: --/2 [OK]" present linux
rmdir "$TEST_BASE/proc/1/status"
check "a vanished PID status makes the Linux running count unknown" "PROC: --/2 [OK]" present linux

printf 'State:\tS (sleeping)\n' > "$TEST_BASE/proc/2/status"
check "a later arrival cannot replace an unreadable PID in the snapshot" "PROC: --/2 [OK]" newcomer linux

check 'a Darwin process with an unclassified state still contributes to total' 'PROC: 1/3 [OK]' unclassified
# A cached reading is shown only if the probe could have published it: a
# positive total of at most ten digits, and a running count no larger.
render_cached() (
    local sb
    sb=$(mktemp -d "$TEST_BASE/cached.XXXXXX") || exit 1
    mkdir -m 700 "$sb/cortado-cache" || exit 1
    printf '%s\n' 'MODULE_ORDER="processes"' 'MODULE_PROCESSES="true"' \
        'COLOR_THEME="monochrome"' 'PROC_SHOW_RUNNING="true"' 'PROC_SHOW_STATUS="true"' \
        'TERMINAL_WIDTH=200' > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf" || exit 1
    (umask 077; printf '%s\n' "$1" > "$sb/cortado-cache/processes-running")
    # The seeded entry is fresh, so the render starts no probe.
    CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" render_sample
)

check_cached() {
    assert_eq "$1" "$2" "$(render_cached "$3")"
}
check_cached 'a valid cached reading is displayed' 'PROC: 3/12 [OK]' '12 3'
check_cached 'a cached unknown running count beside a total is displayed' 'PROC: --/12 [OK]' '12 --'
check_cached 'a cached zero total is absence' 'PROC: --' '0 --'
check_cached 'a cached running count above the total is absence' 'PROC: --' '5 10'
check_cached 'a cached total beyond ten digits is absence' 'PROC: --' '9999999999999999999999 1'
check_cached 'a cached running count beyond ten digits is absence' 'PROC: --' '12 9999999999999999999999'
check_cached 'a cached total with a leading zero is absence' 'PROC: --' '012 3'
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
