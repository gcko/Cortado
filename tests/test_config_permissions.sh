#!/bin/bash
# Exercise trusted config loading through the statusline, editor, and installer.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented
mkdir "$TEST_BASE/bin" "$TEST_BASE/project" || exit 1

REAL_STAT=/usr/bin/stat
REAL_UNAME=$(command -v uname)
REAL_READLINK=$(command -v readlink)
export REAL_STAT REAL_UNAME REAL_READLINK
cat > "$TEST_BASE/bin/stat" <<'STUB'
#!/bin/bash
if [ "$("$REAL_UNAME")" = Darwin ]; then
    opt=-f format='%p:%u'
else
    opt=-c format='%a:%u'
fi
if [ "$1" != "$opt" ] || [ "$2" != "$format" ]; then
    exec "$REAL_STAT" "$@"
fi
shift 2
if [ "${TEST_STAT_CASE:-}" = outage ]; then
    exit 1
fi
status=0
for path in "$@"; do
    case "$path" in
        "${TEST_METADATA_PATH:-}"|*/.cortado-install.*/cortado/cortado.conf)
            if [ -z "${TEST_STAT_CASE:-}" ]; then
                "$REAL_STAT" "$opt" "$format" "$path" || exit 1
                continue
            fi
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
cat > "$TEST_BASE/bin/cp" <<'STUB'
#!/bin/bash
if [ "${TEST_COPY_FAIL:-false}" = true ] && [[ "$1:$2" = -p:*/barista.conf ]]; then
    printf '%s\n' 'MODEL_ICON=INCOMPLETE' > "$3"
    exit 1
fi
if [ -n "${TEST_COPY_ARRIVAL:-}" ] && [[ "$1:$2" = -p:*/barista.conf ]]; then
    /bin/cp "$@" || exit 1
    if [ "$TEST_COPY_ARRIVAL" = dangling ]; then
        ln -s absent "$CLAUDE_CONFIG_DIR/cortado.conf"
    else
        printf '%s\n' 'MODULE_ORDER=model' 'MODULE_MODEL=true' 'MODEL_ICON=ARRIVED' > "$CLAUDE_CONFIG_DIR/cortado.conf"
        chmod 600 "$CLAUDE_CONFIG_DIR/cortado.conf"
    fi
    exit
fi
exec /bin/cp "$@"
STUB
chmod 700 "$TEST_BASE/bin/"* || exit 1

# Inject a native stat failure only into a disposable copy, even on Darwin
# where the renderer should bypass stat on PATH.
fault_tree="$TEST_BASE/fault-tree"
(umask 077; mkdir -p "$fault_tree/lib") || exit 1
cp "$REPO_ROOT/"{cortado.sh,cortado.conf,install.sh,VERSION} "$fault_tree/" || exit 1
chmod 600 "$fault_tree/cortado.conf" || exit 1
ln -s "$REPO_ROOT/modules" "$fault_tree/modules" || exit 1
# Link every other shipped library, so the copy loads like an install.
for lib_file in "$REPO_ROOT"/lib/*.sh; do
    [ "${lib_file##*/}" = config-permissions.sh ] || ln -s "$lib_file" "$fault_tree/lib/" || exit 1
done
sed -e 's@/usr/bin/stat @command stat @g' \
    -e 's/^check_trusted_config()/_native_check_trusted_config()/' "$REPO_ROOT/lib/config-permissions.sh" \
    > "$fault_tree/lib/config-permissions.sh" || exit 1
cat >> "$fault_tree/lib/config-permissions.sh" <<'STUB'

check_trusted_config() {
    if [ "$1" = "${TEST_CHECK_INPUT:-}" ] &&
       [[ -z "${TEST_CHECK_CALLER:-}" || "${FUNCNAME[1]:-}" = "$TEST_CHECK_CALLER" ]]; then
        REPLY="$TEST_CHECKED_PATH"
    else
        _native_check_trusted_config "$@"
    fi
}
STUB

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
    render_status=0
    printf '%s\n' "$payload" | /bin/bash "$@" "$tree/cortado.sh" \
        > "$TEST_BASE/stdout" 2> "$TEST_BASE/stderr" || render_status=$?
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

if [ "$("$REAL_UNAME")" = Darwin ]; then
    gnu_stat=$(type -P gstat)
    if [ -z "$gnu_stat" ]; then
        for candidate in /opt/homebrew/opt/coreutils/libexec/gnubin/stat /usr/local/opt/coreutils/libexec/gnubin/stat; do
            if [ -x "$candidate" ]; then
                gnu_stat="$candidate"
                break
            fi
        done
    fi
    if [ -n "$gnu_stat" ]; then
        gnu_bin="$TEST_BASE/gnu-bin"
        mkdir "$gnu_bin" && ln -s "$gnu_stat" "$gnu_bin/stat" || exit 1
        new_sandbox
        write_override "$config"
        printf '%s\n' 'MODEL_ICON=PROBE' >> "$config"
        PATH="$gnu_bin:$PATH" render
        assert_eq 'GNU stat on Darwin PATH leaves a private override active' 'PROBE Opus' "$rendered"
        new_sandbox
        gnu_install_status=0
        PATH="$gnu_bin:$PATH" HOME="$TEST_BASE/project" \
            /bin/bash "$REPO_ROOT/install.sh" --minimal --skip-update-check --no-color \
            > "$TEST_BASE/gnu-install.log" 2>&1 || gnu_install_status=$?
        assert_eq 'GNU stat on Darwin PATH permits a minimal install' 0 "$gnu_install_status"
    else
        printf '  SKIP: GNU stat unavailable on Darwin\n'
    fi
