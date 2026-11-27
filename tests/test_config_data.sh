#!/bin/bash
# Config files are data: one KEY=VALUE parser reads every scope and nothing in
# a config runs, unless the environment opts the user config into Bash.
# Run with: /bin/bash tests/test_config_data.sh
# Fixtures are literal shell text that must stay unexpanded.
# shellcheck disable=SC2016,SC1003

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented
unset CORTADO_CONF_ALLOW_BASH COLOR_THEME DISPLAY_MODE MODULE_ORDER MODEL_ICON SEPARATOR \
    USE_ICONS MODULE_MODEL DEBUG_MODE TERMINAL_WIDTH LAYOUT_MODE APP_SANDBOX_CONTAINER_ID

# shellcheck source=lib/config-data.sh
. "$REPO_ROOT/lib/config-data.sh"

echo "=== grammar ==="
# parse_case <description> <line> <expected>, where expected is
# "set KEY=VALUE", "skip" or "unread:<reason substring>".
parse_case() {
    local desc="$1" line="$2" expected="$3" status actual LC_ALL=C
    config_parse_line "$line" && status=0 || status=$?
    case "$status" in
        0) actual="set $CONFIG_KEY=$CONFIG_VALUE" ;;
        1) actual=skip ;;
        *) actual="unread:$CONFIG_REASON" ;;
    esac
    case "$expected" in
        unread:*)
            assert_contains "$desc" "$expected" "$actual"
            ;;
        *) assert_eq "$desc" "$expected" "$actual" ;;
    esac
    # The file reader's fast paths must decode exactly as the grammar does.
    printf '%s\n' "$line" > "$TEST_BASE/one-line.conf"
    file_result=skip
    read_config_kv "$TEST_BASE/one-line.conf" parse_allow parse_take parse_unread
    assert_eq "$desc (file reader agrees)" "$actual" "$file_result"
}
parse_allow() { :; }
collect_huge() { huge_unread+=("$1"); }
parse_take() { file_result="set $1=$2"; }
parse_unread() { file_result="unread:$2"; }

