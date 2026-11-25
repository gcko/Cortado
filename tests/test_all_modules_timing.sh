#!/bin/bash
# Measure warm all-modules renders using the CI timing check's nearest rank.
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

cat > "$CLAUDE_CONFIG_DIR/cortado.conf" <<'CONFIG'
MODULE_ORDER="sandbox,version,update,directory,context,git,project,model,cost,rate-limits,time,battery,cpu,memory,disk,network,uptime,load,temperature,brightness,processes,docker,node,weather,timezone"
MODULE_CPU=true MODULE_MEMORY=true MODULE_DISK=true MODULE_NETWORK=true
MODULE_UPTIME=true MODULE_LOAD=true MODULE_TEMPERATURE=true MODULE_BRIGHTNESS=true
MODULE_PROCESSES=true MODULE_DOCKER=true MODULE_NODE=true MODULE_WEATHER=true MODULE_TIMEZONE=true
NETWORK_SHOW_WAN=true
TERMINAL_WIDTH=200
CONFIG
chmod 600 "$CLAUDE_CONFIG_DIR/cortado.conf"
printf '%s\n' '{"workspace":{"current_dir":"."},"model":{"display_name":"Timing fixture"},"context_window":{"used_percentage":25},"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":10}}}' > "$scratch/payload"

# Seed known readings on either platform. Actual probe refreshes, failures
# and cold renders are exercised by the per-module and concurrency suites.
(
    umask 077
    printf '25\n' > "$CACHE_DIR/cpu"
    printf '50\n' > "$CACHE_DIR/brightness"
    printf '12 --\n' > "$CACHE_DIR/processes-total"
    printf '2 --\n' > "$CACHE_DIR/docker-true-false"
    printf '%s\n' '☀️+72°F' > "$CACHE_DIR/weather"
    printf '203.0.113.9\n' > "$CACHE_DIR/network_wan"
    printf '192.0.2.7\n' > "$CACHE_DIR/network-local-true-false"
    printf '8 0.50 0.35 0.20\n' > "$CACHE_DIR/load"
    printf 'checked-current\n' > "$CACHE_DIR/update_check"
)
curl() { return 7; }
export -f curl

# Warm the Node cache under a real PATH and working directory. If Node is
# unavailable, the module still renders its hardware-independent absence.
node_bin=$(type -P node || :)
if [ -n "$node_bin" ]; then
    /bin/bash "$PROJECT_ROOT/cortado.sh" < "$scratch/payload" > /dev/null
    for ((i=0; i<60; i++)); do
        for entry in "$CACHE_DIR"/node-*; do
            case "${entry##*/}" in *-lock|*-failed|*.*) continue ;; esac
            [ ! -s "$entry" ] || break 2
        done
        sleep 0.05
    done
    [ "$i" -lt 60 ] || { fail 'Node did not publish its version for the warm render'; exit 1; }
fi

TIMEFORMAT='%3R'
samples=40
for ((i=1; i<=samples; i++)); do
    # Refresh timestamps outside the measurement to keep the series warm.
    touch "$CACHE_DIR/cpu" "$CACHE_DIR/brightness" "$CACHE_DIR/processes-total" \
        "$CACHE_DIR/docker-true-false" "$CACHE_DIR/network-local-true-false" "$CACHE_DIR/load"
    if [ -n "$node_bin" ]; then touch "$entry"; fi
    { time /bin/bash "$PROJECT_ROOT/cortado.sh" < "$scratch/payload" > "$scratch/output"; } 2>> "$scratch/timings"
    output=$(cat "$scratch/output")
    for reading in 'Timing fixture' '💻 25%' '☀️ 50%' '🔄 12' '192.0.2.7 | 203.0.xxx.xxx' '72°F' '🐳 2 running' '📊 0.50'; do
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

sorted=$(sort -n "$scratch/timings")
awk -v samples="$samples" '
    $0 !~ /^[0-9]+\.[0-9][0-9][0-9]$/ { invalid = 1 }
    NR == int((50 * samples + 99) / 100) { p50 = $1 }
    NR == int((95 * samples + 99) / 100) { p95 = $1 }
    END {
        if (invalid || NR != samples) { print "Could not measure each render"; exit 1 }
        printf "Warm all-modules render (n=%d): p50=%.3fs p95=%.3fs\n", samples, p50, p95
        if (p95 > 0.250) { print "Warm all-modules render p95 exceeds 250 ms"; exit 1 }
    }
' <<< "$sorted"
