#!/bin/bash
# ABOUTME: Exercise the command saved by the installer through sh, with a
# ABOUTME: sandboxed config, and verify backup and restore preserve it.

umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
export HOME="$TEST_BASE/home"
export CORTADO_PATH_TEST="expanded"
mkdir -p "$HOME"

# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented-unquoted
run_installer() {
    local config_dir="$1"
    shift
    local bash_options=()
    if [ "${INSTALLER_XPG_ECHO:-}" = "true" ]; then
        bash_options=(-O xpg_echo)
    fi
    CLAUDE_CONFIG_DIR="$config_dir" CACHE_DIR="$config_dir/cortado-cache" \
        /bin/bash "${bash_options[@]}" "$REPO_ROOT/install.sh" --skip-update-check --no-color --no-emoji "$@"
}

install_minimal() {
    local config_dir="$1"
    if ! run_installer "$config_dir" --minimal > "$TEST_BASE/install.log" 2>&1; then
        fail "install completes in ${config_dir##*/}"
        cat "$TEST_BASE/install.log"
        return 1
    fi
}

assert_statusline_runs() {
    local desc="$1" settings="$2" cmd output render_dir
    local payload='{"workspace":{"current_dir":"/"},"model":{"display_name":"Opus[1m]"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'
    if ! cmd=$(jq -er '.statusLine.command' "$settings"); then
        fail "$desc (no saved command)"
        return
    fi
    render_dir=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
    if output=$(cd / && printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$render_dir" \
        CACHE_DIR="$render_dir/cortado-cache" TERMINAL_WIDTH=200 /bin/sh -c "$cmd" 2>"$render_dir/stderr"); then
        case "$output" in
            *"25%"*"MODEL: Opus[1m]"*)
                pass "$desc"
                return
                ;;
        esac
    fi
    fail "$desc"
    printf '    stdout: %s\n' "$output"
    if [ -s "$render_dir/stderr" ]; then
        printf '    stderr:\n'
        cat "$render_dir/stderr"
    fi
}

space_dir="$TEST_BASE/with space"
for name in 'with space' "apostrophe's" 'double"quote' "literal\$CORTADO_PATH_TEST" 'literal`tick'; do
    config_dir="$TEST_BASE/$name"
    install_minimal "$config_dir"
    assert_eq "fresh install sets the statusLine type [$name]" "command" \
        "$(jq -r '.statusLine.type' "$config_dir/settings.json")"
    assert_statusline_runs "fresh install renders through sh [$name]" "$config_dir/settings.json"
done

relative_dir='rel space'
if (cd "$TEST_BASE" && install_minimal "$relative_dir"); then
    assert_statusline_runs 'relative config saves a statusline command runnable from /' \
        "$TEST_BASE/$relative_dir/settings.json"
else
    fail 'relative config installs successfully'
fi

quoted_home="$TEST_BASE/quote\"home"
mkdir -p "$quoted_home" || exit 1
HOME="$quoted_home" install_minimal "$TEST_BASE/quoted home"
assert_file_contains 'self-test renders the quoted HOME directory' 'DIR: quote"home' "$TEST_BASE/install.log"
assert_file_contains 'self-test renders the sample model with a quoted HOME' 'MODEL: Test' "$TEST_BASE/install.log"

assert_install_failure() {
    local desc="$1" config_dir="$2" diagnostic="$3" output
    if output=$(run_installer "$config_dir" --minimal 2>&1); then
        fail "$desc exits non-zero"
    else
        pass "$desc exits non-zero"
    fi
    assert_contains "$desc explains the failure" "$diagnostic" "$output"
    assert_not_contains "$desc does not report a settings update" 'Updated settings.json' "$output"
    assert_not_contains "$desc does not report settings creation" 'Created settings.json' "$output"
    assert_not_contains "$desc does not report installation complete" 'Installation Complete!' "$output"
    assert_empty "$desc cleans up staged settings" "$(find "$config_dir" -name '.settings.*')"
}

for invalid in empty whitespace null zero multiple; do
    case "$invalid" in
        empty) content='' ;;
        whitespace) content=$' \n\t' ;;
        null) content='null' ;;
        zero) content='0' ;;
        multiple) content=$'{}\n{}' ;;
    esac
    config_dir=$(mktemp -d "$TEST_BASE/invalid.XXXXXX") || exit 1
    printf '%s' "$content" > "$config_dir/settings.json" || exit 1
    cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
    assert_install_failure "$invalid settings" "$config_dir" 'Could not prepare settings.json'
    assert_rc "$invalid settings stay byte-identical" 0 cmp -s \
        "$TEST_BASE/previous-settings" "$config_dir/settings.json"
done

