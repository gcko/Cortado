#!/bin/bash
# ABOUTME: cortado setup, update, uninstall and help: setup points Claude Code at
# ABOUTME: the copy it runs from (the stable opt path on Homebrew), update runs the
# ABOUTME: installed copy's verified --update against a fake release, and uninstall
# ABOUTME: restores the previous statusLine. Run with: /bin/bash tests/test_cortado_lifecycle.sh

umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented

TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1
REPO_PHYS=$(cd "$REPO_ROOT" && pwd -P) || exit 1
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
for tool in jq bc; do
    tool_path=$(command -v "$tool") || continue
    BASE_PATH="${tool_path%/*}:$BASE_PATH"
done
FAKE_BIN="$TEST_BASE/bin"
mkdir -p "$FAKE_BIN" || exit 1

# quoted <path>: the command text the installer writes for a path.
quoted() { jq -nr --arg path "$1" '$path | @sh'; }

# new_case: a fresh HOME and config directory (with spaces in their paths).
new_case() {
    root=$(mktemp -d "$TEST_BASE/case.XXXXXX") || exit 1
    home="$root/my home"
    cfg="$root/claude config"
    mkdir -p "$home" || exit 1
    settings="$cfg/settings.json"
    manifest="$cfg/.cortado-backup/manifest.json"
    cmd="$home/.local/bin/cortado"
    runtime="$cfg/cortado"
    : > "$root/curl-calls"
}

# run <script> <args...>: run a cortado script in the sandbox; stdin from $STDIN_TEXT.
run() {
    local script="$1"
    shift
    out=$(printf '%b' "${STDIN_TEXT:-}" | HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" \
        TMPDIR="$root" PATH="$FAKE_BIN:$BASE_PATH" CURL_CALLS="$root/curl-calls" FIXTURE="$TEST_BASE/release" \
        /bin/bash "$script" "$@" 2>&1)
    status=$?
}

install_sandbox() {
    out=$(HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" PATH="$BASE_PATH" \
        /bin/bash "$REPO_ROOT/install.sh" --minimal --skip-update-check --no-color --no-emoji 2>&1 < /dev/null)
    install_status=$?
}

others() { jq -cS 'del(.statusLine)' "$1" 2>/dev/null; }
statusline() { jq -cS '.statusLine' "$1" 2>/dev/null; }
leftovers() { find "$cfg" -maxdepth 2 \( -name '.settings.*' -o -name 'snapshot.*' -o -name '*.backup.*' \
    -o -name '.cortado-runtime.*' -o -name '.cortado-previous.*' -o -name '.cortado-update.lock' \) 2>/dev/null; }

# A curl that records every call, serves one fake release, and never touches the network.
cat > "$FAKE_BIN/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_CALLS"
while [ "$#" -gt 0 ]; do
    case "$1" in
        https://*) url="$1" ;;
        -o) output="$2"; shift ;;
    esac
    shift
done
case "$url" in
    https://api.github.com/*) printf '%s\n200\n' '{"tag_name":"v99.0.0"}' ;;
    */v99.0.0/SHA256SUMS) cp "$FIXTURE/SHA256SUMS" "$output" ;;
    */v99.0.0/Cortado-source.zip) cp "$FIXTURE/Cortado-source.zip" "$output" ;;
    *) exit 22 ;;
esac
STUB
chmod +x "$FAKE_BIN/curl"

echo "=== cortado setup ==="
SELF="$REPO_PHYS/cortado.sh"
SELF_CMD=$(quoted "$SELF")
ours="{\"command\":$(jq -n --arg c "$SELF_CMD" '$c'),\"type\":\"command\"}"

# --- a missing settings.json is created ----------------------------------------
new_case
run "$REPO_ROOT/cortado.sh" setup
assert_eq 'setup with no settings.json exits 0' 0 "$status"
assert_eq 'setup with no settings.json writes statusLine to this copy' "$ours" "$(statusline "$settings")"
assert_eq 'setup with no settings.json writes nothing else' '{}' "$(others "$settings")"
assert_match 'setup writes settings.json owner-only' '^-rw-------' "$(ls -l "$settings")"
assert_contains 'setup says what Claude Code now runs' "Claude Code now runs $SELF" "$out"
assert_rc 'setup with no previous statusLine writes no backup' 1 test -e "$manifest"
assert_empty 'setup leaves no staging files' "$(leftovers)"