parse_case 'blank line' '' skip
parse_case 'whitespace line' $' \t ' skip
parse_case 'comment line' '   # MODULE_GIT=true' skip
parse_case 'unquoted value' 'MODULE_GIT=true' 'set MODULE_GIT=true'
parse_case 'double-quoted value' 'SEPARATOR=" | "' 'set SEPARATOR= | '
parse_case 'single-quoted value is literal' "MODEL_ICON='\$(x) \`y\` \\n'" 'set MODEL_ICON=$(x) `y` \n'
parse_case 'empty value' 'TERMINAL_WIDTH=' 'set TERMINAL_WIDTH='
parse_case 'empty quotes' 'TERMINAL_WIDTH=""' 'set TERMINAL_WIDTH='
parse_case 'inline comment after a number' 'CONTEXT_WARNING_THRESHOLD=60    # Yellow' 'set CONTEXT_WARNING_THRESHOLD=60'
parse_case 'inline comment after quotes' 'GIT_SYMBOL_MODIFIED="●"     # Uncommitted changes' 'set GIT_SYMBOL_MODIFIED=●'
parse_case 'hash inside a word is literal' 'MODEL_ICON=a#b' 'set MODEL_ICON=a#b'
parse_case 'hash inside quotes is literal' 'MODEL_ICON="a # b"' 'set MODEL_ICON=a # b'
parse_case 'export prefix is accepted' 'export DISPLAY_MODE=compact' 'set DISPLAY_MODE=compact'
parse_case 'indented export with comment' $'\texport  DISPLAY_MODE="compact"  # note' 'set DISPLAY_MODE=compact'
parse_case 'double-quote escapes' 'MODEL_ICON="a\"b\\c\$d\`e\x"' 'set MODEL_ICON=a"b\c$d`e\x'
parse_case 'unquoted escapes' 'MODEL_ICON=a\ b\$c' 'set MODEL_ICON=a b$c'
parse_case 'adjacent quoted segments' "MODEL_ICON='a'\"b\"c" 'set MODEL_ICON=abc'
parse_case 'glob characters are literal' 'PROGRESS_BAR_FILLED=*' 'set PROGRESS_BAR_FILLED=*'
parse_case 'CRLF line ending' $'COLOR_THEME="minimal"\r' 'set COLOR_THEME=minimal'
parse_case 'invalid UTF-8 bytes are kept' $'MODEL_ICON="\xff\xfe"' $'set MODEL_ICON=\xff\xfe'
parse_case 'a raw escape byte is kept in quotes' $'SEPARATOR=" \033[36m|\033[0m "' $'set SEPARATOR= \033[36m|\033[0m '
parse_case 'command substitution in double quotes' 'MODEL_ICON="$(touch x)"' 'unread:command substitution'
parse_case 'unquoted command substitution' 'MODEL_ICON=$(touch x)' 'unread:command substitution'
parse_case 'backticks in double quotes' 'MODEL_ICON="`touch x`"' 'unread:command substitution'
parse_case 'variable expansion' 'DISK_PATH="$HOME/x"' 'unread:variable expansion'
parse_case 'braced expansion' 'DISK_PATH=${HOME}' 'unread:variable expansion'
parse_case 'ANSI-C quoting' "SEPARATOR=\$' | '" "unread:ANSI-C quoting"
parse_case 'locale quoting' 'SEPARATOR=$" | "' 'unread:variable expansion'
parse_case 'function definition' 'pwn() { touch x; }' 'unread:function definition'
parse_case 'function keyword' 'function pwn { touch x; }' 'unread:function definition'
parse_case 'conditional' 'if true; then DISPLAY_MODE=compact; fi' 'unread:conditional'
parse_case 'test command' '[ -f x ] && DISPLAY_MODE=compact' 'unread:conditional'
parse_case 'line continuation' 'DISPLAY_MODE=normal \' 'unread:line continuation'
parse_case 'unterminated double quote' 'SEPARATOR="open' 'unread:unterminated quote'
parse_case 'unterminated single quote' "SEPARATOR='open" 'unread:unterminated quote'
parse_case 'two assignments on one line' 'MODULE_CPU=true MODULE_DISK=true' 'unread:not a single KEY=VALUE'
parse_case 'assignment before a command' 'DISPLAY_MODE=compact touch' 'unread:not a single KEY=VALUE'
parse_case 'command after a semicolon' 'DISPLAY_MODE=compact; touch x' 'unread:not a single KEY=VALUE'
parse_case 'pipe' 'DISPLAY_MODE=a|b' 'unread:not a single KEY=VALUE'
parse_case 'tilde expansion' 'DISK_PATH=~/x' 'unread:tilde expansion'
parse_case 'tilde after a colon' 'DISK_PATH=/a:~/x' 'unread:tilde expansion'
parse_case 'a tilde inside a word is literal' 'MODEL_ICON=a~b' 'set MODEL_ICON=a~b'
parse_case 'a quoted tilde is literal' 'SEPARATOR="~"' 'set SEPARATOR=~'
# Bash expands a tilde only in unquoted text, so a quoted ":~" stays literal.
parse_case 'a quoted colon-tilde is literal' 'SEPARATOR="a:~"' 'set SEPARATOR=a:~'
parse_case 'a quoted colon-tilde before a comment is literal' 'SEPARATOR="a:~" # c' 'set SEPARATOR=a:~'
parse_case 'an exported quoted colon-tilde is literal' 'export SEPARATOR="a:~"' 'set SEPARATOR=a:~'
parse_case 'a single-quoted colon-tilde is literal' "SEPARATOR=':~'" 'set SEPARATOR=:~'
parse_case 'an unquoted colon-tilde expands' 'SEPARATOR=a:~' 'unread:tilde expansion'
parse_case 'a bare tilde expands' 'SEPARATOR=~' 'unread:tilde expansion'
parse_case 'an unquoted colon-tilde after a quoted part expands' 'DISK_PATH="/a":~/x' 'unread:tilde expansion'
parse_case 'a tilde after an empty quoted part is literal' 'MODEL_ICON=""~' 'set MODEL_ICON=~'
parse_case 'a tilde after a quoted word is literal' 'MODEL_ICON="a"~b' 'set MODEL_ICON=a~b'
parse_case 'a tilde after a quoted colon is literal' 'MODEL_ICON="a:"~' 'set MODEL_ICON=a:~'
parse_case 'a tilde after an escaped colon is literal' 'MODEL_ICON=a\:~' 'set MODEL_ICON=a:~'
parse_case 'an escaped tilde after a colon is literal' 'MODEL_ICON=a:\~' 'set MODEL_ICON=a:~'
parse_case 'a quote inside single quotes leaves one unterminated' "SEPARATOR='a'b'" 'unread:unterminated quote'
parse_case 'an unbraced variable' 'DISK_PATH=$HOME' 'unread:variable expansion'
parse_case 'array assignment' 'MODULE_ORDER=(a b)' 'unread:not a single KEY=VALUE'
parse_case 'plain command' 'touch x' 'unread:shell command'
parse_case 'unset command' 'unset MODEL_ICON' 'unread:shell command'
parse_case 'readonly command' 'readonly SEPARATOR' 'unread:shell command'
parse_case 'invalid name' '1KEY=x' 'unread:'
parse_case 'a hash after a closing quote is literal' 'MODEL_ICON="a"#b' 'set MODEL_ICON=a#b'
parse_case 'a space after = starts a command' 'DISPLAY_MODE= compact' 'unread:not a single KEY=VALUE'
parse_case 'export with an option' 'export -n DISPLAY_MODE=compact' 'unread:shell command'
parse_case 'declare' 'declare DISPLAY_MODE=compact' 'unread:shell command'
parse_case 'a tab before an inline comment' $'DISPLAY_MODE=compact\t# note' 'set DISPLAY_MODE=compact'
parse_case 'a NUL-free line with a backslash before a quote' 'MODEL_ICON=\"x' 'set MODEL_ICON="x'
long_value=$(printf '%5000s' '' | tr ' ' x)
parse_case 'line over the byte limit' "MODEL_ICON=$long_value" 'unread:line longer than 4096 bytes'
# A repository can commit a huge project config line. The parser must refuse it
# in linear time (pattern removal on it is quadratic in Bash).
printf 'MODEL_ICON="%s"\r\n   %s\n' "$(head -c 1000000 /dev/zero | tr '\0' x)" "$(head -c 1000000 /dev/zero | tr '\0' y)" \
    > "$TEST_BASE/huge.conf"
