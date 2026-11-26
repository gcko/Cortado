#!/bin/bash
# ABOUTME: Tests for modules/uptime.sh. format_uptime is the pure seconds->string formatter: it
# ABOUTME: cascades days->hours->mins and renders each style distinctly (short shows the two
# ABOUTME: coarsest non-zero units, long spells them out, days collapses to "Nd" or "Nh"). The
# ABOUTME: render tests drive cortado.sh and check that a failed probe shows "UP: --".
# ABOUTME: Run with: bash tests/test_uptime.sh
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" uptime

# Load the module under test. format_uptime is pure (integer arithmetic + echo, no I/O).
# shellcheck source=modules/uptime.sh
. "$PROJECT_ROOT/modules/uptime.sh"

# 90061s = 1d 1h 1m 1s ; 3661s = 1h 1m 1s ; 61s = 1m 1s
# short (default): the two coarsest non-zero units, finer units dropped
assert_eq "short: 1d1h1m -> 1d 1h"      "1d 1h" "$(format_uptime 90061 short)"
assert_eq "short is the default style"  "1d 1h" "$(format_uptime 90061)"
assert_eq "short: 1h1m -> 1h 1m"        "1h 1m" "$(format_uptime 3661 short)"
assert_eq "short: under an hour -> 1m"  "1m"    "$(format_uptime 61 short)"

# long: units spelled out
assert_eq "long: days + hours"          "1 days, 1 hours" "$(format_uptime 90061 long)"
assert_eq "long: hours + mins"          "1 hours, 1 mins" "$(format_uptime 3661 long)"
assert_eq "long: mins only"             "1 mins"          "$(format_uptime 61 long)"

# days: collapses to whole days, or hours when under a day
assert_eq "days: >=1 day -> Nd"         "1d" "$(format_uptime 90061 days)"
assert_eq "days: <1 day falls to Nh"    "1h" "$(format_uptime 3661 days)"

# macOS reads the boot time from sysctl kern.boottime.
RENDER_OS=darwin
cat > "$TEST_BASE/bin/sysctl" <<'STUB'
#!/bin/bash
[ "$*" = "-n kern.boottime" ] || exit 2
now=$(/bin/date +%s)
case "$TEST_SAMPLE" in
    normal) printf '{ sec = %s, usec = 0 } Mon Jan  1 00:00:00 2024\n' "$((now - 90061))" ;;
    future) printf '{ sec = %s, usec = 0 } Mon Jan  1 00:00:00 2024\n' "$((now + 3600))" ;;
    garbage) printf '%s\n' '{ sec = soon, usec = 0 }' ;;
    *) exit 1 ;;
esac
STUB
chmod 700 "$TEST_BASE/bin/sysctl"
check_render 'uptime shows the time since boot on macOS' 'UP: 1d 1h' normal
check_render 'uptime shows absence when sysctl fails on macOS' 'UP: --' failed
check_render 'uptime shows absence for a non-numeric boot time' 'UP: --' garbage
check_render 'uptime shows absence for a boot time in the future' 'UP: --' future

# UPTIME_SHOW_LOAD appends the 1-minute load average from uptime(1).
cat > "$TEST_BASE/bin/uptime" <<'STUB'
#!/bin/bash
case "$TEST_LOAD" in
    normal) printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1.25 0.75 0.50' ;;
    malformed) printf '%s\n' '10:00  up 1 day, 1 user' ;;
    garbage) printf '%s\n' '10:00  up 1 day, 1 user, load averages: n/a' ;;
    locale)
        if [ "${LC_ALL:-}" = C ]; then
            printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1.25 0.75 0.50'
        else
            printf '%s\n' '10:00  up 1 day, 1 user, load averages: 1,25 0,75 0,50'
        fi ;;
    *) exit 1 ;;
esac
STUB
chmod 700 "$TEST_BASE/bin/uptime"
TEST_LOAD=normal check_render 'uptime shows the load average when asked' 'UP: 1d 1h [1.25]' normal '' 'UPTIME_SHOW_LOAD=true'
TEST_LOAD=failed check_render 'uptime marks a missing load average when uptime fails' 'UP: 1d 1h [--]' normal '' 'UPTIME_SHOW_LOAD=true'
TEST_LOAD=malformed check_render 'uptime marks a missing load average when uptime prints none' 'UP: 1d 1h [--]' normal '' 'UPTIME_SHOW_LOAD=true'
TEST_LOAD=garbage check_render 'uptime marks a non-numeric load average as missing' 'UP: 1d 1h [--]' normal '' 'UPTIME_SHOW_LOAD=true'
TEST_LOAD=failed check_render 'uptime without load enabled shows no load part' 'UP: 1d 1h' normal ''
# Exporting a locale from the config is Bash, so it needs the environment's opt-in (#33).
CORTADO_CONF_ALLOW_BASH=1 TEST_LOAD=locale check_render 'uptime reads the load average independently of the caller locale' \
    'UP: 1d 1h [1.25]' normal '' 'UPTIME_SHOW_LOAD=true' 'export LC_ALL=POSIX'

# Linux reads /proc/uptime. The cut stub stands in for it on every host.
RENDER_OS=linux
cat > "$TEST_BASE/bin/cut" <<'STUB'
#!/bin/bash
if [ "${!#}" = /proc/uptime ]; then
    case "$TEST_SAMPLE" in
        normal) printf '%s\n' 90061 ;;
        garbage) printf '%s\n' 'n/a' ;;
        *) exit 1 ;;
    esac
    exit 0
fi
exec /usr/bin/cut "$@"
STUB
chmod 700 "$TEST_BASE/bin/cut"
check_render 'uptime shows the time since boot on Linux' 'UP: 1d 1h' normal
check_render 'uptime shows absence when /proc/uptime is unreadable' 'UP: --' failed
check_render 'uptime shows absence for a non-numeric /proc/uptime' 'UP: --' garbage

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