# --- an empty object ------------------------------------------------------------
new_case
mkdir -p "$cfg" && printf '{}\n' > "$settings"
run "$REPO_ROOT/cortado.sh" setup
assert_eq 'setup with an empty settings.json exits 0' 0 "$status"
assert_eq 'setup with an empty settings.json adds statusLine' "$ours" "$(statusline "$settings")"
assert_eq 'setup with an empty settings.json adds nothing else' '{}' "$(others "$settings")"

# --- an existing settings.json: every other key kept, the old statusLine backed up
new_case
mkdir -p "$cfg"
previous='{"command":"echo previous line","padding":2,"type":"command"}'
printf '%s\n' "{\"model\":\"opus\",\"hooks\":{\"Stop\":[{\"x\":1}]},\"statusLine\":$previous,\"env\":{\"A\":\"b\"}}" > "$settings"
before_others=$(others "$settings")
run "$REPO_ROOT/cortado.sh" setup
assert_eq 'setup over an existing statusLine exits 0' 0 "$status"
assert_eq 'setup replaces statusLine' "$ours" "$(statusline "$settings")"
assert_eq 'setup preserves every other key' "$before_others" "$(others "$settings")"
assert_eq 'setup backs up the previous statusLine in the installer manifest' "$previous" \
    "$(jq -cS '.settings_statusline' "$manifest" 2>/dev/null)"
assert_eq 'the backup lists no files' '[]' "$(jq -c '.files' "$manifest" 2>/dev/null)"
assert_empty 'setup leaves no staging or snapshot files' "$(leftovers)"

# Twice: the second run changes nothing.
cp "$settings" "$root/settings.once"
cp "$manifest" "$root/manifest.once"
inode_once=$(ls -i "$settings" | awk '{print $1}')
run "$REPO_ROOT/cortado.sh" setup
assert_eq 'a second setup does not rewrite settings.json' "$inode_once" "$(ls -i "$settings" | awk '{print $1}')"
assert_eq 'a second setup exits 0' 0 "$status"
assert_rc 'a second setup leaves settings.json byte for byte' 0 cmp -s "$root/settings.once" "$settings"
assert_rc 'a second setup leaves the backup alone' 0 cmp -s "$root/manifest.once" "$manifest"
assert_contains 'a second setup says nothing changed' "Claude Code already runs $SELF" "$out"

# The installer's --uninstall restores the statusLine setup backed up.
STDIN_TEXT='1\nn\n' run "$REPO_ROOT/install.sh" --uninstall --no-color --no-emoji
assert_eq 'uninstall after setup exits 0' 0 "$status"
assert_eq 'uninstall after setup restores the previous statusLine' "$previous" "$(statusline "$settings")"
assert_eq 'uninstall after setup keeps every other key' "$before_others" "$(others "$settings")"

# An existing restore point is kept: the first statusLine before Cortado wins.
new_case
mkdir -p "$cfg/.cortado-backup"
printf '%s\n' '{"timestamp":"t","files":[],"settings_statusline":{"type":"command","command":"first"}}' > "$manifest"
printf '%s\n' '{"statusLine":{"type":"command","command":"second"}}' > "$settings"
cp "$manifest" "$root/manifest.before"
run "$REPO_ROOT/cortado.sh" setup
assert_eq 'setup with an existing backup exits 0' 0 "$status"
assert_rc 'setup keeps an existing backup' 0 cmp -s "$root/manifest.before" "$manifest"
assert_eq 'setup with an existing backup still points Claude Code here' "$ours" "$(statusline "$settings")"

# --- settings.json it cannot use: refused, nothing changed -----------------------
for shape in garbage two-docs array string directory; do
    new_case
    mkdir -p "$cfg"
    case "$shape" in
        garbage) printf '%s\n' '{"statusLine": oops' > "$settings" ;;
        two-docs) printf '%s\n' '{} {}' > "$settings" ;;
        array) printf '%s\n' '[]' > "$settings" ;;
        string) printf '%s\n' '"x"' > "$settings" ;;
        directory) mkdir "$settings" ;;
    esac
    printf '%s\n' '{"timestamp":"t","files":[],"settings_statusline":null}' > "$root/no-manifest"
    cp -R "$cfg" "$root/cfg.before"
    run "$REPO_ROOT/cortado.sh" setup
    assert_eq "setup refuses a $shape settings.json" 1 "$status"
    assert_contains "setup says why it refused a $shape settings.json" 'Nothing was changed' "$out"
    assert_rc "setup changes nothing for a $shape settings.json" 0 diff -r "$root/cfg.before" "$cfg"
