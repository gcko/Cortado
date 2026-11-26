#!/bin/bash
# Measure warm all-modules renders using the CI timing check's nearest rank.
# A positive CORTADO_ALL_MODULES_P95_LIMIT_MS enables a local timing gate.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$PROJECT_ROOT/tests/lib/assert.sh" plain
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -m 700 "$scratch/config" "$scratch/config/cortado-cache" "$scratch/workspace"
export CLAUDE_CONFIG_DIR="$scratch/config" CACHE_DIR="$scratch/config/cortado-cache"
export LC_ALL=C LC_NUMERIC=C
cd "$scratch/workspace"
unset DOCKER_HOST DOCKER_CONTEXT
export DOCKER_CONFIG="$scratch/docker"
mkdir "$DOCKER_CONFIG" "$scratch/bin"
export TIMING_DOCKER_CALLS="$scratch/docker.calls"
cat > "$scratch/bin/docker" <<'DOCKER'
#!/bin/bash
printf '%s\n' "$*" >> "$TIMING_DOCKER_CALLS"
printf '%s\n' abc123 def456
DOCKER
chmod 700 "$scratch/bin/docker"
export PATH="$scratch/bin:$PATH"
git init -q -b timing-fixture
printf '%s\n' fixture > timing.txt
git add timing.txt

# Config is data (#33): one KEY=VALUE per line.
cat > "$CLAUDE_CONFIG_DIR/cortado.conf" <<'CONFIG'
MODULE_ORDER="sandbox,version,update,directory,context,git,project,model,cost,rate-limits,time,battery,cpu,memory,disk,network,uptime,load,temperature,brightness,processes,docker,node,weather,timezone"
MODULE_CPU=true
MODULE_MEMORY=true
MODULE_DISK=true
MODULE_NETWORK=true
MODULE_UPTIME=true
MODULE_LOAD=true
MODULE_TEMPERATURE=true
MODULE_BRIGHTNESS=true
MODULE_PROCESSES=true
MODULE_DOCKER=true
MODULE_NODE=true
MODULE_WEATHER=true
MODULE_TIMEZONE=true
NETWORK_SHOW_WAN=true
TERMINAL_WIDTH=200
GIT_CACHE_TTL=600
VERSION_SHOW_DURATION=600
CONFIG
chmod 600 "$CLAUDE_CONFIG_DIR/cortado.conf"
printf '%s\n' '{"session_id":"all-modules-timing","workspace":{"current_dir":"."},"model":{"display_name":"Timing fixture"},"context_window":{"used_percentage":25},"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":10}}}' > "$scratch/payload"

# shellcheck source=modules/docker.sh
. "$PROJECT_ROOT/modules/docker.sh"
_docker_selection
docker_entry="$CACHE_DIR/docker-v2-true-false-${REPLY%% *}"
# Seed known readings on either platform. Actual probe refreshes, failures
# and cold renders are exercised by the per-module and concurrency suites.
(
    umask 077
    printf '25\n' > "$CACHE_DIR/cpu"
    printf '50\n' > "$CACHE_DIR/brightness"
    printf '12 --\n' > "$CACHE_DIR/processes-total"
    printf '2 --\n' > "$docker_entry"
    printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather-default-u"
    printf '203.0.113.9\n' > "$CACHE_DIR/network_wan"
    printf '192.0.2.7\n' > "$CACHE_DIR/network-local-true-false"
    printf '8 0.50 0.35 0.20\n' > "$CACHE_DIR/load"
    printf 'checked-current\n' > "$CACHE_DIR/update_check"
)
curl() { return 7; }
export -f curl

