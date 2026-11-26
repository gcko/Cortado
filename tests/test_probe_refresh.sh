#!/bin/bash
# Exercise cold, warm, failed and overlapping probe refreshes through the renderer.
set -u
set -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
section="${PROBE_TEST_SECTION:-all}"

# The sections are independent and spend most of their time waiting for
# 5 s refresh deadlines, so a full run starts each one as its own copy of
# this suite, with its own scratch directory, in PROBE_TEST_JOBS lanes
# (default 3). Sections are listed slowest first and dealt to lanes in turn.
if [ "$section" = all ]; then
    sections='locks deadline validation lifecycle setup clear publication local privacy resolution keys'
    # Every section this file tests must be in the list, or it would not run.
    # shellcheck disable=SC2016 # The pattern matches a literal $section.
    while IFS= read -r name; do
        case " all $sections " in
            *" $name "*) ;;
            *) fail "section $name is scheduled to run" ;;
        esac
    done < <(sed -nE 's/.*"\$section" = ([a-z]+) .*/\1/p' "${BASH_SOURCE[0]}")
    jobs="${PROBE_TEST_JOBS:-3}"
    case "$jobs" in ''|*[!0-9]*|0*) jobs=3 ;; esac
    lane=0
    lanes=()
    for name in $sections; do
        lanes[lane]="${lanes[lane]:-} $name"
        lane=$(((lane + 1) % jobs))
    done
    for lane in "${lanes[@]}"; do
        (
            for name in $lane; do
                PROBE_TEST_SECTION=$name /bin/bash "${BASH_SOURCE[0]}" > "$scratch/$name.out" 2>&1
                printf '%s\n' "$?" > "$scratch/$name.status"
            done
        ) &
    done
    wait
    for name in $sections; do
        printf '== %s\n' "$name"
        cat "$scratch/$name.out" 2>/dev/null
        results=$(sed -nE 's/^Results: ([0-9]+) passed, ([0-9]+) failed$/\1 \2/p' "$scratch/$name.out" 2>/dev/null)
        if [ -n "$results" ]; then
            PASS=$((PASS + ${results% *}))
            FAIL=$((FAIL + ${results#* }))
        fi
        if [ -z "$results" ] || [ "$(cat "$scratch/$name.status" 2>/dev/null)" != 0 ]; then
            fail "section $name reports its results and exits cleanly"
        fi
    done
    printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
    exit
fi
mkdir "$scratch/bin" "$scratch/workspace" || exit 1
cd "$scratch/workspace" || exit 1
export LC_NUMERIC=C REAL_PERL
REAL_PERL=$(command -v perl) || exit 1
export PATH="$scratch/bin:$PATH"

cat > "$scratch/bin/perl" <<'STUB'
#!/bin/bash
case "${2:-}" in
    -MPOSIX=setsid*)
        printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/supervisor.pid"
        if [ "${TEST_SAMPLE:-}" = delayed ]; then
            printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/delayed.pid"
            for ((i=0; i<80; i++)); do
                [ ! -f "$CLAUDE_CONFIG_DIR/release" ] || break
                sleep 0.05
            done
        fi
        ;;
esac
if [ "${TEST_SAMPLE:-}" = broken-snapshot ] && [ "${1:-}" = -MFcntl=:mode ]; then
    exit 1
fi
# Leave the probe half a microsecond of its deadline: the third monotonic
# reading (the probe's bounded() call) lands just before the deadline.
if [ "${TEST_SAMPLE:-}" = tiny-deadline ] && [[ "${2:-}" == -MPOSIX=setsid* ]]; then
    shift 3
    exec "$REAL_PERL" -MFcntl=:DEFAULT,:flock,:mode -MPOSIX=setsid,setpgid,_exit \
        -MTime::HiRes=alarm,CLOCK_MONOTONIC -e '
        BEGIN {
            my ($calls, $start) = (0);
            *main::clock_gettime = sub {
                my $now = Time::HiRes::clock_gettime(@_);
                $start = $now unless defined $start;
                return ++$calls == 3 ? $start + 4.9999995 : $now;
            };
        }
    ' "$@"
fi
exec "$REAL_PERL" "$@"
STUB
cat > "$scratch/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_CONFIG_DIR/curl.calls"
case "$TEST_SAMPLE" in
    weather-http)
        printf '%s\n' '☀️+72°F'
        case " $* " in *" -f "*) exit 22 ;; esac ;;
    weather-malformed) printf '%s\n' 'not weather' ;;
    weather-partial) printf '%s\n' '☀️+72°F'; exit 7 ;;
    oversized) printf '203.0.113.9%064d\n' 0 ;;
    oversized-weather) printf '☀️%1013s+72°F' ' ' ;;
    slow)
        printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/curl.pid"
        printf '%s\n' 'curl output'
        printf '%s\n' 'curl diagnostic' >&2
        # Outlast the renders until the test releases it. Unreleased, the
        # refresh deadline ends it at 5 s.
        for ((i=0; i<120; i++)); do
            [ ! -f "$CLAUDE_CONFIG_DIR/release" ] || break
            sleep 0.05
        done
        exit 28 ;;
    hang)
        printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/curl.pid"
        perl -e '
            my @target = stat($ARGV[0]);
            for my $fd (3..32) {
                open(my $fh, ">&", $fd) or next;
                my @file = stat($fh);
                if (@file && $file[0] == $target[0] && $file[1] == $target[1]) {
                    print "inherited\n";
                    last;
                }
            }
        ' "$CLAUDE_CONFIG_DIR/cortado-cache/weather-default-u-lock" > "$CLAUDE_CONFIG_DIR/curl.fd"
        perl -e '
            print "6\n" if open(my $read_end, "<&", 6);
            print "7\n" if open(my $write_end, ">&", 7);
        ' > "$CLAUDE_CONFIG_DIR/curl-payload-fds"
        printf 'ready\n' > "$CLAUDE_CONFIG_DIR/curl-fds-ready"
        exec sleep 25 ;;
    fail) exit 7 ;;
    http-error)
        printf '%s\n' 403
        case " $* " in *" -f "*) exit 22 ;; esac ;;
    http-error-ip)
        printf '%s\n' 203.0.113.9
        case " $* " in *" -f "*) exit 22 ;; esac ;;
    malformed) printf '%s\n' '999.0.0.7' ;;
    malformed-v6) printf '%s\n' '1234:::abcd' ;;
    multiline) printf '%s\n' '2001:db8::1' '2001:db8::2' ;;
    nul) printf '203.0.113.9\000garbage' ;;
    tiny-deadline)
        printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/curl.pid"
        exec sleep 20 ;;
    held|held-failure)
        printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/held.pid"
        for ((i=0; i<80; i++)); do
            [ ! -f "$CLAUDE_CONFIG_DIR/release" ] || break
            sleep 0.05
        done
        [ "$TEST_SAMPLE" != held-failure ] || exit 7
        printf '%s\n' '☀️+60°F' ;;
    normal|delayed|broken-publication|held-publication)
        case "${!#}" in
            *wttr.in*) printf '%s\n' '☀️+72°F' ;;
            https://ifconfig.me|https://icanhazip.com) printf '%s\n' '203.0.113.9' ;;
        esac ;;
    ipv6) printf '%s\n' '2001:db8::1' ;;
    freezing) printf '%s\n' '❄️-12°C' ;;
