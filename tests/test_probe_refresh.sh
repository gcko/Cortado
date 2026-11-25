#!/bin/bash
# Exercise cold, warm, failed and overlapping probe refreshes through the renderer.
set -u
set -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/workspace" || exit 1
cd "$scratch/workspace" || exit 1
export LC_NUMERIC=C REAL_PERL
REAL_PERL=$(command -v perl) || exit 1
export PATH="$scratch/bin:$PATH"
section="${PROBE_TEST_SECTION:-all}"

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
exec "$REAL_PERL" "$@"
STUB
cat > "$scratch/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_CONFIG_DIR/curl.calls"
case "$TEST_SAMPLE" in
    slow)
        printf '%s\n' "$$" > "$CLAUDE_CONFIG_DIR/curl.pid"
        printf '%s\n' 'curl output'
        printf '%s\n' 'curl diagnostic' >&2
        sleep 2
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
        ' "$CLAUDE_CONFIG_DIR/cortado-cache/weather-lock" > "$CLAUDE_CONFIG_DIR/curl.fd"
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
    normal|delayed)
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
if [ "${TEST_SAMPLE:-}" = stalled-write ] && [[ "${!#}" == */weather-failed ]]; then
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

fast_render() {
    local elapsed
    elapsed=$(cat "$sb/elapsed")
    if LC_ALL=C awk -v elapsed="$elapsed" 'BEGIN {exit !(elapsed + 0 < 0.250)}'; then
        pass "$1 (${elapsed}s)"
    else
        fail "$1 (${elapsed}s)"
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
    if wait_for_file "$CACHE_DIR/weather-failed"; then
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
        if ! lock_is_free "$CACHE_DIR/weather-lock"; then
            pass 'the refresh holds its lock while curl is running'
        else
            fail 'the refresh holds its lock while curl is running'
        fi
    fi
    render_is 'a second render while curl runs returns weather absence' '--' slow '{"context_window":null}'
    fast_render 'a second render finishes below 250 ms during a sleeping curl'
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
    [ "$FAIL" -eq 0 ] || exit 1
    weather_failure 'a failed request leaves a short-lived failure entry'
    previous_supervisor=$(cat "$sb/supervisor.pid")
    for payload in '{}' '{"context_window":{"used_percentage":0}}' '{"context_window":{"used_percentage":null}}'; do
        render_is 'a render during failure cooldown still shows absence' '--' slow "$payload"
        fast_render 'a render during failure cooldown finishes below 250 ms'
    done
    assert_eq 'the failure entry suppresses further attempts until expiry' 1 "$(calls)"
    assert_eq 'renders during cooldown launch no worker' "$previous_supervisor" "$(cat "$sb/supervisor.pid")"
    assert_eq 'background curl stdout and stderr stay off the line' '' "$(cat "$sb/stderr")"

    if [ -f "$CACHE_DIR/weather-failed" ]; then
        touch -t 200001010000 "$CACHE_DIR/weather-failed"
    fi
    render_is 'an expired failure renders absence while retrying' '--' normal
    if wait_for_file "$CACHE_DIR/weather"; then
        render_is 'successful retry supplies fresh weather' '☀️ 72°F' normal
    fi
    assert_eq 'expiry allows a new request' 2 "$(calls)"
    if [ -f "$CACHE_DIR/weather" ]; then
        touch -t 200001010000 "$CACHE_DIR/weather"
    fi
    rm -f "$CACHE_DIR/weather-failed"
    render_is 'expired weather does not read as current' '--' fail
    weather_failure 'a failed refresh of stale weather records failure'

    sandbox weather
    printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather"
    perl -e 'my $future = time + 3600; utime $future, $future, $ARGV[0]' "$CACHE_DIR/weather"
    render_is 'a future-dated cache entry does not read as current' '--' fail
    weather_failure 'a future-dated cache entry allows a refresh'
fi

if [[ "$section" = all || "$section" = deadline ]]; then
    sandbox weather
    render_is 'a hung curl returns immediately on the cold render' '--' hang
    if wait_for_file "$sb/curl.pid"; then
        weather_failure 'the refresh deadline also records failure'
        if wait_for_lock "$CACHE_DIR/weather-lock"; then
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
    render_is 'a stalled failure-cache writer does not delay the render' '--' stalled-write
    if wait_for_file "$sb/writer.pid" && process_exits "$(cat "$sb/writer.pid")" 45 &&
        wait_for_lock "$CACHE_DIR/weather-lock"; then
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
        if wait_for_file "$CACHE_DIR/weather" && wait_for_lock "$CACHE_DIR/weather-lock"; then
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
    render_is 'weather shows absence while a supervised probe hangs' '--' hang
    if wait_for_file "$sb/curl.pid" && wait_for_file "$sb/supervisor.pid"; then
        wait_for_file "$sb/curl.fd" || :
        assert_eq 'the probe itself inherits the lock descriptor through exec' 'inherited' "$(cat "$sb/curl.fd" 2>/dev/null)"
    fi
    if [ -s "$sb/curl.pid" ] && [ -s "$sb/supervisor.pid" ] &&
        kill -KILL "$(cat "$sb/supervisor.pid")"; then
        if lock_is_free "$CACHE_DIR/weather-lock"; then
            fail 'the probe and watchdog inherit the lock from a killed supervisor'
        else
            pass 'the probe and watchdog inherit the lock from a killed supervisor'
        fi
        render_is 'rendering after supervisor death still shows absence' '--' hang
        assert_eq 'a killed supervisor cannot let a second curl start' 1 "$(calls)"
        if process_exits "$(cat "$sb/curl.pid")" && wait_for_lock "$CACHE_DIR/weather-lock"; then
            pass 'the watchdog terminates the probe and releases the lock after supervisor death'
        else
            fail 'the watchdog terminates the probe and releases the lock after supervisor death'
        fi
    else
        fail 'the hanging probe starts under a killable detached supervisor'
    fi

    sandbox weather
    printf '%s\n' '☀️+72°F' > "$sb/outside"
    ln -s "$sb/outside" "$CACHE_DIR/weather"
    ln -s "$sb/outside" "$CACHE_DIR/weather-lock"
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
    ln "$sb/outside" "$CACHE_DIR/weather-lock"
    render_is 'a hardlinked lock renders as absence' '--' normal
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")"; then
        assert_eq 'a hardlinked lock prevents the probe from running' 0 "$(calls)"
    else
        fail 'a hardlinked lock is rejected without stalling'
    fi

    sandbox weather
    mkfifo -m 644 "$CACHE_DIR/weather-lock"
    render_is 'a FIFO lock leaves weather absent' '--' normal
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")" 15; then
        pass 'a FIFO lock without a reader cannot stall the supervisor'
    else
        fail 'a FIFO lock without a reader cannot stall the supervisor'
        if [ -s "$sb/supervisor.pid" ]; then kill -KILL "$(cat "$sb/supervisor.pid")" 2>/dev/null || :; fi
    fi
    exec 8<>"$CACHE_DIR/weather-lock"
    rm -f "$sb/supervisor.pid"
    render_is 'a FIFO lock with a reader also leaves weather absent' '--' normal
    if wait_for_file "$sb/supervisor.pid" && process_exits "$(cat "$sb/supervisor.pid")"; then
        assert_eq 'the refresh leaves a FIFO lock untouched' 644 \
            "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$CACHE_DIR/weather-lock")"
    else
        fail 'a FIFO lock with a reader is rejected'
    fi
    exec 8>&-

    sandbox weather
    : > "$CACHE_DIR/weather-lock"
    chmod 644 "$CACHE_DIR/weather-lock"
    render_is 'an old regular lock can be used for a refresh' '--' normal
    if wait_for_file "$CACHE_DIR/weather"; then
        assert_eq 'the cache, lock, and directory are owner-only' '700 600 600' \
            "$(perl -e 'printf "%o %o %o", map { (stat($_))[2] & 0777 } @ARGV' \
                "$CACHE_DIR" "$CACHE_DIR/weather" "$CACHE_DIR/weather-lock")"
    else
        fail 'a refresh writes to a cache protected by the repaired lock'
    fi

    sandbox weather
    rmdir "$CACHE_DIR"
    mkdir "$sb/outside"
    printf '%s\n' '☀️+72°F' > "$sb/outside/weather"
    ln -s "$sb/outside" "$CACHE_DIR"
    render_is 'a symlinked cache directory never supplies a reading' '--' normal
    assert_eq 'a symlinked cache directory leaves its target alone' '' "$(ls "$sb/outside" | sed '/^weather$/d')"
fi

if [[ "$section" = all || "$section" = validation ]]; then
    for sample in http-error http-error-ip malformed malformed-v6 multiline nul; do
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
    else
        fail 'a valid IPv6 address is cached'
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
    printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather"
    perl -e 'utime 946684800, 946684800, $ARGV[0]' "$CACHE_DIR/weather"
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
    printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather"
    render_is 'an unusable clock cannot make cached weather look fresh' '--' normal
fi

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