huge_unread=()
huge_start=$SECONDS
read_config_kv "$TEST_BASE/huge.conf" parse_allow parse_take collect_huge
huge_elapsed=$((SECONDS - huge_start))
if [ "$huge_elapsed" -le 3 ] && [ "${#huge_unread[@]}" -eq 2 ]; then
    pass 'two 1 MB lines are refused in linear time'
else
    fail "two 1 MB lines are refused in linear time (${huge_elapsed}s, ${#huge_unread[@]} reported)"
fi

echo "=== typed keys ==="
# shellcheck source=lib/module-registry.sh
. "$REPO_ROOT/lib/module-registry.sh"
discover_module_registry "$REPO_ROOT/modules" "" false || exit 1
allowed() { trusted_config_setting_allowed "$1" "$2"; }
assert_rc 'a core string key' 0 allowed SEPARATOR ' | '
assert_rc 'a module @config int key' 0 allowed CONTEXT_WARNING_THRESHOLD 60
assert_rc 'a module @config number key' 0 allowed COST_MINIMUM_DISPLAY 0.01
assert_rc 'a trusted-only key' 0 allowed WEATHER_LOCATION Lisbon
assert_rc 'a module flag' 0 allowed MODULE_GIT true
assert_rc 'an empty int leaves the default' 0 allowed TERMINAL_WIDTH ''
assert_rc 'an int key refuses text' 1 allowed CONTEXT_WARNING_THRESHOLD abc
assert_rc 'a number key refuses two points' 1 allowed COST_MINIMUM_DISPLAY 1.2.3
assert_rc 'a bool key keeps the legacy yes spelling' 0 allowed MODULE_GIT yes
assert_rc 'a bool key refuses other words' 1 allowed MODULE_GIT maybe
assert_rc 'an unknown key' 1 allowed GIT_FOO x
assert_rc 'PATH is not a setting' 1 allowed PATH /tmp
assert_rc 'IFS is not a setting' 1 allowed IFS x
assert_rc 'the opt-in is not a setting' 1 allowed CORTADO_CONF_ALLOW_BASH 1
assert_rc 'CACHE_DIR is not a setting' 1 allowed CACHE_DIR /tmp

# The trusted policy and its assignment run as one call when the statusline
# loads a config (trusted_config_apply). It must accept, refuse and explain
# exactly as trusted_config_setting_allowed does, and assign what it accepts.
apply_mismatches=$(
    LC_ALL=C
    keys="$(compgen -v _CORTADO_CORE_KEY_TYPE_ | sed 's/^_CORTADO_CORE_KEY_TYPE_//')
$(compgen -v _CORTADO_KEY_TYPE_ | sed 's/^_CORTADO_KEY_TYPE_//')
MODULE_GIT MODULE_NOSUCH GIT_FOO PATH IFS CORTADO_CONF_ALLOW_BASH CACHE_DIR lower A-B 1ABC"
    checked=0
    for key in $keys; do
        for value in '' true false yes maybe 60 -1 abc 0.5 1.2.3 ' | ' '-.'; do
            CONFIG_POLICY_REASON='' CONFIG_POLICY_KIND=''
            trusted_config_setting_allowed "$key" "$value" && want=0 || want=$?
            want="$want|$CONFIG_POLICY_REASON|$CONFIG_POLICY_KIND"
            CONFIG_POLICY_REASON='' CONFIG_POLICY_KIND=''
            checked=$((checked + 1))
            if [ "$key" = PATH ] || [ "$key" = IFS ]; then saved="${!key}"; fi
            trusted_config_apply "$key" "$value" && got=0 || got=$?
            got="$got|$CONFIG_POLICY_REASON|$CONFIG_POLICY_KIND"
            if [ "$key" = PATH ] || [ "$key" = IFS ]; then printf -v "$key" '%s' "$saved"; fi
            if [ "$got" != "$want" ]; then
                printf '%s=[%s]: apply %s, policy %s\n' "$key" "$value" "$got" "$want"
            elif [ "${got%%|*}" = 0 ] && [ "${!key}" != "$value" ]; then
                printf '%s=[%s]: accepted but not assigned\n' "$key" "$value"
            fi
        done
    done
    printf 'checked %s\n' "$checked"
)
assert_match 'the combined trusted apply is compared on every key and value' \
    '^checked [0-9]{4,}$' "${apply_mismatches##*$'\n'}"