fi

tree="$fault_tree"
for stat_case in failed empty malformed-mode missing-owner foreign; do
    new_sandbox
    write_override "$config"
    PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE="$stat_case" TEST_METADATA_PATH="$config" render
    assert_refused "Config metadata $stat_case"
    case "$stat_case" in
        empty|malformed-mode|missing-owner)
            assert_file_contains "Config metadata $stat_case is reported as invalid" \
                'invalid permission metadata' "$TEST_BASE/stderr"
            ;;
    esac
done

new_sandbox
write_override "$config"
mkdir -m 700 "$CACHE_DIR" || exit 1
printf '%s\n' checked-current > "$CACHE_DIR/update_check" || exit 1
tree="$fault_tree" PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=outage \
    payload='{"model":{"display_name":"Opus"}}' render
assert_eq 'A total metadata outage renders successfully' 0 "$render_status"
assert_contains 'A total metadata outage still displays the model' Opus "$rendered"
assert_not_contains 'A total metadata outage ignores the refused override' OVERRIDE "$rendered"
assert_eq 'Both config refusals produce one short notice' 1 \
    "$(grep -oF 'Config refused' "$TEST_BASE/stdout" | wc -l | tr -d ' ')"
assert_contains 'A total metadata outage joins the notice with the default separator' \
    'Config refused | ' "$rendered"
assert_file_contains 'A metadata outage explains the reason on stderr' \
    'could not read permission metadata' "$TEST_BASE/stderr"

new_sandbox
printf '%s\n' 'MODULE_ORDER=model' 'MODULE_MODEL=false' > "$config"
chmod 600 "$config"
tree="$fault_tree" PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=failed TEST_METADATA_PATH="$fault_tree/cortado.conf" render
assert_not_contains 'A trusted explicit disable overrides the built-in model default' Opus "$rendered"
assert_contains 'A packaged refusal is visible when all modules are disabled' 'Config refused' "$rendered"

new_sandbox
write_override "$config"
PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=foreign TEST_METADATA_PATH="$CLAUDE_CONFIG_DIR" render
assert_refused 'A parent owned by another user'
assert_file_contains 'A foreign parent diagnostic identifies the parent owner' \
    'parent must belong to the current user or root' "$TEST_BASE/stderr"

if [ "$EUID" -ne 0 ]; then
    new_sandbox
    write_override "$config"
    PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=root TEST_METADATA_PATH="$config" render
    assert_refused 'A root-owned user override'

    new_sandbox
    PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=root TEST_METADATA_PATH="$tree/cortado.conf" render
    assert_empty 'A root-owned packaged config is trusted' "$(cat "$TEST_BASE/stderr")"

    new_sandbox
    write_override "$config"
    PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=root TEST_METADATA_PATH="$CLAUDE_CONFIG_DIR" render
    assert_eq 'A user file in a root-owned private parent is accepted' 'OVERRIDE Opus' "$rendered"

    new_sandbox
    rc=0
    PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=root TEST_METADATA_PATH="$tree/cortado.conf" \
        /bin/bash "$tree/cortado.sh" config --show > "$TEST_BASE/stdout" 2> "$TEST_BASE/stderr" || rc=$?
    assert_eq 'The editor opens with a root-owned packaged config' 0 "$rc"
    assert_empty 'The editor trusts a root-owned packaged config' "$(cat "$TEST_BASE/stderr")"
fi
tree="$REPO_ROOT"

for mode in 620 602; do
    new_sandbox
    write_override "$config"
    chmod "$mode" "$config"
    render
    assert_refused "A file with mode $mode"
    assert_file_contains "A file with mode $mode identifies the file write bits" \
        'file is group- or world-writable' "$TEST_BASE/stderr"
done

new_sandbox
write_override "$config"
printf '%s\n' DEBUG_MODE=true >> "$config"
chmod 775 "$CLAUDE_CONFIG_DIR"
render
assert_refused 'A 600 file in a 775 parent'
assert_contains 'A refused config alone cannot hide the statusline notice' 'Config refused' "$rendered"
assert_file_contains 'A writable parent diagnostic identifies the parent write bits' \
    'parent is group- or world-writable without the sticky bit' "$TEST_BASE/stderr"
chmod go-w "$CLAUDE_CONFIG_DIR" || exit 1
render
assert_eq 'Removing extra parent write access restores the override' 'OVERRIDE Opus' "$rendered"

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

