#!/bin/bash
# Measure wall time for fresh statusline renders with the shipped configuration.
set -euo pipefail

samples="${1-20}"
if [ "$#" -gt 1 ] || ! [[ "$samples" =~ ^[1-9][0-9]{0,2}$ ]]; then
    printf '%s\n' 'Usage: render_timing.sh [sample-count (1-999)]' >&2
    exit 2
fi

for tool in jq bc; do
    if ! command -v "$tool" >/dev/null; then
        printf 'Cannot time renders without %s\n' "$tool" >&2
        exit 1
    fi
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch=$(mktemp -d)
start_dir="$PWD"
trap 'cd "$start_dir" && rm -rf "$scratch"' EXIT
# A fresh workspace keeps project overrides and Git state out of the measurement.
cd "$scratch"
scratch="$PWD"
printf '%s\n' '{"workspace":{"current_dir":"."},"model":{"display_name":"Timing fixture"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}' > "$scratch/payload"

# Keep the default update check in the render path with a deterministic offline result.
curl() { return 7; }
export -f curl
export LC_ALL=C
TIMEFORMAT='%3R'
for ((i = 0; i < samples; i++)); do
    config=$(mktemp -d "$scratch/config.XXXXXX")
    if ! { time CLAUDE_CONFIG_DIR="$config" CACHE_DIR="$config/cortado-cache" \
        /bin/bash "$root/cortado.sh" < "$scratch/payload" > "$scratch/render" \
            2> "$scratch/render.err"; } 2>> "$scratch/timings" ||
        ! grep -Fq 'Timing fixture' "$scratch/render"; then
        printf 'Default render %s failed\n' "$((i + 1))" >&2
        cat "$scratch/render" "$scratch/render.err" >&2
        exit 1
    fi
done

# Nearest rank uses the first sample at or above each percentile.
sort -n "$scratch/timings" | awk -v samples="$samples" '
    $0 !~ /^[0-9]+\.[0-9][0-9][0-9]$/ { invalid = 1 }
    NR == int((50 * samples + 99) / 100) { p50 = $1 }
    NR == int((95 * samples + 99) / 100) { p95 = $1 }
    END {
        if (invalid || NR != samples) {
            print "Could not measure every default render" > "/dev/stderr"
            exit 1
        }
        printf "Default render (n=%d): p50=%.3fs p95=%.3fs\n", samples, p50, p95
    }
'