done

# A FIFO is refused before anything reads it (a read would wait forever).
new_case
mkdir -p "$cfg" && mkfifo "$settings" || exit 1
out=$(HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" PATH="$BASE_PATH" \
    perl -e 'alarm 20; exec @ARGV' /bin/bash "$REPO_ROOT/cortado.sh" setup 2>&1 < /dev/null)
status=$?
assert_eq 'setup refuses a FIFO settings.json without waiting on it' 1 "$status"
assert_contains 'setup says a FIFO settings.json is not a regular file' 'is not a regular file. Nothing was changed' "$out"
assert_rc 'setup leaves a FIFO settings.json in place' 0 test -p "$settings"

# --- Homebrew: the stable opt path, never the versioned Cellar path --------------
# brew_layout <opt target version>: a fake prefix with Cellar/cortado/9.9.9 and bin link.
brew_layout() {
    brew="$root/brew"
    keg="$brew/Cellar/cortado/9.9.9"
    mkdir -p "$keg/libexec" "$brew/Cellar/cortado/9.9.8/libexec" "$brew/opt" "$brew/bin" || exit 1
    cp -R "$REPO_ROOT/cortado.sh" "$REPO_ROOT/cortado.conf" "$REPO_ROOT/VERSION" \
        "$REPO_ROOT/lib" "$REPO_ROOT/modules" "$keg/libexec/" || exit 1
    cp -R "$keg/libexec/." "$brew/Cellar/cortado/9.9.8/libexec/" || exit 1
    [ -z "$1" ] || ln -s "../Cellar/cortado/$1" "$brew/opt/cortado" || exit 1
    ln -s ../Cellar/cortado/9.9.9/libexec/cortado.sh "$brew/bin/cortado" || exit 1
}
for via in bin cellar opt; do
    new_case
    brew_layout 9.9.9
    case "$via" in
        bin) script="$brew/bin/cortado" ;;
        cellar) script="$keg/libexec/cortado.sh" ;;
        opt) script="$brew/opt/cortado/libexec/cortado.sh" ;;
    esac
    run "$script" setup
    assert_eq "Homebrew setup through $via exits 0" 0 "$status"
    assert_eq "Homebrew setup through $via writes the opt path" \
        "$(quoted "$brew/opt/cortado/libexec/cortado.sh")" "$(jq -r '.statusLine.command' "$settings" 2>/dev/null)"
    assert_not_contains "Homebrew setup through $via never writes the Cellar path" 'Cellar' "$(cat "$settings" 2>/dev/null)"
done
for opt in none 9.9.8; do
    new_case
    brew_layout "${opt#none}"
    mkdir -p "$cfg" && printf '%s\n' '{"statusLine":{"type":"command","command":"keep"}}' > "$settings"
    cp -R "$cfg" "$root/cfg.before"
    run "$brew/bin/cortado" setup
    assert_eq "Homebrew setup with opt=$opt refuses" 1 "$status"
    assert_contains "Homebrew setup with opt=$opt names the stable path it needs" "$brew/opt/cortado/libexec/cortado.sh" "$out"
    assert_rc "Homebrew setup with opt=$opt changes nothing" 0 diff -r "$root/cfg.before" "$cfg"
done

echo "=== cortado update ==="
# --- Homebrew: no network, nothing changed ---------------------------------------
new_case
brew_layout 9.9.9
cp -R "$brew" "$root/brew.before"
run "$brew/bin/cortado" update
assert_eq 'Homebrew update exits 1' 1 "$status"
assert_contains 'Homebrew update says to run brew upgrade' 'brew upgrade cortado' "$out"
assert_empty 'Homebrew update makes no request' "$(cat "$root/curl-calls")"
assert_rc 'Homebrew update changes nothing in the prefix' 0 diff -r "$root/brew.before" "$brew"
assert_rc 'Homebrew update creates no config directory' 1 test -e "$cfg"