# A config directory Cortado cannot search hides whether a config exists (#85).
if [ "$EUID" -ne 0 ]; then
    new_sandbox
    write_override "$config"
    chmod 600 "$CLAUDE_CONFIG_DIR"
    render
    chmod 700 "$CLAUDE_CONFIG_DIR"
    assert_refused 'A config directory without search permission'
    assert_contains 'An unsearchable config directory shows the refusal notice' 'Config refused' "$rendered"
    assert_file_contains 'The unsearchable directory refusal names the reason' \
        'cannot search the directory that holds it' "$TEST_BASE/stderr"

    new_sandbox
    hidden_parent="$CLAUDE_CONFIG_DIR"
    CLAUDE_CONFIG_DIR="$hidden_parent/inner"
    mkdir -m 700 "$CLAUDE_CONFIG_DIR"
    write_override "$CLAUDE_CONFIG_DIR/cortado.conf"
    chmod 600 "$hidden_parent"
    render
    chmod 700 "$hidden_parent"
    assert_refused 'A config directory below an unsearchable directory'
    assert_contains 'An unsearchable ancestor shows the refusal notice' 'Config refused' "$rendered"

    new_sandbox
    write_override "$config"
    chmod 600 "$CLAUDE_CONFIG_DIR"
    show_status=0
    /bin/bash "$tree/cortado.sh" config --show > "$TEST_BASE/config.out" 2> "$TEST_BASE/config.err" ||
        show_status=$?
    chmod 700 "$CLAUDE_CONFIG_DIR"
    assert_eq 'Show runs with an unsearchable config directory' 0 "$show_status"
    assert_file_contains 'Show says the unsearchable config is inactive' 'Saved settings are inactive' \
        "$TEST_BASE/config.out"
else
    printf '  SKIP: root searches every directory\n'
fi

new_sandbox
CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR/absent/claude"
render
assert_eq 'A config directory that does not exist renders silently with the defaults' 0 "$render_status"
assert_contains 'A missing config directory still renders the model' 'Opus' "$rendered"
assert_not_contains 'A missing config directory shows no refusal' 'Config refused' "$rendered"
assert_empty 'A missing config directory prints no refusal' "$(cat "$TEST_BASE/stderr")"

# A macOS ACL can grant write access the mode bits do not show (#79).
acl_probe="$TEST_BASE/acl-probe"
if : > "$acl_probe" && chmod +a 'everyone allow read' "$acl_probe" 2>/dev/null; then
    rm -f "$acl_probe"
    me=$(id -un)
    write_module() {
        mkdir -m 700 "$CLAUDE_CONFIG_DIR/cortado-modules" 2>/dev/null
        printf '%s\n' '# @cortado-module mine' '# @default true' '# @args none' \
            'module_mine() { printf "MINE\n"; }' > "$CLAUDE_CONFIG_DIR/cortado-modules/mine.sh"
        chmod 600 "$CLAUDE_CONFIG_DIR/cortado-modules/mine.sh"
        printf '%s\n' 'MODULE_ORDER="model,mine"' 'MODULE_MODEL="true"' 'MODEL_ICON="OVERRIDE"' > "$config"
        chmod 600 "$config"
    }

    for entry in 'everyone allow write,append' 'everyone allow writeattr' 'staff allow chown' \
        "everyone allow read,delete"; do
        new_sandbox
        write_override "$config"
        chmod +a "$entry" "$config" || exit 1
        render
        assert_refused "A config with the ACL entry '$entry'"
        assert_file_contains "The ACL refusal for '$entry' names the entry" \
            'an access control entry lets others write' "$TEST_BASE/stderr"
    done

    # A listing line this cannot read fails closed, here one forged by a file name.
    new_sandbox
    forged="$CLAUDE_CONFIG_DIR/user.conf"$'\n'' 0: forged entry'
    write_override "$forged"
    ln -s "$forged" "$config"
    render
    assert_refused 'A config whose ACL listing has an unreadable entry'
    assert_file_contains 'The unreadable entry is named as the reason' \
        'an access control entry could not be read' "$TEST_BASE/stderr"

    new_sandbox
    write_override "$config"
    chmod +a 'everyone allow add_file,delete_child' "$CLAUDE_CONFIG_DIR" || exit 1
    render
    assert_refused 'A config whose directory has a write ACL entry'
    assert_contains 'A directory ACL refusal shows the notice' 'Config refused' "$rendered"

    new_sandbox
    write_override "$config"
    chmod +a "user:$me allow write,append" "$config" || exit 1
    chmod +a 'everyone deny write,delete' "$config" || exit 1
    chmod +a 'everyone allow read,readattr,readextattr,readsecurity' "$config" || exit 1
    render
    assert_eq 'An owner, deny or read-only ACL entry keeps the override' 'OVERRIDE Opus' "$rendered"

    new_sandbox
    chmod +a "user:$me allow write,file_inherit" "$CLAUDE_CONFIG_DIR" || exit 1
    chmod +a 'everyone allow list,search,file_inherit' "$CLAUDE_CONFIG_DIR" || exit 1
    write_override "$config"
    render
    assert_contains 'The config inherited its owner entry' "user:$me inherited allow write" \
        "$(/bin/ls -le "$config")"
    assert_eq 'Inherited owner and read-only entries keep the override' 'OVERRIDE Opus' "$rendered"

    new_sandbox
    write_module
    render
    assert_eq 'A private user module renders' 'OVERRIDE Opus | MINE' "$rendered"
    chmod +a 'everyone allow write,append' "$CLAUDE_CONFIG_DIR/cortado-modules/mine.sh" || exit 1
    render
    assert_eq 'A user module with a write ACL entry does not run' 'OVERRIDE Opus' "$rendered"

    new_sandbox
    write_module
    chmod +a 'everyone allow add_file,delete_child' "$CLAUDE_CONFIG_DIR/cortado-modules" || exit 1
    render
    assert_eq 'A user module in a directory with a write ACL entry does not run' 'OVERRIDE Opus' "$rendered"

    new_sandbox
    write_module
    chmod +a "user:$me allow write,append" "$CLAUDE_CONFIG_DIR/cortado-modules/mine.sh" || exit 1
    chmod +a 'everyone allow read' "$CLAUDE_CONFIG_DIR/cortado-modules/mine.sh" || exit 1
    render
    assert_eq 'A user module with owner and read-only ACL entries runs' 'OVERRIDE Opus | MINE' "$rendered"