assert_eq 'the combined trusted apply agrees with the trusted policy on every key' '' \
    "$(printf '%s\n' "$apply_mismatches" | sed '/^checked [0-9]*$/d')"

# The shipped config is pure data: every line is a comment or a setting.
unread_lines=()
collect_unread() { unread_lines+=("$1: $2"); }
read_config_kv "$REPO_ROOT/cortado.conf" trusted_config_setting_allowed trusted_config_assign collect_unread
assert_eq 'the shipped cortado.conf has no unread lines' '' "${unread_lines[*]}"

echo "=== renders ==="
payload=$(jq -nc --arg dir "$TEST_BASE" '{workspace: {current_dir: $dir}, model: {display_name: "Opus"}}') || exit 1

# A disposable install, so the packaged config can be edited.
tree="$TEST_BASE/tree"
mkdir -p "$tree" && cp -R "$REPO_ROOT/"{cortado.sh,cortado.conf,VERSION,lib,modules} "$tree/" || exit 1
chmod 600 "$tree/cortado.conf"
cp "$tree/cortado.conf" "$TEST_BASE/packaged.orig"

new_sandbox() {
    sb=$(mktemp -d "$TEST_BASE/sb.XXXXXX") || exit 1
    mkdir -m 700 "$sb/cortado-cache"
    project="$sb/project"
    mkdir "$project"
    cp "$TEST_BASE/packaged.orig" "$tree/cortado.conf"
}

# user_config <lines...>
user_config() {
    printf '%s\n' "$@" > "$sb/cortado.conf" && chmod 600 "$sb/cortado.conf"
}

render() {
    local data
    data=$(jq -nc --arg dir "$project" '{workspace: {current_dir: $dir}, model: {display_name: "Opus"}}')
    printf '%s' "$data" | CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" MARK="$sb/marker" \
        "$@" /bin/bash "$tree/cortado.sh" 2> "$sb/stderr" | sed $'s/\x1b\\[[0-9;]*m//g'
}

marker_absent() {
    if [ -e "$sb/marker" ]; then fail "$1"; else pass "$1"; fi
}

marker_present() {
    if [ -e "$sb/marker" ]; then pass "$1"; else fail "$1"; fi
}

base=('MODULE_ORDER="model"' 'MODULE_MODEL="true"' 'COLOR_THEME="default"' 'USE_ICONS="true"')

new_sandbox
user_config "${base[@]}" 'MODEL_ICON="DATA"'
assert_eq 'a plain user config renders its values' 'DATA Opus' "$(render env)"

new_sandbox
user_config "${base[@]}" 'MODEL_ICON="$(touch "$MARK")X"'
out=$(render env)
marker_absent 'a $(...) line in the user config does not run'
assert_eq 'the line renders what it could read and says so' $'Config partly read: run cortado config --show | 🤖 Opus' "$out"

new_sandbox
user_config "${base[@]}" 'MODEL_ICON=`touch "$MARK"`'
render env > /dev/null
marker_absent 'a backtick line in the user config does not run'

new_sandbox
user_config "${base[@]}" 'pwn() { touch "$MARK"; }' 'pwn' 'MODEL_ICON=OK'
out=$(render env)
marker_absent 'a function definition and call in the user config do not run'
assert_contains 'settings after the function still apply' 'OK Opus' "$out"

new_sandbox
user_config "${base[@]}" 'MODEL_ICON="$(touch "$MARK")X"'
out=$(render env CORTADO_CONF_ALLOW_BASH=1)
marker_present 'CORTADO_CONF_ALLOW_BASH=1 sources the user config'
assert_eq 'the opted-in user config renders as Bash did' 'X Opus' "$out"

new_sandbox
user_config "${base[@]}" 'MODEL_ICON="$(touch "$MARK")X"'
render env CORTADO_CONF_ALLOW_BASH=true > /dev/null
marker_absent 'only the value 1 opts in'

