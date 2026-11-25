#!/bin/bash
# Measure wall time for fresh statusline renders with the shipped configuration.

report_percentiles() {
    local samples="$1" sorted
    if ! sorted=$(LC_ALL=C sort -n "$2"); then
        printf '%s\n' 'Could not sort default render timings' >&2
        return 1
    fi

    # Nearest rank uses the first sample at or above each percentile.
    LC_ALL=C awk -v samples="$samples" -v limit="${3:-0}" '
        $0 !~ /^[0-9]+\.[0-9][0-9][0-9]$/ { invalid = 1 }
        NR == int((50 * samples + 99) / 100) { p50 = $1 }
        NR == int((95 * samples + 99) / 100) { p95 = $1 }
        END {
            if (invalid || NR != samples) {
                print "Could not measure every default render" > "/dev/stderr"
                exit 1
            }
            printf "Default render (n=%d): p50=%.3fs p95=%.3fs\n", samples, p50, p95
            if (limit && int(p95 * 1000 + 0.5) > limit) {
                printf "Default render p95 exceeds %d ms\n", limit > "/dev/stderr"
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
    trap 'cd "$start_dir" && rm -rf "$scratch"' EXIT
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
    report_percentiles "$samples" "$scratch/head.timings" "$limit"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    measure_default_renders "$@"
fi