else
    rm -f "$acl_probe"
    printf '  SKIP: chmod +a is not available (macOS ACL cases)\n'
fi

# The ACL listing runs beside stat and must end with its nonce; a listing that
# stopped early (ls failed or was cut off) refuses, whatever it held so far.
acl_parse() {
    /bin/bash -c '. "$1/lib/config-permissions.sh"; _CORTADO_ACL_DONE=done-marker _check_config_acl' _ "$REPO_ROOT"
}
assert_eq 'A finished listing with no ACL entries passes' 0 \
    "$(printf '%s\n' '-rw-------  1 me  staff  0 Nov 26 12:00 /x' done-marker | acl_parse >/dev/null; echo "$?")"
assert_eq 'A finished listing with a read-only entry passes' 0 \
    "$(printf '%s\n' '-rw-------  1 me  staff  0 Nov 26 12:00 /x' ' 0: group:everyone allow read' done-marker |
        acl_parse >/dev/null; echo "$?")"
assert_eq 'A listing without its nonce is refused' 1 \
    "$(printf '%s\n' '-rw-------  1 me  staff  0 Nov 26 12:00 /x' | acl_parse >/dev/null; echo "$?")"
assert_contains 'An unfinished listing names the reason' 'could not read access control lists' \
    "$(printf '%s\n' '-rw-------  1 me  staff  0 Nov 26 12:00 /x' | acl_parse)"
assert_eq 'A write entry after the nonce is not part of the listing' 0 \
    "$(printf '%s\n' done-marker ' 0: group:everyone allow write' | acl_parse >/dev/null; echo "$?")"

mkdir -m 700 "$TEST_BASE/safe target" "$TEST_BASE/shared target"
write_override "$TEST_BASE/safe target/override"
write_override "$TEST_BASE/shared target/override"
chmod 770 "$TEST_BASE/shared target"
new_sandbox
ln -s '../safe target/override' "$config"
render
assert_eq 'A relative symlink to a safe target is sourced' 'OVERRIDE Opus' "$rendered"

checked_path() (
    # shellcheck source=lib/config-permissions.sh
    . "$REPO_ROOT/lib/config-permissions.sh"
    cd "$1" || exit 1
    check_trusted_config "$2" && printf '%s\n' "$REPLY"
)
assert_eq 'A bare relative config name resolves to its exact physical path' "$TEST_BASE/safe target/override" \
    "$(checked_path "$TEST_BASE/safe target" override)"
ln -s override "$TEST_BASE/safe target/same-dir-link" || exit 1
assert_eq 'A same-directory file link resolves to its exact physical target' "$TEST_BASE/safe target/override" \
    "$(checked_path "$TEST_BASE/safe target" same-dir-link)"
ln -s "$TEST_BASE/safe target" "$TEST_BASE/private-directory-link" || exit 1
assert_eq 'A directory link to a private parent keeps the physical target path' "$TEST_BASE/safe target/override" \
    "$(checked_path "$TEST_BASE" private-directory-link/override)"

new_sandbox
ln -s "$TEST_BASE/shared target" "$CLAUDE_CONFIG_DIR/directory-link"
ln -s directory-link/override "$config"
assert_rc 'A config reached through a directory link to a writable parent is refused' 1 \
    checked_path "$CLAUDE_CONFIG_DIR" directory-link/override
render
assert_refused 'A file link through a directory link to a writable parent'

new_sandbox
write_override "$TEST_BASE/safe target/replacement"
printf 'MODEL_ICON=REPLACEMENT\n' >> "$TEST_BASE/safe target/replacement"
ln -s '../safe target/override' "$config"
tree="$fault_tree" PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=retarget TEST_METADATA_PATH="$TEST_BASE/safe target/override" \
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
tree="$fault_tree" PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=foreign TEST_METADATA_PATH="$CLAUDE_CONFIG_DIR/barista.conf" render
assert_refused 'A foreign-owned legacy override'
if [ ! -e "$config" ]; then
    pass 'Migration does not copy a foreign-owned override'
else
    fail 'Migration does not copy a foreign-owned override'
