#!/bin/bash
# ABOUTME: Tests that the update notice names brew upgrade cortado on a Homebrew copy only.
# ABOUTME: Run with: bash tests/test_update_homebrew.sh
#
# Every render uses a cached "available" result, so nothing touches the network.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/tests/lib/assert.sh" indented

# Curl must never run: a stub that records a call fails the "no request" check.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/bin/bash
printf 'call\n' >> "$CURL_LOG"
exit 28
STUB
chmod +x "$TEST_DIR/bin/curl"

# make_copy <dir>: a runnable copy of the shipped files, as a keg or a manual install holds them.
make_copy() {
    mkdir -p "$1" || exit 1
    cp -R "$SCRIPT_DIR/cortado.sh" "$SCRIPT_DIR/cortado.conf" "$SCRIPT_DIR/VERSION" \
        "$SCRIPT_DIR/lib" "$SCRIPT_DIR/modules" "$1/" || exit 1
}

# render <cortado.sh> <cache content> [config line...]: the rendered line, colour stripped.
render() {
    local script="$1" cached="$2" sandbox payload
    shift 2
    sandbox=$(mktemp -d "$TEST_DIR/config.XXXXXX")
    mkdir -p "$sandbox/cortado-cache" && chmod 700 "$sandbox/cortado-cache"
    [ -z "$cached" ] || printf '%s\n' "$cached" > "$sandbox/cortado-cache/update_check"
    printf '%s\n' 'MODULE_ORDER="model,update"' 'MODULE_MODEL="true"' 'MODULE_UPDATE="true"' \
        "$@" > "$sandbox/cortado.conf"
    chmod 600 "$sandbox/cortado.conf"
    : > "$TEST_DIR/curl-calls"
    payload=$(jq -n --arg dir "$sandbox" '{workspace:{current_dir:$dir},model:{display_name:"Fixture"}}')
    printf '%s\n' "$payload" |
        CLAUDE_CONFIG_DIR="$sandbox" CURL_LOG="$TEST_DIR/curl-calls" PATH="$TEST_DIR/bin:$PATH" \
        /bin/bash "$script" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
}

curl_calls() {
    awk 'END {print NR}' "$TEST_DIR/curl-calls"
}

# Layouts: a Homebrew prefix reached by its Cellar path and by its opt link,
# a manual install under a plain opt/cortado, and a source-style directory.
brew="$TEST_DIR/brew"
make_copy "$brew/Cellar/cortado/9.9.9/libexec"
mkdir -p "$brew/opt"
ln -s ../Cellar/cortado/9.9.9 "$brew/opt/cortado"
cellar_script="$brew/Cellar/cortado/9.9.9/libexec/cortado.sh"
opt_script="$brew/opt/cortado/libexec/cortado.sh"
mkdir -p "$brew/bin"
ln -s ../Cellar/cortado/9.9.9/libexec/cortado.sh "$brew/bin/cortado"
make_copy "$TEST_DIR/manual/opt/cortado"
manual_script="$TEST_DIR/manual/opt/cortado/cortado.sh"
make_copy "$TEST_DIR/source/Cortado"
source_script="$TEST_DIR/source/Cortado/cortado.sh"

avail='available:9.9.9'
hint='brew upgrade cortado'

# --- A Homebrew copy names brew upgrade, in every display mode and theme -----
out=$(render "$cellar_script" "$avail" 'COLOR_THEME="monochrome"')
assert_eq "Cellar copy, monochrome: notice names brew upgrade" "MODEL: Fixture | UPD: v9.9.9 ($hint)" "$out"
assert_eq "Cellar copy: the notice makes no request" 0 "$(curl_calls)"
out=$(render "$opt_script" "$avail" 'COLOR_THEME="monochrome"')
assert_eq "opt link copy, monochrome: notice names brew upgrade" "MODEL: Fixture | UPD: v9.9.9 ($hint)" "$out"
out=$(render "$brew/bin/cortado" "$avail" 'COLOR_THEME="monochrome"')
assert_eq "cortado command link into the Cellar: notice names brew upgrade" "MODEL: Fixture | UPD: v9.9.9 ($hint)" "$out"
out=$(render "$cellar_script" "$avail")
assert_contains "Cellar copy, default theme: notice names brew upgrade" "v9.9.9 ($hint)" "$out"
assert_contains "Cellar copy, default theme: notice keeps the icon" "⬆ v9.9.9" "$out"
for mode in compact verbose; do
    out=$(render "$cellar_script" "$avail" 'COLOR_THEME="monochrome"' "DISPLAY_MODE=\"$mode\"")
    assert_contains "Cellar copy, $mode mode: notice names brew upgrade" "UPD: v9.9.9 ($hint)" "$out"
done
out=$(render "$cellar_script" "$avail" 'USE_ICONS="false"')
assert_contains "Cellar copy, icons off: notice names brew upgrade" "v9.9.9 ($hint)" "$out"

# --- A source or manual copy is unchanged ------------------------------------
for script in "$manual_script" "$source_script"; do
    out=$(render "$script" "$avail" 'COLOR_THEME="monochrome"')
    assert_eq "non-Homebrew copy ${script#"$TEST_DIR"/}: notice is unchanged" 'MODEL: Fixture | UPD: v9.9.9' "$out"
done

# --- Absences: no newer release means no brew advice -------------------------
out=$(render "$cellar_script" 'checked-current' 'COLOR_THEME="monochrome"')
assert_eq "Cellar copy, current release: no notice" 'MODEL: Fixture' "$out"
out=$(render "$cellar_script" 'unknown' 'COLOR_THEME="monochrome"')
assert_eq "Cellar copy, failed check: stated absence, no brew advice" 'MODEL: Fixture | UPD: --' "$out"
out=$(render "$cellar_script" 'available:not-a-version' 'COLOR_THEME="monochrome"')
assert_not_contains "Cellar copy, malformed cached version: no brew advice for it" "$hint" "$out"

# A keg missing the helper that holds the detection keeps the plain notice.
make_copy "$TEST_DIR/brew2/Cellar/cortado/9.9.9/libexec"
rm -f "$TEST_DIR/brew2/Cellar/cortado/9.9.9/libexec/lib/statusline-settings.sh"
out=$(render "$TEST_DIR/brew2/Cellar/cortado/9.9.9/libexec/cortado.sh" "$avail" 'COLOR_THEME="monochrome"')
assert_eq "Homebrew copy without the detection helper keeps the plain notice" 'MODEL: Fixture | UPD: v9.9.9' "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
