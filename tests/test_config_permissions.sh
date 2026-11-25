#!/bin/bash
# Exercise trusted config loading through the statusline, editor, and installer.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented
mkdir "$TEST_BASE/bin" "$TEST_BASE/project" || exit 1

REAL_STAT=$(command -v stat)
REAL_UNAME=$(command -v uname)
REAL_READLINK=$(command -v readlink)
export REAL_STAT REAL_UNAME REAL_READLINK
# The old renderer only hits a PATH stat stub on its GNU branch.
cat > "$TEST_BASE/bin/uname" <<'STUB'
#!/bin/bash
if [ -n "${TEST_STAT_CASE:-}" ]; then printf '%s\n' Linux
else exec "$REAL_UNAME" "$@"
fi
STUB
cat > "$TEST_BASE/bin/stat" <<'STUB'
#!/bin/bash
if [ "$("$REAL_UNAME")" = Darwin ]; then
    opt=-f format='%p:%u'
else
    opt=-c format='%a:%u'
fi
if [ "$1" = -c ] && [ "$2" = '%a' ]; then
    if [ "$3" = "$TEST_METADATA_PATH" ] && [ "${TEST_STAT_CASE:-}" = failed ]; then
        exit 1
    fi
    if [ "$opt" = -f ]; then
        exec "$REAL_STAT" -f '%Lp' "$3"
    fi
fi
if [ "$1" != "$opt" ] || [ "$2" != "$format" ]; then
    exec "$REAL_STAT" "$@"
fi
shift 2
status=0
for path in "$@"; do
    case "$path" in
        "$TEST_METADATA_PATH")
            mode=$("$REAL_STAT" "$opt" "${format%:%u}" "$path") || exit 1
            case "$TEST_STAT_CASE" in
                failed)
                    # A command can print valid-looking output and still fail.
                    "$REAL_STAT" "$opt" "$format" "$path" || exit 1
                    status=1
                    ;;
                empty) exit 0 ;;
                malformed-mode) printf '0000600:%s\n' "$EUID" ;;
                missing-owner) printf '%s:\n' "$mode" ;;
                foreign) printf '%s:%s\n' "$mode" "$((EUID + 1))" ;;
                root) printf '%s:0\n' "$mode" ;;
                retarget)
                    "$REAL_STAT" "$opt" "$format" "$path" || exit 1
                    ln -sf "$TEST_NEW_TARGET" "$TEST_LINK_PATH" || exit 1
                    ;;
            esac
            ;;
        *) "$REAL_STAT" "$opt" "$format" "$path" || exit 1 ;;
    esac
done
exit "$status"
STUB
cat > "$TEST_BASE/bin/readlink" <<'STUB'
#!/bin/bash
"$REAL_READLINK" "$@" || exit 1
exit "${TEST_READLINK_STATUS:-0}"
STUB
chmod 700 "$TEST_BASE/bin/uname" "$TEST_BASE/bin/stat" "$TEST_BASE/bin/readlink" || exit 1

export CLAUDE_CONFIG_DIR CACHE_DIR
new_sandbox() {
    CLAUDE_CONFIG_DIR=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
    CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
    config="$CLAUDE_CONFIG_DIR/cortado.conf"
}

write_override() {
    printf '%s\n' 'MODULE_ORDER="model"' 'MODULE_MODEL="true"' \
        'USE_ICONS="true"' 'MODEL_ICON="OVERRIDE"' > "$1" &&
        chmod 600 "$1" || exit 1
}

payload=$(jq -nc --arg dir "$TEST_BASE/project" '{
    workspace: {current_dir: $dir}, model: {display_name: "Opus"},
    rate_limits: {five_hour: {used_percentage: 20}, seven_day: {used_percentage: 30}}
}') || exit 1
tree="$REPO_ROOT"
render() {
    printf '%s\n' "$payload" | /bin/bash "$tree/cortado.sh" \
        > "$TEST_BASE/stdout" 2> "$TEST_BASE/stderr"
    rendered=$(sed $'s/\x1b\\[[0-9;]*m//g' "$TEST_BASE/stdout")
}

assert_refused() {
    local label="$1"
    assert_not_contains "$label leaves the override out of the statusline" OVERRIDE "$rendered"
    assert_contains "$label still renders the model" 'Opus' "$rendered"
    assert_file_contains "$label reports refusal on stderr" 'refusing to source config' "$TEST_BASE/stderr"
}

new_sandbox
write_override "$config"
render
assert_eq 'An owner-only override is sourced' 'OVERRIDE Opus' "$rendered"

new_sandbox
write_override "$config"
case "$("$REAL_UNAME")" in
    Darwin) foreign_ostype=linux-gnu ;;
    *) foreign_ostype=darwin ;;
esac
OSTYPE="$foreign_ostype" render
assert_eq 'Native stat is selected when OSTYPE describes a different platform' 'OVERRIDE Opus' "$rendered"

