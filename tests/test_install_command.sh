#!/bin/bash
# ABOUTME: The installer's cortado command: ~/.local/bin/cortado links to the
# ABOUTME: installed runtime, is never put over anything it did not create, and
# ABOUTME: --uninstall removes only its own. Run with: /bin/bash tests/test_install_command.sh
# shellcheck disable=SC2016,SC2088 # Expected installer text is literal: $HOME and ~ unexpanded.

umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented

TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1
VERSION_TEXT=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
# A PATH without any ~/.local/bin, so the hint is shown unless a case adds one.
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
for tool in jq bc; do
    tool_path=$(command -v "$tool") || continue
    BASE_PATH="${tool_path%/*}:$BASE_PATH"
done

# new_home: a fresh HOME (with a space in its path) and config directory.
new_home() {
    root=$(mktemp -d "$TEST_BASE/case.XXXXXX") || exit 1
    home="$root/my home"
    cfg="$root/claude config"
    mkdir -p "$home" || exit 1
    bin="$home/.local/bin"
    cmd="$bin/cortado"
    runtime="$cfg/cortado/cortado.sh"
}

# install [flag] [PATH]: run the installer in the sandbox; out holds its output.
install() {
    out=$(HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" PATH="${2:-$BASE_PATH}" \
        /bin/bash "$REPO_ROOT/install.sh" "${1:---minimal}" --skip-update-check --no-color --no-emoji 2>&1 < /dev/null)
    install_status=$?
}

# uninstall [answers]: run --uninstall with the menu answers on stdin.
uninstall() {
    out=$(printf '%b' "${1:-}" | HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" PATH="$BASE_PATH" \
        /bin/bash "$REPO_ROOT/install.sh" --uninstall --no-color --no-emoji 2>&1)
    uninstall_status=$?
}

link_text() {
    if [ -L "$1" ]; then readlink "$1"; else printf 'not a link'; fi
}

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
case "$OSTYPE" in
    darwin*) BASH_RC='~/.bash_profile' ;;
    *) BASH_RC='~/.bashrc' ;;
esac

echo "=== the cortado command ==="

# --- a fresh install creates the command and its directory --------------------
new_home
install --minimal
assert_eq 'a fresh install completes' 0 "$install_status"
assert_eq 'a fresh install links ~/.local/bin/cortado to the installed runtime' "$runtime" "$(link_text "$cmd")"
assert_contains 'the installer says it created the command' "Created the cortado command: $cmd" "$out"
assert_eq 'the command runs the installed copy' "$VERSION_TEXT" \
    "$(CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" "$cmd" version 2>&1)"
assert_eq 'the command runs config against the config it is given' "$cfg/cortado.conf" \
    "$(CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" "$cmd" config --path 2>&1)"
assert_match 'a created ~/.local/bin takes the installer umask' '^drwx------' "$(ls -ld "$bin")"
# Off the PATH: the exact line to add, for zsh and bash, and the full path to run.
assert_contains 'off the PATH, the installer says ~/.local/bin is not on it' "$bin is not on your PATH" "$out"
assert_contains 'off the PATH, the installer prints the line for zsh' "zsh:  add to ~/.zshrc:   $PATH_LINE" "$out"
assert_contains 'off the PATH, the installer prints the line for bash' "bash: add to $BASH_RC:  $PATH_LINE" "$out"
assert_contains 'off the PATH, the final message runs config by the full path' \
    "Or run:   $(printf '%s' "$runtime" | jq -Rr @sh) config" "$out"

# Re-running over its own command keeps it, and says so.
install --defaults
assert_eq 'a reinstall completes' 0 "$install_status"
assert_eq 'a reinstall keeps the command on the runtime' "$runtime" "$(link_text "$cmd")"
assert_contains 'a reinstall reports the command already in place' "The cortado command is in place: $cmd" "$out"
assert_not_contains 'a reinstall does not report a new command' 'Created the cortado command' "$out"