fi

new_sandbox
ln -s "$TEST_BASE/safe target/override" "$CLAUDE_CONFIG_DIR/barista.conf" || exit 1
chmod 770 "$CLAUDE_CONFIG_DIR"
for attempt in first second; do
    render
    assert_eq "A trusted legacy link stays active on the $attempt render in a writable parent" 'OVERRIDE Opus' "$rendered"
    assert_rc "The $attempt render does not shadow the trusted legacy link" 1 test -e "$config"
done

new_sandbox
write_override "$CLAUDE_CONFIG_DIR/barista.conf"
for attempt in first second; do
    PATH="$TEST_BASE/bin:$PATH" TEST_COPY_FAIL=true render
    assert_eq "The $attempt render still uses the trusted legacy config after a failed copy" 'OVERRIDE Opus' "$rendered"
    assert_rc "The $attempt failed copy leaves no partial user config" 1 test -e "$config"
done

new_sandbox
write_override "$CLAUDE_CONFIG_DIR/barista.conf"
PATH="$TEST_BASE/bin:$PATH" TEST_COPY_ARRIVAL=true render
assert_eq 'An interrupted migration uses the checked legacy path for the current render' 'OVERRIDE Opus' "$rendered"
assert_file_contains 'Migration preserves a config that appears during the copy' MODEL_ICON=ARRIVED "$config"
render
assert_eq 'The next render honors the newly arrived config' 'ARRIVED Opus' "$rendered"

new_sandbox
write_override "$CLAUDE_CONFIG_DIR/barista.conf"
PATH="$TEST_BASE/bin:$PATH" TEST_COPY_ARRIVAL=dangling render
assert_eq 'Migration preserves a dangling config that appears during the copy' absent "$(readlink "$config")"
assert_rc 'Migration leaves the newly dangling referent absent' 1 test -e "$CLAUDE_CONFIG_DIR/absent"

new_sandbox
printf '%s\n' 'COLOR_THEME=minimal' 'printf "OVERRIDE_MARKER\n"' > "$config"
chmod 600 "$config"
editor_output=$(PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=foreign TEST_METADATA_PATH="$config" \
    /bin/bash "$fault_tree/cortado.sh" config --show 2> "$TEST_BASE/stderr")
assert_not_contains 'The editor leaves shell syntax inert in an unsafe override' OVERRIDE_MARKER "$editor_output"
assert_contains 'The editor can still read an unsafe override as literal settings' 'COLOR_THEME=minimal' "$editor_output"

# Both fixtures are harmless and parse successfully, so sourcing or copying the
# original argument instead of the checked path produces the wrong value.
checked_fixture="$TEST_BASE/safe target/checked"
printf '%s\n' 'MODULE_ORDER=model,fixture-a' 'MODULE_MODEL=true' 'USE_ICONS=true' \
    'MODEL_ICON=CHECKED' 'COLOR_THEME=vibrant' > "$checked_fixture" || exit 1
chmod 600 "$checked_fixture"
write_unchecked_fixture() {
    printf '%s\n' 'MODULE_ORDER=model,fixture-b' 'MODULE_MODEL=true' 'USE_ICONS=true' \
        'MODEL_ICON=ORIGINAL' 'COLOR_THEME=minimal' > "$1" && chmod 600 "$1" || exit 1
}

new_sandbox
write_unchecked_fixture "$config"
editor_output=$(TEST_CHECK_CALLER=_cfg_load_into_shell TEST_CHECK_INPUT="$config" TEST_CHECKED_PATH="$checked_fixture" \
    /bin/bash "$fault_tree/cortado.sh" config --show)
assert_contains 'The editor reads settings from the checked global path' 'COLOR_THEME=vibrant' "$editor_output"
assert_not_contains 'The editor leaves the original global value unused' 'COLOR_THEME=minimal' "$editor_output"

for migration in copy in-place; do
    new_sandbox
    legacy="$CLAUDE_CONFIG_DIR/barista.conf"
    write_unchecked_fixture "$legacy"
    if [ "$migration" = in-place ]; then chmod 775 "$CLAUDE_CONFIG_DIR"; fi
    tree="$fault_tree" TEST_CHECK_INPUT="$legacy" TEST_CHECKED_PATH="$checked_fixture" render
    assert_eq "Renderer legacy $migration uses the checked config value" 'CHECKED Opus' "$rendered"
    if [ "$migration" = copy ]; then
        assert_rc 'Renderer migration copies the checked config bytes' 0 cmp -s "$checked_fixture" "$config"
    fi
done

new_sandbox
write_override "$CLAUDE_CONFIG_DIR/barista.conf"
ln -s absent "$config" || exit 1
render
assert_refused 'A dangling current config with a trusted legacy file present'
assert_eq 'Renderer migration keeps a dangling destination link' absent "$(readlink "$config")"
assert_rc 'Renderer migration leaves the dangling referent absent' 1 test -e "$CLAUDE_CONFIG_DIR/absent"

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
new_sandbox
write_override "$config"
render -u
assert_eq 'Trusted debug renders under nounset' 0 "$render_status"
assert_eq 'Trusted debug without refusals displays the configured model' 'OVERRIDE Opus' "$rendered"
new_sandbox
ln -s absent "$CLAUDE_CONFIG_DIR/barista.conf" || exit 1
render
assert_refused 'A dangling legacy source'
assert_file_contains 'Trusted debug records the dangling legacy refusal' 'barista.conf:' "$CLAUDE_CONFIG_DIR/cortado.log"
assert_rc 'Renderer migration leaves the destination absent after a dangling legacy refusal' 1 test -e "$config"
tree="$REPO_ROOT"

