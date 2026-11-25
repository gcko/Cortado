#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" directory

cat > "$TEST_BASE/bin/basename" <<'STUB'
#!/bin/bash
if [ "$TEST_SAMPLE" = failed-basename ] && [ "$1" = /nonexistent/fixture-project ]; then
    exit 1
fi
exec /usr/bin/basename "$@"
STUB
chmod +x "$TEST_BASE/bin/basename"

check_render 'directory shows the workspace basename' 'DIR: fixture-project' \
    normal '{"workspace":{"current_dir":"/nonexistent/fixture-project"},"cwd":"/nonexistent/legacy-project"}'
check_render 'directory shows absence when both paths are missing' 'DIR: --' missing '{}'
check_render 'directory shows absence when both paths are null' 'DIR: --' \
    null '{"workspace":{"current_dir":null},"cwd":null}'
check_render 'directory shows absence for a numeric path' 'DIR: --' \
    zero '{"workspace":{"current_dir":0}}'
check_render 'directory preserves an explicit dot path' 'DIR: .' normal '{"cwd":"."}'
check_render 'directory preserves a numeric-looking string path' 'DIR: 0' normal '{"cwd":"0"}'
check_render 'directory falls back to a usable legacy path' 'DIR: legacy' \
    normal '{"workspace":{"current_dir":0},"cwd":"/nonexistent/legacy"}'
check_render 'directory shows absence when basename fails for the workspace path' 'DIR: --' \
    failed-basename '{"workspace":{"current_dir":"/nonexistent/fixture-project"}}'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