new_sandbox
user_config "${base[@]}"
printf '%s\n' 'MODEL_ICON="$(touch "$MARK")X"' >> "$tree/cortado.conf"
render env CORTADO_CONF_ALLOW_BASH=1 > /dev/null
marker_absent 'the packaged config is never sourced, even with the opt-in'

for opt_in in 'CORTADO_CONF_ALLOW_BASH=1' 'export CORTADO_CONF_ALLOW_BASH=1' "CORTADO_CONF_ALLOW_BASH='1'"; do
    new_sandbox
    printf '%s\n' "$opt_in" >> "$tree/cortado.conf"
    user_config "$opt_in" "${base[@]}" 'MODEL_ICON="$(touch "$MARK")X"'
    printf '%s\n' "$opt_in" > "$project/.cortado.conf"
    render env > /dev/null
    marker_absent "config files cannot opt in with: $opt_in"
done

new_sandbox
user_config "${base[@]}"
printf '%s\n' 'MODEL_ICON="$(touch "$MARK")"' 'touch "$MARK"' > "$project/.cortado.conf"
render env CORTADO_CONF_ALLOW_BASH=1 > /dev/null
marker_absent 'a project config with code does not run under the opt-in'

new_sandbox
user_config "${base[@]}" 'MODEL_ICON=FIRST' 'MODEL_ICON=LAST'
assert_eq 'a key repeated later in the file takes the later value' 'LAST Opus' "$(render env)"

new_sandbox
user_config "${base[@]}" 'MODEL_ICON=KEPT' 'MODEL_ICON="$(touch "$MARK")"'
assert_eq 'an unread later line keeps the earlier value' $'Config partly read: run cortado config --show | KEPT Opus' "$(render env)"

new_sandbox
printf 'MODULE_ORDER="model"\r\nMODULE_MODEL="true"\r\nUSE_ICONS="true"\r\nMODEL_ICON="CRLF"\r\n' > "$sb/cortado.conf"
chmod 600 "$sb/cortado.conf"
assert_eq 'a CRLF user config renders its values' 'CRLF Opus' "$(render env)"

new_sandbox
user_config "${base[@]}" "MODEL_ICON=$long_value" 'MODEL_ICON=SHORT'
assert_eq 'a very long line is skipped and the next line applies' $'Config partly read: run cortado config --show | SHORT Opus' "$(render env)"

new_sandbox
user_config "${base[@]}" 'MODULE_MODEL=maybe'
assert_eq 'a mistyped value is reported and the default applies' $'Config partly read: run cortado config --show | 🤖 Opus' "$(render env)"

new_sandbox
user_config "${base[@]}" 'GIT_FOO=1' 'MODEL_ICON=SAME'
assert_eq 'an unknown name, which no module reads, leaves the line unmarked' 'SAME Opus' "$(render env)"
show=$(CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --show 2>&1)
assert_contains 'config --show still lists the unknown name' 'line 5: GIT_FOO is not a Cortado setting' "$show"

new_sandbox
user_config "${base[@]}" 'DEBUG_MODE="true"' 'MODEL_ICON="$(touch "$MARK")"' 'pwn() { :; }'
render env > /dev/null
assert_file_contains 'debug mode logs the unread command substitution' \
    'line 6: command substitution' "$sb/cortado.log"
assert_file_contains 'debug mode logs the unread function' 'line 7: function definition' "$sb/cortado.log"

# A FIFO or a symlink to one is never opened (a read would block the line).
new_sandbox
mkfifo "$sb/cortado.conf"
out=$(render env)
assert_contains 'a FIFO user config is refused and the line still renders' 'Opus' "$out"
new_sandbox
mkfifo "$sb/fifo"
ln -s fifo "$sb/cortado.conf"
out=$(render env)
assert_contains 'a symlink to a FIFO is refused and the line still renders' 'Opus' "$out"
new_sandbox
user_config "${base[@]}"
mkfifo "$project/.cortado.conf"
out=$(render env)
assert_contains 'a FIFO project config is skipped' 'Opus' "$out"
new_sandbox
printf '%s\n' "${base[@]}" 'MODEL_ICON=LINKED' > "$sb/real.conf"
chmod 600 "$sb/real.conf"
ln -s real.conf "$sb/cortado.conf"
assert_eq 'a symlinked user config is read as data' 'LINKED Opus' "$(render env)"

echo "=== cortado config ==="
new_sandbox
user_config "${base[@]}" 'MODEL_ICON="$(touch "$MARK")"' 'DISPLAY_MODE=compact'
show=$(CLAUDE_CONFIG_DIR="$sb" MARK="$sb/marker" /bin/bash "$tree/cortado.sh" config --show 2>&1)
marker_absent 'config --show does not run the user config'
assert_contains 'config --show names the unread line' 'line 5: command substitution' "$show"
assert_contains 'config --show still reads the other settings' 'DISPLAY_MODE=compact' "$show"