# Load the actual installer validation and migration functions without running main.
# shellcheck source=install.sh
. "$REPO_ROOT/install.sh"
# main fills the module catalog that validation checks MODULE_ORDER against.
init_installer_catalog || exit 1
new_sandbox
printf '%s\n' 'printf "INSTALLER_OVERRIDE\n"' > "$config"
chmod 600 "$config"
# Validation reads a safe config as data (#33), so the command is named, not run.
assert_eq 'Installer validation reads a safe config as data' \
    'Warning: config line 1 is not read (shell command): printf "INSTALLER_OVERRIDE\n"' "$(validate_config "$config")"
chmod 620 "$config"
installer_status=0
installer_output=$(validate_config "$config" 2> "$TEST_BASE/stderr") || installer_status=$?
assert_empty 'Installer validation never runs an unsafe config' "$installer_output"
assert_eq 'Installer validation reports refusal through its exit status' 1 "$installer_status"
assert_file_contains 'Installer validation reports refusal on stderr' 'refusing to source config' "$TEST_BASE/stderr"
new_sandbox
ln -s absent "$config" || exit 1
assert_rc 'Installer validation refuses a dangling config' 1 validate_config "$config"

new_sandbox
write_override "$CLAUDE_CONFIG_DIR/barista.conf"
migration_status=0
# shellcheck source=lib/config-permissions.sh
. "$fault_tree/lib/config-permissions.sh"
PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=foreign TEST_METADATA_PATH="$CLAUDE_CONFIG_DIR/barista.conf" \
    migrate_legacy_user_config "$CLAUDE_CONFIG_DIR/barista.conf" "$config" \
    > "$TEST_BASE/stdout" 2> "$TEST_BASE/stderr" || migration_status=$?
assert_eq 'Installer migration refuses a foreign-owned config' 1 "$migration_status"
assert_file_contains 'Installer migration reports refusal on stderr' 'refusing to source config' "$TEST_BASE/stderr"

new_sandbox
write_unchecked_fixture "$config"
installer_output=$(TEST_CHECK_INPUT="$config" TEST_CHECKED_PATH="$checked_fixture" validate_config "$config")
assert_eq 'Installer validation reads the checked config value' 'Warning: Unknown module in MODULE_ORDER: fixture-a' \
    "$installer_output"
if [ "$EUID" -ne 0 ]; then
    chmod 600 "$config"
    installer_output=$(PATH="$TEST_BASE/bin:$PATH" TEST_STAT_CASE=root TEST_METADATA_PATH="$config" validate_config "$config")
    assert_eq 'Installer validation accepts a root-owned packaged config' \
        'Warning: Unknown module in MODULE_ORDER: fixture-b' "$installer_output"
fi

new_sandbox
legacy="$CLAUDE_CONFIG_DIR/barista.conf"
write_unchecked_fixture "$legacy"
TEST_CHECK_INPUT="$legacy" TEST_CHECKED_PATH="$checked_fixture" migrate_legacy_user_config "$legacy" "$config" \
    > "$TEST_BASE/stdout" 2> "$TEST_BASE/stderr"
assert_rc 'Installer migration copies the checked config bytes' 0 cmp -s "$checked_fixture" "$config"

new_sandbox
legacy="$CLAUDE_CONFIG_DIR/barista.conf"
write_override "$legacy"
ln -s absent "$config" || exit 1
assert_empty 'Installer migration skips a dangling destination silently' "$(migrate_legacy_user_config "$legacy" "$config" 2>&1)"
assert_eq 'Installer migration preserves the dangling destination link' absent "$(readlink "$config")"
assert_rc 'Installer migration leaves the dangling referent absent' 1 test -e "$CLAUDE_CONFIG_DIR/absent"

new_sandbox
legacy="$CLAUDE_CONFIG_DIR/barista.conf"
ln -s absent "$legacy" || exit 1
assert_rc 'Installer migration refuses a dangling legacy source' 1 migrate_legacy_user_config "$legacy" "$config"
assert_rc 'Installer migration leaves the destination absent after a dangling legacy refusal' 1 test -e "$config"

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
    /bin/bash "$fault_tree/install.sh" --minimal --skip-update-check --no-color \
    > "$TEST_BASE/install.out" 2> "$TEST_BASE/stderr" || install_status=$?
assert_eq 'Installer exits when it cannot verify the generated config' 1 "$install_status"
assert_not_contains 'Installer stops before the sample when config validation fails' \
    'Testing statusline before applying' "$(cat "$TEST_BASE/install.out")"