# --- on the PATH: no hint, and the short form ----------------------------------
for spelling in plain slash dot; do
    new_home
    case "$spelling" in
        plain) path_entry="$bin" ;;
        slash) path_entry="$bin/" ;;
        dot) path_entry="$home/.local/./bin" ;;
    esac
    mkdir -p "$bin" || exit 1
    install --force "$path_entry:$BASE_PATH"
    assert_eq "with $path_entry on the PATH, the command is created" "$runtime" "$(link_text "$cmd")"
    assert_not_contains "with $path_entry on the PATH, no PATH hint" 'is not on your PATH' "$out"
    assert_contains "with $path_entry on the PATH, the final message runs cortado config" 'Or run:   cortado config' "$out"
done
# A linked ~/.local/bin on the PATH by its real name counts too.
new_home
mkdir -p "$root/dotfiles/bin" "$home/.local" || exit 1
ln -s "$root/dotfiles/bin" "$bin" || exit 1
install --minimal "$root/dotfiles/bin:$BASE_PATH"
assert_eq 'a linked ~/.local/bin gets the command in the directory it names' "$runtime" \
    "$(link_text "$root/dotfiles/bin/cortado")"
assert_eq 'a linked ~/.local/bin stays a link' "$root/dotfiles/bin" "$(link_text "$bin")"
assert_not_contains 'a linked ~/.local/bin reached by its real name is on the PATH' 'is not on your PATH' "$out"

# An existing ~/.local/bin keeps its mode.
new_home
mkdir -p "$bin" && chmod 750 "$bin" || exit 1
install --minimal
assert_eq 'an existing ~/.local/bin gets the command' "$runtime" "$(link_text "$cmd")"
assert_match 'an existing ~/.local/bin keeps its mode' '^drwxr-x---' "$(ls -ld "$bin")"

# --- never over a cortado it did not create -----------------------------------
# check_kept <label>: the install completes, says so, and leaves $cmd alone.
check_kept() {
    local label="$1" before="$2"
    assert_eq "$label: the install completes" 0 "$install_status"
    assert_eq "$label: settings.json runs the runtime" "$(printf '%s' "$runtime" | jq -Rr @sh)" \
        "$(jq -r '.statusLine.command' "$cfg/settings.json" 2>/dev/null)"
    assert_contains "$label: the installer says it left it" "Left $cmd as it is: it was not made by this installer" "$out"
    assert_eq "$label: it is unchanged" "$before" "$(ls -ld "$cmd" | awk '{print $1}') $(link_text "$cmd")"
}
new_home
mkdir -p "$bin" && printf '#!/bin/sh\necho mine\n' > "$cmd" && chmod 700 "$cmd" || exit 1
before="$(ls -ld "$cmd" | awk '{print $1}') $(link_text "$cmd")"
install --minimal
check_kept 'a regular file' "$before"
assert_eq 'a regular file keeps its bytes' 'mine' "$("$cmd")"

new_home
mkdir -p "$cmd" "$root/shim" || exit 1
real_ln=$(command -v ln) || exit 1
# A logging ln shows the installer never even tries to link over it.
cat > "$root/shim/ln" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$root/ln.log"
exec "$real_ln" "\$@"
SHIM
chmod 700 "$root/shim/ln" || exit 1
before="$(ls -ld "$cmd" | awk '{print $1}') $(link_text "$cmd")"
install --minimal "$root/shim:$BASE_PATH"
check_kept 'a directory' "$before"
assert_eq 'nothing is created inside a cortado directory' '' "$(ls -A "$cmd")"
assert_not_contains 'the installer never runs ln at a cortado directory' '/.local/bin/cortado' "$(cat "$root/ln.log" 2>/dev/null)"

for other in other-tool source-clone other-config relative trailing-slash; do
    new_home
    case "$other" in
        other-tool) target=/opt/other-tool/bin/cortado ;;
        source-clone) target="$REPO_ROOT/cortado.sh" ;;
        other-config) target="$root/other config/cortado/cortado.sh" ;;
        # The same file by another spelling is still not the installer's link.
        relative) target="../../claude config/cortado/cortado.sh" ;;
        trailing-slash) target="$runtime/" ;;
    esac
    mkdir -p "$bin" && ln -s "$target" "$cmd" || exit 1
    before="$(ls -ld "$cmd" | awk '{print $1}') $(link_text "$cmd")"
    install --minimal
    check_kept "a link to the $other" "$before"
