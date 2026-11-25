#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" directory

check_render 'directory shows the workspace basename' 'DIR: fixture-project' \
    normal '{"workspace":{"current_dir":"/nonexistent/fixture-project"},"cwd":"/nonexistent/legacy-project"}'
check_render_gap 'directory shows absence when both paths are missing' 'DIR: --' 'DIR: .' missing '{}'
check_render_gap 'directory shows absence when both paths are null' 'DIR: --' 'DIR: .' \
    null '{"workspace":{"current_dir":null},"cwd":null}'
check_render_gap 'directory shows absence for a numeric path' 'DIR: --' 'DIR: 0' \
    zero '{"workspace":{"current_dir":0}}'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
