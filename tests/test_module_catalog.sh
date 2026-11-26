#!/bin/bash
# Exercise module discovery through the shipped entry points.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$ROOT/tests/lib/assert.sh" plain
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
umask 077
tree="$TEST_BASE/tree"
mkdir -p "$tree" "$TEST_BASE/project"
cp -R "$ROOT"/cortado.sh "$ROOT"/cortado.conf "$ROOT"/install.sh "$ROOT"/VERSION \
    "$ROOT"/lib "$ROOT"/modules "$tree/" || exit 1
cd "$TEST_BASE/project" || exit 1

export CLAUDE_CONFIG_DIR="$TEST_BASE/config" CACHE_DIR="$TEST_BASE/config/cortado-cache"
mkdir "$CLAUDE_CONFIG_DIR"
user_dir="$CLAUDE_CONFIG_DIR/cortado-modules"
mkdir "$user_dir"

render() {
    printf '%s' "${1-'{}'}" | /bin/bash "$tree/cortado.sh"
}

project_payload() {
    jq -nc --arg cwd "$PWD" '{cwd:$cwd}'
}

cat > "$tree/modules/fixture.sh" <<'MODULE'
# @cortado-module fixture
# @default true
# @args dir
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @config FIXTURE_LABEL:string
# @description Fixture directory
module_fixture() {
    printf '%s %s%s\n' "${FIXTURE_LABEL:-Fixture}" "${1##*/}" "${FIXTURE_UNDECLARED:+ $FIXTURE_UNDECLARED}"
}
MODULE

assert_contains 'the config CLI lists a module added as one file' 'Fixture directory' \
    "$(/bin/bash "$tree/cortado.sh" config --list)"
assert_contains 'the installer lists the same module' 'fixture - ' \
    "$(/bin/bash "$tree/install.sh" --help)"
printf '%s\n' 'MODULE_ORDER=fixture' > "$CLAUDE_CONFIG_DIR/cortado.conf"
printf '%s\n' 'FIXTURE_LABEL=Project' 'FIXTURE_UNDECLARED=ignored' > .cortado.conf
assert_eq 'the declared dir argument and project setting reach the module' 'Project project' \
    "$(render "$(project_payload)")"
printf '%s\n' 'MODULE_FIXTURE=false' >> .cortado.conf
assert_eq 'a project can disable the discovered module' '' "$(render "$(project_payload)")"
rm .cortado.conf

cat > "$tree/modules/payload-probe.sh" <<'MODULE'
# @cortado-module payload-probe
# @default true
# @args payload
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
module_payload_probe() {
    if [ "$#" -ne 1 ] || [ "$1" != "$EXPECTED_PAYLOAD" ]; then
        printf '%s\n' 'Payload argument missing'
    else
        printf 'Payload %s\n' "${CTX_CONTEXT_PERCENT/#-/--}"
    fi
}
MODULE
printf '%s\n' 'MODULE_ORDER=payload-probe' > "$CLAUDE_CONFIG_DIR/cortado.conf"
for entry in '{}' '{"used_percentage":null}' '{"used_percentage":0}'; do
    payload='{"context_window":'"$entry"'}'
    expected='Payload --'
    case "$entry" in *:0*) expected='Payload 0' ;; esac
    assert_eq "the payload argument preserves $entry" "$expected" "$(EXPECTED_PAYLOAD="$payload" render "$payload")"
done

awk '
    /^### Crafting Custom Modules$/ { recipe=1; next }
    recipe && /^## / { exit }
    recipe && /^```/ { if (code) code=0; else { n++; code=1 }; next }
    recipe && code && n==1 { print }
' "$ROOT/README.md" > "$user_dir/mycustom.sh"
awk '
    /^### Crafting Custom Modules$/ { recipe=1; next }
    recipe && /^## / { exit }
    recipe && /^```/ { if (code) code=0; else { n++; code=1 }; next }
    recipe && code && n==2 { print }
' "$ROOT/README.md" > "$CLAUDE_CONFIG_DIR/cortado.conf"

recipe_render() { render '{"model":{"display_name":"Opus"}}'; }
assert_eq 'the README recipe produces the custom segment' '🤖 Opus | 🎯 My Output' "$(recipe_render)"
assert_contains 'the config CLI lists the owner-controlled user module' '] mycustom' \
    "$(/bin/bash "$tree/cortado.sh" config --list)"

cat > "$user_dir/mycustom-path.sh" <<'MODULE'
# @cortado-module mycustom-path
module_mycustom_path() { printf '%s\n' 'Other custom module'; }
MODULE
assert_eq 'a similar module ID cannot change an authorized source path' '🤖 Opus | 🎯 My Output' \
    "$(recipe_render 2>/dev/null)"
rm "$user_dir/mycustom-path.sh"

chmod 620 "$user_dir/mycustom.sh"
assert_eq 'a group-writable user module cannot render' '🤖 Opus' "$(recipe_render 2>/dev/null)"
chmod 602 "$user_dir/mycustom.sh"
assert_eq 'a world-writable user module cannot render' '🤖 Opus' "$(recipe_render 2>/dev/null)"
chmod 600 "$user_dir/mycustom.sh"

