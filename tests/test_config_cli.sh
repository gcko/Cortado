#!/bin/bash
# ABOUTME: Tests for cortado.sh config subcommand (CLI path, show, set, toggle, write)
# ABOUTME: Run with: bash tests/test_config_cli.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (missing '$needle')"; echo "    in: $haystack"; FAIL=$((FAIL + 1)) ;;
    esac
}

assert_file_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF "$needle" "$file" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing '$needle' in $file)"
        FAIL=$((FAIL + 1))
    fi
}

TMPHOME=$(mktemp -d "${TMPDIR:-/tmp}/cortado-cfg-test.XXXXXX")
export CLAUDE_CONFIG_DIR="$TMPHOME/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
trap 'rm -rf "$TMPHOME"' EXIT

CORTADO="$SCRIPT_DIR/cortado.sh"

echo "=== config CLI tests ==="

ver=$("$CORTADO" version 2>/dev/null | tr -d '[:space:]')
assert_eq "version prints VERSION file" "1.8.0" "$ver"

help_out=$("$CORTADO" help 2>&1)
assert_contains "help mentions config" "config" "$help_out"

path_out=$("$CORTADO" config --path 2>&1)
assert_eq "config --path uses CLAUDE_CONFIG_DIR" "$CLAUDE_CONFIG_DIR/cortado.conf" "$path_out"

show_out=$("$CORTADO" config --show 2>&1)
assert_contains "show lists modules" "Modules:" "$show_out"
assert_contains "show default git on" "[on ] git" "$show_out" || assert_contains "show git line" "git" "$show_out"

# set + write
"$CORTADO" config --set COLOR_THEME=minimal >/dev/null 2>&1
assert_file_contains "set writes COLOR_THEME" 'COLOR_THEME="minimal"' "$CLAUDE_CONFIG_DIR/cortado.conf"

"$CORTADO" config --toggle weather >/dev/null 2>&1
assert_file_contains "toggle weather on" 'MODULE_WEATHER="true"' "$CLAUDE_CONFIG_DIR/cortado.conf"

"$CORTADO" config --toggle weather >/dev/null 2>&1
assert_file_contains "toggle weather off" 'MODULE_WEATHER="false"' "$CLAUDE_CONFIG_DIR/cortado.conf"

# project scope
PROJ="$TMPHOME/proj"
mkdir -p "$PROJ"
(
  cd "$PROJ" || exit 1
  "$CORTADO" config --project --set MODULE_DIRECTORY=false >/dev/null 2>&1
)
assert_file_contains "project conf written" 'MODULE_DIRECTORY="false"' "$PROJ/.cortado.conf"

# statusline path still works with empty-ish JSON (no args)
json='{"cwd":"/tmp","model":{"display_name":"Test"},"context_window":{"used_percentage":10}}'
# Must not treat missing args as config
out=$(echo "$json" | "$CORTADO" 2>/dev/null | head -c 200)
# Just ensure it produced some output or empty without error
rc=0
echo "$json" | "$CORTADO" >/dev/null 2>&1 || rc=$?
assert_eq "statusline main still exits 0" "0" "$rc"

# unknown module
rc=0
"$CORTADO" config --toggle not-a-module >/dev/null 2>&1 || rc=$?
assert_eq "unknown module fails" "2" "$rc"

# --set must not accept process-critical names or injectable values
rc=0
"$CORTADO" config --set PATH=/tmp/evil >/dev/null 2>&1 || rc=$?
assert_eq "set rejects PATH" "2" "$rc"

rc=0
"$CORTADO" config --set COLOR_THEME='default" && echo PWNED #' >/dev/null 2>&1 || rc=$?
assert_eq "set rejects quote/amp value" "2" "$rc"
if grep -q 'PWNED' "$CLAUDE_CONFIG_DIR/cortado.conf" 2>/dev/null; then
    echo "  FAIL: injected payload written to config"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: injected payload not written"
    PASS=$((PASS + 1))
fi

# Preserve unmanaged keys + custom MODULE_ORDER on --set
printf '%s\n' \
    'RATE_SHOW_PROGRESS_BAR="true"' \
    'MODULE_GIT="true"' \
    'MODULE_DIRECTORY="true"' \
    'MODULE_ORDER="git,directory"' \
    > "$CLAUDE_CONFIG_DIR/cortado.conf"
