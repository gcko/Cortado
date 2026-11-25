#!/bin/bash
# ABOUTME: Exercise the command saved by the installer through sh, with a
# ABOUTME: sandboxed config, and verify backup and restore preserve it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
export HOME="$TEST_BASE/home"
export CORTADO_PATH_TEST="expanded"
mkdir -p "$HOME"

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
    if output=$(printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$render_dir" \
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