config_dir="$TEST_BASE/dangling-settings"
mkdir "$config_dir" || exit 1
ln -s "$TEST_BASE/missing-settings.json" "$config_dir/settings.json" || exit 1
assert_install_failure 'settings path with a missing symlink target' "$config_dir" 'Could not prepare settings.json'
assert_eq 'failed install keeps the original settings symlink' "$TEST_BASE/missing-settings.json" \
    "$(readlink "$config_dir/settings.json")"

config_dir="$TEST_BASE/fifo-settings"
mkdir "$config_dir" || exit 1
mkfifo "$config_dir/settings.json" || exit 1
assert_install_failure 'settings path is a FIFO' "$config_dir" 'Could not prepare settings.json'
assert_rc 'failed install keeps the original settings FIFO' 0 test -p "$config_dir/settings.json"

old_settings='{"statusLine":{"type":"command","command":"old-command","padding":4},"other":true}'
config_dir="$TEST_BASE/read-only"
mkdir -p "$config_dir/cortado" "$config_dir/.cortado-backup" || exit 1
printf '%s\n' "$old_settings" > "$config_dir/settings.json" || exit 1
cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
chmod 500 "$config_dir" || exit 1
if [ ! -w "$config_dir" ]; then
    assert_install_failure 'read-only config directory' "$config_dir" 'Could not stage settings.json'
    assert_rc 'read-only config keeps the original settings bytes' 0 cmp -s \
        "$TEST_BASE/previous-settings" "$config_dir/settings.json"
    assert_eq 'read-only config keeps the complete statusLine backup' \
        '{"type":"command","command":"old-command","padding":4}' \
        "$(jq -c '.settings_statusline' "$config_dir/.cortado-backup/manifest.json")"
else
    printf '  SKIP: current user can write to a chmod 500 directory\n'
fi
chmod 700 "$config_dir" || exit 1

# Inject failures at the tool boundary so the real installer handles the
# exit status, empty output or bad candidate file.
fault_bin="$TEST_BASE/fault-bin"
mkdir "$fault_bin" || exit 1
FAULT_REAL_JQ=$(type -P jq) || exit 1
FAULT_STAGE_DIR=$(mktemp -d "$TEST_BASE/stage-fault.XXXXXX") || exit 1
export FAULT_REAL_JQ FAULT_STAGE_DIR
cat > "$fault_bin/jq" <<'SH'
#!/bin/bash
case "$1 ${2:-} ${3:-}" in
    '-nc --arg dir')
        case "$INSTALLER_TEST_FAULT:$4" in
            payload:*|probe-payload:*/cortado\"test)
                "$FAULT_REAL_JQ" "$@"
                exit 1
                ;;
        esac
        ;;
    '-nr --arg path')
        if [ "$INSTALLER_TEST_FAULT" = quote ]; then
            "$FAULT_REAL_JQ" "$@"
            exit 1
        fi
        ;;
    '-s --arg command')
        case "$INSTALLER_TEST_FAULT" in
            incomplete) printf '%s\n' '{"other":true}'; exit 0 ;;
            wrong-command) printf '%s\n' '{"statusLine":{"type":"command","command":"other"}}'; exit 0 ;;
            multiple-candidates) "$FAULT_REAL_JQ" "$@"; exec "$FAULT_REAL_JQ" "$@" ;;
            writer) "$FAULT_REAL_JQ" "$@"; exit 1 ;;
        esac
        ;;
esac
exec "$FAULT_REAL_JQ" "$@"
SH
cat > "$fault_bin/mv" <<'SH'
#!/bin/bash
if [ "$INSTALLER_TEST_FAULT" = rename ]; then
    exit 1
fi
exec /bin/mv "$@"
SH
cat > "$fault_bin/basename" <<'SH'
#!/bin/bash
if [ "$INSTALLER_TEST_FAULT" = directory ]; then
    case "$1" in
        *'"'*) exit 1 ;;
    esac
fi
exec /usr/bin/basename "$@"
SH
cat > "$fault_bin/mktemp" <<'SH'
#!/bin/bash
if [ "$#" -eq 1 ] && [ "$1" = -d ]; then
    case "$INSTALLER_TEST_FAULT" in
        probe-temp) printf '%s\n' "$FAULT_PROBE_DIR"; exit 1 ;;
        probe-renderer) printf '%s\n' "$FAULT_PROBE_DIR"; exit 0 ;;
    esac
fi
case "${2:-}" in
    */.settings.*)
        if [ "$INSTALLER_TEST_FAULT" = stage ]; then
            printf '%s\n' "$FAULT_STAGE_DIR"
            exit 1
        fi
        ;;
esac
exec /usr/bin/mktemp "$@"
SH
chmod +x "$fault_bin/"* || exit 1