# A refused (world-writable) file is never sourced, so --show must not say it is.
new_sandbox
user_config "${base[@]}" 'MODEL_ICON="$(touch "$MARK")"'
chmod 666 "$sb/cortado.conf"
show=$(CORTADO_CONF_ALLOW_BASH=1 CLAUDE_CONFIG_DIR="$sb" MARK="$sb/marker" /bin/bash "$tree/cortado.sh" config --show 2>&1)
marker_absent 'config --show under the opt-in does not run a refused file'
assert_contains 'config --show says a refused file is inactive' 'inactive' "$show"
assert_not_contains 'config --show does not call a refused file sourced' 'sourced as Bash' "$show"
new_sandbox
user_config "${base[@]}"
show=$(CORTADO_CONF_ALLOW_BASH=1 CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --show 2>&1)
assert_contains 'config --show names the opt-in for a trusted file' 'sourced as Bash' "$show"

new_sandbox
user_config "${base[@]}" 'MODEL_ICON="$(touch "$MARK")"' 'f() { touch "$MARK"; }' \
    'if true; then' 'DISPLAY_MODE=verbose' 'fi' "SEPARATOR=\$' | '" 'DISPLAY_MODE=normal \' \
    'MODEL_ICON=`id`' 'GIT_FOO=1'
touch -t 200001020304 "$sb/cortado.conf"
cksum_before=$(cksum < "$sb/cortado.conf")
ls_before=$(ls -lT "$sb/cortado.conf" 2>/dev/null || ls -l --full-time "$sb/cortado.conf")
dry=$(cd "$project" && CLAUDE_CONFIG_DIR="$sb" MARK="$sb/marker" /bin/bash "$tree/cortado.sh" config --migrate --dry-run 2>&1)
dry_status=$?
assert_eq 'migrate --dry-run succeeds' 0 "$dry_status"
for expected in 'line 5: command substitution' 'line 6: function definition' \
    'line 7: conditional' 'line 9: conditional' "line 10: ANSI-C quoting" \
    'line 11: line continuation' 'line 12: command substitution' 'line 13: GIT_FOO is not a Cortado setting'; do
    assert_contains "migrate --dry-run lists $expected" "$expected" "$dry"
done
assert_not_contains 'migrate --dry-run does not list a readable setting' 'line 8:' "$dry"
assert_eq 'migrate --dry-run leaves the file byte-identical' "$cksum_before" "$(cksum < "$sb/cortado.conf")"
assert_eq 'migrate --dry-run leaves the mtime and mode' "$ls_before" \
    "$(ls -lT "$sb/cortado.conf" 2>/dev/null || ls -l --full-time "$sb/cortado.conf")"
assert_eq 'migrate --dry-run writes no backup or lock' '' \
    "$(find "$sb" -maxdepth 1 -name 'cortado.conf?*' -print)"
marker_absent 'migrate --dry-run runs nothing'

# The opt-in sources the file for the statusline, never for the dry-run.
new_sandbox
user_config "${base[@]}" 'MODEL_ICON="$(touch "$MARK")"'
dry=$(CORTADO_CONF_ALLOW_BASH=1 CLAUDE_CONFIG_DIR="$sb" MARK="$sb/marker" /bin/bash "$tree/cortado.sh" config --migrate --dry-run 2>&1)
marker_absent 'migrate --dry-run runs nothing under the opt-in'
assert_contains 'migrate --dry-run under the opt-in still lists the line' 'line 5: command substitution' "$dry"

# Before the first render, only barista.conf exists. The dry-run reads it in
# place and copies nothing.
new_sandbox
printf '%s\n' 'MODEL_ICON="$(touch "$MARK")"' 'DISPLAY_MODE=compact' > "$sb/barista.conf"
chmod 600 "$sb/barista.conf"
dry=$(CORTADO_CONF_ALLOW_BASH=1 CLAUDE_CONFIG_DIR="$sb" MARK="$sb/marker" /bin/bash "$tree/cortado.sh" config --migrate --dry-run 2>&1)
assert_rc 'migrate --dry-run does not copy barista.conf to cortado.conf' 1 test -e "$sb/cortado.conf"
marker_absent 'migrate --dry-run does not run barista.conf'
assert_contains 'migrate --dry-run names the legacy file it read' "Config file: $sb/barista.conf" "$dry"
assert_contains 'migrate --dry-run lists the legacy line' 'line 1: command substitution' "$dry"
assert_not_contains 'migrate --dry-run does not list the legacy setting' 'line 2:' "$dry"
# The same holds when the directory refuses the copy.
chmod 500 "$sb"
dry=$(CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --migrate --dry-run 2>&1)
chmod 700 "$sb"
assert_contains 'migrate --dry-run reads barista.conf in a read-only directory' 'line 1: command substitution' "$dry"

