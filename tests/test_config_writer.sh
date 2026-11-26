#!/bin/bash
# ABOUTME: Exercises config edits, symlinks, backups and rendered module flags.
# ABOUTME: Run with: /bin/bash tests/test_config_writer.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/tests/lib/assert.sh" plain
# shellcheck source=tests/lib/sections.sh
. "$SCRIPT_DIR/tests/lib/sections.sh"

# Each section edits its own sandboxed config, so a full run starts each one as
# its own copy of this suite in WRITER_TEST_JOBS lanes (default 4), slowest first.
section="${WRITER_TEST_SECTION:-all}"
if [ "$section" = all ]; then
    run_sections WRITER_TEST_SECTION "${WRITER_TEST_JOBS:-4}" "${BASH_SOURCE[0]}" \
        refused modules permissions failed umask lines usermodule order shell later menu project
fi

TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
umask 077
export CLAUDE_CONFIG_DIR="$TEST_BASE/claude"
export CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
mkdir -p "$CACHE_DIR" "$TEST_BASE/dot files" "$TEST_BASE/bin" "$TEST_BASE/project"
cd "$TEST_BASE" || exit 1
CORTADO="$SCRIPT_DIR/cortado.sh"
config="$CLAUDE_CONFIG_DIR/cortado.conf"
target="$TEST_BASE/dot files/user.conf"
stdout="$TEST_BASE/stdout"
stderr="$TEST_BASE/stderr"
before="$TEST_BASE/before"
expected="$TEST_BASE/expected"
export REAL_MV
REAL_MV=$(command -v mv)

config_edit() {
    /bin/bash "$CORTADO" config "$@" > "$stdout" 2> "$stderr"
}