"$CORTADO" config --set COLOR_THEME=minimal >/dev/null 2>&1
assert_file_contains "set preserves RATE_*" 'RATE_SHOW_PROGRESS_BAR="true"' "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_file_contains "set preserves custom MODULE_ORDER" 'MODULE_ORDER="git,directory"' "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_file_contains "set still writes theme" 'COLOR_THEME="minimal"' "$CLAUDE_CONFIG_DIR/cortado.conf"

# --toggle appends/removes one name; does not rebuild catalog order
"$CORTADO" config --toggle weather >/dev/null 2>&1
assert_file_contains "toggle appends module to order" 'MODULE_ORDER="git,directory,weather"' "$CLAUDE_CONFIG_DIR/cortado.conf"
assert_file_contains "toggle still preserves RATE_*" 'RATE_SHOW_PROGRESS_BAR="true"' "$CLAUDE_CONFIG_DIR/cortado.conf"

# Project .cortado.conf must not be sourced (644 is typical for a cloned repo)
PROJ_PWN="$PROJ"
printf '%s\n' 'touch "$CLAUDE_CONFIG_DIR/pwned"' 'MODULE_DIRECTORY="false"' > "$PROJ_PWN/.cortado.conf"
chmod 644 "$PROJ_PWN/.cortado.conf"
(
  cd "$PROJ_PWN" || exit 1
  "$CORTADO" config --project --show >/dev/null 2>&1
)
if [ -e "$CLAUDE_CONFIG_DIR/pwned" ]; then
    echo "  FAIL: project .cortado.conf was sourced (pwned marker exists)"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: project .cortado.conf is not sourced"
    PASS=$((PASS + 1))
fi
# Safe parser should still honor KEY=VALUE
show_proj=$(cd "$PROJ_PWN" && "$CORTADO" config --project --show 2>&1)
assert_contains "project --show still works" "Modules:" "$show_proj"
assert_contains "project --show honors MODULE_DIRECTORY=false" "[off] directory" "$show_proj"

# --project --set must not copy extras that are not allowlisted / not safe
printf '%s\n' \
    'touch "$CLAUDE_CONFIG_DIR/pwned2"' \
    'PATH=/tmp/evil' \
    'IFS=hack' \
    'BASH_ENV=/tmp/evil.bashrc' \
    'RATE_SHOW_PROGRESS_BAR="true"; echo PWNED_EXTRA' \
    'MODULE_CPU="true"' \
    > "$PROJ_PWN/.cortado.conf"
chmod 644 "$PROJ_PWN/.cortado.conf"
(
  cd "$PROJ_PWN" || exit 1
  "$CORTADO" config --project --set COLOR_THEME=minimal >/dev/null 2>&1
)
if [ -e "$CLAUDE_CONFIG_DIR/pwned2" ]; then
    echo "  FAIL: project --set sourced .cortado.conf"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: project --set does not source .cortado.conf"
    PASS=$((PASS + 1))
fi
assert_file_contains "project --set writes theme" 'COLOR_THEME="minimal"' "$PROJ_PWN/.cortado.conf"
if grep -qE 'PATH=|IFS=|BASH_ENV=|PWNED_EXTRA|touch ' "$PROJ_PWN/.cortado.conf"; then
    echo "  FAIL: project --set copied unsafe extras"
    FAIL=$((FAIL + 1))
    echo "    file:"
    cat "$PROJ_PWN/.cortado.conf"
else
    echo "  PASS: project --set drops PATH/IFS/BASH_ENV/injection extras"
    PASS=$((PASS + 1))
fi

# Same extras must not survive --project --toggle
printf '%s\n' \
    'PATH=/tmp/evil' \
    'IFS=hack' \
    'BASH_ENV=/tmp/evil.bashrc' \
    'RATE_SHOW_PROGRESS_BAR="true"; echo PWNED_EXTRA' \
    'MODULE_CPU="true"' \
    > "$PROJ_PWN/.cortado.conf"
(
  cd "$PROJ_PWN" || exit 1
  "$CORTADO" config --project --toggle weather >/dev/null 2>&1
)
if grep -qE 'PATH=|IFS=|BASH_ENV=|PWNED_EXTRA' "$PROJ_PWN/.cortado.conf"; then
    echo "  FAIL: project --toggle copied unsafe extras"
    FAIL=$((FAIL + 1))
    cat "$PROJ_PWN/.cortado.conf"
else
    echo "  PASS: project --toggle drops PATH/IFS/BASH_ENV/injection extras"
    PASS=$((PASS + 1))
fi

# Documented default separator must be settable
rc=0
"$CORTADO" config --set 'SEPARATOR= | ' >/dev/null 2>&1 || rc=$?
assert_eq "set allows pipe separator" "0" "$rc"
assert_file_contains "set writes pipe separator" 'SEPARATOR=" | "' "$CLAUDE_CONFIG_DIR/cortado.conf"