chmod 720 "$user_dir"
assert_eq 'a group-writable module directory cannot supply code' '🤖 Opus' "$(recipe_render 2>/dev/null)"
chmod 700 "$user_dir"
chmod 702 "$CLAUDE_CONFIG_DIR"
assert_eq 'a world-writable config parent cannot supply modules' '🤖 Opus' "$(recipe_render 2>/dev/null)"
chmod 700 "$CLAUDE_CONFIG_DIR"

mv "$user_dir" "$CLAUDE_CONFIG_DIR/other-modules"
ln -s other-modules "$user_dir"
assert_eq 'a symlink cannot replace the user module directory' '🤖 Opus' "$(recipe_render 2>/dev/null)"
rm "$user_dir"
mv "$CLAUDE_CONFIG_DIR/other-modules" "$user_dir"

mv "$user_dir/mycustom.sh" "$user_dir/target"
ln -s target "$user_dir/mycustom.sh"
chmod 620 "$user_dir/target"
assert_eq 'a symlink to a writable file cannot render' '🤖 Opus' "$(recipe_render 2>/dev/null)"
chmod 600 "$user_dir/target"
assert_eq 'a symlink to a safe file in the checked directory renders' '🤖 Opus | 🎯 My Output' "$(recipe_render)"
rm "$user_dir/mycustom.sh"
mv "$user_dir/target" "$CLAUDE_CONFIG_DIR/target"
ln -s ../target "$user_dir/mycustom.sh"
assert_eq 'a module symlink cannot leave its directory' '🤖 Opus' "$(recipe_render 2>/dev/null)"
rm "$user_dir/mycustom.sh"
mv "$CLAUDE_CONFIG_DIR/target" "$user_dir/mycustom.sh"

mkdir "$TEST_BASE/bin"
cat > "$TEST_BASE/bin/stat" <<'STAT'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        */cortado-modules/mycustom.sh)
            [ "${TEST_STAT_FAILURE:-false}" != true ] || exit 1
            if [[ "${BASH_VERSINFO[5]}" == *-darwin* ]]; then
                printf '100600:%s\n40700:%s\n' "$((EUID+1))" "$EUID"
            else
                printf '600:%s\n700:%s\n' "$((EUID+1))" "$EUID"
            fi
            exit 0
            ;;
    esac
done
exec /usr/bin/stat "$@"
STAT
chmod 700 "$TEST_BASE/bin/stat"
assert_eq 'a user module with a different owner cannot render' '🤖 Opus' \
    "$(PATH="$TEST_BASE/bin:$PATH" recipe_render 2>/dev/null)"
assert_eq 'a user module with unreadable ownership metadata cannot render' '🤖 Opus' \
    "$(TEST_STAT_FAILURE=true PATH="$TEST_BASE/bin:$PATH" recipe_render 2>/dev/null)"

sed 's/mycustom/UnsafeName/g' "$user_dir/mycustom.sh" > "$user_dir/UnsafeName.sh"
printf '%s\n' 'MODULE_ORDER=UnsafeName' 'MODULE_UNSAFENAME=true' > "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_not_contains 'a mixed-case module ID never reaches the catalog' '] UnsafeName' \
    "$(/bin/bash "$tree/cortado.sh" config --list)"
assert_eq 'a mixed-case module ID cannot run' '' "$(render)"

# Record attempts to source the file even if they yield no segment.
cat >> "$user_dir/mycustom.sh" <<'MODULE'
printf '%s\n' sourced >> "$CLAUDE_CONFIG_DIR/loaded"
MODULE
rm -f "$CLAUDE_CONFIG_DIR/loaded"
printf '%s\n' 'MODULE_ORDER=fixture' 'MODULE_MYCUSTOM=true' > "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_eq 'a user module stays off when the trusted order omits it' 'Fixture project' \
    "$(render "$(project_payload)")"
printf '%s\n' 'MODULE_ORDER=mycustom' > .cortado.conf
assert_eq 'an untrusted project order cannot activate user code' '' "$(render "$(project_payload)")"
if [ -e "$CLAUDE_CONFIG_DIR/loaded" ]; then
    fail 'user module source cannot run without trusted selection'
else
    pass 'user module source cannot run without trusted selection'
fi
rm .cortado.conf

printf '%s\n' 'MODULE_ORDER=fixture' 'MODULE_FIXTURE=true' > "$CLAUDE_CONFIG_DIR/cortado.conf"
preview=$(
    # shellcheck disable=SC1090
    . "$tree/install.sh"
    init_installer_catalog
    SELECTED_MODULES=(fixture)
    setup_colors
    show_statusline_preview
)
assert_contains 'the installer preview runs the selected fixture through Cortado' 'Fixture ' "$preview"

printf '#!/bin/sh\nexit 1\n' > "$TEST_BASE/bin/awk"
chmod 700 "$TEST_BASE/bin/awk"
assert_eq 'a failed metadata reader reports an unavailable catalog' 'cortado: module catalog unavailable' \
    "$(PATH="$TEST_BASE/bin:$PATH" render 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