# cortado config and the renderer judge a symlinked user config by the file
# it resolves to, so a save the renderer would refuse is never silent.
config_cmd() {
    /bin/bash "$REPO_ROOT/cortado.sh" config "$@" > "$TEST_BASE/config.out" 2> "$TEST_BASE/config.err"
}
mkdir -m 700 "$TEST_BASE/linked private" "$TEST_BASE/linked shared" || exit 1
chmod 770 "$TEST_BASE/linked shared" || exit 1
linked_shared="$TEST_BASE/linked shared/override"
linked_private="$TEST_BASE/linked private/override"

new_sandbox
write_override "$linked_shared"
ln -s "$linked_shared" "$config"
assert_rc 'A save through a link into a shared directory succeeds' 0 config_cmd --set MODEL_ICON=SAVED
assert_eq 'The save keeps the user config link' "$linked_shared" "$(readlink "$config")"
assert_file_contains 'The save edits the link target' 'MODEL_ICON="SAVED"' "$linked_shared"
assert_file_contains 'The save says a link target in a shared directory is inactive' \
    "Saved settings are inactive until Cortado can trust $config" "$TEST_BASE/config.err"
assert_file_contains 'The inactive save names the link target parent as the reason' \
    'parent is group- or world-writable without the sticky bit' "$TEST_BASE/config.err"
render
assert_not_contains 'The renderer ignores the saved link target in a shared directory' SAVED "$rendered"
assert_contains 'The renderer still shows the model for a refused link target' Opus "$rendered"
assert_rc 'Show runs for a refused link target' 0 config_cmd --show
assert_file_contains 'Show flags a link target in a shared directory as inactive' \
    'Saved settings are inactive' "$TEST_BASE/config.out"

new_sandbox
write_override "$linked_private"
chmod 660 "$linked_private" || exit 1
cp "$linked_private" "$TEST_BASE/linked-before" || exit 1
ln -s "$linked_private" "$config"
assert_rc 'The writer refuses a group-writable link target' 1 config_cmd --set MODEL_ICON=SAVED
assert_file_contains 'The writer refusal names the link target' \
    "review it, then run: chmod go-w $linked_private" "$TEST_BASE/config.err"
assert_rc 'A refused link target is left byte-identical' 0 cmp -s "$TEST_BASE/linked-before" "$linked_private"
render
assert_refused 'A group-writable link target'
assert_rc 'Show runs for a group-writable link target' 0 config_cmd --show
assert_file_contains 'Show flags a group-writable link target as inactive' \
    'Saved settings are inactive' "$TEST_BASE/config.out"

chmod go-w "$linked_private" || exit 1
assert_rc 'A save through a link to a private target succeeds' 0 config_cmd --set MODEL_ICON=SAVED
assert_not_contains 'A trusted link target saves without an inactive warning' \
    'Saved settings are inactive' "$(cat "$TEST_BASE/config.err")"
render
assert_eq 'The renderer sources the saved private link target' 'SAVED Opus' "$rendered"

new_sandbox
ln -s "$TEST_BASE/safe target/override/" "$config"
render
assert_refused 'A link target with a trailing slash'
assert_contains 'A link target with a trailing slash shows the refusal notice' 'Config refused' "$rendered"
assert_file_contains 'A link target with a trailing slash is not a regular file' \
    'not a regular file' "$TEST_BASE/stderr"
assert_rc 'The writer also refuses a link target with a trailing slash' 1 config_cmd --set MODEL_ICON=SAVED

new_sandbox
ln -s absent "$config"
assert_rc 'Show runs for a dangling user config link' 0 config_cmd --show
assert_file_contains 'Show flags a dangling user config link as inactive' \
    'Saved settings are inactive' "$TEST_BASE/config.out"
assert_not_contains 'Show does not call a dangling user config link missing' \
    'does not exist yet' "$(cat "$TEST_BASE/config.out")"

# The renderer keeps using barista.conf in place when it cannot publish a
# copy, so cortado config must show and edit that same file.
mkdir -m 700 "$TEST_BASE/legacy private" || exit 1
legacy_target="$TEST_BASE/legacy private/barista.conf"
printf '%s\n' 'MODULE_ORDER="model"' 'MODULE_MODEL="true"' 'USE_ICONS="true"' \
    'MODEL_ICON="LEGACY"' 'COLOR_THEME="vibrant"' > "$legacy_target" && chmod 600 "$legacy_target" || exit 1
new_sandbox
chmod 770 "$CLAUDE_CONFIG_DIR"
ln -s "$legacy_target" "$CLAUDE_CONFIG_DIR/barista.conf"
render
assert_eq 'A trusted legacy link renders in a writable config directory' 'LEGACY Opus' "$rendered"
assert_rc 'Show runs for a trusted legacy link' 0 config_cmd --show
assert_file_contains 'Show reads the legacy file the renderer uses' 'COLOR_THEME=vibrant' "$TEST_BASE/config.out"
assert_not_contains 'Show does not call the legacy settings missing' \
    'does not exist yet' "$(cat "$TEST_BASE/config.out")"