file_mode() {
    if [ "$(uname -s)" = Darwin ]; then
        /usr/bin/stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

project="$TEST_BASE/project/.cortado.conf"
project_edit() {
    (cd "$TEST_BASE/project" && config_edit --project "$@")
}
with_umask() (
    umask "$1"
    shift
    "$@"
)
# Drive the real menu through a terminal and save at once.
menu_save() (
    export TERM=xterm NO_COLOR=1
    if [ "$(uname)" = Darwin ]; then
        script -q /dev/null /bin/bash "$CORTADO" config <<< s
    else
        # The shell started by script expands this path.
        # shellcheck disable=SC2016
        CORTADO_MENU_SCRIPT="$CORTADO" script -q -c 'exec /bin/bash "$CORTADO_MENU_SCRIPT" config' /dev/null <<< s
    fi
)

if section_is lines; then
    echo "=== line-preserving edits ==="
    printf '%s\n' '  # Keep leading/trailing space and the next empty line.  ' > "$before"
    cat >> "$before" <<'CONFIG'

DISPLAY_MODE=verbose
SEPARATOR=$' | '
MODEL_ICON="CUSTOM"
if [ "$(hostname)" = "$(hostname)" ]; then MODEL_ICON="HOST"; fi
cat <<'CORTADO_TEXT' > /dev/null
DISPLAY_MODE=verbose
CORTADO_TEXT
DISPLAY_MODE="normal"
CONFIG
    printf '%s' '# no final newline' >> "$before"
    sed 's/^DISPLAY_MODE="normal"$/DISPLAY_MODE="compact"/' "$before" |
        sed '$d' > "$expected"
    printf '%s' '# no final newline' >> "$expected"
    cp "$before" "$target"
    chmod 700 "$target"
    ln -s '../dot files/next.conf' "$config"
    ln -s user.conf "$TEST_BASE/dot files/next.conf"

    assert_rc 'set updates a symlink target' 0 config_edit --set DISPLAY_MODE=compact
    assert_eq 'the config symlink remains relative and intact' '../dot files/next.conf' "$(readlink "$config")"
    assert_eq 'the intermediate symlink remains intact' user.conf "$(readlink "$TEST_BASE/dot files/next.conf")"
    assert_rc 'only the effective assignment line changed, including untouched EOF' 0 cmp -s "$expected" "$target"
    assert_rc 'the backup holds the original bytes beside the target' 0 cmp -s "$before" "$target.bak"
    assert_eq 'the target keeps its owner-only mode' 700 "$(file_mode "$target")"
    assert_eq 'the backup is owner-only' 600 "$(file_mode "$target.bak" 2>/dev/null)"
    assert_empty 'no preservation warning on an exact edit' "$(cat "$stderr")"

    cp "$expected" "$before"
    printf '\n%s\n' 'COLOR_THEME="monochrome"' >> "$expected"
    assert_rc 'set appends a missing key after an unterminated line' 0 config_edit --set COLOR_THEME=monochrome
    assert_rc 'append keeps the original ending text and separates the new assignment' 0 cmp -s "$expected" "$target"
    assert_rc 'a second edit backs up the preceding save' 0 cmp -s "$before" "$target.bak"

    printf '%s\n' 'cat <<CORTADO_TEXT > /dev/null' 'DISPLAY_MODE=verbose' 'CORTADO_TEXT' \
        'if true; then' '    DISPLAY_MODE=normal' 'fi' \
        '> /dev/null printf "%s\n" '$'\\' 'DISPLAY_MODE=verbose' > "$target"
    cp "$target" "$expected"
    printf '%s\n' 'DISPLAY_MODE="compact"' >> "$expected"
    assert_rc 'set appends when the key appears only inside shell constructs' 0 config_edit --set DISPLAY_MODE=compact
    assert_rc 'the heredoc, conditional and continuation stay byte-identical' 0 cmp -s "$expected" "$target"

    printf '%s\n' 'export DISPLAY_MODE=normal  # note' > "$target"
    printf '%s\n' 'export DISPLAY_MODE="compact"  # note' > "$expected"
    assert_rc 'set edits an exported standalone setting' 0 config_edit --set DISPLAY_MODE=compact
    assert_rc 'the edit keeps export and its inline comment' 0 cmp -s "$expected" "$target"

    printf '%s\n' 'MODEL_ICON=☕' '# an unquoted icon' > "$target"
    printf '%s\n' 'MODEL_ICON="Tea"' '# an unquoted icon' > "$expected"
    assert_rc 'set updates an unquoted Unicode setting' 0 config_edit --set MODEL_ICON=Tea
    assert_rc 'an unquoted Unicode assignment is replaced in place' 0 cmp -s "$expected" "$target"

    printf '#!/bin/sh\nexit 1\n' > "$TEST_BASE/bin/readlink"
    chmod 700 "$TEST_BASE/bin/readlink"
    PATH="$TEST_BASE/bin:$PATH" assert_rc 'writer refuses a failed symlink lookup' 1 config_edit --set DISPLAY_MODE=normal
    assert_contains 'writer identifies the failed lookup' 'could not resolve config destination' "$(cat "$stderr")"
    assert_rc 'a failed link lookup leaves the target alone' 0 cmp -s "$expected" "$target"
    rm "$TEST_BASE/bin/readlink"

    # The renderer keeps a trailing newline in a link target's name (#86).
    rm -f "$config"
    nl_dir="$TEST_BASE/newline target"
    mkdir "$nl_dir"
    nl_target="$nl_dir/user.conf"$'\n'
    printf '%s\n' 'MODULE_ORDER="model"' 'MODEL_ICON="NL"' > "$nl_target"
    chmod 600 "$nl_target"
    ln -s "$nl_target" "$config"
    assert_rc 'set edits a link target whose name ends in a newline' 0 config_edit --set MODEL_ICON=EDITED
    assert_file_contains 'the newline-named target holds the edit' 'MODEL_ICON="EDITED"' "$nl_target"
    assert_rc 'no sibling without the newline is created' 1 test -e "$nl_dir/user.conf"
    nl_line=$(printf '%s' '{"model":{"display_name":"Opus"}}' | /bin/bash "$CORTADO" 2>/dev/null |
        sed $'s/\x1b\\[[0-9;]*m//g')
    assert_eq 'the statusline reads the edited newline-named target' 'EDITED Opus' "$nl_line"
    rm -rf "$config" "$nl_dir"
fi

if section_is modules; then
    echo "=== module values and rendering ==="
    rm -f "$config"
    printf '%s\n' 'MODULE_ORDER="context,model"' 'MODULE_MODEL=false' 'COLOR_THEME=monochrome' > "$config"
    for alias in yes 1 on no 0 off; do
        case "$alias" in
            yes|1|on) state=true order=context,model ;;
            *) state=false order=context ;;
        esac
        printf '%s\n' "MODULE_ORDER=\"$order\"" "MODULE_MODEL=\"$state\"" 'COLOR_THEME=monochrome' > "$expected"
        assert_rc "set accepts module alias $alias" 0 config_edit --set "MODULE_MODEL=$alias"
        assert_rc "set stores MODULE_MODEL=$state and syncs its order for alias $alias" 0 cmp -s "$expected" "$config"
    done
    cp "$config" "$before"
    cp "$config.bak" "$expected" 2>/dev/null
    assert_rc 'set refuses an invalid module value' 2 config_edit --set MODULE_MODEL=maybe
    assert_rc 'an invalid module value leaves config bytes alone' 0 cmp -s "$before" "$config"
    assert_rc 'an invalid module value leaves the backup alone' 0 cmp -s "$expected" "$config.bak"

    assert_rc 'a module flag can be enabled with yes' 0 config_edit --set MODULE_MODEL=yes
    payload='{"model":{"display_name":"Opus"}}'
    line=$(printf '%s' "$payload" | /bin/bash "$CORTADO" | sed $'s/\x1b\\[[0-9;]*m//g')
    assert_eq 'the saved flag renders the model beside the missing context reading' 'CTX: -- | MODEL: Opus' "$line"

    printf '%s\n' 'MODULE_ORDER="context,model"' 'MODULE_WEATHER=false' '# local preference' > "$config"
    printf '%s\n' 'MODULE_ORDER="context,model,weather"' 'MODULE_WEATHER="true"' '# local preference' > "$expected"
    assert_rc 'toggle still adds an enabled module to the order' 0 config_edit --toggle weather
    assert_rc 'toggle changes its module and order while preserving the comment' 0 cmp -s "$expected" "$config"