# Bash reads this hook only in the fault cases below. Preserve valid output
# while failing the operation so each exit-status check has its own regression.
cat > "$TEST_BASE/fault-env" <<'SH'
case "$INSTALLER_TEST_FAULT" in
    probe-config)
        printf() {
            builtin printf "$@" || return
            [ "${2:-}" != 'MODULE_ORDER="directory"' ]
        }
        ;;
    probe-renderer)
        if [ "$CLAUDE_CONFIG_DIR" = "$FAULT_PROBE_DIR" ]; then
            printf '%s\n' 'Dir: cortado"test'
            exit 7
        fi
        ;;
esac
SH

for fault in stage writer incomplete wrong-command multiple-candidates rename payload quote \
    directory probe-temp probe-config probe-payload probe-renderer; do
    config_dir="$TEST_BASE/fault-$fault"
    mkdir "$config_dir" || exit 1
    printf '%s\n' "$old_settings" > "$config_dir/settings.json" || exit 1
    cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
    case "$fault" in
        stage) diagnostic='Could not stage settings.json' ;;
        writer) diagnostic='Could not prepare settings.json' ;;
        incomplete|wrong-command|multiple-candidates) diagnostic='Could not verify statusLine' ;;
        rename) diagnostic='Could not replace settings.json' ;;
        payload|quote) diagnostic='Could not prepare statusline test' ;;
        directory|probe-*) diagnostic='Statusline test FAILED - sample directory missing' ;;
    esac
    FAULT_PROBE_DIR=$(mktemp -d "$TEST_BASE/probe-fault.XXXXXX") || exit 1
    export FAULT_PROBE_DIR
    PATH="$fault_bin:$PATH" HOME="$quoted_home" INSTALLER_TEST_FAULT="$fault" \
        BASH_ENV="$TEST_BASE/fault-env" assert_install_failure "$fault failure" "$config_dir" "$diagnostic"
    assert_rc "$fault failure keeps original settings bytes" 0 cmp -s \
        "$TEST_BASE/previous-settings" "$config_dir/settings.json"
    assert_eq "$fault failure keeps the complete statusLine backup" \
        '{"type":"command","command":"old-command","padding":4}' \
        "$(jq -c '.settings_statusline' "$config_dir/.cortado-backup/manifest.json")"
    if [ "$fault" = probe-renderer ]; then
        assert_rc 'failed directory probe cleans up its sandbox' 1 test -e "$FAULT_PROBE_DIR"
    fi
done

config_dir="$TEST_BASE/renderer-error"
mkdir "$config_dir" || exit 1
printf '%s\n' 'printf "%s\n" "DIR: home | MODEL: Test"' 'exit 7' > "$config_dir/cortado.conf" || exit 1
chmod 600 "$config_dir/cortado.conf" || exit 1
assert_install_failure 'nonzero renderer with output' "$config_dir" 'Statusline test FAILED'

config_dir="$TEST_BASE/directory-disabled"
mkdir "$config_dir" || exit 1
printf '%s\n' 'MODULE_DIRECTORY="false"' > "$config_dir/cortado.conf" || exit 1
chmod 600 "$config_dir/cortado.conf" || exit 1
install_minimal "$config_dir"
assert_file_contains 'user config can hide the directory in the sample' 'MODEL: Test' "$TEST_BASE/install.log"
assert_not_contains 'sample honors the disabled directory' 'DIR: home' "$(cat "$TEST_BASE/install.log")"

# Simulate a settings edit made between installs. Reinstall should detect the
# saved command, back it up and update the settings while preserving other keys.
settings="$space_dir/settings.json"
manifest="$space_dir/.cortado-backup/manifest.json"
jq '.includeCoAuthoredBy = true | .statusLine.padding = 4' "$settings" > "$TEST_BASE/settings.json" || exit 1
mv "$TEST_BASE/settings.json" "$settings" || exit 1
original_statusline=$(jq -c '.statusLine' "$settings")

install_minimal "$space_dir"
assert_eq "reinstall backs up the complete statusLine" "$original_statusline" \
    "$(jq -c '.settings_statusline' "$manifest")"
assert_eq "reinstall preserves unrelated settings" "true" \
    "$(jq -r '.includeCoAuthoredBy' "$settings")"
assert_eq "reinstall replaces the statusLine object" "false" \
    "$(jq -r '.statusLine | has("padding")' "$settings")"
assert_statusline_runs "reinstall renders through sh [with space]" "$settings"
hint=$(sed -n 's/^  Or run: *//p' "$TEST_BASE/install.log")
# Parse the hint as a shell command without launching the interactive config TUI.
hint_args=$(/bin/sh -c "set -- $hint; printf '%s\n' \"\$#\" \"\$@\"")
assert_eq "config hint names the installed executable and config argument" \
    "$(printf '2\n%s\nconfig' "$space_dir/cortado/cortado.sh")" "$hint_args"