new_sandbox
user_config "${base[@]}"
dry=$(CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --migrate --dry-run 2>&1)
assert_contains 'migrate --dry-run says when every line is data' 'no lines to migrate' "$dry"
printf '%s\n' 'MODEL_ICON="$(touch x)"' "$(printf 'SEPARATOR="\033]0;title\007"')" > "$project/.cortado.conf"
dry=$(cd "$project" && CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --project --migrate --dry-run 2>&1)
assert_contains 'migrate --dry-run reads the project config' 'line 1: command substitution' "$dry"
case "$dry" in
    *$'\033'*|*$'\007'*) fail 'migrate --dry-run prints no control bytes from a project line' ;;
    *) pass 'migrate --dry-run prints no control bytes from a project line' ;;
esac
rm -f "$project/.cortado.conf"
mkfifo "$project/.cortado.conf"
rc=0
dry=$(cd "$project" && CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --project --migrate --dry-run 2>&1) || rc=$?
assert_eq 'migrate --dry-run refuses a FIFO without opening it' 1 "$rc"
assert_contains 'migrate --dry-run names the FIFO as not a regular file' 'not a regular file' "$dry"
rc=0
CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --migrate > /dev/null 2>&1 || rc=$?
assert_eq 'migrate without --dry-run is a usage error' 2 "$rc"

new_sandbox
user_config "${base[@]}"
rc=0
CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --set CONTEXT_WARNING_THRESHOLD=abc > /dev/null 2>&1 || rc=$?
assert_eq 'config --set refuses a value of the wrong type' 2 "$rc"
rc=0
CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --set CORTADO_CONF_ALLOW_BASH=1 > /dev/null 2>&1 || rc=$?
assert_eq 'config --set refuses the opt-in' 2 "$rc"
assert_file_not_contains() { if grep -q "$2" "$3"; then fail "$1"; else pass "$1"; fi; }
assert_file_not_contains 'the opt-in never reaches the user config' CORTADO_CONF_ALLOW_BASH "$sb/cortado.conf"

echo "=== user modules ==="
new_sandbox
mkdir -m 700 "$sb/cortado-modules"
cat > "$sb/cortado-modules/mine.sh" <<'EOF'
# @cortado-module mine
# @default false
# @args none
# @config MINE_LABEL:string
# @config MINE_WIDTH:int
# @config PATH:string
# @config MODEL_ICON:int
# @config OTHER_LABEL:string
module_mine() { printf '%s %s %s\n' "${MINE_LABEL:-none}" "${MINE_WIDTH:-0}" "${OTHER_LABEL:-unset}"; }
EOF
chmod 600 "$sb/cortado-modules/mine.sh"
user_config 'MODULE_ORDER="mine,model"' 'MODULE_MINE=true' 'MODULE_MODEL=true' 'USE_ICONS=true' \
    'MINE_LABEL=hello' 'MINE_WIDTH=7' 'PATH=/nonexistent' 'MODEL_ICON=M' 'OTHER_LABEL=leak'
assert_eq 'a user module reads its own prefixed settings only, never PATH, and cannot retype a built-in key' \
    'hello 7 unset | M Opus' "$(render env)"

# A user module cannot widen the config to shell or runtime state, even under
# its own prefix.
new_sandbox
mkdir -m 700 "$sb/cortado-modules"
printf '%s\n' '# @cortado-module cache' '# @default false' '# @config CACHE_DIR:string' \
    '# @config CACHE_LABEL:string' 'module_cache() { printf "%s\n" "${CACHE_LABEL:-none}"; }' \
    > "$sb/cortado-modules/cache.sh"
chmod 600 "$sb/cortado-modules/cache.sh"
user_config "${base[@]}"
rc=0
CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --set CACHE_LABEL=hi > /dev/null 2>&1 || rc=$?
assert_eq 'a user module setting under its prefix can be set' 0 "$rc"
rc=0
CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --set CACHE_DIR=/tmp/x > /dev/null 2>&1 || rc=$?
assert_eq 'a reserved shell name is never a setting, even under the prefix' 2 "$rc"