fi

if section_is project; then
    echo "=== project scope ==="
    # A repository can commit .cortado.conf as a link to a file of the user's.
    mkdir -p "$TEST_BASE/home"
    user_file="$TEST_BASE/home/.bashrc"
    printf '%s\n' 'alias ll="ls -l"' > "$user_file"
    cp "$user_file" "$before"
    ln -s ../home/.bashrc "$project"
    assert_rc 'project set refuses a symlinked project config' 1 project_edit --set MODULE_MODEL=off
    assert_contains 'the project refusal names the symlink' 'symlink' "$(cat "$stderr")"
    assert_rc 'the project symlink target stays byte-identical' 0 cmp -s "$before" "$user_file"
    assert_rc 'no backup appears beside the symlink target' 1 test -e "$user_file.bak"
    assert_rc 'no backup appears beside the project symlink' 1 test -e "$project.bak"
    assert_eq 'the project symlink is unchanged' ../home/.bashrc "$(readlink "$project")"
    rm "$project"

    printf '%s\n' 'SEPARATOR=" | "' 'HOME=ignored-by-project-parser' > "$project"
    assert_rc 'project set accepts a false alias' 0 project_edit --set MODULE_MODEL=off
    assert_file_contains 'project disable is stored canonically' 'MODULE_MODEL="false"' "$project"
    assert_file_contains 'project save backs up its original preference' 'SEPARATOR=" | "' "$project.bak"
    assert_contains 'project save identifies omitted input by line number' 'omits or reformats line 2' "$(cat "$stderr")"
    assert_not_contains 'project warning omits the original contents' 'ignored-by-project-parser' "$(cat "$stderr")"

    # A project file is never sourced, so a group-writable one is saved owner-only.
    rm -f "$project" "$project.bak"
    printf '%s\n' 'MODULE_MODEL="true"' > "$project"
    chmod 664 "$project"
    assert_rc 'a group-writable project config saves under umask 002' 0 with_umask 002 project_edit --set MODULE_MODEL=off
    assert_file_contains 'the group-writable project config gets the change' 'MODULE_MODEL="false"' "$project"
    assert_eq 'the saved project config is owner-only' 600 "$(file_mode "$project")"
    assert_eq 'the project backup is owner-only' 600 "$(file_mode "$project.bak" 2>/dev/null)"
    rm -f "$project" "$project.bak"
fi

if section_is permissions; then
    echo "=== refused and failed writes ==="
    printf '%s\n' 'COLOR_THEME=default' > "$before"
    cp "$before" "$config"
    chmod 660 "$config"
    assert_rc 'writer refuses to promote a group-writable global config' 1 config_edit --set DISPLAY_MODE=compact
    assert_rc 'group-writable config bytes are untouched' 0 cmp -s "$before" "$config"
    assert_eq 'group-writable config mode is untouched' 660 "$(file_mode "$config")"
    chmod 664 "$config"
    assert_rc 'a 664 user config is refused under umask 002' 1 with_umask 002 config_edit --set DISPLAY_MODE=compact
    assert_rc 'the refused 664 user config is byte-identical' 0 cmp -s "$before" "$config"
    assert_contains 'the refusal names the remedy' "review it, then run: chmod go-w $config" "$(cat "$stderr")"
    chmod 600 "$config"

    # A Bash hook in the user config needs the opt-in (#33).
    cat > "$config" <<'CONFIG'
