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

for bash_bin in /bin/bash "$(command -v bash)"; do
    sb=$(mktemp -d "$TEST_BASE/nounset.XXXXXX") || exit 1
    output=
    for ((i=0; i<45; i++)); do
        # shellcheck disable=SC2016
        output=$(CLAUDE_CONFIG_DIR="$sb" PATH="$TEST_BASE/bin:$PATH" TEST_SAMPLE=normal \
            "$bash_bin" -uc '. "$1/modules/utils.sh"; . "$1/modules/node.sh"; USE_ICONS=false; module_node' node "$PROJECT_ROOT" 2>&1)
        [ "$output" = 'NODE: --' ] || break
        sleep 0.05
    done
    assert_eq "an external Node version warms under nounset ($bash_bin)" 'NODE: 22.14.0' "$output"
done
# With no Node on PATH, a cache file named node must not stand in for the
# runtime's identity and start a probe of an empty command.
mkdir "$TEST_BASE/no-node-bin"
for tool in awk bash cat chmod date dirname grep jq mkdir mktemp mv perl rm sed stat tr uname; do
    tool_path=$(type -P "$tool") && ln -s "$tool_path" "$TEST_BASE/no-node-bin/$tool"
done
sb=$(mktemp -d "$TEST_BASE/metadata.XXXXXX") || exit 1
mkdir -m 700 "$sb/cortado-cache"
(umask 077; printf '%s\n' stale > "$sb/cortado-cache/node")
printf '%s\n' 'MODULE_ORDER=node' 'MODULE_NODE=true' 'COLOR_THEME="monochrome"' > "$sb/cortado.conf"
chmod 600 "$sb/cortado.conf"
output=$(printf '{}' | LC_ALL=C PATH="$TEST_BASE/no-node-bin" CLAUDE_CONFIG_DIR="$sb" \
    /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1)
assert_eq 'without Node, a cache file named node leaves the line absent' 'NODE: --' "$output"
other_entries() {
    local entry
    for entry in "$sb/cortado-cache"/* "$sb/cortado-cache"/.[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        [ "${entry##*/}" = node ] || printf '%s\n' "${entry##*/}"
    done
}
for ((i=0; i<10; i++)); do
    [ -z "$(other_entries)" ] || break
    sleep 0.05
done
assert_eq 'without Node, a cache file named node starts no probe' '' "$(other_entries)"
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
