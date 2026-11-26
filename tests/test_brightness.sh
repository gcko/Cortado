#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" brightness

RENDER_OS=darwin
cat > "$TEST_BASE/bin/brightness" <<'STUB'
#!/bin/bash
# Force the built-in ioreg fallback except for the fractional CLI fixture.
case "$TEST_SAMPLE" in
    too-bright) printf '%s\n' 'display 0: brightness 1.01'; exit 0 ;;
    fraction) printf '%s\n' 'display 0: brightness 0.500000'; exit 0 ;;
    partial) printf '%s\n' 'display 0: brightness 0.9' ;;
esac
exit 1
STUB
chmod +x "$TEST_BASE/bin/brightness"
cat > "$TEST_BASE/bin/ioreg" <<'STUB'
#!/bin/bash
[ "$*" = "-r -d 1 -k IODisplayParameters" ] || exit 2
case "$TEST_SAMPLE" in
    overflow) value=65537 ;;
    normal) value=32768 ;;
    raw) printf '%s\n' '"IODisplayParameters"={"rawBrightness"={"min"=0,"max"=4,"value"=1}}'; exit 0 ;;
    zero) value=0 ;;
    *) exit 1 ;;
esac
printf '    "IODisplayParameters"={"brightness"={"min"=0,"max"=65536,"value"=%s}}\n' "$value"
STUB
chmod +x "$TEST_BASE/bin/ioreg"

# A cold render schedules the probe. Observe its result in the same cache.
check_probe() {
    local desc="$1" expected="$2" sample="$3" sb i entry
    shift 3
    sb=$(mktemp -d "$TEST_BASE/probe.XXXXXX") || exit 1
    RENDER_CONFIG_DIR="$sb" render "$sample" '' "$@" >/dev/null || { fail "$desc (cold render failed)"; return; }
    for ((i=0; i<60; i++)); do
        for entry in "$sb"/cortado-cache/brightness*; do
            case "${entry##*/}" in *-lock|*.*) continue ;; esac
            [ ! -s "$entry" ] || break 2
        done
        sleep 0.05
    done
    [ "$i" -lt 60 ] || { fail "$desc (refresh did not publish)"; return; }
    case "$sample" in
        too-bright|overflow)
            assert_eq "$desc (positive cache is empty)" '' "$(cat "$sb/cortado-cache/brightness" 2>/dev/null)" ;;
    esac
    RENDER_CONFIG_DIR="$sb" check_render "$desc" "$expected" "$sample" '' "$@"
}

check_probe 'brightness shows the measured percentage' 'BRT: 50%' normal
check_probe 'brightness uses the raw fallback scale' 'BRT: 25%' raw
check_probe 'brightness preserves a measured zero' 'BRT: 0%' zero
check_probe 'brightness shows absence when both probes fail' 'BRT: --' failed
check_probe 'brightness ignores output from a failed probe' 'BRT: --' partial
check_probe 'brightness rounds a fractional CLI reading' 'BRT: 50%' fraction
comma_locale=$(locale -a | awk 'tolower($0) ~ /^de_de\.utf-?8$/ {print; exit}')
if [ -n "$comma_locale" ]; then
    check_probe 'brightness rounds a fractional CLI reading in a comma-decimal locale' \
        'BRT: 50%' fraction "export LC_ALL=$comma_locale"
fi

check_probe 'a CLI fraction above one cannot produce a brightness reading' 'BRT: --' too-bright
check_probe 'a raw value above the maximum cannot produce a brightness reading' 'BRT: --' overflow
sb=$(mktemp -d "$TEST_BASE/corrupt.XXXXXX") || exit 1
mkdir -m 700 "$sb/cortado-cache"
(umask 077; printf '999\n' > "$sb/cortado-cache/brightness")
RENDER_CONFIG_DIR="$sb" check_render 'a corrupt cached brightness percentage does not display' 'BRT: --' failed ''
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