function [ {
    if builtin test "$1" = '!' && builtin test "$2" = -O; then return 0; fi
    builtin [ "$@"
}
COLOR_THEME=default
CONFIG
    cp "$config" "$before"
    CORTADO_CONF_ALLOW_BASH=1 assert_rc 'writer refuses a target the caller does not own' 1 config_edit --set DISPLAY_MODE=compact
    assert_rc 'a refused owner check leaves the config alone' 0 cmp -s "$before" "$config"

    # The shared mode helper (lib/platform.sh) reads BSD or GNU stat for the host;
    # replace it from the trusted config to drive the writer's failure paths. These
    # hooks are Bash, so they run only with the environment's opt-in (#33).
    cat > "$config" <<'CONFIG'
cortado_file_mode() { return 1; }
COLOR_THEME=default
CONFIG
    cp "$config" "$before"
    CORTADO_CONF_ALLOW_BASH=1 assert_rc 'writer refuses a target with an unreadable mode' 1 config_edit --set DISPLAY_MODE=compact
    assert_rc 'a failed mode check leaves the config alone' 0 cmp -s "$before" "$config"
    cat > "$config" <<'CONFIG'
cortado_file_mode() { printf 'bogus\n'; }
COLOR_THEME=default
CONFIG
    cp "$config" "$before"
    CORTADO_CONF_ALLOW_BASH=1 assert_rc 'writer refuses a malformed mode result' 1 config_edit --set DISPLAY_MODE=compact
    assert_eq 'malformed mode output is diagnosed as a permission check failure' \
        "config: cannot save over a config with unsafe ownership or permissions: $config" "$(cat "$stderr")"
    assert_rc 'a malformed mode result leaves the config alone' 0 cmp -s "$before" "$config"
fi

if section_is refused; then
    printf '%s\n' 'COLOR_THEME=default' > "$config"
    cp "$config" "$before"
    mkdir "$config.cortado-lock"
    assert_rc 'an active edit lock prevents a second save' 1 config_edit --set DISPLAY_MODE=compact
    assert_rc 'a refused second save leaves the config alone' 0 cmp -s "$before" "$config"
    assert_contains 'the lock refusal names the lock' "$config.cortado-lock" "$(cat "$stderr")"
    assert_contains 'the lock refusal says how to recover' 'remove it' "$(cat "$stderr")"
    assert_not_contains 'the lock refusal hides the raw mkdir error' 'mkdir:' "$(cat "$stderr")"
    rmdir "$config.cortado-lock"
    chmod 500 "$CLAUDE_CONFIG_DIR"
    assert_rc 'a read-only config directory prevents a save' 1 config_edit --set DISPLAY_MODE=compact
    chmod 700 "$CLAUDE_CONFIG_DIR"
    assert_contains 'a lock that cannot be made is named' "could not create the edit lock: $config.cortado-lock" "$(cat "$stderr")"
    assert_not_contains 'no stale lock is reported when none exists' 'remove it' "$(cat "$stderr")"
    assert_rc 'a read-only directory leaves the config alone' 0 cmp -s "$before" "$config"

    printf '%s\n' 'cat <<CORTADO_TEXT > /dev/null' 'unfinished content' > "$config"
    cp "$config" "$before"
    assert_rc 'writer refuses to append inside an unfinished heredoc' 1 config_edit --set DISPLAY_MODE=compact
    assert_contains 'writer explains why the new line could not be appended' 'incomplete shell syntax' "$(cat "$stderr")"
    assert_rc 'failed append leaves incomplete shell syntax alone' 0 cmp -s "$before" "$config"

    rm -f "$config" "$config.bak"
    ln -s "$TEST_BASE/missing" "$config"
    assert_rc 'writer refuses a dangling config symlink' 1 config_edit --set DISPLAY_MODE=compact
    assert_eq 'writer leaves the dangling link intact' "$TEST_BASE/missing" "$(readlink "$config")"
    assert_empty 'writer does not create the missing link target' "$(find "$TEST_BASE" -name missing -print)"
    rm "$config"
    ln -s cortado.conf "$config"
    assert_rc 'writer refuses a config symlink loop' 1 config_edit --set DISPLAY_MODE=compact
    assert_eq 'writer leaves the link loop intact' cortado.conf "$(readlink "$config")"
    rm "$config"

    mkfifo "$config"
    assert_rc 'writer refuses a non-regular config' 1 config_edit --set DISPLAY_MODE=compact
    assert_rc 'the FIFO is retained' 0 test -p "$config"
    rm "$config"
fi

if section_is failed; then
    printf 'COLOR_THEME=default\n# uncopyable byte\000\n' > "$config"
    cp "$config" "$before"
    assert_rc 'writer refuses a config containing a NUL byte' 1 config_edit --set DISPLAY_MODE=compact
    assert_contains 'writer explains the byte-preservation failure' 'NUL' "$(cat "$stderr")"
    assert_rc 'binary config bytes are untouched' 0 cmp -s "$before" "$config"

    printf '%s\n' 'COLOR_THEME=default' > "$config"
    cp "$config" "$before"
    mkdir "$TEST_BASE/backup-dir"
    ln -s "$TEST_BASE/backup-dir" "$config.bak"
    assert_rc 'writer refuses a symlink as the backup destination' 1 config_edit --set DISPLAY_MODE=compact
    assert_empty 'a backup directory is never populated through a symlink' "$(ls -A "$TEST_BASE/backup-dir")"
    assert_rc 'an unusable backup leaves the config untouched' 0 cmp -s "$before" "$config"
    rm "$config.bak"

    for tool in cat chmod; do
        printf '#!/bin/sh\nexit 1\n' > "$TEST_BASE/bin/$tool"
        chmod 700 "$TEST_BASE/bin/$tool"
        PATH="$TEST_BASE/bin:$PATH" assert_rc "failed $tool reports failure" 1 config_edit --set DISPLAY_MODE=compact
        assert_rc "failed $tool leaves config bytes alone" 0 cmp -s "$before" "$config"
        rm "$TEST_BASE/bin/$tool"
    done

    cat > "$TEST_BASE/bin/mv" <<'STUB'
#!/bin/bash
while [ "$#" -gt 2 ]; do shift; done
source_path="$1"
dest="$2"
if [ "${source_path%/*}" != "${dest%/*}" ]; then
    exit 88
fi
case "$dest" in
    *.bak) if [ "${FAIL_MOVE:-}" = backup ]; then exit 1; fi ;;
    *) if [ "${FAIL_MOVE:-}" = config ]; then exit 1; fi ;;