assert_rc 'A save edits the legacy file the renderer uses' 0 config_cmd --set MODEL_ICON=EDITED
assert_file_contains 'The legacy save edits the link target' 'MODEL_ICON="EDITED"' "$legacy_target"
assert_rc 'The legacy save creates no shadowing cortado.conf' 1 test -e "$config"
assert_not_contains 'The legacy save is not reported inactive' \
    'Saved settings are inactive' "$(cat "$TEST_BASE/config.err")"
render
assert_eq 'The renderer shows the edited legacy setting' 'EDITED Opus' "$rendered"

new_sandbox
printf '%s\n' 'COLOR_THEME=minimal' 'MODEL_ICON=REFUSED' > "$CLAUDE_CONFIG_DIR/barista.conf"
chmod 620 "$CLAUDE_CONFIG_DIR/barista.conf"
assert_rc 'Show runs for a refused legacy file' 0 config_cmd --show
assert_file_contains 'Show flags a refused legacy file as inactive' \
    'Saved settings are inactive' "$TEST_BASE/config.out"
assert_file_contains 'Show reads a refused legacy file as literal settings' 'COLOR_THEME=minimal' "$TEST_BASE/config.out"
assert_not_contains 'Show does not call a refused legacy file missing' \
    'does not exist yet' "$(cat "$TEST_BASE/config.out")"
assert_rc 'The writer refuses a group-writable legacy file' 1 config_cmd --set MODEL_ICON=EDITED
assert_file_contains 'The legacy refusal gives the chmod hint' \
    "chmod go-w $CLAUDE_CONFIG_DIR/barista.conf" "$TEST_BASE/config.err"
assert_rc 'A refused legacy save creates no cortado.conf' 1 test -e "$config"

# A checkout others can write refuses its packaged config. The editor must
# still start from the renderer's default order and report the refusal once.
shared_checkout="$TEST_BASE/shared checkout"
mkdir "$shared_checkout" && chmod 775 "$shared_checkout" || exit 1
cp "$REPO_ROOT/cortado.sh" "$REPO_ROOT/cortado.conf" "$REPO_ROOT/VERSION" "$shared_checkout/" || exit 1
chmod 644 "$shared_checkout/cortado.conf" || exit 1
ln -s "$REPO_ROOT/modules" "$shared_checkout/modules" || exit 1
ln -s "$REPO_ROOT/lib" "$shared_checkout/lib" || exit 1
default_order='sandbox,version,update,directory,context,git,project,model,cost,rate-limits,time,battery'
new_sandbox
shared_status=0
/bin/bash "$shared_checkout/cortado.sh" config --show > "$TEST_BASE/config.out" 2> "$TEST_BASE/config.err" ||
    shared_status=$?
assert_eq 'Show runs when the packaged config is refused' 0 "$shared_status"
assert_eq 'Show uses the renderer default order when the packaged config is refused' \
    "MODULE_ORDER=$default_order" "$(grep '^MODULE_ORDER=' "$TEST_BASE/config.out")"
assert_eq 'Show reports the packaged refusal once' 1 "$(grep -c 'refusing to source' "$TEST_BASE/config.err")"
shared_status=0
/bin/bash "$shared_checkout/cortado.sh" config --toggle cpu > "$TEST_BASE/config.out" 2> "$TEST_BASE/config.err" ||
    shared_status=$?
assert_eq 'A toggle saves when the packaged config is refused' 0 "$shared_status"
assert_eq 'A toggle keeps the default order and appends the module' \
    "MODULE_ORDER=\"$default_order,cpu\"" "$(grep '^MODULE_ORDER=' "$config")"

# Bash 4+ reports unset variables in pattern expansions under nounset.
nounset_bash=""
for candidate in /bin/bash "$(type -P bash)" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$candidate" ] && [ "$("$candidate" -c "echo \"\${BASH_VERSINFO[0]}\"")" -ge 4 ] 2>/dev/null; then
        nounset_bash="$candidate"
        break
    fi
done
if [ -n "$nounset_bash" ]; then
    new_sandbox
    printf '%s\n' 'set -u' 'MODEL_ICON=NOUNSET' > "$config"
    chmod 600 "$config"
    nounset_status=0
    printf '%s\n' '{"model":{"display_name":"Opus"}}' | "$nounset_bash" "$shared_checkout/cortado.sh" \
        > "$TEST_BASE/stdout" 2> "$TEST_BASE/stderr" || nounset_status=$?
    assert_eq 'A nounset user config without MODULE_ORDER renders under Bash 4+' 0 "$nounset_status"
    assert_not_contains 'A nounset user config without MODULE_ORDER is not unbound' \
        'MODULE_ORDER: unbound variable' "$(cat "$TEST_BASE/stderr")"
else
    printf '  SKIP: no Bash 4+ for the nounset MODULE_ORDER case\n'
fi

partial_source="$TEST_BASE/partial-source"
mkdir -p "$partial_source/lib"
cp "$REPO_ROOT/cortado.sh" "$partial_source/"
cp "$REPO_ROOT/lib/config-tui.sh" "$partial_source/lib/"
ln -s "$REPO_ROOT/modules" "$partial_source/modules"
assert_rc 'Runtime copy requires the shared config permission helper' 1 \
    copy_runtime_files "$partial_source" "$TEST_BASE/partial-dest"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