# MODULE_ORDER=* must not expand cwd names
rc=0
"$CORTADO" config --set 'MODULE_ORDER=*' >/dev/null 2>&1 || rc=$?
assert_eq "set rejects MODULE_ORDER glob" "2" "$rc"
touch "$TMPHOME/STAR_GLOB_MARKER"
printf '%s\n' 'MODULE_ORDER="*"' 'MODULE_GIT="true"' > "$CLAUDE_CONFIG_DIR/cortado.conf"
(
  cd "$TMPHOME" || exit 1
  "$CORTADO" config --toggle git >/dev/null 2>&1
)
if grep -q 'STAR_GLOB_MARKER' "$CLAUDE_CONFIG_DIR/cortado.conf"; then
    echo "  FAIL: toggle expanded MODULE_ORDER glob into filenames"
    FAIL=$((FAIL + 1))
    cat "$CLAUDE_CONFIG_DIR/cortado.conf"
else
    echo "  PASS: toggle does not expand MODULE_ORDER globs"
    PASS=$((PASS + 1))
fi

# --- Migration from Barista (pre-rename file names) ---
echo ""
echo "--- Barista migration ---"
file_mode() {
    if [ "$(uname)" = "Darwin" ]; then /usr/bin/stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

MIG_DIR="$TMPHOME/mig-claude"
mkdir -p "$MIG_DIR"
printf '%s\n' 'COLOR_THEME="vibrant"' 'RATE_SHOW_PROGRESS_BAR="true"' > "$MIG_DIR/barista.conf"
chmod 600 "$MIG_DIR/barista.conf"
mig_show=$(CLAUDE_CONFIG_DIR="$MIG_DIR" "$CORTADO" config --show 2>&1)
assert_contains "legacy barista.conf settings apply" "COLOR_THEME=vibrant" "$mig_show"
assert_file_contains "barista.conf copied to cortado.conf" 'COLOR_THEME="vibrant"' "$MIG_DIR/cortado.conf"
assert_eq "migrated cortado.conf keeps 600 mode" "600" "$(file_mode "$MIG_DIR/cortado.conf")"
assert_file_contains "legacy barista.conf left in place" 'COLOR_THEME="vibrant"' "$MIG_DIR/barista.conf"

# An existing cortado.conf is never overwritten by the legacy file
printf '%s\n' 'COLOR_THEME="minimal"' > "$MIG_DIR/cortado.conf"
chmod 600 "$MIG_DIR/cortado.conf"
mig_show=$(CLAUDE_CONFIG_DIR="$MIG_DIR" "$CORTADO" config --show 2>&1)
assert_contains "cortado.conf wins over barista.conf" "COLOR_THEME=minimal" "$mig_show"
assert_file_contains "cortado.conf not overwritten" 'COLOR_THEME="minimal"' "$MIG_DIR/cortado.conf"

# Project .barista.conf is honored (safe parser) when no .cortado.conf exists
PROJ_MIG="$TMPHOME/proj-mig"
mkdir -p "$PROJ_MIG"
printf '%s\n' 'MODULE_ORDER="directory,model"' \
    'SEPARATOR="@@"' 'RATE_SHOW_PROGRESS_BAR="true"' > "$PROJ_MIG/.barista.conf"
mig_json='{"workspace":{"current_dir":"'"$PROJ_MIG"'"},"model":{"display_name":"Test"}}'
mig_out=$(echo "$mig_json" | "$CORTADO" 2>/dev/null)
assert_contains "statusline reads project .barista.conf" "@@" "$mig_out"

proj_show=$(cd "$PROJ_MIG" && "$CORTADO" config --project --show 2>&1)
assert_contains "project --show reads .barista.conf" "proj-mig/.barista.conf" "$proj_show"
if [ -f "$PROJ_MIG/.cortado.conf" ]; then
    echo "  FAIL: project --show should not create .cortado.conf"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: project --show does not create .cortado.conf"
    PASS=$((PASS + 1))
fi
(cd "$PROJ_MIG" && "$CORTADO" config --project --set COLOR_THEME=minimal >/dev/null 2>&1)
assert_file_contains "project --set writes .cortado.conf" 'COLOR_THEME="minimal"' "$PROJ_MIG/.cortado.conf"
assert_file_contains "project --set carries over .barista.conf extras" 'RATE_SHOW_PROGRESS_BAR="true"' "$PROJ_MIG/.cortado.conf"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