esac
exec "$REAL_MV" "$@"
STUB
    chmod 700 "$TEST_BASE/bin/mv"
    for failure in backup config; do
        assert_rc "failed $failure rename reports failure" 1 \
            env PATH="$TEST_BASE/bin:$PATH" FAIL_MOVE="$failure" /bin/bash "$CORTADO" config --set DISPLAY_MODE=compact 2>/dev/null
        assert_rc "failed $failure rename leaves config bytes alone" 0 cmp -s "$before" "$config"
    done
    mv "$config" "$target"
    ln -s "$target" "$config"
    PATH="$TEST_BASE/bin:$PATH" assert_rc 'target and backup are staged in the resolved target directory' 0 \
        config_edit --set DISPLAY_MODE=compact
    assert_empty 'no staging files are left behind' \
        "$(find "$CLAUDE_CONFIG_DIR" "$TEST_BASE/dot files" \( -name '*.cortado-lock' -o -name '.cortado-config.*' \) -print)"
fi

if section_is order; then
    echo "=== module order follows --set ==="
    rm -f "$config" "$config.bak" "$target" "$target.bak"
    assert_rc 'set enables a catalog module in an empty config' 0 config_edit --set MODULE_CPU=on
    assert_file_contains 'the enabled flag is stored canonically' 'MODULE_CPU="true"' "$config"
    assert_eq 'one MODULE_ORDER line ends with the enabled module' 1 "$(grep -c '^MODULE_ORDER=".*,cpu"$' "$config")"
    assert_rc 'set disables the catalog module' 0 config_edit --set MODULE_CPU=off
    assert_eq 'the disabled module leaves MODULE_ORDER' 0 "$(grep '^MODULE_ORDER=' "$config" | grep -c cpu)"
    assert_eq 'the config keeps one MODULE_ORDER line' 1 "$(grep -c '^MODULE_ORDER=' "$config")"

    printf '%s\n' 'MODULE_ORDER="model,cpu"' 'MODULE_CPU=false' > "$config"
    printf '%s\n' 'MODULE_ORDER="model,cpu"' 'MODULE_CPU="true"' > "$expected"
    assert_rc 'set enables a module already in the order' 0 config_edit --set MODULE_CPU=on
    assert_rc 'an order that already lists the module is left alone' 0 cmp -s "$expected" "$config"

    printf '%s\n' 'COLOR_THEME=default' > "$config"
    printf '%s\n' 'COLOR_THEME=default' 'MODULE_CPU="false"' > "$expected"
    assert_rc 'set disables a module the order never listed' 0 config_edit --set MODULE_CPU=off
    assert_rc 'an unchanged order is not written' 0 cmp -s "$expected" "$config"

    rm -f "$config" "$config.bak"
    printf '%s\n' 'MODULE_ORDER="model,context"' > "$expected"
    assert_rc 'set accepts MODULE_ORDER, which is not a flag' 0 config_edit --set MODULE_ORDER=model,context
    assert_rc 'MODULE_ORDER is stored as given' 0 cmp -s "$expected" "$config"