done

# A link with exactly the installer's target is its own, even while it dangles.
new_home
mkdir -p "$bin" && ln -s "$runtime" "$cmd" || exit 1
install --minimal
assert_contains 'a dangling link to this runtime is the installer'"'"'s own' "The cortado command is in place: $cmd" "$out"
assert_eq 'a dangling link to this runtime works once installed' "$VERSION_TEXT" \
    "$(CLAUDE_CONFIG_DIR="$cfg" "$cmd" version 2>&1)"

# --- a ~/.local/bin that cannot hold the command --------------------------------
for shape in dangling file; do
    new_home
    mkdir -p "$home/.local" || exit 1
    case "$shape" in
        dangling) ln -s "$root/nowhere" "$bin" || exit 1 ;;
        file) printf 'x\n' > "$bin" || exit 1 ;;
    esac
    install --minimal
    assert_eq "a $shape ~/.local/bin: the install completes" 0 "$install_status"
    assert_contains "a $shape ~/.local/bin: the installer says why there is no command" \
        "Could not create the cortado command: $bin is not a directory" "$out"
    assert_rc "a $shape ~/.local/bin: nothing is created there" 1 test -e "$root/nowhere"
done

# A directory that appears between the check and the link is left empty.
new_home
mkdir -p "$root/shim" "$bin" || exit 1
cat > "$root/shim/ln" <<SHIM
#!/bin/bash
# Play a cortado directory appearing just before the link is made.
case "\$*" in *"/.local/bin/cortado") mkdir -p "\${@: -1}" ;; esac
exec "$real_ln" "\$@"
SHIM
chmod 700 "$root/shim/ln" || exit 1
install --minimal "$root/shim:$BASE_PATH"
assert_eq 'a raced directory: the install completes' 0 "$install_status"
assert_eq 'a raced directory: nothing is left inside it' '' "$(ls -A "$cmd")"
assert_contains 'a raced directory: the installer says it left it' "Left $cmd as it is: it was not made by this installer" "$out"

# A raced directory that already held a link named cortado.sh keeps it: only a
# link this run made is ever cleaned up.
new_home
mkdir -p "$root/shim" "$bin" || exit 1
cat > "$root/shim/ln" <<SHIM
#!/bin/bash
case "\$*" in *"/.local/bin/cortado") mkdir -p "\${@: -1}" && "$real_ln" -s "\${@: -2:1}" "\${@: -1}/cortado.sh" ;; esac
exec "$real_ln" "\$@"
SHIM
chmod 700 "$root/shim/ln" || exit 1
install --minimal "$root/shim:$BASE_PATH"
assert_eq 'a raced directory with its own link: the install completes' 0 "$install_status"
assert_eq 'a raced directory with its own link: that link is kept' "$runtime" "$(link_text "$cmd/cortado.sh")"

# A link to a directory that appears just before the link is made is not followed.
new_home
mkdir -p "$root/shim" "$root/elsewhere" "$bin" || exit 1
cat > "$root/shim/ln" <<SHIM
#!/bin/bash
case "\$*" in *"/.local/bin/cortado") "$real_ln" -s "$root/elsewhere" "\${@: -1}" ;; esac
exec "$real_ln" "\$@"
SHIM
chmod 700 "$root/shim/ln" || exit 1
install --minimal "$root/shim:$BASE_PATH"
assert_eq 'a raced link to a directory: the install completes' 0 "$install_status"
assert_eq 'a raced link to a directory: nothing is created where it points' '' "$(ls -A "$root/elsewhere")"
assert_eq 'a raced link to a directory: it is left as it is' "$root/elsewhere" "$(link_text "$cmd")"

# A ~/.local that is a file: no command, and the install still completes.
new_home
printf 'x\n' > "$home/.local" || exit 1
install --minimal
assert_eq 'a file at ~/.local: the install completes' 0 "$install_status"
assert_contains 'a file at ~/.local: the installer says why there is no command' \
    "Could not create the cortado command: could not create $bin" "$out"

