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
mkdir "$TEST_BASE/0" "$TEST_BASE/legacy"
touch "$TEST_BASE/0/Cargo.toml"
printf '%s\n' '{}' > "$TEST_BASE/legacy/package.json"
legacy_payload=$(jq -cn --arg cwd "$TEST_BASE/legacy" '{workspace:{current_dir:0},cwd:$cwd}')
project_config=('MODULE_ORDER=directory,project' 'MODULE_PROJECT=true'
    'PROJECT_SHOW_DEV_SERVER=false' 'PROJECT_SHOW_BUILD=false')
check_render 'directory and project use the same usable legacy path' 'DIR: legacy | Node.js' \
    normal "$legacy_payload" "${project_config[@]}"
printf '%s\n' 'DIRECTORY_STYLE=text' > "$TEST_BASE/legacy/.cortado.conf"
chmod 600 "$TEST_BASE/legacy/.cortado.conf"
check_render 'directory uses the style from that same legacy project' 'Dir: legacy | Node.js' \
    normal "$legacy_payload" "${project_config[@]}"
check_render 'directory falls back to legacy when the workspace path is empty' 'Dir: legacy | Node.js' \
    normal '{"workspace":{"current_dir":""},"cwd":"legacy"}' "${project_config[@]}"
check_render 'directory falls back to legacy when workspace is malformed' 'Dir: legacy | Node.js' \
    normal '{"workspace":17,"cwd":"legacy"}' "${project_config[@]}"

git -C "$TEST_BASE" init -q &&
    git -C "$TEST_BASE" symbolic-ref HEAD refs/heads/launcher &&
    git -C "$TEST_BASE/legacy" init -q &&
    git -C "$TEST_BASE/legacy" symbolic-ref HEAD refs/heads/legacy || exit 1
touch "$TEST_BASE/Cargo.toml"
printf '%s\n' 'DIRECTORY_STYLE=text' > "$TEST_BASE/.cortado.conf"
chmod 600 "$TEST_BASE/.cortado.conf"
git_config=('MODULE_ORDER=directory,project,git' 'MODULE_GIT=true'
    'GIT_SHOW_STATUS=false' 'GIT_SHOW_FILE_COUNT=false' 'GIT_CACHE_TTL=0')
check_render 'Git also uses the resolved legacy directory' 'Dir: legacy | Node.js | GIT: legacy' \
    normal "$legacy_payload" "${project_config[@]}" "${git_config[@]}"
check_render 'missing paths skip project config, project type and Git for the launcher directory' 'DIR: --' \
    missing '{}' "${project_config[@]}" "${git_config[@]}"
check_render 'a non-string legacy directory is absent' 'DIR: --' \
    normal '{"workspace":{"current_dir":null},"cwd":0}' "${project_config[@]}" "${git_config[@]}"
check_render 'an explicit dot still selects the launcher directory' 'Dir: . | Rust | GIT: launcher' \
    normal '{"cwd":"."}' "${project_config[@]}" "${git_config[@]}"

direct_directory() (
    local input_json='{"cwd":"unrelated"}'
    # shellcheck source=modules/utils.sh
    . "$PROJECT_ROOT/modules/utils.sh"
    # shellcheck source=modules/directory.sh
    . "$PROJECT_ROOT/modules/directory.sh"
    USE_ICONS=false module_directory /work/explicit
)
assert_eq 'directory uses its explicit argument in a direct call' 'DIR: explicit' "$(direct_directory)"

check_render 'directory preserves a dash-prefixed basename' 'DIR: -foo' normal '{"cwd":"-foo"}'
check_render 'directory shows absence when basename fails for the workspace path' 'DIR: --' \
    failed-basename '{"workspace":{"current_dir":"/nonexistent/fixture-project"}}'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