fi

if section_is shell; then
    echo "=== shell boundaries ==="
    printf '%s\n' "# Windows path C:\\" 'DISPLAY_MODE=normal' > "$config"
    printf '%s\n' "# Windows path C:\\" 'DISPLAY_MODE="compact"' > "$expected"
    assert_rc 'set edits a key after a comment ending in a backslash' 0 config_edit --set DISPLAY_MODE=compact
    assert_rc 'a comment ending in a backslash is not a continuation' 0 cmp -s "$expected" "$config"

    printf '%s\n' 'DISPLAY_MODE=normal' "# ends in C:\\" > "$config"
    printf '%s\n' 'DISPLAY_MODE=normal' "# ends in C:\\" 'COLOR_THEME="monochrome"' > "$expected"
    assert_rc 'set appends after a final comment ending in a backslash' 0 config_edit --set COLOR_THEME=monochrome
    assert_rc 'the append follows the backslash comment' 0 cmp -s "$expected" "$config"

    printf '%s\n' "MODEL_ICON=\\\\" > "$config"
    printf '%s\n' "MODEL_ICON=\\\\" 'COLOR_THEME="monochrome"' > "$expected"
    assert_rc 'set appends after an escaped backslash value' 0 config_edit --set COLOR_THEME=monochrome
    assert_rc 'the append follows the escaped backslash' 0 cmp -s "$expected" "$config"

    printf '%s\n' "DISPLAY_MODE=normal \\" 'COLOR_THEME=x' > "$config"
    printf '%s\n' "DISPLAY_MODE=normal \\" 'COLOR_THEME=x' 'COLOR_THEME="monochrome"' > "$expected"
    assert_rc 'set appends when the key sits on a continued line' 0 config_edit --set COLOR_THEME=monochrome
    assert_rc 'a real continuation stays byte-identical' 0 cmp -s "$expected" "$config"

    printf '%s\n' 'SEPARATOR="open' 'DISPLAY_MODE=normal' > "$config"
    cp "$config" "$before"
    assert_rc 'set refuses a key inside an unterminated quote' 1 config_edit --set DISPLAY_MODE=compact
    assert_rc 'the unterminated quote stays byte-identical' 0 cmp -s "$before" "$config"
fi

if section_is later; then
    echo "=== later assignments ==="
    printf '%s\n' 'DISPLAY_MODE=normal' 'if true; then DISPLAY_MODE=verbose; fi' > "$config"
    cp "$config" "$expected"
    printf '%s\n' 'DISPLAY_MODE="compact"' >> "$expected"
    assert_rc 'set saves a key a later line also assigns' 0 config_edit --set DISPLAY_MODE=compact
    assert_rc 'the new value is appended after the later assignment' 0 cmp -s "$expected" "$config"
    # shellcheck disable=SC2016
    assert_eq 'the saved value is the effective one' compact "$(/bin/bash -c '. "$1"; printf %s "$DISPLAY_MODE"' _ "$config")"
    assert_contains 'the warning names the later line' 'DISPLAY_MODE is also assigned at line 2' "$(cat "$stderr")"
    printf '%s\n' 'DISPLAY_MODE=normal' 'if true; then DISPLAY_MODE=verbose; fi' 'DISPLAY_MODE="normal"' > "$expected"
    assert_rc 'a second set of that key succeeds' 0 config_edit --set DISPLAY_MODE=normal
    assert_rc 'the second set replaces the appended line in place' 0 cmp -s "$expected" "$config"
    assert_empty 'the second set has nothing to warn about' "$(cat "$stderr")"

    printf '%s\n' 'DISPLAY_MODE=normal' '# DISPLAY_MODE=verbose also works' > "$config"
    printf '%s\n' 'DISPLAY_MODE="compact"' '# DISPLAY_MODE=verbose also works' > "$expected"
    assert_rc 'set edits a key a later comment mentions' 0 config_edit --set DISPLAY_MODE=compact
    assert_rc 'a later comment does not move the edit' 0 cmp -s "$expected" "$config"
    assert_empty 'a later comment is not reported' "$(cat "$stderr")"

    printf '%s\n' 'PROGRESS_BAR_WIDTH=10' 'RATE_PROGRESS_BAR_WIDTH=8' > "$config"
    printf '%s\n' 'PROGRESS_BAR_WIDTH="12"' 'RATE_PROGRESS_BAR_WIDTH=8' > "$expected"
    assert_rc 'set edits a key that ends another key' 0 config_edit --set PROGRESS_BAR_WIDTH=12
    assert_rc 'a longer key with the same ending does not move the edit' 0 cmp -s "$expected" "$config"
    assert_empty 'a longer key with the same ending is not reported' "$(cat "$stderr")"