# --- a fake verified release ------------------------------------------------------
release="$TEST_BASE/release"
package="$TEST_BASE/package"
mkdir -p "$release" "$package" || exit 1
cp -R "$REPO_ROOT/cortado.sh" "$REPO_ROOT/cortado.conf" "$REPO_ROOT/install.sh" \
    "$REPO_ROOT/lib" "$REPO_ROOT/modules" "$package/" || exit 1
printf '%s\n' '# release fixture marker' >> "$package/cortado.sh"
printf '%s\n' '# release fixture marker' >> "$package/install.sh"
printf '%s\n' 99.0.0 > "$package/VERSION"
mkdir -p "$package/docs" "$package/tests" || exit 1
printf 'readme\n' > "$package/README.md"
printf 'doc\n' > "$package/docs/install.md"
printf 'test\n' > "$package/tests/test_x.sh"
fixture_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$package" "$@"; }
fixture_git init -q --template= &&
    fixture_git add -A &&
    fixture_git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
        -c core.hooksPath=/dev/null commit -qm fixture &&
    fixture_git archive --format=zip --prefix=Cortado-99.0.0/ -o "$release/Cortado-source.zip" HEAD || exit 1
if command -v sha256sum >/dev/null; then
    sum=$(sha256sum < "$release/Cortado-source.zip")
else
    sum=$(shasum -a 256 < "$release/Cortado-source.zip")
fi
printf '%s  Cortado-source.zip\n' "${sum%% *}" > "$release/SHA256SUMS"

# --- an installed copy updates itself from the release ----------------------------
new_case
install_sandbox
assert_eq 'the sandbox install completes' 0 "$install_status"
assert_rc 'the installed copy includes install.sh' 0 test -x "$runtime/install.sh"
assert_rc 'the installed install.sh is the shipped one' 0 cmp -s "$REPO_ROOT/install.sh" "$runtime/install.sh"
printf '# retired\n' > "$runtime/modules/zz-retired.sh"
printf 'mine\n' > "$runtime/my-notes.txt"
cp "$runtime/cortado.conf" "$root/conf.before"
cp "$settings" "$root/settings.before"
run "$cmd" update --no-color --no-emoji
assert_eq 'cortado update exits 0' 0 "$status"
assert_contains 'cortado update reports the release' 'Updated to version 99.0.0' "$out"
assert_contains 'cortado update restarts the new installer, which is current' 'Already up to date (99.0.0)' "$out"
assert_contains 'cortado update fetches the checksum for the tag' '/releases/download/v99.0.0/SHA256SUMS' "$(cat "$root/curl-calls")"
assert_eq 'the installed copy is on the release' 99.0.0 "$(tr -d '[:space:]' < "$runtime/VERSION")"
assert_file_contains 'the installed cortado.sh is the release one' '# release fixture marker' "$runtime/cortado.sh"
assert_file_contains 'the installed install.sh is the release one' '# release fixture marker' "$runtime/install.sh"
assert_rc 'cortado.conf carries over' 0 cmp -s "$root/conf.before" "$runtime/cortado.conf"
assert_eq 'files the user added carry over' mine "$(cat "$runtime/my-notes.txt" 2>/dev/null)"
assert_rc 'a module the release dropped is gone' 1 test -e "$runtime/modules/zz-retired.sh"
for extra in README.md docs tests .git; do
    assert_rc "the release's $extra is not copied into the installed copy" 1 test -e "$runtime/$extra"
done
assert_rc 'settings.json is unchanged' 0 cmp -s "$root/settings.before" "$settings"
assert_empty 'the update leaves no backup, staging or lock behind' "$(leftovers)"
assert_eq 'the update leaves nothing beside the config directory' '' \
    "$(find "$root" -maxdepth 1 -name 'claude config.backup.*' -o -maxdepth 1 -name 'cortado-update.*' | head -1)"