for stat_case in failed empty malformed-mode missing-owner foreign; do
    new_sandbox
    write_override "$config"
    PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE="$stat_case" TEST_METADATA_PATH="$config" render
    assert_refused "Config metadata $stat_case"
done

new_sandbox
write_override "$config"
PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=foreign TEST_METADATA_PATH="$CLAUDE_CONFIG_DIR" render
assert_refused 'A parent owned by another user'

if [ "$EUID" -ne 0 ]; then
    new_sandbox
    write_override "$config"
    PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=root TEST_METADATA_PATH="$config" render
    assert_refused 'A root-owned user override'

    new_sandbox
    PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=root TEST_METADATA_PATH="$REPO_ROOT/cortado.conf" render
    assert_empty 'A root-owned packaged config is trusted' "$(cat "$TEST_BASE/stderr")"
fi

for mode in 620 602; do
    new_sandbox
    write_override "$config"
    chmod "$mode" "$config"
    render
    assert_refused "A file with mode $mode"
done

for mode in 770 707; do
    new_sandbox
    write_override "$config"
    chmod "$mode" "$CLAUDE_CONFIG_DIR"
    render
    assert_refused "A parent with mode $mode"
done

new_sandbox
write_override "$config"
chmod 1777 "$CLAUDE_CONFIG_DIR"
render
assert_eq 'A sticky parent protects an owner-only override' 'OVERRIDE Opus' "$rendered"

mkdir -m 700 "$TEST_BASE/safe target" "$TEST_BASE/shared target"
write_override "$TEST_BASE/safe target/override"
write_override "$TEST_BASE/shared target/override"
chmod 770 "$TEST_BASE/shared target"
new_sandbox
ln -s '../safe target/override' "$config"
render
assert_eq 'A relative symlink to a safe target is sourced' 'OVERRIDE Opus' "$rendered"

new_sandbox
write_override "$TEST_BASE/safe target/replacement"
printf 'MODEL_ICON=REPLACEMENT\n' >> "$TEST_BASE/safe target/replacement"
ln -s '../safe target/override' "$config"
PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=retarget TEST_METADATA_PATH="$TEST_BASE/safe target/override" \
    TEST_LINK_PATH="$config" TEST_NEW_TARGET="$TEST_BASE/safe target/replacement" render
assert_eq 'The renderer sources the checked target if a symlink changes' 'OVERRIDE Opus' "$rendered"

new_sandbox
mkdir -m 700 "$TEST_BASE/safe target/subdir"
newline_target="$TEST_BASE/safe target/override"$'\n'
write_override "$newline_target"
printf 'MODEL_ICON=NEWLINE\n' >> "$newline_target"
ln -s 'subdir/../override'$'\n' "$TEST_BASE/safe target/second link"
ln -s "$TEST_BASE/safe target/second link" "$config"
render
assert_eq 'A symlink chain preserves the complete safe target name' 'NEWLINE Opus' "$rendered"

new_sandbox
ln -s '../safe target/override' "$config"
PATH="$TEST_BASE/bin:$PATH" TEST_READLINK_STATUS=1 render
assert_refused 'A symlink read failure'

new_sandbox
ln -s "$TEST_BASE/shared target/override" "$config"
render
assert_refused 'A symlink to a file in a writable parent'

new_sandbox
chmod 602 "$TEST_BASE/safe target/override"
ln -s '../safe target/override' "$config"
render
assert_refused 'A symlink to a writable file'
chmod 600 "$TEST_BASE/safe target/override"

new_sandbox
ln -s absent "$config"
render
assert_refused 'A broken config symlink'

new_sandbox
ln -s cortado.conf "$config"
render
assert_refused 'A looped config symlink'

new_sandbox
for ((link=0; link<40; link++)); do
    ln -s "link-$((link + 1))" "$CLAUDE_CONFIG_DIR/link-$link"
done
ln -s link-0 "$config"
write_override "$CLAUDE_CONFIG_DIR/link-40"
render
assert_refused 'A config symlink chain over the resolution limit'

new_sandbox
write_override "$CLAUDE_CONFIG_DIR/override"
ln -s 'missing-parent/override' "$config"
render
assert_refused 'A symlink with a missing target parent'

new_sandbox
mkdir -m 700 "$config"
render
assert_refused 'A non-regular config'

new_sandbox
write_override "$CLAUDE_CONFIG_DIR/barista.conf"
PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=foreign TEST_METADATA_PATH="$CLAUDE_CONFIG_DIR/barista.conf" render
assert_refused 'A foreign-owned legacy override'
if [ ! -e "$config" ]; then
    pass 'Migration does not copy a foreign-owned override'
else
    fail 'Migration does not copy a foreign-owned override'
fi