fi

if section_is menu; then
    echo "=== menu save and sourced shell options ==="
    if command -v script >/dev/null 2>&1; then
        printf '%s\n' 'MODULE_CPU=yes' > "$config"
        menu_save >/dev/null 2>&1
        assert_eq 'a menu save stores a yes flag as true' 'MODULE_CPU="true"' "$(grep '^MODULE_CPU=' "$config")"
    else
        echo "SKIP: script is not installed"
    fi

    printf '%s\n' 'set -C' 'DISPLAY_MODE=normal' > "$config"
    printf '%s\n' 'set -C' 'DISPLAY_MODE="compact"' > "$expected"
    assert_rc 'set saves a config that turns on noclobber' 0 config_edit --set DISPLAY_MODE=compact
    assert_rc 'the noclobber config gets the change' 0 cmp -s "$expected" "$config"
    printf '%s\n' '# Cortado project configuration' 'MODULE_MODEL="false"' > "$expected"
    assert_rc 'a project save works under a noclobber user config' 0 project_edit --set MODULE_MODEL=off
    assert_rc 'the project file gets the change under noclobber' 0 cmp -s "$expected" "$project"
    rm -f "$project" "$project.bak"
fi

if section_is usermodule; then
    echo "=== settings a user module declares (#81) ==="
    user_modules="$CLAUDE_CONFIG_DIR/cortado-modules"
    mkdir -m 700 "$user_modules"
    # shellcheck disable=SC2016 # The module source keeps its expansion literal.
    printf '%s\n' '# @cortado-module mine' '# @default true' '# @args none' \
        '# @config MINE_LABEL:string' '# @config MINE_COUNT:int' '# @config OTHER_LABEL:string' \
        '# @config BASH_ENV:string' '# @description Mine' \
        'module_mine() { printf "MINE=%s\n" "${MINE_LABEL:-default}"; }' > "$user_modules/mine.sh"
    # A module may claim BASH_* only under its own prefix, and BASH* stays reserved.
    # shellcheck disable=SC2016 # The module source keeps its expansion literal.
    printf '%s\n' '# @cortado-module bash' '# @default false' '# @args none' \
        '# @config BASH_ENV:string' '# @description Reserved' 'module_bash() { :; }' > "$user_modules/bash.sh"
    chmod 600 "$user_modules/mine.sh" "$user_modules/bash.sh"
    printf '%s\n' '# my modules' 'MODULE_ORDER="model,mine"' 'COLOR_THEME=monochrome' > "$config"
    cp "$config" "$before"
    { cat "$before"; printf '%s\n' 'MINE_LABEL="hello"'; } > "$expected"
    assert_rc 'set accepts a setting the user module declares' 0 config_edit --set MINE_LABEL=hello
    assert_rc 'the user module setting is appended and nothing else changes' 0 cmp -s "$expected" "$config"
    mine_line=$(printf '%s' '{"model":{"display_name":"Opus"}}' | /bin/bash "$CORTADO" 2>/dev/null |
        sed $'s/\x1b\\[[0-9;]*m//g')
    assert_eq 'the statusline renders the saved user module setting' 'MODEL: Opus | MINE=hello' "$mine_line"
    assert_rc 'set refuses a mistyped value for a user module int' 2 config_edit --set MINE_COUNT=lots
    assert_contains 'the type refusal names the type' 'MINE_COUNT expects a int value' "$(cat "$stderr")"
    cp "$config" "$before"
    for key in NOT_A_KEY OTHER_LABEL BASH_ENV; do
        assert_rc "set still refuses $key" 2 config_edit --set "$key=x"
        assert_contains "the $key refusal names the key" "unknown or invalid key: $key" "$(cat "$stderr")"
    done
    assert_rc 'refused keys leave the config byte-identical' 0 cmp -s "$before" "$config"
    assert_rc 'toggle saves with a user module setting present' 0 config_edit --toggle cpu
    assert_eq 'toggle keeps the user module setting' 'MINE_LABEL="hello"' "$(grep '^MINE_LABEL=' "$config")"
    if command -v script >/dev/null 2>&1; then
        menu_save >/dev/null 2>&1
        assert_eq 'a menu save keeps the user module setting' 'MINE_LABEL="hello"' "$(grep '^MINE_LABEL=' "$config")"
    fi
    rm -rf "$user_modules" "$config" "$config.bak"