# A relative HOME names no fixed place, so no command is made under the working directory.
new_home
mkdir -p "$root/cwd" || exit 1
out=$(cd "$root/cwd" && HOME="rel home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" PATH="$BASE_PATH" \
    /bin/bash "$REPO_ROOT/install.sh" --minimal --skip-update-check --no-color --no-emoji 2>&1 < /dev/null)
install_status=$?
assert_eq 'a relative HOME: the install completes' 0 "$install_status"
assert_contains 'a relative HOME: the installer says why there is no command' \
    'Could not create the cortado command: HOME is not an absolute path' "$out"
assert_rc 'a relative HOME: nothing is created under the working directory' 1 test -e "$root/cwd/rel home/.local"

# A relative PATH entry is not ~/.local/bin, even run from inside it.
new_home
mkdir -p "$bin" || exit 1
out=$(cd "$bin" && HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" PATH=".:$BASE_PATH" \
    /bin/bash "$REPO_ROOT/install.sh" --minimal --skip-update-check --no-color --no-emoji 2>&1 < /dev/null)
assert_contains 'a relative PATH entry does not count as ~/.local/bin' "$bin is not on your PATH" "$out"

# A config directory reached through a link: the command names the real runtime,
# and uninstall through the same link still knows it.
new_home
mkdir -p "$root/real config" || exit 1
ln -s "$root/real config" "$cfg" || exit 1
install --minimal
assert_eq 'a linked config directory: the command names the physical runtime' \
    "$root/real config/cortado/cortado.sh" "$(link_text "$cmd")"
uninstall
assert_rc 'a linked config directory: uninstall removes the command' 1 test -L "$cmd"

# --- uninstall removes only its own command -----------------------------------
new_home
install --minimal
printf 'keep\n' > "$bin/other-tool"
uninstall
assert_eq 'uninstall completes' 0 "$uninstall_status"
assert_rc 'uninstall removes the command it created' 1 test -L "$cmd"
assert_contains 'uninstall says it removed the command' "Removed the cortado command: $cmd" "$out"
assert_eq 'uninstall keeps other files in ~/.local/bin' 'keep' "$(cat "$bin/other-tool")"
assert_rc 'uninstall keeps ~/.local/bin' 0 test -d "$bin"

# With a backup, options 1 and 2 remove it, and Cancel keeps it.
for answers in '1\nn\n' '2\n' '3\n'; do
    new_home
    mkdir -p "$cfg" || exit 1
    printf '%s\n' '{"statusLine":{"type":"command","command":"echo previous"}}' > "$cfg/settings.json"
    install --minimal
    assert_eq "install over a previous statusline links the command (${answers%%\\*})" "$runtime" "$(link_text "$cmd")"
    uninstall "$answers"
    case "$answers" in
        3*) assert_eq 'Cancel keeps the command' "$runtime" "$(link_text "$cmd")" ;;
        *) assert_rc "uninstall option ${answers%%\\*} removes the command" 1 test -L "$cmd" ;;
    esac
done

# Anything else at ~/.local/bin/cortado is left, and said so.
for shape in file other-link other-config; do
    new_home
    install --minimal
    rm -f "$cmd"
    case "$shape" in
        file) printf 'mine\n' > "$cmd" ;;
        other-link) ln -s /opt/other-tool/bin/cortado "$cmd" ;;
        other-config) ln -s "$root/other config/cortado/cortado.sh" "$cmd" ;;
    esac
    before="$(ls -ld "$cmd" | awk '{print $1}') $(link_text "$cmd")"
    uninstall
    assert_eq "uninstall keeps a $shape at ~/.local/bin/cortado" "$before" \
        "$(ls -ld "$cmd" | awk '{print $1}') $(link_text "$cmd")"
    assert_contains "uninstall says it left a $shape" "Left $cmd as it is: it was not made by this installer" "$out"
done

# No command at all: uninstall says nothing about one.
new_home
install --minimal
rm -f "$cmd"
uninstall
assert_eq 'uninstall with no command completes' 0 "$uninstall_status"
assert_not_contains 'uninstall with no command does not mention one' 'cortado command' "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