new_sandbox
printf '%s\n' 'COLOR_THEME=minimal' 'printf "OVERRIDE_MARKER\n"' > "$config"
chmod 600 "$config"
editor_output=$(PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=foreign TEST_METADATA_PATH="$config" \
    /bin/bash "$REPO_ROOT/cortado.sh" config --show 2> "$TEST_BASE/stderr")
assert_not_contains 'The editor leaves shell syntax inert in an unsafe override' OVERRIDE_MARKER "$editor_output"
assert_contains 'The editor can still read an unsafe override as literal settings' 'COLOR_THEME=minimal' "$editor_output"

new_sandbox
tree="$TEST_BASE/debug"
mkdir -m 700 "$tree"
cp "$REPO_ROOT/cortado.sh" "$REPO_ROOT/cortado.conf" "$tree/"
chmod 600 "$tree/cortado.conf"
printf '\nDEBUG_MODE=true\n' >> "$tree/cortado.conf"
ln -s "$REPO_ROOT/modules" "$tree/modules"
ln -s "$REPO_ROOT/lib" "$tree/lib"
write_override "$config"
chmod 620 "$config"
render
assert_file_contains 'Debug mode logs a config refusal' 'refusing to source config' "$CLAUDE_CONFIG_DIR/cortado.log"
tree="$REPO_ROOT"

# Load the actual installer validation and migration functions without running main.
# shellcheck source=install.sh
. "$REPO_ROOT/install.sh"
new_sandbox
printf '%s\n' 'printf "INSTALLER_OVERRIDE\n"' > "$config"
chmod 600 "$config"
assert_eq 'Installer validation reads a safe config' INSTALLER_OVERRIDE "$(validate_config "$config")"
chmod 620 "$config"
installer_status=0
installer_output=$(validate_config "$config" 2> "$TEST_BASE/stderr") || installer_status=$?
assert_empty 'Installer validation never runs an unsafe config' "$installer_output"
assert_eq 'Installer validation reports refusal through its exit status' 1 "$installer_status"
assert_file_contains 'Installer validation reports refusal on stderr' 'refusing to source config' "$TEST_BASE/stderr"

new_sandbox
write_override "$CLAUDE_CONFIG_DIR/barista.conf"
migration_status=0
PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=foreign TEST_METADATA_PATH="$CLAUDE_CONFIG_DIR/barista.conf" \
    migrate_legacy_user_config "$CLAUDE_CONFIG_DIR/barista.conf" "$config" \
    > "$TEST_BASE/stdout" 2> "$TEST_BASE/stderr" || migration_status=$?
assert_eq 'Installer migration refuses a foreign-owned config' 1 "$migration_status"
assert_file_contains 'Installer migration reports refusal on stderr' 'refusing to source config' "$TEST_BASE/stderr"

new_sandbox
# Exercise creation of both the config root and the runtime directory.
CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR/new-root"
CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
install_status=0
(umask 002; HOME="$TEST_BASE/project" /bin/bash "$REPO_ROOT/install.sh" --minimal --skip-update-check --no-color) \
    > "$TEST_BASE/install.out" 2> "$TEST_BASE/stderr" || install_status=$?
assert_eq 'Installer succeeds under umask 002' 0 "$install_status"
if [ "$install_status" -ne 0 ]; then
    cat "$TEST_BASE/install.out" "$TEST_BASE/stderr"
fi
assert_empty 'The generated config is accepted by the shared check' "$(cat "$TEST_BASE/stderr")"
assert_match 'The installer creates a private config root' '^drwx------' "$(ls -ld "$CLAUDE_CONFIG_DIR")"
assert_match 'The installer creates a private runtime directory' '^drwx------' "$(ls -ld "$CLAUDE_CONFIG_DIR/cortado")"
assert_match 'The installer creates an owner-only packaged config' '^-rw-------' "$(ls -ld "$CLAUDE_CONFIG_DIR/cortado/cortado.conf")"

new_sandbox
install_status=0
HOME="$TEST_BASE/project" PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=failed \
    TEST_METADATA_PATH="$CLAUDE_CONFIG_DIR/cortado/cortado.conf" \
    /bin/bash "$REPO_ROOT/install.sh" --minimal --skip-update-check --no-color \
    > "$TEST_BASE/install.out" 2> "$TEST_BASE/stderr" || install_status=$?
assert_eq 'Installer exits when it cannot verify the generated config' 1 "$install_status"
assert_not_contains 'Installer stops before the sample when config validation fails' \
    'Testing statusline before applying' "$(cat "$TEST_BASE/install.out")"

partial_source="$TEST_BASE/partial-source"
mkdir -p "$partial_source/lib"
cp "$REPO_ROOT/cortado.sh" "$partial_source/"
cp "$REPO_ROOT/lib/config-tui.sh" "$partial_source/lib/"
ln -s "$REPO_ROOT/modules" "$partial_source/modules"
assert_rc 'Runtime copy requires the shared config permission helper' 1 \
    copy_runtime_files "$partial_source" "$TEST_BASE/partial-dest"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
