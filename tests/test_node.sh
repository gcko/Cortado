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

check_render 'node shows the probed runtime version' 'NODE: 22.14.0' normal
check_render 'node shows absence when its version probe fails' 'NODE: --' failed
check_render 'node ignores version output from a failed probe' 'NODE: --' partial

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
