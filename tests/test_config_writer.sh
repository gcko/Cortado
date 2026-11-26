#!/bin/bash
# ABOUTME: Exercises config edits, symlinks, backups and rendered module flags.
# ABOUTME: Run with: /bin/bash tests/test_config_writer.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/tests/lib/assert.sh" plain

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

echo "=== module values and rendering ==="
rm "$config"
printf '%s\n' 'MODULE_ORDER="context,model"' 'MODULE_MODEL=false' 'COLOR_THEME=monochrome' > "$config"
for alias in yes 1 on no 0 off; do
    case "$alias" in
        yes|1|on) state=true ;;
        *) state=false ;;
    esac
    printf '%s\n' 'MODULE_ORDER="context,model"' "MODULE_MODEL=\"$state\"" 'COLOR_THEME=monochrome' > "$expected"
    assert_rc "set accepts module alias $alias" 0 config_edit --set "MODULE_MODEL=$alias"
    assert_rc "set writes only MODULE_MODEL=$state for alias $alias" 0 cmp -s "$expected" "$config"
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

project="$TEST_BASE/project/.cortado.conf"
project_target="$TEST_BASE/dot files/project.conf"
printf '%s\n' 'SEPARATOR=" | "' 'HOME=ignored-by-project-parser' > "$project_target"
ln -s "$project_target" "$project"
project_edit() {
    (cd "$TEST_BASE/project" && config_edit --project "$@")
}
assert_rc 'project set accepts a false alias through a symlink' 0 project_edit --set MODULE_MODEL=off
assert_file_contains 'project disable is stored canonically' 'MODULE_MODEL="false"' "$project_target"
assert_eq 'project symlink still points to its target' "$project_target" "$(readlink "$project")"
assert_file_contains 'project save backs up its original preference' 'SEPARATOR=" | "' "$project_target.bak"
assert_contains 'project save identifies omitted input by line number' 'omits or reformats line 2' "$(cat "$stderr")"
assert_not_contains 'project warning omits the original contents' 'ignored-by-project-parser' "$(cat "$stderr")"

echo "=== refused and failed writes ==="
printf '%s\n' 'COLOR_THEME=default' > "$before"
cp "$before" "$config"
chmod 660 "$config"
assert_rc 'writer refuses to promote a group-writable global config' 1 config_edit --set DISPLAY_MODE=compact
assert_rc 'group-writable config bytes are untouched' 0 cmp -s "$before" "$config"
assert_eq 'group-writable config mode is untouched' 660 "$(file_mode "$config")"
chmod 600 "$config"

cat > "$config" <<'CONFIG'
function [ {
    if builtin test "$1" = '!' && builtin test "$2" = -O; then return 0; fi
    builtin [ "$@"
}
COLOR_THEME=default
CONFIG
cp "$config" "$before"
assert_rc 'writer refuses a target the caller does not own' 1 config_edit --set DISPLAY_MODE=compact
assert_rc 'a refused owner check leaves the config alone' 0 cmp -s "$before" "$config"

cat > "$config" <<'CONFIG'
uname() {
    if [ "${1:-}" = -s ]; then printf 'Linux\n'; else command uname "$@"; fi
}
COLOR_THEME=default
CONFIG
printf '#!/bin/sh\nexit 1\n' > "$TEST_BASE/bin/stat"
chmod 700 "$TEST_BASE/bin/stat"
cp "$config" "$before"
PATH="$TEST_BASE/bin:$PATH" assert_rc 'writer refuses a target with an unreadable mode' 1 config_edit --set DISPLAY_MODE=compact
assert_rc 'a failed mode check leaves the config alone' 0 cmp -s "$before" "$config"
printf '#!/bin/sh\nprintf "bogus\\n"\n' > "$TEST_BASE/bin/stat"
PATH="$TEST_BASE/bin:$PATH" assert_rc 'writer refuses a malformed mode result' 1 config_edit --set DISPLAY_MODE=compact
assert_eq 'malformed mode output is diagnosed as a permission check failure' \
    "config: cannot save over a config with unsafe ownership or permissions: $config" "$(cat "$stderr")"
rm "$TEST_BASE/bin/stat"

printf '%s\n' 'COLOR_THEME=default' > "$config"
cp "$config" "$before"
mkdir "$config.cortado-lock"
assert_rc 'an active edit lock prevents a second save' 1 config_edit --set DISPLAY_MODE=compact
assert_rc 'a refused second save leaves the config alone' 0 cmp -s "$before" "$config"
rmdir "$config.cortado-lock"

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

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