printf '1\nn\n' | run_installer "$space_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1
assert_eq "uninstall restores the saved statusLine verbatim" "$original_statusline" \
    "$(jq -c '.statusLine' "$settings")"
assert_statusline_runs "restored statusline renders through sh [with space]" "$settings"

printf '2\n' | run_installer "$space_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1
assert_eq "uninstall without restore removes the statusLine key" "false" \
    "$(jq -r 'has("statusLine")' "$settings")"
assert_eq "uninstall preserves unrelated settings" "true" \
    "$(jq -r '.includeCoAuthoredBy' "$settings")"

# xpg_echo interprets backslashes in JSON escapes for the quoted command.
config_dir="$TEST_BASE/restore apostrophe's"
settings="$config_dir/settings.json"
manifest="$config_dir/.cortado-backup/manifest.json"
INSTALLER_XPG_ECHO=true install_minimal "$config_dir"
jq '.statusLine.padding = 7' "$settings" > "$TEST_BASE/settings.json" || exit 1
mv "$TEST_BASE/settings.json" "$settings" || exit 1
original_statusline=$(jq -ce '.statusLine' "$settings") || exit 1

INSTALLER_XPG_ECHO=true install_minimal "$config_dir"
if jq -es --argjson original "$original_statusline" --arg dir "$config_dir/cortado" '
    length == 1 and (.[0] | type == "object" and .settings_statusline == $original
        and any(.files[]; .type == "directory" and .original == $dir))
' "$manifest" >/dev/null; then
    pass "xpg_echo reinstall backs up the apostrophe path and complete statusLine"
else
    fail "xpg_echo reinstall backs up the apostrophe path and complete statusLine"
fi

if ! printf '1\nn\n' | INSTALLER_XPG_ECHO=true run_installer "$config_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1; then
    fail "xpg_echo uninstall completes with restore"
    cat "$TEST_BASE/uninstall.log"
fi
if [ -x "$config_dir/cortado/cortado.sh" ]; then
    pass "xpg_echo uninstall restores the executable"
else
    fail "xpg_echo uninstall restores the executable"
fi
assert_eq "xpg_echo uninstall restores the complete statusLine" "$original_statusline" \
    "$(jq -c '.statusLine' "$settings")"
assert_statusline_runs "xpg_echo restored statusline renders through sh" "$settings"

# The saved command must trigger a backup even without old runtime files.
config_dir="$TEST_BASE/settings only \$CORTADO_PATH_TEST"
settings="$config_dir/settings.json"
manifest="$config_dir/.cortado-backup/manifest.json"
mkdir -p "$config_dir" || exit 1
# shellcheck disable=SC2016 # $path is a jq variable.
jq -n --arg path "$config_dir/cortado/cortado.sh" '
    {statusLine: {type: "command", command: ($path | @sh), padding: 11},
     includeCoAuthoredBy: false}
' > "$settings" || exit 1
original_statusline=$(jq -ce '.statusLine' "$settings") || exit 1

install_minimal "$config_dir"
if jq -es --argjson original "$original_statusline" '
    length == 1 and (.[0] | type == "object" and .settings_statusline == $original)
' "$manifest" >/dev/null; then
    pass "settings-only install backs up the complete quoted statusLine"
else
    fail "settings-only install backs up the complete quoted statusLine"
fi
assert_eq "settings-only install preserves unrelated settings" "false" \
    "$(jq -r '.includeCoAuthoredBy' "$settings")"
assert_statusline_runs 'updated settings render through sh with a literal $ in the path' "$settings"

# Disable the only listed module to trigger the installer's manual test hint.
config_dir="$TEST_BASE/manual hint's"
mkdir -p "$config_dir" || exit 1
printf '%s\n' 'MODULE_ORDER="model"' 'MODULE_MODEL="false"' > "$config_dir/cortado.conf" || exit 1
chmod 600 "$config_dir/cortado.conf" || exit 1
if run_installer "$config_dir" --minimal > "$TEST_BASE/install.log" 2>&1; then
    fail "empty statusline triggers the manual test hint"
else
    hint=$(sed -n 's/^i Try running manually: //p' "$TEST_BASE/install.log")
    render_dir=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
    if output=$(CLAUDE_CONFIG_DIR="$render_dir" CACHE_DIR="$render_dir/cortado-cache" \
        TERMINAL_WIDTH=200 /bin/sh -c "$hint" 2>"$render_dir/stderr") &&
        [[ "$output" == *"MODEL: Test"* ]]; then
        pass "manual test hint renders the sample through sh"
    else
        fail "manual test hint renders the sample through sh"
        printf '    hint: %s\n    stdout: %s\n' "$hint" "$output"
        cat "$render_dir/stderr"
    fi
fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
