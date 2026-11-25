#!/bin/bash
# ABOUTME: Exercise the command saved by the installer through sh, with a
# ABOUTME: sandboxed config, and verify backup and restore preserve it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
export HOME="$TEST_BASE/home"
export CORTADO_PATH_TEST="expanded"
mkdir -p "$HOME"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc"
        printf '    expected: %s\n    actual:   %s\n' "$expected" "$actual"
    fi
}

run_installer() {
    local config_dir="$1"
    shift
    CLAUDE_CONFIG_DIR="$config_dir" CACHE_DIR="$config_dir/cortado-cache" \
        /bin/bash "$REPO_ROOT/install.sh" --skip-update-check --no-color --no-emoji "$@"
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
        CACHE_DIR="$render_dir/cortado-cache" TERMINAL_WIDTH=200 sh -c "$cmd" 2>&1); then
        case "$output" in
            *"25%"*"MODEL: Opus[1m]"*)
                pass "$desc"
                return
                ;;
        esac
    fi
    fail "$desc"
    printf '    got: %s\n' "$output"
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

printf '1\nn\n' | run_installer "$space_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1
assert_eq "uninstall restores the saved statusLine verbatim" "$original_statusline" \
    "$(jq -c '.statusLine' "$settings")"
assert_statusline_runs "restored statusline renders through sh [with space]" "$settings"

printf '2\n' | run_installer "$space_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1
assert_eq "uninstall without restore removes the statusLine key" "false" \
    "$(jq -r 'has("statusLine")' "$settings")"
assert_eq "uninstall preserves unrelated settings" "true" \
    "$(jq -r '.includeCoAuthoredBy' "$settings")"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