run "$cmd" version
assert_eq 'cortado version reads the release' 99.0.0 "$out"
render=$(printf '%s' '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Test"}}' |
    HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" PATH="$BASE_PATH" /bin/bash "$runtime/cortado.sh" 2>&1)
assert_contains 'the updated copy still renders' 'Test' "$render"

# An older installed copy without install.sh: explained, no request.
new_case
install_sandbox
rm -f "$runtime/install.sh"
run "$cmd" update
assert_eq 'update without install.sh exits 1' 1 "$status"
assert_contains 'update without install.sh says how to get it' './install.sh --update' "$out"
assert_empty 'update without install.sh makes no request' "$(cat "$root/curl-calls")"

# A copy installed before install.sh rode along, on the current release: the
# clone's --update refreshes it so it gains install.sh, keeping cortado.conf.
new_case
install_sandbox
rm -f "$runtime/install.sh"
printf '%s\n' 99.0.0 > "$runtime/VERSION"
cp "$runtime/cortado.conf" "$root/conf.before"
mkdir -p "$root/clone" && cp -R "$package/." "$root/clone/" && rm -rf "$root/clone/.git" || exit 1
run "$root/clone/install.sh" --update --no-color --no-emoji
assert_eq 'a clone update over a current copy without install.sh exits 0' 0 "$status"
assert_file_contains 'the current copy gains the release install.sh' '# release fixture marker' "$runtime/install.sh"
assert_rc 'the refreshed copy keeps cortado.conf' 0 cmp -s "$root/conf.before" "$runtime/cortado.conf"
assert_rc 'the clone is not copied into the installed copy' 1 test -e "$runtime/README.md"

# An installer without lib/statusline-settings.sh stops and names it.
new_case
mkdir -p "$root/partial" && cp -R "$REPO_ROOT/install.sh" "$REPO_ROOT/VERSION" "$REPO_ROOT/lib" "$root/partial/" || exit 1
rm "$root/partial/lib/statusline-settings.sh"
run "$root/partial/install.sh" --update
assert_eq 'an installer without lib/statusline-settings.sh exits 1' 1 "$status"
assert_contains 'an installer without lib/statusline-settings.sh names it' \
    "cannot load $root/partial/lib/statusline-settings.sh" "$out"
assert_empty 'an installer without lib/statusline-settings.sh makes no request' "$(cat "$root/curl-calls")"

# Only display flags pass through.
new_case
install_sandbox
run "$cmd" update --uninstall
assert_eq 'update refuses another installer option' 2 "$status"
assert_empty 'a refused update option makes no request' "$(cat "$root/curl-calls")"
assert_rc 'a refused update option keeps the installed copy' 0 test -f "$runtime/cortado.sh"

echo "=== cortado uninstall ==="
new_case
mkdir -p "$cfg"
printf '%s\n' '{"model":"opus","statusLine":{"type":"command","command":"echo before cortado"}}' > "$settings"
install_sandbox
assert_eq 'install over a previous statusline completes' 0 "$install_status"
assert_rc 'the install made the cortado command' 0 test -L "$cmd"
STDIN_TEXT='1\nn\n' run "$cmd" uninstall --no-color --no-emoji
assert_eq 'cortado uninstall exits 0' 0 "$status"
assert_eq 'cortado uninstall restores the previous statusLine' \
    '{"command":"echo before cortado","type":"command"}' "$(statusline "$settings")"
assert_eq 'cortado uninstall keeps other settings' '{"model":"opus"}' "$(others "$settings")"
assert_rc 'cortado uninstall removes the cortado command' 1 test -L "$cmd"
assert_rc 'cortado uninstall removes the installed copy' 1 test -e "$runtime"
assert_contains 'cortado uninstall says it removed the command' "Removed the cortado command: $cmd" "$out"

new_case
install_sandbox
rm -f "$runtime/install.sh"
run "$cmd" uninstall
assert_eq 'uninstall without install.sh exits 1' 1 "$status"
assert_rc 'uninstall without install.sh keeps the command' 0 test -L "$cmd"

new_case
install_sandbox
run "$cmd" uninstall --update
assert_eq 'uninstall refuses another installer option' 2 "$status"
assert_rc 'a refused uninstall option keeps the installed copy' 0 test -f "$runtime/cortado.sh"

echo "=== cortado help ==="
new_case
run "$REPO_ROOT/cortado.sh" help
assert_eq 'cortado help exits 0' 0 "$status"
for sub in config setup update uninstall version help; do
    assert_match "cortado help lists $sub" "^  cortado $sub( |\$)" "$(printf '%s\n' "$out" | grep -E "^  cortado $sub( |\$)")"
done
assert_not_contains 'cortado help names the command, not the script' 'cortado.sh config' "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
