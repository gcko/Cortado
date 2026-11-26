#!/bin/bash
# Measure wall time for fresh statusline renders with the shipped configuration,
# then for renders while a weather request hangs (network unreachable).

report_percentiles() {
    local samples="$1" sorted label="${4:-Default render}"
    if ! sorted=$(LC_ALL=C sort -n "$2"); then
        printf 'Could not sort %s timings\n' "$label" >&2
        return 1
    fi

    # Nearest rank uses the first sample at or above each percentile.
    LC_ALL=C awk -v samples="$samples" -v limit="${3:-0}" -v label="$label" '
        $0 !~ /^[0-9]+\.[0-9][0-9][0-9]$/ { invalid = 1 }
        NR == int((50 * samples + 99) / 100) { p50 = $1 }
        NR == int((95 * samples + 99) / 100) { p95 = $1 }
        END {
            if (invalid || NR != samples) {
                print "Could not measure every " tolower(label) > "/dev/stderr"
                exit 1
            }
            printf "%s (n=%d): p50=%.3fs p95=%.3fs\n", label, samples, p50, p95
            if (limit && int(p95 * 1000 + 0.5) > limit) {
                printf "%s p95 exceeds %d ms\n", label, limit > "/dev/stderr"
                exit 1
            }
        }
    ' <<< "$sorted"
}

record_render() {
    local tree="$1" timings="$2" sample="$3" config
    config=$(mktemp -d "$scratch/config.XXXXXX")
    if ! { time CLAUDE_CONFIG_DIR="$config" CACHE_DIR="$config/cortado-cache" \
        LC_ALL="$render_lc_all" LC_NUMERIC="$render_lc_numeric" \
        /bin/bash "$tree/cortado.sh" < "$scratch/payload" > "$scratch/render" \
            2> "$scratch/render.err"; } 2>> "$timings" ||
        ! LC_ALL=C grep -Fq 'Timing fixture' "$scratch/render"; then
        printf 'Default render %s failed\n' "$sample" >&2
        cat "$scratch/render" "$scratch/render.err" >&2
        return 1
    fi
}

# One config directory: the first render starts a weather refresh whose curl
# sleeps past the refresh deadline. Every later render is measured. They run
# while that request holds its lock, or during the failure cooldown after it.
measure_stalled_weather_renders() {
    local samples="$1" stalled order i attempt
    stalled=$(mktemp -d "$scratch/stalled.XXXXXX")
    mkdir -m 700 "$stalled/cortado-cache"
    order=$(sed -n 's/^MODULE_ORDER="\(.*\)"$/\1/p' "$root/cortado.conf")
    printf '%s\n' "MODULE_ORDER=\"$order,weather\"" 'MODULE_WEATHER="true"' > "$stalled/cortado.conf"
    chmod 600 "$stalled/cortado.conf"
    export CORTADO_TIMING_CURL_PIDS="$scratch/curl.pids"
    # shellcheck disable=SC2329
    curl() {
        sleep 6 &
        printf '%s\n' "$!" >> "$CORTADO_TIMING_CURL_PIDS"
        wait "$!"
        return 28
    }
    export -f curl

    for ((i = 0; i <= samples; i++)); do
        if ! { time CLAUDE_CONFIG_DIR="$stalled" CACHE_DIR="$stalled/cortado-cache" \
            LC_ALL="$render_lc_all" LC_NUMERIC="$render_lc_numeric" \
            /bin/bash "$root/cortado.sh" < "$scratch/payload" > "$scratch/render" \
                2> "$scratch/render.err"; } 2>> "$scratch/stalled.timings" ||
            ! LC_ALL=C grep -Fq 'Timing fixture' "$scratch/render" ||
            LC_ALL=C grep -Fq '°' "$scratch/render"; then
            printf 'Stalled weather render %s failed\n' "$i" >&2
            cat "$scratch/render" "$scratch/render.err" >&2
            return 1
        fi
        if [ "$i" -eq 0 ]; then
            # The first render only starts the request. Wait until curl sleeps.
            : > "$scratch/stalled.timings"
            for ((attempt = 0; attempt < 100; attempt++)); do
                [ ! -s "$CORTADO_TIMING_CURL_PIDS" ] || break
                sleep 0.05
            done
            if [ ! -s "$CORTADO_TIMING_CURL_PIDS" ]; then
                printf '%s\n' 'The stalled weather request did not start' >&2
                return 1
            fi
        fi
    done
    # Informational, like the warm all-modules series: the no-wait guarantee is proven by
    # tests/test_probe_refresh.sh, so this series reports but never gates.
    report_percentiles "$samples" "$scratch/stalled.timings" 0 'Stalled weather render'
}