# Warm the Node cache under a real PATH and working directory. If Node is
# unavailable, the module still renders its hardware-independent absence.
# A cold runner can take seconds to start Node the first time, past the
# probe's 5 s deadline, so wait up to 20 s and retry once after a failed
# probe. This step is informational: a Node that still has no reading is
# reported, and the series is timed without the Node check.
node_bin=$(type -P node || :)
node_published() {
    for entry in "$CACHE_DIR"/node-*; do
        case "${entry##*/}" in *-lock|*-failed|*.*) continue ;; esac
        [ ! -s "$entry" ] || return 0
    done
    return 1
}
node_failed() {
    local failed
    for failed in "$CACHE_DIR"/node-*-failed; do
        [ ! -s "$failed" ] || return 0
    done
    return 1
}
NODE_WAIT_SECONDS=${NODE_WAIT_SECONDS:-20}
/bin/bash "$PROJECT_ROOT/cortado.sh" < "$scratch/payload" > /dev/null
if [ -n "$node_bin" ]; then
    for attempt in 1 2; do
        stop=$((SECONDS + NODE_WAIT_SECONDS))
        until node_published || node_failed || [ "$SECONDS" -ge "$stop" ]; do sleep 0.1; done
        node_published && break
        [ "$attempt" -eq 2 ] && break
        rm -f "$CACHE_DIR"/node-*-failed
        /bin/bash "$PROJECT_ROOT/cortado.sh" < "$scratch/payload" > /dev/null
    done
    if ! node_published; then
        printf '%s\n' 'Node did not publish its version for the warm render; timing without the Node reading'
        node_bin=
    fi
fi

: > "$TIMING_DOCKER_CALLS"
version=$(< "$PROJECT_ROOT/VERSION")
TIMEFORMAT='%3R'
samples=${CORTADO_ALL_MODULES_SAMPLES:-40}
limit_ms=${CORTADO_ALL_MODULES_P95_LIMIT_MS:-0}
printf 'Using %s\n' "$(jq --version)"
for ((i=1; i<=samples; i++)); do
    # Refresh timestamps outside the measurement to keep the series warm.
    touch "$CACHE_DIR/cpu" "$CACHE_DIR/brightness" "$CACHE_DIR/processes-total" \
        "$docker_entry" "$CACHE_DIR/network-local-true-false" "$CACHE_DIR/load"
    if [ -n "$node_bin" ]; then touch "$entry"; fi
    { time /bin/bash "$PROJECT_ROOT/cortado.sh" < "$scratch/payload" > "$scratch/output"; } 2>> "$scratch/timings"
    output=$(cat "$scratch/output")
    for reading in '🌿 timing-fixture' "☕ v$version" 'Timing fixture' '💻 25%' '☀️ 50%' '🔄 12' '192.0.2.7 | 203.0.xxx.xxx' '72°F' '🐳 2 running' '📊 0.50'; do
        if [[ "$output" != *"$reading"* ]]; then
            fail "warm all-modules render missed $reading (got [$output])"
            exit 1
        fi
    done
    if [ -n "$node_bin" ] && [[ "$output" != *"⬢ $(< "$entry")"* ]]; then
        fail "warm all-modules render missed the cached Node version (got [$output])"
        exit 1
    fi
done

if [ -s "$TIMING_DOCKER_CALLS" ]; then
    fail 'warm renders made a Docker CLI call'
    exit 1
fi

sorted=$(sort -n "$scratch/timings")
awk -v samples="$samples" -v limit_ms="$limit_ms" '
    $0 !~ /^[0-9]+\.[0-9][0-9][0-9]$/ { invalid = 1 }
    NR == int((50 * samples + 99) / 100) { p50 = $1 }
    NR == int((95 * samples + 99) / 100) { p95 = $1 }
    END {
        if (invalid || NR != samples) { print "Could not measure each render"; exit 1 }
        printf "Warm all-modules render (n=%d): p50=%.3fs p95=%.3fs\n", samples, p50, p95
        if (limit_ms > 0 && p95 * 1000 > limit_ms) {
            printf "Warm all-modules render p95 exceeds %d ms\n", limit_ms
            exit 1
        }
    }
' <<< "$sorted"