esac
STUB
cat > "$scratch/bin/mv" <<'STUB'
#!/bin/bash
case "${TEST_SAMPLE:-}:${!#}" in
    broken-publication:*/weather-default-u) exit 1 ;;
    held-publication:*/weather-default-u)
        printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/rename.pid"
        sleep 0.5 ;;
esac
if [ "${TEST_SAMPLE:-}" = stalled-write ] && [[ "${!#}" == */weather-default-u-failed ]]; then
    printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/writer.pid"
    exec sleep 25
fi
exec /bin/mv "$@"
STUB
chmod 700 "$scratch/bin/curl" "$scratch/bin/perl" "$scratch/bin/mv"

sandbox() {
    local order="$1"
    shift
    sb=$(mktemp -d "$scratch/render.XXXXXX") || exit 1
    mkdir -m 700 "$sb/cortado-cache" || exit 1
    printf '%s\n' "MODULE_ORDER=$order" 'COLOR_THEME=monochrome' 'TERMINAL_WIDTH=200' \
        'MODULE_WEATHER=true MODULE_NETWORK=true' 'NETWORK_SHOW_LAN=false NETWORK_SHOW_WAN=true' \
        "$@" > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf" || exit 1
    export CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache"
}

render() {
    local sample="$1" payload='{}'
    payload="${2:-$payload}"
    local TIMEFORMAT='%3R'
    { time printf '%s' "$payload" | LC_ALL=C TEST_SAMPLE="$sample" \
        /bin/bash "$PROJECT_ROOT/cortado.sh" > "$sb/output" 2> "$sb/stderr"; } 2> "$sb/elapsed"
}

render_is() {
    local desc="$1" expected="$2" sample="$3"
    shift 3
    if render "$sample" "$@"; then
        assert_eq "$desc" "$expected" "$(cat "$sb/output")"
    else
        fail "$desc (render failed)"
    fi
}

# A generous regression ceiling only. Whether a render waited for a probe is
# proved structurally (the probe is still running after the render returns);
# the 250 ms budget is measured over many samples in tests/render_timing.sh.
render_within_ceiling() {
    local elapsed
    elapsed=$(cat "$sb/elapsed")
    if LC_ALL=C awk -v elapsed="$elapsed" 'BEGIN {exit !(elapsed + 0 < 2)}'; then
        pass "$1 (${elapsed}s)"
    else
        fail "$1 (${elapsed}s)"
    fi
}

