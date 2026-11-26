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

# Print code block $1 of the README's custom-module recipe.
recipe_block() {
    awk -v want="$1" '
        /^### Crafting Custom Modules$/ { recipe=1; next }
        recipe && /^## / { exit }
        recipe && /^```/ { if (code) code=0; else { n++; code=1 }; next }
        recipe && code && n==want { print }
    ' "$ROOT/README.md"
}
recipe_block 1 > "$user_dir/mycustom.sh"
recipe_block 2 > "$CLAUDE_CONFIG_DIR/cortado.conf"

recipe_render() { render '{"model":{"display_name":"Opus"}}'; }
assert_eq 'the README recipe produces the custom segment' '🤖 Opus | 🎯 My Output' "$(recipe_render)"

recipe_text=$(awk '/^### Crafting Custom Modules$/ { p=1; next } p && /^## / { exit } p' "$ROOT/README.md")
assert_contains 'the recipe gives the module directory command' 'chmod 700' "$recipe_text"
assert_contains 'the recipe gives the module file command' 'chmod 600' "$recipe_text"

# Ubuntu's default umask 002 leaves new files group-writable. The recipe's own
# permission commands must still produce a segment.
loose="$TEST_BASE/loose"
loose_render=$(
    umask 002
    mkdir "$loose" "$loose-home" "$loose/cortado-modules"
    recipe_block 1 > "$loose/cortado-modules/mycustom.sh"
    recipe_block 2 > "$loose/cortado.conf"
    CLAUDE_CONFIG_DIR="$loose" HOME="$loose-home" /bin/bash -c "$(recipe_block 3)" >/dev/null 2>&1
    CLAUDE_CONFIG_DIR="$loose" HOME="$loose-home" CACHE_DIR="$loose/cortado-cache" recipe_render 2>/dev/null
)
assert_eq 'the recipe works from a umask 002 shell' '🤖 Opus | 🎯 My Output' "$loose_render"
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

# Each user-module guard below has an assertion that fails when the guard is removed.
rm -f "$user_dir/UnsafeName.sh"
list_modules() { /bin/bash "$tree/cortado.sh" config --list 2>/dev/null; }
model_payload='{"model":{"display_name":"Opus"}}'

# Reserved IDs: a user order.sh would otherwise own the flag MODULE_ORDER.
printf '%s\n' '# @cortado-module order' '# @default false' 'module_order() { echo ORDER; }' \
    > "$user_dir/order.sh"
assert_not_contains 'a user module cannot take a reserved ID' '] order ' "$(list_modules)"
rm "$user_dir/order.sh"

# Shipped names: a user git.sh must not replace or duplicate the built-in.
printf '%s\n' '# @cortado-module git' '# @args dir' 'module_git() { echo USER-GIT; }' > "$user_dir/git.sh"
printf '%s\n' 'MODULE_ORDER=git' > "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_not_contains 'a user module cannot replace the built-in of the same name' 'USER-GIT' \
    "$(render "$(project_payload)" 2>/dev/null)"
assert_eq 'the built-in keeps the only catalog entry for its name' 1 "$(list_modules | grep -c '] git ')"
rm "$user_dir/git.sh"

# A user module must not widen the untrusted per-project allowlist, through
# @config or through a field separator in its description.
# shellcheck disable=SC2016 # The module source keeps its expansions literal.
printf '%s\n' '# @cortado-module probe' '# @default true' '# @config PROBE_SECRET:string' \
    'module_probe() { printf "PROBE_SECRET=%s\n" "${PROBE_SECRET:-unset}"; }' > "$user_dir/probe.sh"
# shellcheck disable=SC2016 # The module source keeps its expansions literal.
printf '%s\n' '# @cortado-module probe2' '# @default true' '# @description x| PROBE2_SECRET ' \
    'module_probe2() { printf "PROBE2_SECRET=%s\n" "${PROBE2_SECRET:-unset}"; }' > "$user_dir/probe2.sh"
printf '%s\n' 'MODULE_ORDER="probe,probe2"' > "$CLAUDE_CONFIG_DIR/cortado.conf"
printf '%s\n' 'PROBE_SECRET=project' 'PROBE2_SECRET=project' > .cortado.conf
probes=$(render "$(project_payload)" 2>/dev/null)
assert_contains 'a user @config key is not settable by an untrusted project' 'PROBE_SECRET=unset' "$probes"
assert_contains 'a user description cannot inject a project-settable key' 'PROBE2_SECRET=unset' "$probes"
rm .cortado.conf "$user_dir/probe.sh" "$user_dir/probe2.sh"

printf '# @cortado-module escdesc\n# @description bad\033[31mred\nmodule_escdesc() { :; }\n' \
    > "$user_dir/escdesc.sh"
catalog=$(list_modules)
assert_contains 'a module with a control byte in its description is still listed' '] escdesc ' "$catalog"
case "$catalog" in
    *$'\033'*) fail 'a description cannot put an escape sequence in the catalog' ;;
    *) pass 'a description cannot put an escape sequence in the catalog' ;;
esac
rm "$user_dir/escdesc.sh"

# @config may not name a MODULE_* flag, even in a shipped module.
mkdir "$TEST_BASE/keys"
cp "$tree"/modules/*.sh "$TEST_BASE/keys/"
printf '%s\n' '# @cortado-module zz' '# @config MODULE_GIT:bool' '# @config ZZ_OK:string' 'module_zz() { :; }' \
    > "$TEST_BASE/keys/zz.sh"
keys=$(/bin/bash -c '. "$1/lib/config-permissions.sh"; . "$1/lib/module-registry.sh"
    discover_module_registry "$2" "" >/dev/null 2>&1; printf "%s" "$_CORTADO_PROJECT_KEYS"' \
    _ "$tree" "$TEST_BASE/keys")
assert_contains 'a shipped @config key reaches the project allowlist' ' ZZ_OK ' "$keys"
assert_not_contains 'an @config line cannot name a MODULE_ flag' ' MODULE_GIT ' "$keys"

# The header ID must equal the filename, so a file with no header is not a module.
printf '%s\n' '# @cortado-module other' 'module_named() { echo NAMED; }' > "$user_dir/named.sh"
printf '%s\n' 'module_bare() { echo BARE; }' > "$user_dir/bare.sh"
catalog=$(list_modules)
assert_not_contains 'a header naming another ID is not a module' '] named ' "$catalog"
assert_not_contains 'a file with no header is not a module' '] bare ' "$catalog"
rm "$user_dir/named.sh" "$user_dir/bare.sh"

printf '%s\n' '# @cortado-module guard' '# @default true' 'module_guard() { printf "%s\n" GUARD; }' \
    > "$user_dir/guard.sh"
printf '%s\n' 'MODULE_ORDER="model,guard"' > "$CLAUDE_CONFIG_DIR/cortado.conf"
guard_render() { render "$model_payload" 2>/dev/null; }
assert_eq 'control: a safe user module renders' '🤖 Opus | GUARD' "$(guard_render)"

# The sticky bit protects a shared config, but not module code.
chmod 1777 "$CLAUDE_CONFIG_DIR"
assert_eq 'a sticky world-writable config dir cannot supply modules' '🤖 Opus' "$(guard_render)"
chmod 700 "$CLAUDE_CONFIG_DIR"

# Report another user as the owner of one path. TEST_FOREIGN_POS limits that to
# one stat operand, so the module directory can be foreign where it is the
# target and keep its real owner where it is a file's parent.
mkdir "$TEST_BASE/ownerbin"
cat > "$TEST_BASE/ownerbin/stat" <<'STAT'
#!/bin/bash
out=$(/usr/bin/stat "$@") || exit
n=0 i=0
for arg in "$@"; do
    case "$arg" in -*|%*) continue ;; esac
    i=$((i + 1))
    if [ "$arg" = "${TEST_FOREIGN_PATH:-}" ] && { [ -z "${TEST_FOREIGN_POS:-}" ] || [ "$TEST_FOREIGN_POS" = "$i" ]; }; then
        n=$i
    fi
done
printf '%s\n' "$out" | awk -v n="$n" -v o="$((EUID + 1))" 'BEGIN { FS = OFS = ":" } NR == n { $2 = o } 1'
STAT
chmod 700 "$TEST_BASE/ownerbin/stat"
real_config=$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)
owner_render() { PATH="$TEST_BASE/ownerbin:$PATH" guard_render; }
assert_eq 'control: the owner stub alone changes nothing' '🤖 Opus | GUARD' "$(owner_render)"
assert_eq 'a config dir owned by another user cannot supply modules' '🤖 Opus' \
    "$(TEST_FOREIGN_PATH="$real_config" owner_render)"
assert_eq 'a module dir owned by another user cannot supply modules' '🤖 Opus' \
    "$(TEST_FOREIGN_PATH="$real_config/cortado-modules" TEST_FOREIGN_POS=1 owner_render)"

case "$(uname -s)" in
    Darwin) other_os=linux ;;
    *) other_os=darwin ;;
esac
printf '%s\n' '# @cortado-module guard' '# @default true' "# @platforms $other_os" \
    'module_guard() { printf "%s\n" GUARD; }' > "$user_dir/guard.sh"
assert_eq "a module for $other_os does not run on $(uname -s)" '🤖 Opus' "$(guard_render)"
rm "$user_dir/guard.sh"

# A symlink loop must be refused, not followed forever. Without the limit the
# check spins in a child process, so run it in its own process group and stop
# the whole group if it outlives the deadline.
mkdir "$TEST_BASE/loop"
ln -s b "$TEST_BASE/loop/a"
ln -s a "$TEST_BASE/loop/b"
set -m
/bin/bash -c '. "$1"; check_trusted_config "$2" module' _ \
    "$tree/lib/config-permissions.sh" "$TEST_BASE/loop/a" >/dev/null 2>&1 &
loop_pid=$!
set +m
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$loop_pid" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "$loop_pid" 2>/dev/null; then
    kill -TERM -- "-$loop_pid" 2>/dev/null
    wait "$loop_pid" 2>/dev/null
    fail 'a symlink loop is refused within 5 seconds'
elif wait "$loop_pid"; then
    fail 'a symlink loop is refused within 5 seconds (it was accepted)'
else
    pass 'a symlink loop is refused within 5 seconds'
fi

# Fix-round tests for the user-module loader and catalog.
printf '%s\n' '# @cortado-module guard' '# @default true' 'module_guard() { printf "%s\n" GUARD; }' \
    > "$user_dir/guard.sh"

# Discovery owns every source binding. An inherited one is neither trusted nor kept.
printf '%s\n' 'module_model() { echo ENV_SOURCED; }' > "$TEST_BASE/inherited.sh"
chmod 777 "$TEST_BASE/inherited.sh"
printf '%s\n' 'MODULE_ORDER=model' > "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_eq 'an inherited module source path is ignored' '🤖 Opus' \
    "$(_CORTADO_SOURCE_model="$TEST_BASE/inherited.sh" render "$model_payload" 2>/dev/null)"
stale=$(/bin/bash -c '. "$1/lib/config-permissions.sh"; . "$1/lib/module-registry.sh"
    discover_module_registry "$1/modules" "$2" 2>/dev/null
    discover_module_registry "$1/modules" ""
    printf "%s" "${_CORTADO_SOURCE_guard-}"' _ "$tree" "$user_dir")
assert_eq 'a later discovery forgets earlier user module sources' '' "$stale"

# A trailing slash must not turn the directory into its own parent.
mkdir -m 777 "$TEST_BASE/open"
mkdir -m 700 "$TEST_BASE/open/modules"
for candidate in "$TEST_BASE/open/modules" "$TEST_BASE/open/modules/"; do
    if /bin/bash -c '. "$1"; check_trusted_config "$2" module-directory' _ \
        "$tree/lib/config-permissions.sh" "$candidate" >/dev/null 2>&1; then
        fail "a module directory under a world-writable parent is refused ($candidate)"
    else
        pass "a module directory under a world-writable parent is refused ($candidate)"
    fi
done

# An ID that starts with a hyphen reads as an option to echo and tr.
printf '%s\n' '# @cortado-module -n' '# @default true' '# @description Dash module' \
    'module__n() { echo DASH; }' > "$user_dir/-n.sh"
assert_not_contains 'a module ID cannot start with a hyphen' 'Dash module' "$(list_modules)"
/bin/bash "$tree/cortado.sh" config --toggle -n >/dev/null 2>&1
assert_eq 'toggling a hyphen-led name writes no empty flag' '' \
    "$(grep '^MODULE_=' "$CLAUDE_CONFIG_DIR/cortado.conf")"
rm -- "$user_dir/-n.sh"

printf '%s\n' '# @cortado-module emptydesc' '# @description' 'module_emptydesc() { :; }' \
    > "$user_dir/emptydesc.sh"
assert_match 'an empty description falls back to the module ID' '\] emptydesc +emptydesc$' \
    "$(list_modules | grep emptydesc)"
rm "$user_dir/emptydesc.sh"

# Sourcing defines the function. A false last command in the file must not drop it.
# shellcheck disable=SC2016 # The module source keeps its expansions literal.
printf '%s\n' '# @cortado-module lastfalse' '# @default true' \
    'module_lastfalse() { printf "%s\n" LAST; }' '[ -n "${UNSET_X:-}" ] && X=1' > "$user_dir/lastfalse.sh"
printf '%s\n' 'MODULE_ORDER="model,lastfalse"' > "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_eq 'a user module whose last command is false still renders' '🤖 Opus | LAST' \
    "$(render "$model_payload" 2>/dev/null)"
rm "$user_dir/lastfalse.sh"

# A refusal is a debug diagnostic: silent by default, logged and named in debug mode.
printf '%s\n' '# @cortado-module unsafe' 'module_unsafe() { echo UNSAFE; }' > "$user_dir/unsafe.sh"
chmod 666 "$user_dir/unsafe.sh"
printf '%s\n' 'MODULE_ORDER=model' > "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_eq 'an unsafe user module writes nothing to stderr outside debug mode' '' \
    "$(render "$model_payload" 2>&1 >/dev/null)"
printf '%s\n' 'MODULE_ORDER="model,unsafe"' 'DEBUG_MODE=true' > "$CLAUDE_CONFIG_DIR/cortado.conf"
rm -f "$CLAUDE_CONFIG_DIR/cortado.log"
render "$model_payload" >/dev/null 2>&1
debug_log=$(cat "$CLAUDE_CONFIG_DIR/cortado.log" 2>/dev/null)
assert_contains 'debug mode logs the refused module file' 'refusing to source module with' "$debug_log"
assert_contains 'the refusal names the module file' 'unsafe.sh' "$debug_log"
assert_contains 'debug mode reports a listed refused module as refused' \
    'Refused module in MODULE_ORDER (unsafe owner or permissions): unsafe' "$debug_log"
assert_not_contains 'a refused module is not reported as unknown' 'Unknown module in MODULE_ORDER: unsafe' "$debug_log"
rm "$user_dir/unsafe.sh"
chmod 770 "$user_dir"
rm -f "$CLAUDE_CONFIG_DIR/cortado.log"
printf '%s\n' 'MODULE_ORDER="model,guard"' 'DEBUG_MODE=true' > "$CLAUDE_CONFIG_DIR/cortado.conf"
render "$model_payload" >/dev/null 2>&1
debug_log=$(cat "$CLAUDE_CONFIG_DIR/cortado.log" 2>/dev/null)
assert_contains 'debug mode logs a refused module directory' 'refusing to source module directory' "$debug_log"
assert_contains 'a module in a refused directory is reported as refused' \
    'Refused module in MODULE_ORDER (unsafe owner or permissions): guard' "$debug_log"
chmod 700 "$user_dir"

# The global editor keeps settings that a shipped module declares with @config.
printf '%s\n' 'MODULE_ORDER=fixture' > "$CLAUDE_CONFIG_DIR/cortado.conf"
set_status=0
/bin/bash "$tree/cortado.sh" config --set FIXTURE_LABEL=hello >/dev/null 2>&1 || set_status=$?
assert_eq 'config --set accepts a shipped module @config key' 0 "$set_status"
assert_file_contains 'config --set writes the @config key' 'FIXTURE_LABEL=' "$CLAUDE_CONFIG_DIR/cortado.conf"
/bin/bash "$tree/cortado.sh" config --toggle git >/dev/null 2>&1
assert_file_contains 'config --toggle keeps a shipped module @config key' 'FIXTURE_LABEL=' \
    "$CLAUDE_CONFIG_DIR/cortado.conf"
rm "$user_dir/guard.sh"

# Keep this last: ShellCheck treats variables used after the sourced installer as
# possibly changed in its subshell.
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