# Stop the sleeping requests, then let their refreshes release the cache.
stop_stalled_requests() {
    local pid attempt
    [ -s "${CORTADO_TIMING_CURL_PIDS:-}" ] || return 0
    while IFS= read -r pid; do
        kill "$pid" 2>/dev/null || :
    done < "$CORTADO_TIMING_CURL_PIDS"
    for ((attempt = 0; attempt < 40; attempt++)); do
        perl -MFcntl=:flock -e '
            for (@ARGV) { open(my $lock, ">>", $_) or next; exit 1 unless flock($lock, LOCK_EX|LOCK_NB) }
        ' "$scratch"/stalled.*/cortado-cache/*-lock 2>/dev/null && return 0
        sleep 0.05
    done
}

measure_default_renders() (
    set -euo pipefail

    local samples="${1-20}" base="${2:-}" root scratch start_dir i
    local limit="${CORTADO_RENDER_P95_LIMIT_MS:-0}"
    local render_lc_all="${LC_ALL-}" render_lc_numeric="${LC_NUMERIC-}"
    local TIMEFORMAT='%3R'
    if [ "$#" -gt 2 ] || ! [[ "$samples" =~ ^[1-9][0-9]{0,2}$ ]]; then
        printf '%s\n' 'Usage: render_timing.sh [sample-count (1-999)] [base-tree]' >&2
        exit 2
    fi
    if ! [[ "$limit" =~ ^[0-9]{1,6}$ ]]; then
        printf '%s\n' 'CORTADO_RENDER_P95_LIMIT_MS must be an integer in milliseconds' >&2
        exit 2
    fi
    if [ -n "$base" ]; then
        base=$(cd "$base" && pwd) || exit 2
    fi
    if ! command -v jq >/dev/null; then
        printf '%s\n' 'Cannot time renders without jq' >&2
        exit 1
    fi

    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    scratch=$(mktemp -d)
    start_dir="$PWD"
    trap 'stop_stalled_requests; cd "$start_dir" && rm -rf "$scratch"' EXIT
    # A fresh workspace keeps project overrides and Git state out of the measurement.
    cd "$scratch"
    scratch="$PWD"
    printf '%s\n' '{"workspace":{"current_dir":"."},"model":{"display_name":"Timing fixture"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}' > "$scratch/payload"

    # Keep the measurement offline if a default module attempts a request.
    # shellcheck disable=SC2329
    curl() { return 7; }
    export -f curl
    # Bash's time uses this shell's numeric locale. The renderer gets the caller's locale.
    unset LC_ALL
    export LC_NUMERIC=C
    for ((i = 1; i <= samples; i++)); do
        if [ -n "$base" ] && (( i % 2 )); then
            record_render "$base" "$scratch/base.timings" "$i"
        fi
        record_render "$root" "$scratch/head.timings" "$i"
        if [ -n "$base" ] && (( i % 2 == 0 )); then
            record_render "$base" "$scratch/base.timings" "$i"
        fi
    done

    if [ -n "$base" ]; then
        printf 'Base: '
        report_percentiles "$samples" "$scratch/base.timings"
        printf 'Head: '
    fi
    local status=0
    report_percentiles "$samples" "$scratch/head.timings" "$limit" || status=1
    measure_stalled_weather_renders "$samples" || status=1
    return "$status"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    measure_default_renders "$@"
fi