# The render returned while the background process was still running.
still_running() {
    local desc="$1" pid="$2"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

wait_for_file() {
    local path="$1" attempts="${2:-160}" stop="${3:-}" i
    for ((i=0; i<attempts; i++)); do
        [ ! -s "$path" ] || return 0
        [ -z "$stop" ] || [ ! -s "$stop" ] || return 1
        sleep 0.05
    done
    return 1
}

calls() {
    awk 'END {print NR+0}' "$sb/curl.calls" 2>/dev/null || printf 0
}

lock_is_free() {
    perl -MFcntl=:flock -e 'open my $lock, ">>", $ARGV[0] or exit 1; exit !flock($lock, LOCK_EX|LOCK_NB)' "$1"
}

wait_for_lock() {
    local i
    for ((i=0; i<50; i++)); do
        lock_is_free "$1" && return 0
        sleep 0.05
    done
    return 1
}

process_exits() {
    local pid="$1" attempts="${2:-150}" i
    for ((i=0; i<attempts; i++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.05
    done
    return 1
}

weather_failure() {
    if wait_for_file "$CACHE_DIR/weather-default-u-failed"; then
        pass "$1"
    else
        fail "$1"
    fi
}

if [[ "$section" = all || "$section" = lifecycle ]]; then
    sandbox weather
    render_is 'cold weather explicitly shows absence with missing input' '--' slow '{}'
    if wait_for_file "$sb/curl.pid"; then
        primary=$(cat "$sb/supervisor.pid")
        assert_eq 'the supervisor starts its own session and process group' "$primary" \
            "$(perl -e 'print getpgrp($ARGV[0])' "$primary")"
        if ! lock_is_free "$CACHE_DIR/weather-default-u-lock"; then
            pass 'the refresh holds its lock while curl is running'
        else
            fail 'the refresh holds its lock while curl is running'
        fi
    fi
    render_is 'a second render while curl runs returns weather absence' '--' slow '{"context_window":null}'
    still_running 'the second render returns while the sleeping curl still runs' "$(cat "$sb/curl.pid" 2>/dev/null)"
    if ! lock_is_free "$CACHE_DIR/weather-default-u-lock"; then
        pass 'the second render returns while the refresh still holds its lock'
    else
        fail 'the second render returns while the refresh still holds its lock'
    fi
    render_within_ceiling 'a second render during a sleeping curl stays under the 2 s ceiling'
    contender=
    for ((i=0; i<16; i++)); do
        contender=$(cat "$sb/supervisor.pid")
        [ "$contender" = "${primary:-}" ] || break
        sleep 0.05
    done
    if [ -n "$contender" ] && [ "$contender" != "${primary:-}" ] && process_exits "$contender" 12; then
        pass 'a contender exits promptly while the first refresh is active'
    else
        fail 'a contender exits promptly while the first refresh is active'
    fi
    assert_eq 'two renders start only one concurrent request' 1 "$(calls)"
    : > "$sb/release"
    weather_failure 'a failed request leaves a short-lived failure entry'
    previous_supervisor=$(cat "$sb/supervisor.pid")
    for payload in '{}' '{"context_window":{"used_percentage":0}}' '{"context_window":{"used_percentage":null}}'; do
        render_is 'a render during failure cooldown still shows absence' '--' slow "$payload"
        render_within_ceiling 'a render during failure cooldown stays under the 2 s ceiling'
    done
    assert_eq 'the failure entry suppresses further attempts until expiry' 1 "$(calls)"
    assert_eq 'renders during cooldown launch no worker' "$previous_supervisor" "$(cat "$sb/supervisor.pid")"
    assert_eq 'background curl stdout and stderr stay off the line' '' "$(cat "$sb/stderr")"

    if [ -f "$CACHE_DIR/weather-default-u-failed" ]; then
        touch -t 200001010000 "$CACHE_DIR/weather-default-u-failed"
    fi
    render_is 'an expired failure renders absence while retrying' '--' normal
    if wait_for_file "$CACHE_DIR/weather-default-u"; then
        render_is 'successful retry supplies fresh weather' '☀️ 72°F' normal
    fi
    assert_eq 'expiry allows a new request' 2 "$(calls)"
    if [ -f "$CACHE_DIR/weather-default-u" ]; then
        touch -t 200001010000 "$CACHE_DIR/weather-default-u"
    fi
    rm -f "$CACHE_DIR/weather-default-u-failed"
    render_is 'expired weather does not read as current' '--' fail
    weather_failure 'a failed refresh of stale weather records failure'

    sandbox weather
    printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather-default-u"
    perl -e 'my $future = time + 3600; utime $future, $future, $ARGV[0]' "$CACHE_DIR/weather-default-u"
    render_is 'a future-dated cache entry does not read as current' '--' fail
    weather_failure 'a future-dated cache entry allows a refresh'
fi

if [[ "$section" = all || "$section" = deadline ]]; then
    sandbox weather
    render_is 'a hung curl returns immediately on the cold render' '--' hang
    if wait_for_file "$sb/curl.pid"; then
        weather_failure 'the refresh deadline also records failure'
        if wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
            pass 'the deadline releases the refresh lock'
        else
            fail 'the deadline releases the refresh lock'
        fi
        if process_exits "$(cat "$sb/curl.pid")"; then
            pass 'the deadline terminates the probe process'
        else
            fail 'the deadline terminates the probe process'
            kill -KILL "$(cat "$sb/curl.pid")" 2>/dev/null || :
        fi
    else
        fail 'the hung probe started in the background'
    fi
    sandbox weather
    render_is 'a sub-microsecond remaining deadline renders absence' '--' tiny-deadline
    if wait_for_file "$CACHE_DIR/weather-default-u-failed" 130; then
        pass 'a sub-microsecond remaining deadline still ends the refresh'
    else
        fail 'a sub-microsecond remaining deadline still ends the refresh'
    fi
    if wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
        pass 'a sub-microsecond remaining deadline releases the lock'
    else
        fail 'a sub-microsecond remaining deadline releases the lock'
    fi
    if [ -s "$sb/curl.pid" ] && kill -0 "$(cat "$sb/curl.pid")" 2>/dev/null; then
        fail 'a sub-microsecond remaining deadline leaves no probe running'
        kill -KILL "$(cat "$sb/curl.pid")" 2>/dev/null || :
    else
        pass 'a sub-microsecond remaining deadline leaves no probe running'
    fi

    sandbox weather
    render_is 'a stalled failure-cache writer does not delay the render' '--' stalled-write
    if wait_for_file "$sb/writer.pid" && process_exits "$(cat "$sb/writer.pid")" 45 &&
        wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
        pass 'the failure-cache writer has a separate deadline and releases the lock'
    else
        fail 'the failure-cache writer has a separate deadline and releases the lock'
        if [ -s "$sb/writer.pid" ]; then kill -KILL "$(cat "$sb/writer.pid")" 2>/dev/null || :; fi
    fi
fi

if [[ "$section" = all || "$section" = locks ]]; then
    sandbox weather
    render_is 'a refresh with a delayed launch leaves the line available' '--' delayed
    if wait_for_file "$sb/delayed.pid"; then
        render_is 'another render can schedule a refresh before the delayed launch locks' '--' normal
        if wait_for_file "$CACHE_DIR/weather-default-u" && wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
            : > "$sb/release"
            if process_exits "$(cat "$sb/delayed.pid")"; then
                assert_eq 'a delayed contender rechecks the cache after acquiring the lock' 1 "$(calls)"
            else
                fail 'the delayed contender exits after the successful refresh'
            fi
        else
            fail 'the first locked refresh publishes a reading'
        fi
    else
        fail 'the delayed launcher enters the scheduling window'
    fi

    sandbox weather
    render_is 'a stalled launch leaves room for a failing contender' '--' delayed
    if wait_for_file "$sb/delayed.pid"; then
        render_is 'the other render can publish a failure' '--' fail
        if wait_for_file "$CACHE_DIR/weather-default-u-failed" && wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
            : > "$sb/release"
            if process_exits "$(cat "$sb/delayed.pid")"; then
                assert_eq 'a delayed contender respects failure cooldown after taking the lock' 1 "$(calls)"
            else
                fail 'the contender exits during failure cooldown'
            fi
        else
            fail 'the failing contender publishes a negative entry'
        fi
    else
        fail 'the delayed launcher enters the failure scheduling window'
    fi

    sandbox weather
    render_is 'weather shows absence while a supervised probe hangs' '--' hang
    if wait_for_file "$sb/curl.pid" && wait_for_file "$sb/supervisor.pid"; then
        wait_for_file "$sb/curl.fd" || :
        assert_eq 'the probe itself inherits the lock descriptor through exec' 'inherited' "$(cat "$sb/curl.fd" 2>/dev/null)"
        if wait_for_file "$sb/curl-fds-ready"; then
            assert_eq 'detached probes close the renderer payload pipes' '' "$(cat "$sb/curl-payload-fds" 2>/dev/null)"
        else
            fail 'the probe inspects its payload pipe descriptors'
        fi
    fi
    if [ -s "$sb/curl.pid" ] && [ -s "$sb/supervisor.pid" ] &&
        kill -KILL "$(cat "$sb/supervisor.pid")"; then
        if lock_is_free "$CACHE_DIR/weather-default-u-lock"; then
            fail 'the probe and watchdog inherit the lock from a killed supervisor'
        else
            pass 'the probe and watchdog inherit the lock from a killed supervisor'
        fi
        render_is 'rendering after supervisor death still shows absence' '--' hang
        assert_eq 'a killed supervisor cannot let a second curl start' 1 "$(calls)"
        if process_exits "$(cat "$sb/curl.pid")" && wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
            pass 'the watchdog terminates the probe and releases the lock after supervisor death'
        else
            fail 'the watchdog terminates the probe and releases the lock after supervisor death'
        fi
    else
        fail 'the hanging probe starts under a killable detached supervisor'
    fi

    sandbox weather
    printf '%s\n' '☀️+72°F' > "$sb/outside"
    ln -s "$sb/outside" "$CACHE_DIR/weather-default-u"
    ln -s "$sb/outside" "$CACHE_DIR/weather-default-u-lock"
    chmod 644 "$sb/outside"
    render_is 'a symlinked cache entry never becomes a reading' '--' normal
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")"; then
        assert_eq 'a symlinked lock prevents the probe from running' 0 "$(calls)"
    else
        fail 'a symlinked lock is rejected without stalling'
    fi

    sandbox weather
    printf 'sentinel\n' > "$sb/outside"
    chmod 644 "$sb/outside"
    ln "$sb/outside" "$CACHE_DIR/weather-default-u-lock"
    render_is 'a hardlinked lock renders as absence' '--' normal
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")"; then
        assert_eq 'a hardlinked lock prevents the probe from running' 0 "$(calls)"
    else
        fail 'a hardlinked lock is rejected without stalling'
    fi

    sandbox weather
    mkfifo -m 644 "$CACHE_DIR/weather-default-u-lock"
    render_is 'a FIFO lock leaves weather absent' '--' normal
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")" 15; then
        pass 'a FIFO lock without a reader cannot stall the supervisor'
    else
        fail 'a FIFO lock without a reader cannot stall the supervisor'
        if [ -s "$sb/supervisor.pid" ]; then kill -KILL "$(cat "$sb/supervisor.pid")" 2>/dev/null || :; fi
    fi
    exec 8<>"$CACHE_DIR/weather-default-u-lock"
    rm -f "$sb/supervisor.pid"
    render_is 'a FIFO lock with a reader also leaves weather absent' '--' normal
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")"; then
        assert_eq 'the refresh leaves a FIFO lock untouched' 644 \
            "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$CACHE_DIR/weather-default-u-lock")"
    else
        fail 'a FIFO lock with a reader is rejected'
    fi
    exec 8>&-

    # Owner-only mode and a reader get a FIFO past every check but the file type.
    sandbox weather
    mkfifo -m 600 "$CACHE_DIR/weather-default-u-lock"
    exec 8<>"$CACHE_DIR/weather-default-u-lock"
    render_is 'an owner-only FIFO lock with a reader leaves weather absent' '--' normal
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")"; then
        assert_eq 'an owner-only FIFO lock prevents the probe from running' 0 "$(calls)"
    else
        fail 'an owner-only FIFO lock with a reader is rejected'
    fi
    exec 8>&-

    sandbox weather
    : > "$CACHE_DIR/weather-default-u-lock"
    chmod 644 "$CACHE_DIR/weather-default-u-lock"
    render_is 'an old regular lock can be used for a refresh' '--' normal
    if wait_for_file "$CACHE_DIR/weather-default-u"; then
        assert_eq 'the cache, lock, and directory are owner-only' '700 600 600' \
            "$(perl -e 'printf "%o %o %o", map { (stat($_))[2] & 0777 } @ARGV' \
                "$CACHE_DIR" "$CACHE_DIR/weather-default-u" "$CACHE_DIR/weather-default-u-lock")"
    else
        fail 'a refresh writes to a cache protected by the repaired lock'
    fi

    # The target is private and holds a fresh reading under the current key,
    # so only the symlink itself can be what refuses it.
    sandbox weather
    rmdir "$CACHE_DIR"
    mkdir -m 700 "$sb/outside"
    (umask 077; printf '%s\n' '☀️+72°F' > "$sb/outside/weather-default-u")
    ln -s "$sb/outside" "$CACHE_DIR"
    render_is 'a symlinked cache directory never supplies a reading' '--' normal
    sleep 0.3
    render_is 'a symlinked cache directory supplies no reading after a refresh window' '--' normal
    assert_eq 'a symlinked cache directory leaves its private target alone' 'weather-default-u' "$(ls -A "$sb/outside")"
    assert_eq 'a symlinked cache directory starts no request' 0 "$(calls)"
    assert_eq 'a symlinked cache directory schedules no refresh' '' "$(cat "$sb/supervisor.pid" 2>/dev/null)"
fi

if [[ "$section" = all || "$section" = validation ]]; then
    for sample in http-error http-error-ip oversized malformed malformed-v6 multiline nul; do
        sandbox network
        render_is "WAN $sample is absent during lookup" 'NET: --' "$sample"
        if wait_for_file "$CACHE_DIR/network_wan-failed" 160 "$CACHE_DIR/network_wan"; then
            render_is "WAN $sample remains absent after lookup" 'NET: --' "$sample"
            assert_eq "WAN $sample leaves no positive cache" '' "$(cat "$CACHE_DIR/network_wan" 2>/dev/null)"
        else
            fail "WAN $sample records lookup failure"
        fi
    done
    sandbox network
    render_is 'cold WAN explicitly shows absence' 'NET: --' ipv6
    if wait_for_file "$CACHE_DIR/network_wan"; then
        render_is 'a measured IPv6 address is redacted on the line' 'NET: 2001:db8:xxxx:xxxx' ipv6
        assert_eq 'WAN curl uses HTTPS with startup-file loading disabled' \
            '-q -f -s --max-time 2 --proto =https --max-filesize 64 https://ifconfig.me' \
            "$(head -1 "$sb/curl.calls")"
    else
        fail 'a valid IPv6 address is cached'
    fi

    for sample in weather-http weather-malformed weather-partial oversized-weather; do
        sandbox weather
        render_is "$sample is absent during lookup" '--' "$sample"
        if wait_for_file "$CACHE_DIR/weather-default-u-failed" 100 "$CACHE_DIR/weather-default-u"; then
            render_is "$sample stays absent during cooldown" '--' "$sample"
            assert_eq "$sample triggers only one request" 1 "$(calls)"
        else
            fail "$sample creates only a negative cache marker"
        fi
        assert_eq "$sample uses the restricted weather curl invocation" \
            '-q -f -s --globoff --max-time 3 --proto =https --max-filesize 1024 https://wttr.in/?format=%c%t&u' \
            "$(head -1 "$sb/curl.calls" 2>/dev/null)"
    done
    sandbox weather
    printf '%s\n' '☀️+2°C' > "$CACHE_DIR/weather"
    render_is 'automatic US weather ignores an undifferentiated legacy entry' '--' normal
    if wait_for_file "$CACHE_DIR/weather-default-u"; then
        render_is 'automatic US weather only displays the new reading' '☀️ 72°F' normal
    else
        fail 'automatic US weather publishes a distinct entry'
    fi
    sandbox weather 'WEATHER_LOCATION=-33.87,151.21'
    render_is 'signed coordinates start with cold absence' '--' normal
    if wait_for_file "$sb/curl.calls" 30; then
        assert_contains 'signed coordinates reach the intended URL' 'https://wttr.in/-33.87,151.21?' "$(cat "$sb/curl.calls")"
        assert_eq 'signed coordinates make exactly one request' 1 "$(calls)"
    else
        fail 'signed coordinates schedule exactly one weather request'
    fi

    sandbox weather 'WEATHER_UNITS=m' 'WEATHER_LOCATION=Test'
    render_is 'cold weather for a configured location shows absence' '--' freezing
    request_key=$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex("Test\0m")')
    if wait_for_file "$CACHE_DIR/weather-$request_key"; then
        render_is 'negative temperatures retain their sign' '❄️ -12°C' freezing
        printf '%s\n' 'WEATHER_LOCATION=Different' >> "$sb/cortado.conf"
        render_is 'a changed weather location does not reuse the last reading' '--' normal
    else
        fail 'weather fetches and caches a configured location'
    fi

    sandbox weather 'WEATHER_LOCATION="unsafe?other"'
    render_is 'an unsafe location shows absence' '--' normal
    if wait_for_file "$sb/supervisor.pid" 8; then
        fail 'an unsafe weather location never schedules curl'
    else
        pass 'an unsafe weather location never schedules curl'
    fi

    sandbox weather 'WEATHER_CACHE_TTL=0' 'date() { printf "%s\n" 946684800; }'
    printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather-default-u"
    perl -e 'utime 946684800, 946684800, $ARGV[0]' "$CACHE_DIR/weather-default-u"
    render_is 'zero weather TTL still displays a reading from the current second' '☀️ 72°F' normal
fi

if [[ "$section" = all || "$section" = local ]]; then
    cat > "$scratch/bin/hostname" <<'STUB'
#!/bin/bash
[ "$TEST_SAMPLE" != failed ] || exit 1
printf '%s\n' '192.0.2.7 192.0.2.8'
STUB
    cat > "$scratch/bin/ipconfig" <<'STUB'
#!/bin/bash
[ "$TEST_SAMPLE" != failed ] || exit 1
[ "$*" = 'getifaddr en0' ] && printf '%s\n' '192.0.2.7'
STUB
    cat > "$scratch/bin/uptime" <<'STUB'
#!/bin/bash
[ "$TEST_SAMPLE" != failed ] || exit 1
printf '%s\n' '12:00 up 1 day, 1 user, load averages: 1.25 0.75 0.50'
STUB
    cat > "$scratch/bin/node" <<'STUB'
#!/bin/bash
[ "$TEST_SAMPLE" != failed ] || exit 1
[ "$*" = --version ] && printf '%s\n' v20.1.0
STUB
    chmod 700 "$scratch/bin/hostname" "$scratch/bin/ipconfig" "$scratch/bin/uptime" "$scratch/bin/node"

    sandbox 'network,load,node' 'NETWORK_SHOW_LAN=true NETWORK_SHOW_WAN=false' \
        'MODULE_LOAD=true LOAD_SHOW_STATUS=false MODULE_NODE=true'
    render_is 'cold local probes show absence' 'NET: -- | LOAD: -- | NODE: --' normal
    for ((i=0; i<60; i++)); do
        [[ "$(render normal && cat "$sb/output")" = 'NET: 192.0.2.7 | LOAD: 1.25 | NODE: 20.1.0' ]] && break
        sleep 0.05
    done
    assert_eq 'warm local probes display their readings' 'NET: 192.0.2.7 | LOAD: 1.25 | NODE: 20.1.0' "$(cat "$sb/output")"
    render_is 'fresh local readings need no successful probe on the foreground path' \
        'NET: 192.0.2.7 | LOAD: 1.25 | NODE: 20.1.0' failed
    render_is 'an unavailable timestamp snapshot falls back to per-file checks' \
        'NET: 192.0.2.7 | LOAD: 1.25 | NODE: 20.1.0' broken-snapshot

    mkdir "$scratch/other-bin"
    printf '#!/bin/bash\nprintf "v20.2.0\\n"\n' > "$scratch/other-bin/node"
    chmod 700 "$scratch/other-bin/node"
    PATH="$scratch/other-bin:$PATH" render_is 'a changed runtime shows absence until its own probe finishes' \
        'NET: 192.0.2.7 | LOAD: 1.25 | NODE: --' normal
    for ((i=0; i<60; i++)); do
        PATH="$scratch/other-bin:$PATH" render normal || break
        [[ "$(cat "$sb/output")" = 'NET: 192.0.2.7 | LOAD: 1.25 | NODE: 20.2.0' ]] && break
        sleep 0.05
    done
    assert_eq 'a changed runtime publishes a distinct reading' 'NET: 192.0.2.7 | LOAD: 1.25 | NODE: 20.2.0' "$(cat "$sb/output")"

    sandbox network 'NETWORK_SHOW_LAN=true NETWORK_SHOW_WAN=false NETWORK_SHOW_SSID=false'
    printf '%s\n' '192.0.2.7 (Private Wi-Fi)' > "$CACHE_DIR/network-local-true-true"
    render_is 'LAN-only renders never reuse a cached Wi-Fi name' 'NET: --' normal
    if wait_for_file "$CACHE_DIR/network-local-true-false"; then
        render_is 'LAN-only renders keep only the requested reading' 'NET: 192.0.2.7' normal
    else
        fail 'LAN-only lookup publishes its own reading'
    fi

    sandbox load 'MODULE_LOAD=true'
    printf '%s\n' '0 1.25 0.75 0.50' > "$CACHE_DIR/load"
    render_is 'a corrupt cached CPU count cannot imply healthy load' 'LOAD: --' normal

    sandbox weather 'date() { printf "%s\n" invalid; }'
    printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather-default-u"
    render_is 'an unusable clock cannot make cached weather look fresh' '--' normal
fi


if [[ "$section" = all || "$section" = resolution ]]; then
    sandbox weather 'curl() { printf "%s\n" "☀️+72°F"; }'
    render_is 'a trusted curl function starts cold' '--' fail
    if wait_for_file "$CACHE_DIR/weather-default-u" 80 "$CACHE_DIR/weather-default-u-failed"; then
        render_is 'the detached worker uses the trusted curl function' '☀️ 72°F' fail
    else
        fail 'the trusted curl function publishes a reading'
    fi
    assert_eq 'the external curl is not called when a trusted function exists' 0 "$(calls)"
fi

if [[ "$section" = all || "$section" = setup ]]; then
    cat > "$scratch/bin/chmod" <<'STUB'
#!/bin/bash
if [ "${TEST_SAMPLE:-}" = stalled-setup ] && [[ "${!#}" == */cortado-cache ]]; then
    printf '%s\n' "$$" >> "$CLAUDE_CONFIG_DIR/setup.pids"
    exec sleep 25
fi
exec /bin/chmod "$@"
STUB
    /bin/chmod 700 "$scratch/bin/chmod"
    sandbox weather
    /bin/chmod 755 "$CACHE_DIR"
    render_is 'a stalled directory setup leaves weather absent' '--' stalled-setup
    if wait_for_file "$sb/setup.pids"; then
        render_is 'a second render stays available while setup is stalled' '--' stalled-setup
        still_running 'the second render returns while the first setup is still stalled' \
            "$(head -1 "$sb/setup.pids")"
        render_within_ceiling 'stalled directory setup stays off the foreground path'
        while IFS= read -r pid; do
            if process_exits "$pid" 116; then
                pass 'a setup child exits within the deadline'
            else
                fail 'a setup child exits within the deadline'
                kill -KILL "$pid" 2>/dev/null || :
            fi
        done < "$sb/setup.pids"
    else
        fail 'the stalled directory setup reaches the fixture'
    fi
    assert_eq 'stalled setup starts no probe' 0 "$(calls)"
fi

if [[ "$section" = all || "$section" = clear ]]; then
    for clear_key in '' weather-default-u; do
        sandbox weather
        render_is 'weather is absent during a held request' '--' held
        if ! wait_for_file "$sb/held.pid"; then
            fail 'the first request starts'
            continue
        fi
        /bin/bash -c '. "$1/modules/utils.sh"; cache_clear "$2"' clear "$PROJECT_ROOT" "$clear_key"
        render_is 'a cache clear keeps the held request off the line' '--' normal
        sleep 0.2
        assert_eq 'a clear cannot let two requests occupy one probe' 1 "$(calls)"
        : > "$sb/release"
        if wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
            render_is 'a pre-clear request cannot repopulate the cache' '--' normal
            if wait_for_file "$CACHE_DIR/weather-default-u"; then
                render_is 'weather warms from a post-clear request' '☀️ 72°F' normal
            else
                fail 'the post-clear request publishes'
            fi
        else
            fail 'the held request releases its lock'
        fi
    done
fi

if [[ "$section" = all || "$section" = publication ]]; then
    sandbox weather
    render_is 'a failed positive publication keeps the reading absent' '--' broken-publication
    weather_failure 'a failed positive publication records cooldown through cache_set'
    assert_eq 'a failed rename publishes no partial positive reading' '' "$(cat "$CACHE_DIR/weather-default-u" 2>/dev/null)"
    assert_eq 'a failed rename removes its staging file' '' "$(find "$CACHE_DIR" -name 'weather-default-u.*' -print)"

    sandbox weather
    render_is 'a failed request is absent while waiting for a clear' '--' held-failure
    if wait_for_file "$sb/held.pid"; then
        /bin/bash -c '. "$1/modules/utils.sh"; cache_clear "$2"' clear "$PROJECT_ROOT" weather-default-u
        : > "$sb/release"
        if wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
            assert_eq 'a clear also invalidates an in-flight failure entry' '' "$(cat "$CACHE_DIR/weather-default-u-failed" 2>/dev/null)"
            render_is 'a new refresh can run without the discarded cooldown' '--' normal
            if wait_for_file "$CACHE_DIR/weather-default-u"; then
                render_is 'weather recovers with a post-clear reading' '☀️ 72°F' normal
            else
                fail 'the post-clear refresh publishes'
            fi
        else
            fail 'the invalidated failure releases its lock'
        fi
    else
        fail 'the request starts before the clear'
    fi

    sandbox weather
    render_is 'a held rename keeps the foreground available' '--' held-publication
    if wait_for_file "$sb/rename.pid"; then
        if lock_is_free "$CACHE_DIR/.probe-clear-lock"; then
            fail 'publication holds the clear lock through the rename'
        else
            pass 'publication holds the clear lock through the rename'
        fi
        /bin/bash -c '. "$1/modules/utils.sh"; cache_clear "$2"' clear "$PROJECT_ROOT" weather-default-u
        if wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
            assert_eq 'a clear racing publication returns with no reading' '' "$(cat "$CACHE_DIR/weather-default-u" 2>/dev/null)"
        else
            fail 'the racing publication releases its probe lock'
        fi
    else
        fail 'publication reaches the rename fixture'
    fi
    sandbox weather
    pending="$CACHE_DIR/.weather-default-u-pending"
    : > "$pending"
    # Hold the clear lock until the worker clears its old marker. A new
    # marker unexpectedly occupying that name must never start a probe.
    perl -MFcntl=:flock -e '
        my $holder = fork();
        exit 1 unless defined $holder;
        exit 0 if $holder;
        my ($lock, $ready, $release) = @ARGV;
        alarm 4;
        umask 077;
        open(my $handle, ">>", $lock) or exit 1;
        flock($handle, LOCK_EX) or exit 1;
        open(my $signal, ">", $ready) or exit 1;
        print {$signal} "ready\n";
        close($signal);
        select(undef, undef, undef, 0.02) until -e $release;
    ' "$CACHE_DIR/.probe-clear-lock" "$sb/clear-ready" "$sb/clear-release"
    if wait_for_file "$sb/clear-ready" 40; then
        render_is 'an occupied pending-marker destination starts with absence' '--' normal
        for ((i=0; i<40; i++)); do
            [ -e "$pending" ] || break
            sleep 0.05
        done
        if [ ! -e "$pending" ]; then
            : > "$pending"
            : > "$sb/clear-release"
            if wait_for_lock "$CACHE_DIR/weather-default-u-lock"; then
                assert_eq 'a preexisting pending marker cannot start a request' 0 "$(calls)"
            else
                fail 'the worker with an occupied marker releases its probe lock'
            fi
        else
            : > "$sb/clear-release"
            fail 'the worker prepares its pending marker under the probe lock'
        fi
    else
        : > "$sb/clear-release"
        fail 'the clear-lock fixture is ready'
    fi
fi

if [[ "$section" = all || "$section" = keys ]]; then
    sandbox weather
    for key in '' 'weather invalid'; do
        output=$(
            TEST_SAMPLE=normal /bin/bash -c '
                . "$1/modules/utils.sh"
                REPLY=old
                cached_probe "$2" 10 5 "$1/modules/weather.sh" _weather_probe https://wttr.in
                printf "%s" "$REPLY"
            ' guard "$PROJECT_ROOT" "$key"
        )
        assert_eq "an invalid probe key [$key] clears the reply" '' "$output"
    done
    sleep 0.2
    assert_eq 'invalid probe keys start no worker' '' "$(cat "$sb/supervisor.pid" 2>/dev/null)"
fi

if [[ "$section" = all || "$section" = privacy ]]; then
    for entry in weather-default-u weather-default-u-failed; do
        sandbox weather
        case "$entry" in weather-default-u) value='☀️+72°F'; expected='☀️ 72°F' ;; *) value=--; expected=-- ;; esac
        (umask 077; printf '%s\n' "$value" > "$CACHE_DIR/$entry")
        chmod 755 "$CACHE_DIR"
        render normal
        mode=$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$CACHE_DIR")
        if [ "$(cat "$sb/output")" = '☀️ 72°F' ]; then
            assert_eq 'a warm reading is displayed only from a private cache directory' 700 "$mode"
        fi
        for ((i=0; i<40; i++)); do
            mode=$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$CACHE_DIR")
            [ "$mode" != 700 ] || break
            sleep 0.05
        done
        assert_eq 'a cache hit repairs the directory mode' 700 "$mode"
        render_is 'a private cache retains the existing entry' "$expected" normal
        assert_eq 'permission repair does not repeat a probe for a valid entry' 0 "$(calls)"
    done

    # Without a render's snapshot, cached_probe checks the directory itself.
    sandbox weather
    (umask 077; printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather-default-u")
    chmod 755 "$CACHE_DIR"
    output=$(
        TEST_SAMPLE=normal /bin/bash -c '
            . "$1/modules/utils.sh"
            cached_probe weather-default-u 600 15 "$1/modules/weather.sh" _weather_probe https://wttr.in
            printf "%s" "$REPLY"
        ' standalone "$PROJECT_ROOT"
    )
    assert_eq 'a standalone read refuses a fresh entry in a shared directory' '' "$output"
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")"; then
        assert_eq 'the standalone refresh repairs the directory without a request' \
            '700 0' "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$CACHE_DIR") $(calls)"
    else
        fail 'the standalone read schedules a repair'
    fi
fi

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
