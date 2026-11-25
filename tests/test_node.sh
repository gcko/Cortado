#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" node

cat > "$TEST_BASE/bin/node" <<'STUB'
#!/bin/bash
[ "$*" = "--version" ] || exit 2
case "$TEST_SAMPLE" in
    normal|partial) printf '%s\n' v22.14.0 ;;
esac
[ "$TEST_SAMPLE" = normal ]
STUB
chmod +x "$TEST_BASE/bin/node"

check_node() {
    local desc="$1" expected="$2" sample="$3" sb i entry
    sb=$(mktemp -d "$TEST_BASE/probe.XXXXXX") || exit 1
    render "$sample" '' "CLAUDE_CONFIG_DIR='$sb'" >/dev/null || {
        fail "$desc (cold render failed)"
        return
    }
    for ((i=0; i<60; i++)); do
        for entry in "$sb/cortado-cache"/node-*; do
            case "${entry##*/}" in *-lock|*.*) continue ;; esac
            [ ! -s "$entry" ] || break 2
        done
        sleep 0.05
    done
    [ "$i" -lt 60 ] || { fail "$desc (probe did not publish)"; return; }
    check_render "$desc" "$expected" "$sample" '' "CLAUDE_CONFIG_DIR='$sb'"
}

check_node 'node shows the probed runtime version' 'NODE: 22.14.0' normal
check_node 'node shows absence when its version probe fails' 'NODE: --' failed
check_node 'node ignores version output from a failed probe' 'NODE: --' partial

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