fi

if section_is umask; then
    echo "=== modes, backups and races under umask 022 ==="
    rm -f "$config" "$config.bak"
    printf '%s\n' 'DISPLAY_MODE=normal' > "$config"
    chmod 644 "$config"
    assert_rc 'set saves a 644 user config' 0 with_umask 022 config_edit --set DISPLAY_MODE=compact
    assert_eq 'the saved 644 config becomes owner-only' 600 "$(file_mode "$config")"
    assert_eq 'the backup of a 644 config is owner-only' 600 "$(file_mode "$config.bak" 2>/dev/null)"

    rm -f "$config.bak"
    mkdir "$config.bak"
    cp "$config" "$before"
    assert_rc 'a plain directory at the backup path is refused' 1 with_umask 022 config_edit --set DISPLAY_MODE=verbose
    assert_empty 'the backup directory stays empty' "$(ls -A "$config.bak")"
    assert_rc 'a refused backup leaves the config byte-identical' 0 cmp -s "$before" "$config"
    rmdir "$config.bak"

    printf 'DISPLAY_MODE=normal\r\nCOLOR_THEME=default\r\n' > "$config"
    printf 'DISPLAY_MODE="compact"\r\nCOLOR_THEME=default\r\n' > "$expected"
    assert_rc 'set edits a CRLF config' 0 with_umask 022 config_edit --set DISPLAY_MODE=compact
    assert_rc 'a CRLF line is replaced in place and keeps its CR' 0 cmp -s "$expected" "$config"

    printf '%s\n' 'precious' > "$TEST_BASE/victim"
    printf '%s\n' 'DISPLAY_MODE=normal' > "$config"
    mkdir -p "$TEST_BASE/race-bin"
    cat > "$TEST_BASE/race-bin/mkdir" <<SHIM
#!/bin/sh
for arg in "\$@"; do last="\$arg"; done
case "\$last" in *.cortado-lock) rm -f "$config"; ln -s "$TEST_BASE/victim" "$config" ;; esac
exec /bin/mkdir "\$@"
SHIM
    chmod 700 "$TEST_BASE/race-bin/mkdir"
    PATH="$TEST_BASE/race-bin:$PATH" assert_rc 'a symlink swapped in while locking is refused' 1 \
        with_umask 022 config_edit --set DISPLAY_MODE=compact
    assert_eq 'the swapped-in link target is untouched' precious "$(cat "$TEST_BASE/victim")"
    assert_rc 'the swapped-in link remains a link' 0 test -L "$config"
    rm -f "$config" "$config.bak"

    mkdir "$TEST_BASE/tdir"
    ln -s "$TEST_BASE/tdir/" "$config"
    chmod 500 "$TEST_BASE/tdir"
    assert_rc 'a config linked to a directory is refused' 1 config_edit --set DISPLAY_MODE=compact
    assert_contains 'a linked directory is reported as not a regular file' 'not a regular file' "$(cat "$stderr")"
    chmod 700 "$TEST_BASE/tdir"
    assert_empty 'nothing is created inside the linked directory' "$(ls -A "$TEST_BASE/tdir")"
    rm "$config"

    fresh="$TEST_BASE/fresh/claude"
    assert_rc 'set creates a missing config directory' 0 \
        with_umask 022 env CLAUDE_CONFIG_DIR="$fresh" CACHE_DIR="$TEST_BASE/fresh-cache" \
        /bin/bash "$CORTADO" config --set DISPLAY_MODE=compact
    assert_eq 'a new config directory is owner-only' 700 "$(file_mode "$fresh")"
fi

section_results
