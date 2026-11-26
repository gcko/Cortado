#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" load

RENDER_OS=Darwin
cat > "$TEST_BASE/bin/sysctl" <<'STUB'
#!/bin/bash
[ "$*" = "-n hw.ncpu" ] || exit 2
printf '%s\n' 4
STUB
chmod +x "$TEST_BASE/bin/sysctl"
cat > "$TEST_BASE/bin/uptime" <<'STUB'
#!/bin/bash
case "$TEST_SAMPLE" in
    normal)
        if [ "$LC_ALL" = C ]; then
            printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1.25 0.75 0.50'
        else
            printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1,25 0,75 0,50'
        fi ;;
    high) printf '%s\n' '10:00  up 1 day, 1 user, load averages: 16.00 12.00 10.00' ;;
    partial) printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1.25 n/a' ;;
    malformed) printf '%s\n' '10:00  up 1 day, 1 user, load averages: n/a' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/uptime"

check_load() {
    local desc="$1" expected="$2" sample="$3" payload="$4" sb i
    shift 4
    sb=$(mktemp -d "$TEST_BASE/probe.XXXXXX") || exit 1
    render "$sample" "$payload" "CLAUDE_CONFIG_DIR='$sb'" "$@" >/dev/null || {
        fail "$desc (cold render failed)"
        return
    }
    for ((i=0; i<60; i++)); do
        if [ -s "$sb/cortado-cache/load" ] || [ -s "$sb/cortado-cache/load-failed" ]; then break; fi
        sleep 0.05
    done
    [ "$i" -lt 60 ] || { fail "$desc (probe did not publish)"; return; }
    check_render "$desc" "$expected" "$sample" "$payload" "CLAUDE_CONFIG_DIR='$sb'" "$@"
}

check_load 'load shows the measured averages and status' 'LOAD: 1.25 0.75 0.50 [OK]' \
    normal '' 'LOAD_SHOW_ALL="true"'
check_load 'load shows absence when uptime fails' 'LOAD: --' failed '' 'LOAD_SHOW_ALL="true"'
check_load 'load shows absence for an unusable reading' 'LOAD: --' malformed ''
check_load 'load shows absence for each missing average' 'LOAD: 1.25 -- -- [OK]' \
    partial '' 'LOAD_SHOW_ALL=true'
# POSIX is always available. The fixture uses commas for any caller locale other than C.
check_load 'load reads dot decimals independently of the caller locale' 'LOAD: 1.25 0.75 0.50 [OK]' \
    normal '' 'LOAD_SHOW_ALL=true' 'export LC_ALL=POSIX'
check_load 'load reports high status without bc' 'LOAD: 16.00 [CRIT]' \
    high '' 'bc() { return 1; }'
check_load 'load ignores malformed output from the unused bc' 'LOAD: 16.00 [CRIT]' \
    high '' 'bc() { printf "%s\n" unavailable; }'

sb=$(mktemp -d "$TEST_BASE/rounding.XXXXXX") || exit 1
mkdir -m 700 "$sb/cortado-cache"
(umask 077; printf '%s\n' '8 2.9599 -- --' > "$sb/cortado-cache/load")
check_render 'load just below the rounded threshold stays healthy' 'LOAD: 2.9599 [OK]' normal '' \
    "CLAUDE_CONFIG_DIR='$sb'" 'LOAD_WARNING_THRESHOLD=3 LOAD_CRITICAL_THRESHOLD=5'
(umask 077; printf '%s\n' '8 2.9600 -- --' > "$sb/cortado-cache/load")
check_render 'load at the rounded threshold warns' 'LOAD: 2.9600 [WARN]' normal '' \
    "CLAUDE_CONFIG_DIR='$sb'" 'LOAD_WARNING_THRESHOLD=3 LOAD_CRITICAL_THRESHOLD=5'
(umask 077; printf '%s\n' '8 2.97 -- --' > "$sb/cortado-cache/load")
check_render 'load in the same percentage bucket as the warning threshold warns' 'LOAD: 2.97 [WARN]' normal '' \
    "CLAUDE_CONFIG_DIR='$sb'" 'LOAD_WARNING_THRESHOLD=3 LOAD_CRITICAL_THRESHOLD=5'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
