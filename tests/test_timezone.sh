#!/bin/bash
# =============================================================================
# Timezone Render Tests
# Usage: bash tests/test_timezone.sh
# =============================================================================

set -u
set -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE="$(mktemp -d)"
trap 'rm -rf "$TEST_BASE"' EXIT

mkdir -p "$TEST_BASE/project"
touch "$TEST_BASE/project/AAA" "$TEST_BASE/project/BBB"
PAYLOAD=$(jq -cn --arg dir "$TEST_BASE/project" '{workspace:{current_dir:$dir}}')

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (expected [$expected], got [$actual])"
    fi
}

render() (
    local sb
    sb=$(mktemp -d "$TEST_BASE/config.XXXXXX") || exit 1
    mkdir -m 700 "$sb/cortado-cache"
    printf '%s\n' 'MODULE_ORDER="timezone"' 'MODULE_TIMEZONE="true"' "$@" > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf"
    cd "$TEST_BASE/project" || exit 1
    printf '%s' "$PAYLOAD" |
        CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" /bin/bash "$PROJECT_ROOT/cortado.sh" |
        sed $'s/\x1b\\[[0-9;]*m//g; s/[0-9][0-9]:[0-9][0-9]/HH:MM/g'
)

desc="a wildcard zone does not render filenames from the working directory"
if out=$(render 'TIMEZONE_ZONES="UTC,*"'); then
    case "$out" in
        *AAA*|*BBB*) fail "$desc (got [$out])" ;;
        'UTC: HH:MM'*) pass "$desc" ;;
        *) fail "$desc (missing UTC clock in [$out])" ;;
    esac
else
    fail "$desc (render failed)"
fi

out=$(render 'TIMEZONE_ZONES="UTC, Asia/Tokyo"')
assert_eq "two named zones render in order" 'UTC: HH:MM | TOK: HH:MM' "$out"

out=$(render 'TIMEZONE_ZONES="UTC, Asia/Tokyo"' 'TIMEZONE_LABELS="*,Tokyo"')
assert_eq "a wildcard custom label stays literal" '*: HH:MM | Tokyo: HH:MM' "$out"

out=$(render 'TIMEZONE_ZONES=", UTC, , Asia/Tokyo, "' 'TIMEZONE_LABELS=",Tokyo"')
assert_eq "blank zones and omitted labels preserve clock order" 'UTC: HH:MM | Tokyo: HH:MM' "$out"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