# One name from each reserved family, declared by a module whose prefix fits it.
# The whole prefix is reserved, so toggling the module proves it was read.
for pair in bash:BASH_ENV claude:CLAUDE_CONFIG_DIR ctx:CTX_MODEL_NAME cortado:CORTADO_CONF_ALLOW_BASH; do
    id="${pair%%:*}" reserved="${pair#*:}"
    new_sandbox
    mkdir -m 700 "$sb/cortado-modules"
    printf '%s\n' "# @cortado-module $id" '# @default false' "# @config $reserved:string" \
        "module_$id() { printf '%s\n' x; }" > "$sb/cortado-modules/$id.sh"
    chmod 600 "$sb/cortado-modules/$id.sh"
    user_config "${base[@]}"
    rc=0
    CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --toggle "$id" > /dev/null 2>&1 || rc=$?
    assert_eq "the $id user module is read" 0 "$rc"
    rc=0
    CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --set "$reserved=1" > /dev/null 2>&1 || rc=$?
    assert_eq "the reserved name $reserved is never a setting, even under the prefix" 2 "$rc"
done

echo "=== project and legacy scopes ==="
new_sandbox
user_config "${base[@]}"
rc=0
(cd "$project" && CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --project \
    --set CONTEXT_WARNING_THRESHOLD=high > /dev/null 2>&1) || rc=$?
assert_eq 'a project config refuses a value of the wrong type' 2 "$rc"
assert_rc 'the refused project value is not written' 1 test -e "$project/.cortado.conf"
rc=0
(cd "$project" && CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --project \
    --set TERMINAL_WIDTH=notanint > /dev/null 2>&1) || rc=$?
assert_eq 'a project config refuses a mistyped core setting' 2 "$rc"
assert_rc 'the refused core value is not written' 1 test -e "$project/.cortado.conf"
printf '%s\n' 'PROGRESS_BAR_WIDTH=notanint' 'USE_ICONS=maybe' 'CONTEXT_WARNING_THRESHOLD=abc' \
    'SEPARATOR=" / "' 'TERMINAL_WIDTH=120' > "$project/.cortado.conf"
dry=$(cd "$project" && CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" config --project --migrate --dry-run 2>&1)
assert_contains 'a project dry-run types a core int' 'line 1: PROGRESS_BAR_WIDTH expects a int value' "$dry"
assert_contains 'a project dry-run types a core bool' 'line 2: USE_ICONS expects a bool value' "$dry"
assert_contains 'a project dry-run names a mistyped module setting' \
    'line 3: CONTEXT_WARNING_THRESHOLD expects a int value' "$dry"
assert_not_contains 'a project dry-run reads a well-typed core string' 'line 4:' "$dry"
assert_not_contains 'a project dry-run reads a well-typed core int' 'line 5:' "$dry"
rm -f "$project/.cortado.conf"

# A legacy barista.conf used in place (its copy failed) is data too.
new_sandbox
printf '%s\n' "${base[@]}" 'MODEL_ICON="$(touch "$MARK")LEGACY"' 'pwn() { touch "$MARK"; }' 'pwn' \
    > "$sb/barista.conf"
chmod 600 "$sb/barista.conf"
mkdir -p "$TEST_BASE/failing-cp"
printf '%s\n' '#!/bin/bash' 'case "$2" in */barista.conf) exit 1 ;; esac' 'exec /bin/cp "$@"' \
    > "$TEST_BASE/failing-cp/cp"
chmod 700 "$TEST_BASE/failing-cp/cp"
out=$(render env PATH="$TEST_BASE/failing-cp:$PATH")
marker_absent 'a legacy barista.conf read in place does not run'
assert_rc 'the failed copy left no cortado.conf' 1 test -e "$sb/cortado.conf"
assert_eq 'the legacy file renders what it could read and says so' 'Config partly read: run cortado config --show | 🤖 Opus' "$out"

echo "=== installer ==="
# shellcheck source=install.sh
. "$REPO_ROOT/install.sh"
init_installer_catalog || exit 1
for preset in default ascii; do
    gen="$TEST_BASE/generated-$preset.conf"
    if [ "$preset" = ascii ]; then
        PROGRESS_FILLED='*' PROGRESS_EMPTY='.' SEPARATOR_CHAR=' / ' USE_EMOJI=false generate_config "$gen"
    else
        generate_config "$gen"
    fi
    unread_lines=()
    read_config_kv "$gen" trusted_config_setting_allowed trusted_config_assign collect_unread
    assert_eq "the installer's $preset config is data only" '' "${unread_lines[*]}"
done
new_sandbox
printf '%s\n' 'MODULE_ORDER="model,nope"' 'touch "$MARK"' > "$sb/gen.conf"
chmod 600 "$sb/gen.conf"
out=$(MARK="$sb/marker" validate_config "$sb/gen.conf")
marker_absent 'installer validation never runs the config'
assert_contains 'installer validation reads MODULE_ORDER as data' 'Unknown module in MODULE_ORDER: nope' "$out"
assert_contains 'installer validation names the unread line' 'line 2' "$out"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
