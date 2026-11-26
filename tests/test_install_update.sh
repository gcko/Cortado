#!/bin/bash
# ABOUTME: Behavioral tests for installer update flag forwarding, parse_args,
# ABOUTME: version_lt, and Homebrew-prefix refusal. Grep counts are not enough.
# ABOUTME: Run with: bash tests/test_install_update.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT"
INSTALL="$SCRIPT_DIR/install.sh"
CLAUDE_CONFIG_DIR=$(mktemp -d)
export CLAUDE_CONFIG_DIR
export CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
trap 'rm -rf "$CLAUDE_CONFIG_DIR"' EXIT
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented

# Load installer functions without running main.
# shellcheck source=install.sh
. "$INSTALL"

# --- parse_args ---
USE_EMOJI="true"
USE_COLOR="true"
INSTALL_MODE="interactive"
SKIP_UPDATE_CHECK="false"
parse_args --update --no-emoji --no-color --skip-update-check
assert_eq "parse_args INSTALL_MODE=update" "update" "$INSTALL_MODE"
assert_eq "parse_args USE_EMOJI=false" "false" "$USE_EMOJI"
assert_eq "parse_args USE_COLOR=false" "false" "$USE_COLOR"
assert_eq "parse_args SKIP_UPDATE_CHECK=true" "true" "$SKIP_UPDATE_CHECK"

INSTALL_MODE="interactive"
parse_args --check-update
assert_eq "parse_args --check-update" "check-update" "$INSTALL_MODE"

# --- the generated config documents CACHE_MAX_AGE as cortado.conf does ---
# comment_above <key> <file>: the comment lines directly above <key>=.
comment_above() {
    awk -v key="$1=" '
        /^#/ { block = block $0 "\n"; next }
        index($0, key) == 1 { printf "%s", block; found = 1; exit }
        { block = "" }
        END { exit !found }
    ' "$2"
}
generated_conf="$CLAUDE_CONFIG_DIR/generated.conf"
generate_config "$generated_conf" || exit 1
shipped_comment=$(comment_above CACHE_MAX_AGE "$REPO_ROOT/cortado.conf") || exit 1
assert_contains "cortado.conf documents CACHE_MAX_AGE" "GIT_CACHE_TTL" "$shipped_comment"
assert_eq "the generated config documents CACHE_MAX_AGE as cortado.conf does" \
    "$shipped_comment" "$(comment_above CACHE_MAX_AGE "$generated_conf")"

# --- explicit update checks against a stubbed release API ---
mkdir -p "$CLAUDE_CONFIG_DIR/bin"
cat > "$CLAUDE_CONFIG_DIR/bin/curl" <<'STUB'
#!/bin/bash
if [ -n "${RELEASE_CALL_LOG:-}" ]; then
    printf 'call\n' >> "$RELEASE_CALL_LOG"
fi
printf '%s\n%s\n' "$RELEASE_BODY" "$RELEASE_HTTP"
exit "$RELEASE_CURL_STATUS"
STUB
chmod +x "$CLAUDE_CONFIG_DIR/bin/curl"

curl_calls="$CLAUDE_CONFIG_DIR/curl-calls"
run_update_check() {
    local flag="$1" http="$2" body="$3" curl_status="${4:-0}"
    : > "$curl_calls"
    update_output=$(printf 'n\n' |
        PATH="$CLAUDE_CONFIG_DIR/bin:$PATH" RELEASE_HTTP="$http" RELEASE_BODY="$body" \
        RELEASE_CURL_STATUS="$curl_status" RELEASE_CALL_LOG="$curl_calls" \
        /bin/bash "$INSTALL" "$flag" --no-color 2>&1)
    update_status=$?
}

assert_check_failed() {
    local desc="$1"
    shift
    run_update_check "$@"
    assert_eq "$desc exits 1" "1" "$update_status"
    assert_eq "$desc reports an indeterminate version" "Could not determine the latest version" \
        "$(printf '%s\n' "$update_output" | sed -n 's/^.*\(Could not determine the latest version\)$/\1/p')"
    assert_eq "$desc makes no version claim" "" \
        "$(printf '%s\n' "$update_output" | sed -nE '/You have the latest version|Already up to date|Update Available!|Latest version:/p')"
}

installed_version=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
installed_release="{\"tag_name\":\"v$installed_version\"}"
assert_check_failed "--check-update with HTTP 404" --check-update 404 '{"message":"Not Found"}'
assert_check_failed "--check-update with HTTP 404 carrying the installed tag" --check-update 404 "$installed_release"
assert_check_failed "--check with an empty body" --check 200 ''
assert_check_failed "--check-update with no tag" --check-update 200 '{}'
assert_check_failed "--check-update with a null tag" --check-update 200 '{"tag_name":null}'
assert_check_failed "--check-update with a zero tag" --check-update 200 '{"tag_name":0}'
assert_check_failed "--check-update with malformed JSON" --check-update 200 '{"tag_name":"v9.9.9"'
assert_check_failed "--check-update with two JSON documents" --check-update 200 "{} $installed_release"
assert_check_failed "--check-update with an escaped trailing newline in the tag" \
    --check-update 200 "{\"tag_name\":\"v$installed_version\\n\"}"
assert_check_failed "--check-update with an invalid tag" --check-update 200 '{"tag_name":"v9.9.9invalid"}'
assert_check_failed "--check-update when curl fails" --check-update 000 '' 28
assert_check_failed "--check-update when curl fails with partial output" \
    --check-update 200 '{"tag_name":"v9.9.9"}' 28

tagged_release='{"tag_name":"v9.9.9+fixture"}'
PATH="$CLAUDE_CONFIG_DIR/bin:$PATH" RELEASE_HTTP=200 RELEASE_BODY="$tagged_release" RELEASE_CURL_STATUS=0 \
    assert_rc "a same-shell release lookup succeeds" 0 check_remote_version
assert_eq "a successful lookup records the exact tag" "v9.9.9+fixture" "$REMOTE_TAG"
assert_eq "a successful lookup records the numeric version" "9.9.9" "$REMOTE_VERSION"
PATH="$CLAUDE_CONFIG_DIR/bin:$PATH" RELEASE_HTTP=200 RELEASE_BODY="$tagged_release" RELEASE_CURL_STATUS=28 \
    assert_rc "a subsequent transport failure fails the lookup" 1 check_remote_version
assert_empty "a failed lookup clears the previous tag" "$REMOTE_TAG"
assert_empty "a failed lookup clears the previous version" "$REMOTE_VERSION"

run_interactive_install() {
    local reply="$1" install_calls="$CLAUDE_CONFIG_DIR/install-calls"
    : > "$curl_calls"
    : > "$install_calls"
    update_output=$(printf '%s\n' "$reply" |
        PATH="$CLAUDE_CONFIG_DIR/bin:$PATH" RELEASE_HTTP=200 RELEASE_BODY="$tagged_release" \
        RELEASE_CURL_STATUS=28 RELEASE_CALL_LOG="$curl_calls" INSTALL_CALL_LOG="$install_calls" \
        /bin/bash -c '
            . "$1"
            do_install() { printf "%s\n" "$1" >> "$INSTALL_CALL_LOG"; }
            main --no-color --no-emoji
        ' -- "$INSTALL" 2>&1)
    update_status=$?
    install_modes=$(cat "$install_calls")
}

run_interactive_install n
assert_eq "skipping the optional check exits 0" 0 "$update_status"
assert_eq "skipping the optional check starts interactive installation once" interactive "$install_modes"
assert_empty "skipping the optional check makes no lookup" "$(cat "$curl_calls")"
run_interactive_install y
assert_eq "an unavailable optional check exits 0" 0 "$update_status"
assert_eq "an unavailable optional check starts interactive installation once" interactive "$install_modes"
assert_eq "an unavailable optional check makes one lookup" call "$(cat "$curl_calls")"
assert_contains "an unavailable optional check reports the failure" "Could not check for updates" "$update_output"

run_update_check --check-update 200 "$installed_release"
assert_eq "a successful current check exits 0" "0" "$update_status"
assert_eq "a successful current check reports the installed version" \
    "You have the latest version ($installed_version)" \
    "$(printf '%s\n' "$update_output" | sed -n 's/^.*\(You have the latest version.*\)$/\1/p')"

run_update_check --check-update 200 '{"tag_name":"v9.9.9"}'
assert_eq "a successful newer check exits 0 when declining the update" "0" "$update_status"
assert_eq "a successful newer check reports the available version" "9.9.9" \
    "$(printf '%s\n' "$update_output" | sed -n 's/^  Latest version:  //p')"

update_output=$(printf 'n\n' |
    PATH="$CLAUDE_CONFIG_DIR/bin:$PATH" RELEASE_HTTP=200 RELEASE_CURL_STATUS=0 \
    RELEASE_BODY='{"tag_name":"v9.9.9","body":"First paragraph.\r\nSecond paragraph."}' \
    /bin/bash -O xpg_echo "$INSTALL" --check-update --no-color 2>&1)
assert_eq "a valid release with escaped notes exits 0 under xpg_echo" "0" "$?"
assert_eq "a valid release with escaped notes reports the available version" "9.9.9" \
    "$(printf '%s\n' "$update_output" | sed -n 's/^  Latest version:  //p')"

mkdir -p "$CLAUDE_CONFIG_DIR/no-jq"
for tool in dirname cat tail sed tr; do
    ln -s "$(command -v "$tool")" "$CLAUDE_CONFIG_DIR/no-jq/$tool"
done
for flag in --check-update --update; do
    PATH="$CLAUDE_CONFIG_DIR/no-jq" run_update_check "$flag" 200 "$installed_release"
    assert_eq "$flag without jq exits 1" "1" "$update_status"
    assert_eq "$flag without jq names the missing dependency" "jq is required to check for Cortado updates" \
        "$(printf '%s\n' "$update_output" | sed -n 's/^.*\(jq is required.*\)$/\1/p')"
    assert_eq "$flag without jq makes no version claim" "" \
        "$(printf '%s\n' "$update_output" | sed -nE '/You have the latest version|Already up to date|Update Available!|Latest version:/p')"
done

assert_update_failed() {
    local desc="$1"
    shift
    assert_check_failed "$desc" --update "$@"
    assert_eq "$desc only calls the release API" '1' "$(awk 'END {print NR}' "$curl_calls")"
}

update_source="$CLAUDE_CONFIG_DIR/update-source"
mkdir -p "$update_source" "$CORTADO_DIR"
cp -R "$INSTALL" "$REPO_ROOT/VERSION" "$REPO_ROOT/lib" "$update_source/"
printf '%s\n' 'installed fixture' > "$CORTADO_DIR/cortado.sh"
cp -R "$update_source" "$update_source.before"
cp -R "$CORTADO_DIR" "$CORTADO_DIR.before"
INSTALL="$update_source/install.sh" assert_update_failed "--update with HTTP 404" 404 "$installed_release"
INSTALL="$update_source/install.sh" assert_update_failed "--update with an empty body" 200 ''
INSTALL="$update_source/install.sh" assert_update_failed "--update with malformed JSON" 200 '{"tag_name":"v9.9.9"'
INSTALL="$update_source/install.sh" assert_update_failed "--update with two JSON documents" 200 '{} {"tag_name":"v9.9.9"}'
INSTALL="$update_source/install.sh" assert_update_failed "--update when curl fails with partial output" \
    200 '{"tag_name":"v9.9.9"}' 28
assert_rc "failed explicit updates leave source files intact" 0 diff -rq "$update_source.before" "$update_source"
assert_rc "failed explicit updates leave installed files intact" 0 diff -rq "$CORTADO_DIR.before" "$CORTADO_DIR"

# An installer that cannot load its libraries must not claim to be current.
# Each library the installer loads is removed alone, so no later stop can stand
# in for the one under test.
partial_source="$CLAUDE_CONFIG_DIR/partial-source"
mkdir -p "$partial_source"
cp "$INSTALL" "$REPO_ROOT/VERSION" "$partial_source/"

# source_partial: source the partial installer in a fresh Bash; prints its output
# and "after rc=N" when the source returns instead of exiting the shell.
source_partial() {
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" /bin/bash -c '. "$1"; echo "after rc=$?"' _ \
        "$partial_source/install.sh" 2>&1
}

for missing in semver.sh config-permissions.sh config-data.sh module-registry.sh; do
    rm -rf "${partial_source:?}/lib"
    mkdir "$partial_source/lib"
    cp "$REPO_ROOT/lib/"*.sh "$partial_source/lib/"
    rm "$partial_source/lib/$missing"
    for flag in --check-update --update; do
        INSTALL="$partial_source/install.sh" run_update_check "$flag" 200 '{"tag_name":"v9.9.9"}'
        assert_eq "$flag without lib/$missing exits 1" 1 "$update_status"
        assert_contains "$flag without lib/$missing names the missing library" \
            "cannot load $partial_source/lib/$missing" "$update_output"
        assert_eq "$flag without lib/$missing makes no version claim" "" \
            "$(printf '%s\n' "$update_output" | sed -nE '/You have the latest version|Already up to date|Update Available!|Latest version:/p')"
        assert_empty "$flag without lib/$missing makes no release lookup" "$(cat "$curl_calls")"
    done
    partial_output=$(source_partial)
    assert_contains "sourcing without lib/$missing returns 1 instead of exiting" "after rc=1" "$partial_output"
    assert_contains "sourcing without lib/$missing names the missing library" \
        "cannot load $partial_source/lib/$missing" "$partial_output"
    partial_output=$(printf 'n\n' | PATH="$CLAUDE_CONFIG_DIR/bin:$PATH" POSIXLY_CORRECT=1 \
        /bin/bash "$partial_source/install.sh" --check-update --no-color 2>&1)
    assert_contains "a POSIX-mode run without lib/$missing prints the installer's message" \
        "cannot load $partial_source/lib/$missing" "$partial_output"
    assert_not_contains "a POSIX-mode run without lib/$missing prints no raw shell error" \
        "No such file" "$partial_output"
done

run_update_check --update 200 "$installed_release"
assert_eq "an explicit update with a confirmed current release exits 0" "0" "$update_status"
assert_eq "an explicit update reports when the release is confirmed current" "Already up to date ($installed_version)" \
    "$(printf '%s\n' "$update_output" | sed -n 's/^.*\(Already up to date.*\)$/\1/p')"

# --- version_lt (numeric + prerelease sanitizing) ---
assert_rc "version_lt 1.9.0 < 1.10.0" 0 version_lt "1.9.0" "1.10.0"
assert_rc "version_lt 1.10.0 not < 1.9.0" 1 version_lt "1.10.0" "1.9.0"
assert_rc "version_lt equal is not less" 1 version_lt "1.8.0" "1.8.0"
assert_rc "version_lt 1.7.9 < 1.8.0-rc1 (numeric)" 0 version_lt "1.7.9" "1.8.0-rc1"
assert_rc "version_lt 1.8.0-rc1 not < 1.8.0" 1 version_lt "1.8.0-rc1" "1.8.0"
assert_rc "version_lt 2.0.0 not < 1.9.9" 1 version_lt "2.0.0" "1.9.9"
assert_rc "version_lt 1.0.9 < 1.0.10" 0 version_lt "1.0.9" "1.0.10"

# --- brew prefix detection ---
assert_rc "Cellar path is Homebrew" 0 _is_homebrew_prefix "/opt/homebrew/Cellar/cortado/1.8.0/libexec"
assert_rc "opt/cortado is Homebrew" 0 _is_homebrew_prefix "/opt/homebrew/opt/cortado"
assert_rc "opt/cortado/libexec is Homebrew" 0 _is_homebrew_prefix "/usr/local/opt/cortado/libexec"
assert_rc "git clone is not Homebrew" 1 _is_homebrew_prefix "/Users/me/src/Cortado"

# --- do_update refuses Homebrew and does not re-exec ---
REEXEC_LOG=""
# shellcheck disable=SC2329 # The sourced installer calls this mock if the guard fails.
_reexec_installer() {
    REEXEC_LOG="called:$*"
}

USE_COLOR="false"
setup_colors
SCRIPT_DIR="/opt/homebrew/opt/cortado/libexec"
REMOTE_VERSION="1.9.0"
assert_rc "do_update refuses Homebrew prefix" 1 do_update --update --no-emoji
assert_eq "do_update brew path does not re-exec" "" "$REEXEC_LOG"

# --- do_update git path forwards original argv through _reexec_installer ---
SCRIPT_DIR="$REPO_ROOT"
FAKE_ROOT=$(mktemp -d)
mkdir -p "$FAKE_ROOT/.git"
SCRIPT_DIR="$FAKE_ROOT"
REMOTE_VERSION="9.9.9"
REMOTE_TAG="v$REMOTE_VERSION"
REEXEC_ARGS=""
GIT_CHECKOUT=""
_reexec_installer() {
    REEXEC_ARGS=$(printf '%s\n' "$@")
}
_cortado_git() {
    if [ "$1" = checkout ]; then
        GIT_CHECKOUT="$*"
    fi
    return 0
}
do_update --update --no-emoji --no-color
assert_eq "do_update re-exec first arg --update" "--update" "$(printf '%s\n' "$REEXEC_ARGS" | sed -n '1p')"
assert_eq "do_update re-exec keeps --no-emoji" "--no-emoji" "$(printf '%s\n' "$REEXEC_ARGS" | sed -n '2p')"
assert_eq "do_update re-exec keeps --no-color" "--no-color" "$(printf '%s\n' "$REEXEC_ARGS" | sed -n '3p')"

# Dropping "$@" at the do_update call site must fail this test.
REEXEC_ARGS=""
do_update
assert_eq "bare do_update re-exec has empty argv" "" "$REEXEC_ARGS"

REMOTE_TAG=""
REMOTE_VERSION=""
GIT_CHECKOUT=""
REEXEC_ARGS=""
: > "$curl_calls"
PATH="$CLAUDE_CONFIG_DIR/bin:$PATH" RELEASE_HTTP=200 RELEASE_BODY="$tagged_release" \
    RELEASE_CURL_STATUS=0 RELEASE_CALL_LOG="$curl_calls" \
    assert_rc "do_update without a resolved tag succeeds after lookup" 0 do_update --update
assert_eq "do_update without a resolved tag looks up the release once" call "$(cat "$curl_calls")"
assert_eq "do_update checks out the exact resolved tag" 'checkout -q v9.9.9+fixture' "$GIT_CHECKOUT"
assert_eq "do_update restarts after checking out the resolved tag" --update "$REEXEC_ARGS"

REMOTE_TAG=""
REMOTE_VERSION=""
GIT_CHECKOUT=""
REEXEC_ARGS=""
: > "$curl_calls"
PATH="$CLAUDE_CONFIG_DIR/bin:$PATH" RELEASE_HTTP=200 RELEASE_BODY="$tagged_release" \
    RELEASE_CURL_STATUS=28 RELEASE_CALL_LOG="$curl_calls" \
    assert_rc "do_update without a resolved tag fails after lookup failure" 1 do_update --update
assert_eq "do_update with a failed lookup makes one lookup" call "$(cat "$curl_calls")"
assert_empty "do_update with a failed lookup never checks out a tag" "$GIT_CHECKOUT"
assert_empty "do_update with a failed lookup never restarts" "$REEXEC_ARGS"

cd "$REPO_ROOT" || exit 1
rm -f "$FAKE_ROOT/.git" 2>/dev/null
rmdir "$FAKE_ROOT/.git" 2>/dev/null
rmdir "$FAKE_ROOT" 2>/dev/null

# --- copy_runtime_files ships lib/config-tui.sh (from-source install) ---
COPY_DEST=$(mktemp -d)
assert_rc "copy_runtime_files succeeds" 0 copy_runtime_files "$REPO_ROOT" "$COPY_DEST"
if [ -f "$COPY_DEST/lib/config-tui.sh" ]; then
    echo "  PASS: copy_runtime_files installs config-tui.sh"
    PASS=$((PASS + 1))
else
    echo "  FAIL: copy_runtime_files missing lib/config-tui.sh"
    FAIL=$((FAIL + 1))
fi
if [ -x "$COPY_DEST/cortado.sh" ]; then
    echo "  PASS: copy_runtime_files installs cortado.sh"
    PASS=$((PASS + 1))
else
    echo "  FAIL: copy_runtime_files missing cortado.sh"
    FAIL=$((FAIL + 1))
fi
rm -f "$COPY_DEST/cortado.sh" "$COPY_DEST/VERSION" "$COPY_DEST/lib/"*.sh "$COPY_DEST/modules/"*.sh
rmdir "$COPY_DEST/lib" "$COPY_DEST/modules" "$COPY_DEST" 2>/dev/null

incomplete_source=$(mktemp -d "$CLAUDE_CONFIG_DIR/incomplete.XXXXXX") || exit 1
mkdir "$incomplete_source/lib"
cp "$REPO_ROOT/cortado.sh" "$incomplete_source/"
ln -s "$REPO_ROOT/modules" "$incomplete_source/modules"
for missing in config-tui.sh config-permissions.sh; do
    rm -f "$incomplete_source/lib/"*.sh
    for helper in config-tui.sh config-permissions.sh; do
        if [ "$helper" != "$missing" ]; then
            cp "$REPO_ROOT/lib/$helper" "$incomplete_source/lib/"
        fi
    done
    assert_rc "runtime copy fails if $missing is missing" 1 \
        copy_runtime_files "$incomplete_source" "$incomplete_source/dest"
    assert_rc "runtime copy leaves no installed script when $missing is missing" \
        1 test -e "$incomplete_source/dest/cortado.sh"
done

# --- update transactions hand the caller's traps back ---
trap_dir=$(mktemp -d "$CLAUDE_CONFIG_DIR/traps.XXXXXX")
trap_output=$(/bin/bash -c '
    . "$1"
    trap "echo caller-exit" EXIT
    _update_begin
    _update_end
    trap -p EXIT
' -- "$INSTALL")
assert_contains "a finished update restores the caller's EXIT trap" "trap -- 'echo caller-exit' EXIT" "$trap_output"
trap_output=$(/bin/bash -c '
    . "$1"
    trap "echo caller-exit" EXIT
    _update_begin
    _update_mktemp_dir _UPD_TMP "$2/cortado-update.XXXXXX"
    : > "$_UPD_TMP/partial"
    kill -TERM $$
    echo not-reached
' -- "$INSTALL" "$trap_dir")
trap_status=$?
assert_eq "TERM inside an update exits with the signal status" 143 "$trap_status"
assert_eq "TERM inside an update runs the caller's EXIT trap once" caller-exit "$trap_output"
assert_empty "TERM inside an update removes its staging" "$(ls -A "$trap_dir")"

# --- --update publishes the managed runtime from the exact release (real Git) ---
# do_update above left the shell in a removed directory; Git needs a real cwd.
cd "$CLAUDE_CONFIG_DIR" || exit 1
fixture_git() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=Fixture \
        -c user.email=fixture@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false \
        -c core.hooksPath=/dev/null "$@"
}

# git_release_case <name>: a Git source tagged v2.0.0 with a bare origin, and a
# managed 1.0.0 runtime named by settings.json. Sets src, cfg, active, launcher.
git_release_case() {
    local root="$CLAUDE_CONFIG_DIR/git-cases/$1"
    src="$root/source"
    mkdir -p "$src/modules" "$src/lib" || exit 1
    # A real source tree: the installer loads its libraries from lib/.
    cp "$REPO_ROOT/install.sh" "$src/"
    cp "$REPO_ROOT/lib/"*.sh "$src/lib/"
    cat > "$src/cortado.sh" <<'RENDER'
#!/bin/bash
runtime=$(dirname "$0")
. "$runtime/lib/config-tui.sh"
for module in "$runtime"/modules/*.sh; do . "$module"; done
show_current_reading
RENDER
    chmod 755 "$src/cortado.sh"
    printf '%s\n' '# release module' > "$src/modules/model.sh"
    printf '%s\n' 'show_current_reading() { echo released; }' > "$src/lib/config-tui.sh"
    printf '2.0.0\n' > "$src/VERSION"
    fixture_git -C "$src" init -q --template= || exit 1
    if [ "${2:-}" = retired ]; then
        # 1.0.0 shipped a module that 2.0.0 removes; the source stays at 1.0.0.
        printf '%s\n' 'show_current_reading() { echo retired; }' > "$src/modules/zz-retired.sh"
        printf '1.0.0\n' > "$src/VERSION"
        fixture_git -C "$src" add -A && fixture_git -C "$src" commit -qm old || exit 1
        fixture_git -C "$src" rm -q modules/zz-retired.sh || exit 1
        printf '2.0.0\n' > "$src/VERSION"
    fi
    fixture_git -C "$src" add -A &&
        fixture_git -C "$src" commit -qm release &&
        fixture_git -C "$src" tag v2.0.0 &&
        fixture_git clone -q --bare "$src" "$root/origin.git" &&
        fixture_git -C "$src" remote add origin "$root/origin.git" || exit 1

    managed_runtime "$root"
    if [ "${2:-}" = retired ]; then
        fixture_git -C "$src" checkout -q --detach HEAD~1 || exit 1
        cp "$src/cortado.sh" "$active/cortado.sh"
        cp "$src/modules/zz-retired.sh" "$active/modules/"
    fi
}

# managed_runtime <root>: a managed 1.0.0 runtime at <root>/config/cortado with a
# generated config, named by settings.json. Sets cfg, active, launcher, case_bin.
managed_runtime() {
    local root="$1"
    cfg="$root/config"
    active="$cfg/cortado"
    case_bin="$root/bin"
    mkdir -p "$active/modules" "$active/lib" "$case_bin" || exit 1
    printf '#!/bin/bash\necho installed\n' > "$active/cortado.sh"
    chmod 755 "$active/cortado.sh"
    printf '%s\n' '# old module' > "$active/modules/model.sh"
    printf '%s\n' '# old library' > "$active/lib/config-tui.sh"
    printf '1.0.0\n' > "$active/VERSION"
    printf '%s\n' 'custom generated config' > "$active/cortado.conf"
    chmod 600 "$active/cortado.conf"
    # shellcheck disable=SC2016 # $path is a jq variable.
    jq -n --arg path "$active/cortado.sh" '{statusLine:{type:"command",command:($path|@sh)},padding:7}' \
        > "$cfg/settings.json"
    chmod 600 "$cfg/settings.json"
    launcher=$(jq -r '.statusLine.command' "$cfg/settings.json")
    cp "$cfg/settings.json" "$root/settings.before"
    cp "$active/cortado.conf" "$root/conf.before"
}

stub_bin="$CLAUDE_CONFIG_DIR/bin"
# Stubs signal the installer through INSTALLER_PID.
update_launcher=(/bin/bash -c 'export INSTALLER_PID=$$; exec /bin/bash "$@"' --)
run_git_update() {
    git_update_output=$(PATH="$case_bin:$stub_bin:$PATH" CLAUDE_CONFIG_DIR="$cfg" \
        CACHE_DIR="$cfg/cortado-cache" RELEASE_HTTP=200 RELEASE_BODY='{"tag_name":"v2.0.0"}' \
        RELEASE_CURL_STATUS=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "${update_launcher[@]}" "$src/install.sh" --update --no-color --no-emoji 2>&1)
    git_update_status=$?
    active_output=$(printf '{}\n' | /bin/sh -c "$launcher" 2>/dev/null)
    active_status=$?
}

git_release_case dev-commit
printf '%s\n' 'show_current_reading() { echo unreleased; }' > "$src/lib/config-tui.sh"
fixture_git -C "$src" commit -qam development || exit 1
run_git_update
assert_eq "--update from a development commit after the tag exits 0" 0 "$git_update_status"
assert_eq "--update from a development commit publishes the tagged bytes" released "$active_output"
assert_eq "--update from a development commit installs the tag's VERSION" 2.0.0 "$(cat "$active/VERSION")"
assert_rc "--update from a development commit keeps settings byte-identical" 0 \
    cmp "${cfg%/config}/settings.before" "$cfg/settings.json"
assert_rc "--update from a development commit keeps the generated config" 0 \
    cmp "${cfg%/config}/conf.before" "$active/cortado.conf"

git_release_case lib-copy-error
cat > "$case_bin/cp" <<'STUB'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in */source/lib|*/source/lib/*|*/Cortado-2.0.0/lib|*/Cortado-2.0.0/lib/*) exit 1 ;; esac
done
exec /bin/cp "$@"
STUB
chmod 755 "$case_bin/cp"
run_git_update
rm -f "$case_bin/cp"
assert_eq "a failed library copy fails the update" 1 "$git_update_status"
assert_eq "a failed library copy leaves the saved command working" 0 "$active_status"
assert_eq "a failed library copy leaves the old output" installed "$active_output"
assert_eq "a failed library copy leaves the old VERSION" 1.0.0 "$(cat "$active/VERSION")"
assert_rc "a failed library copy keeps settings byte-identical" 0 \
    cmp "${cfg%/config}/settings.before" "$cfg/settings.json"
assert_rc "a failed library copy keeps the generated config" 0 \
    cmp "${cfg%/config}/conf.before" "$active/cortado.conf"
assert_empty "a failed library copy leaves no runtime staging" \
    "$(find "$cfg" -maxdepth 1 -name '.cortado-runtime.*')"

git_release_case retired-module retired
assert_eq "the retired-module fixture starts on the retired module" retired \
    "$(printf '{}\n' | /bin/sh -c "$launcher" 2>/dev/null)"
run_git_update
assert_eq "a Git update that retires a module exits 0" 0 "$git_update_status"
assert_eq "a Git update removes the retired module from the runtime" "" \
    "$(ls "$active/modules/zz-retired.sh" 2>/dev/null)"
assert_eq "a Git update renders the tagged release" \
    "$(printf '{}\n' | /bin/bash "$src/cortado.sh")" "$active_output"
assert_eq "a Git update that retires a module advances VERSION" 2.0.0 "$(cat "$active/VERSION")"
assert_rc "a Git update that retires a module keeps the generated config" 0 \
    cmp "${cfg%/config}/conf.before" "$active/cortado.conf"
assert_rc "a Git update that retires a module keeps settings byte-identical" 0 \
    cmp "${cfg%/config}/settings.before" "$cfg/settings.json"

git_release_case missing-entry-point
rm "$active/cortado.sh"
run_git_update
assert_eq "--update over a missing managed entry point exits 0" 0 "$git_update_status"
assert_not_contains "--update over a missing managed entry point never claims it is current" \
    'Already up to date' "$(printf '%s\n' "$git_update_output" | grep -v Refreshed)"
assert_eq "--update restores a working managed command" 0 "$active_status"
assert_eq "--update restores the released entry point" released "$active_output"
assert_eq "--update over a missing entry point installs the release VERSION" 2.0.0 "$(cat "$active/VERSION")"
assert_rc "--update over a missing entry point keeps settings byte-identical" 0 \
    cmp "${cfg%/config}/settings.before" "$cfg/settings.json"

git_release_case custom-command
printf '%s\n' '{"statusLine":{"type":"command","command":"my-own-statusline"}}' > "$cfg/settings.json"
cp "$cfg/settings.json" "${cfg%/config}/settings.before"
rm "$active/cortado.sh"
run_git_update
assert_eq "--update with a custom statusLine command exits 0" 0 "$git_update_status"
assert_eq "--update leaves a runtime that a custom command does not use" "" "$(ls "$active/cortado.sh" 2>/dev/null)"
assert_eq "--update leaves that runtime's VERSION" 1.0.0 "$(cat "$active/VERSION")"
assert_rc "--update keeps a custom command byte-identical" 0 \
    cmp "${cfg%/config}/settings.before" "$cfg/settings.json"

# --- the runtime swap: what it refuses, and that the old runtime is never lost ---
git_release_case swap-source
swap_src="$src"
export REAL_MKTEMP
REAL_MKTEMP=$(command -v mktemp)

# swap_case <name>: a fresh managed 1.0.0 runtime updated from the shared v2.0.0 source.
swap_case() {
    src="$swap_src"
    managed_runtime "$CLAUDE_CONFIG_DIR/git-cases/swap-$1"
}

# mv_stub <body>: run <body> before the real mv; $last is the destination.
mv_stub() {
    { printf '#!/bin/bash\nfor last in "$@"; do :; done\n'
      printf '%s\n' "$1"
      printf 'exec /bin/mv "$@"\n'; } > "$case_bin/mv"
    chmod 755 "$case_bin/mv"
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

swap_leaks() {
    find "$1" -maxdepth 1 -name '.cortado-*'
}

# assert_old_runtime <desc>: the 1.0.0 runtime still answers, with its config.
assert_old_runtime() {
    assert_eq "$1 keeps the old command output" installed "$active_output"
    assert_eq "$1 keeps the old VERSION" 1.0.0 "$(cat "$active/VERSION" 2>/dev/null)"
    assert_rc "$1 keeps cortado.conf byte-identical" 0 cmp "${cfg%/config}/conf.before" "$active/cortado.conf"
    assert_empty "$1 leaves no swap directories" "$(swap_leaks "$cfg")"
}

# assert_new_runtime <desc>: the release runtime answers, with the carried config.
assert_new_runtime() {
    assert_eq "$1 exits 0" 0 "$git_update_status"
    assert_eq "$1 renders the release" released "$active_output"
    assert_eq "$1 installs the release VERSION" 2.0.0 "$(cat "$active/VERSION" 2>/dev/null)"
    assert_empty "$1 leaves no swap directories" "$(swap_leaks "$cfg")"
}

swap_case dev-symlink
dev="${cfg%/config}/dev"
mv "$active" "$dev"
printf '%s\n' '# uncommitted work' > "$dev/modules/wip.sh"
printf '%s\n' '# uncommitted library' > "$dev/lib/wip-lib.sh"
printf '%s\n' 'echo local edit' >> "$dev/cortado.sh"
cp -pR "$dev" "$dev.before"
ln -s "$dev" "$active"
run_git_update
assert_eq "a symlinked runtime is refused" 1 "$git_update_status"
assert_contains "a symlinked runtime is named as a symbolic link" "$active is a symbolic link" "$git_update_output"
assert_rc "a symlinked runtime leaves the linked checkout untouched" 0 diff -r "$dev.before" "$dev"
assert_rc "a symlinked runtime keeps the link" 0 test -L "$active"
assert_empty "a symlinked runtime stages nothing in the config directory" "$(swap_leaks "$cfg")"
assert_empty "a symlinked runtime stages nothing beside the link target" "$(swap_leaks "${cfg%/config}")"

swap_case regular-file
rm -rf "$active"
printf '%s\n' 'not a runtime, user data' > "$active"
cp "$active" "${cfg%/config}/file.before"
run_git_update
assert_eq "a regular file at the runtime path is refused" 1 "$git_update_status"
assert_contains "a regular file at the runtime path is named" "$active is not a directory" "$git_update_output"
assert_rc "a regular file at the runtime path stays byte-identical" 0 cmp "${cfg%/config}/file.before" "$active"
assert_empty "a regular file at the runtime path stages nothing" "$(swap_leaks "$cfg")"

swap_case dangling-link
rm -rf "$active"
ln -s "${cfg%/config}/missing-runtime" "$active"
run_git_update
assert_eq "a dangling runtime link is refused" 1 "$git_update_status"
assert_contains "a dangling runtime link is named as a symbolic link" "$active is a symbolic link" "$git_update_output"
assert_empty "a dangling runtime link prints no raw mv error" "$(printf '%s\n' "$git_update_output" | grep '^mv:')"
assert_eq "a dangling runtime link is left unchanged" "${cfg%/config}/missing-runtime" "$(readlink "$active")"
assert_empty "a dangling runtime link stages nothing" "$(swap_leaks "$cfg")"

swap_case config-dir-link
mv "$cfg" "${cfg%/config}/real-config"
ln -s "${cfg%/config}/real-config" "$cfg"
run_git_update
assert_new_runtime "a symlinked CLAUDE_CONFIG_DIR"
assert_rc "a symlinked CLAUDE_CONFIG_DIR keeps the generated config" 0 \
    cmp "${cfg%/config}/conf.before" "$active/cortado.conf"
assert_empty "a symlinked CLAUDE_CONFIG_DIR leaves nothing in the real directory" \
    "$(swap_leaks "${cfg%/config}/real-config")"

swap_case link-to-source
rm -rf "$active"
ln -s "$src" "$active"
printf '%s\n' 'scratch' > "$src/untracked-note.txt"
run_git_update
assert_eq "a runtime linked to the source clone is skipped" 0 "$git_update_status"
assert_eq "a runtime linked to the source clone keeps untracked files" scratch "$(cat "$src/untracked-note.txt" 2>/dev/null)"
assert_rc "a runtime linked to the source clone keeps the link" 0 test -L "$active"
assert_empty "a runtime linked to the source clone stages nothing" "$(swap_leaks "$cfg")"
rm -f "$src/untracked-note.txt"

swap_case link-to-homebrew
brew_runtime="${cfg%/config}/homebrew/opt/cortado"
mkdir -p "${brew_runtime%/cortado}"
mv "$active" "$brew_runtime"
cp -pR "$brew_runtime" "$brew_runtime.before"
ln -s "$brew_runtime" "$active"
run_git_update
assert_eq "a runtime linked to a Homebrew prefix is skipped" 0 "$git_update_status"
assert_rc "a runtime linked to a Homebrew prefix is left to Homebrew" 0 diff -r "$brew_runtime.before" "$brew_runtime"
assert_empty "a runtime linked to a Homebrew prefix stages nothing" "$(swap_leaks "$cfg")"

swap_case source-at-runtime
rm -rf "$active"
if ! { fixture_git clone -q "${swap_src%/source}/origin.git" "$active" &&
    fixture_git -C "$active" checkout -q v2.0.0; }; then
    exit 1
fi
# Uncommitted work, including a deleted library, so the runtime looks incomplete.
printf '%s\n' 'echo local edit' >> "$active/cortado.sh"
rm "$active/lib/config-tui.sh"
src="$active"
run_git_update
src="$swap_src"
assert_eq "a source clone at the runtime path is skipped" 0 "$git_update_status"
assert_file_contains "a source clone at the runtime path keeps its local edit" 'local edit' "$active/cortado.sh"
assert_eq "a source clone at the runtime path keeps its uncommitted deletion" "" \
    "$(ls "$active/lib/config-tui.sh" 2>/dev/null)"
assert_rc "a source clone at the runtime path keeps its Git directory" 0 test -d "$active/.git"
assert_empty "a source clone at the runtime path stages nothing" "$(swap_leaks "$cfg")"

# _publish_managed_runtime re-checks the path itself before staging anything.
swap_case publish-guard
publish_target="${cfg%/config}/linked-runtime"
mv "$active" "$publish_target"
ln -s "$publish_target" "$active"
cp -pR "$publish_target" "$publish_target.before"
assert_rc "publishing over a symlinked runtime is refused" 1 _publish_managed_runtime "$swap_src" "$active" 2.0.0
assert_rc "publishing over a symlinked runtime keeps the link" 0 test -L "$active"
assert_rc "publishing over a symlinked runtime leaves its target untouched" 0 \
    diff -r "$publish_target.before" "$publish_target"
rm "$active"
printf '%s\n' 'user data' > "$active"
assert_rc "publishing over a regular file is refused" 1 _publish_managed_runtime "$swap_src" "$active" 2.0.0
assert_eq "publishing over a regular file leaves it byte-identical" 'user data' "$(cat "$active")"
assert_empty "a refused publish stages nothing" "$(swap_leaks "$cfg")"

for interruption in TERM:143 INT:130 HUP:129; do
    sig="${interruption%%:*}"
    swap_case "between-$sig"
    mv_stub "case \"\$last\" in */.cortado-previous.*/runtime) /bin/mv \"\$@\" || exit \$?; kill -$sig \"\$INSTALLER_PID\"; exit 0 ;; esac"
    if [ "$sig" = HUP ]; then
        # Bash cannot trap a HUP it inherited as ignored; reset it before the installer starts.
        update_launcher=(/bin/bash -c 'trap "" HUP; exec "$@"' -- python3 -c '
import os, signal, sys
signal.signal(signal.SIGHUP, signal.SIG_DFL)
os.environ["INSTALLER_PID"] = str(os.getpid())
os.execv(sys.argv[1], sys.argv[1:])
' /bin/bash)
    fi
    run_git_update
    update_launcher=(/bin/bash -c 'export INSTALLER_PID=$$; exec /bin/bash "$@"' --)
    assert_eq "$sig between the renames exits ${interruption#*:}" "${interruption#*:}" "$git_update_status"
    assert_old_runtime "$sig between the renames"
done

swap_case publish-fails
# shellcheck disable=SC2016 # The stub body expands when the stub runs.
mv_stub 'case "$2" in */.cortado-runtime.*) echo "simulated publish failure" >&2; exit 1 ;; esac'
run_git_update
assert_eq "a failed publish rename fails the update" 1 "$git_update_status"
assert_old_runtime "a failed publish rename"

swap_case move-aside-fails
# shellcheck disable=SC2016 # The stub body expands when the stub runs.
mv_stub 'case "$last" in */.cortado-previous.*/runtime) echo "simulated move failure" >&2; exit 1 ;; esac'
run_git_update
assert_eq "a failed move-aside fails the update" 1 "$git_update_status"
assert_contains "a failed move-aside explains the failure" "Could not move the current runtime" "$git_update_output"
assert_old_runtime "a failed move-aside"

swap_case restore-fails
# shellcheck disable=SC2016 # The stub body expands when the stub runs.
mv_stub 'case "$2" in */.cortado-runtime.*|*/.cortado-previous.*/runtime) echo "simulated rename failure" >&2; exit 1 ;; esac'
run_git_update
kept=$(find "$cfg" -maxdepth 1 -name '.cortado-previous.*')
assert_eq "a failed publish and restore fails the update" 1 "$git_update_status"
assert_rc "a failed publish and restore keeps the old cortado.conf byte-identical" 0 \
    cmp "${cfg%/config}/conf.before" "$kept/runtime/cortado.conf"
assert_contains "a failed publish and restore names the kept runtime" "${kept##*/}/runtime" "$git_update_output"
assert_empty "a failed publish and restore removes the staged runtime" "$(find "$cfg" -maxdepth 1 -name '.cortado-runtime.*')"

swap_case cross-device
# A mount-point runtime: mv copies the tree, empties the source, then cannot remove it.
# shellcheck disable=SC2016 # The stub body expands when the stub runs.
mv_stub 'case "$last" in */.cortado-previous.*/runtime)
    /bin/cp -pR "$2" "$last" && /bin/rm -rf "$2"/* "$2"/.[!.]* 2>/dev/null
    echo "mv: cannot remove $2: Resource busy" >&2; exit 1 ;; esac'
run_git_update
kept=$(find "$cfg" -name cortado.conf -path '*/.cortado-previous.*')
assert_eq "a cross-device move-aside fails the update" 1 "$git_update_status"
assert_rc "a cross-device move-aside keeps the old cortado.conf byte-identical" 0 \
    cmp "${cfg%/config}/conf.before" "$kept"
kept="${kept%/runtime/cortado.conf}"
assert_contains "a cross-device move-aside names the kept runtime" "${kept##*/}/runtime" "$git_update_output"

swap_case success-shape
chmod 775 "$active"
printf '%s\n' 'user notes' > "$active/notes.txt"
chmod 664 "$active/notes.txt"
run_git_update
assert_new_runtime "a successful refresh"
assert_rc "a successful refresh carries the generated config" 0 cmp "${cfg%/config}/conf.before" "$active/cortado.conf"
assert_eq "a successful refresh leaves exactly the release and the user's files" \
    "VERSION cortado.conf cortado.sh lib modules notes.txt" "$(LC_ALL=C ls -A "$active" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "a successful refresh drops group write from a 0775 runtime" 755 "$(file_mode "$active")"
assert_eq "a successful refresh drops group write from a carried 0664 file" 644 "$(file_mode "$active/notes.txt")"

swap_case private-runtime
chmod 700 "$active"
run_git_update
assert_new_runtime "a refresh of a 0700 runtime"
assert_eq "a refresh keeps a 0700 runtime private" 700 "$(file_mode "$active")"

swap_case absent-runtime
rm -rf "$active"
run_git_update
assert_new_runtime "a refresh of a removed runtime directory"

swap_case carry-fails
cat > "$case_bin/cp" <<'STUB'
#!/bin/bash
for last in "$@"; do :; done
case "$2:$last" in */cortado.conf:*/.cortado-runtime.*) echo "simulated carry failure" >&2; exit 1 ;; esac
exec /bin/cp "$@"
STUB
chmod 755 "$case_bin/cp"
run_git_update
assert_eq "a failed carry-over fails the update" 1 "$git_update_status"
assert_contains "a failed carry-over names the file" "Could not carry cortado.conf" "$git_update_output"
assert_old_runtime "a failed carry-over"

swap_case current-without-entry-point
printf '2.0.0\n' > "$active/VERSION"
rm "$active/cortado.sh"
run_git_update
assert_new_runtime "a current VERSION without cortado.sh"

# current_runtime: the swap runtime already holds every file the release ships.
current_runtime() {
    cp "$swap_src/cortado.sh" "$swap_src/VERSION" "$active/" &&
        cp "$swap_src/lib/"*.sh "$active/lib/" &&
        cp "$swap_src/modules/"*.sh "$active/modules/" || exit 1
}

swap_case current-complete
current_runtime
run_git_update
assert_eq "a complete current runtime exits 0" 0 "$git_update_status"
assert_not_contains "a complete current runtime is not refreshed" Refreshed "$git_update_output"
assert_eq "a complete current runtime still renders" released "$active_output"

# Every library the release ships is required, not a fixed list.
for lib_file in "$swap_src/lib/"*.sh; do
    lib_name=${lib_file##*/}
    swap_case "current-without-$lib_name"
    current_runtime
    rm "$active/lib/$lib_name"
    run_git_update
    assert_contains "a current VERSION without lib/$lib_name is refreshed" Refreshed "$git_update_output"
    assert_new_runtime "a current VERSION without lib/$lib_name"
    assert_rc "a current VERSION without lib/$lib_name restores the library" 0 test -f "$active/lib/$lib_name"
done
for lib_name in config-data.sh config-permissions.sh module-registry.sh semver.sh; do
    assert_rc "the release fixture ships lib/$lib_name" 0 test -f "$swap_src/lib/$lib_name"
done

for outcome in success publish-fails; do
    swap_case "read-only-$outcome"
    mkdir "$active/user-ro"
    printf '%s\n' 'user data' > "$active/user-ro/data.txt"
    chmod 500 "$active/user-ro"
    if [ "$outcome" = publish-fails ]; then
        # shellcheck disable=SC2016 # The stub body expands when the stub runs.
        mv_stub 'case "$2" in */.cortado-runtime.*) exit 1 ;; esac'
    fi
    run_git_update
    if [ "$outcome" = success ]; then
        assert_new_runtime "a refresh over a read-only user directory"
    else
        assert_eq "a failed publish over a read-only user directory fails the update" 1 "$git_update_status"
        assert_old_runtime "a failed publish over a read-only user directory"
    fi
    assert_empty "a $outcome over a read-only user directory prints no rm error" \
        "$(printf '%s\n' "$git_update_output" | grep 'rm:')"
    assert_eq "a $outcome over a read-only user directory keeps the user's file" 'user data' \
        "$(cat "$active/user-ro/data.txt" 2>/dev/null)"
    chmod -R u+rwX "${cfg%/config}"
done

# TERM kills mktemp ("killed"), or lands just after it made the directory ("made").
for allocation in runtime:killed previous:killed runtime:made previous:made; do
    swap_case "mktemp-term-${allocation%%:*}-${allocation#*:}"
    # shellcheck disable=SC2016 # The stub body expands when the stub runs.
    if [ "${allocation#*:}" = killed ]; then
        allocate='kill -TERM "$INSTALLER_PID"; exit 143'
    else
        allocate='"$REAL_MKTEMP" "$@" && kill -TERM "$INSTALLER_PID"; exit 0'
    fi
    # shellcheck disable=SC2016 # The stub body expands when the stub runs.
    { printf '#!/bin/bash\nfor last in "$@"; do :; done\n'
      printf 'case "$last" in */.cortado-%s.*) %s ;; esac\n' "${allocation%%:*}" "$allocate"
      printf 'exec "$REAL_MKTEMP" "$@"\n'; } > "$case_bin/mktemp"
    chmod 755 "$case_bin/mktemp"
    run_git_update
    desc="TERM while allocating the ${allocation%%:*} directory (${allocation#*:})"
    assert_eq "$desc exits 143" 143 "$git_update_status"
    assert_not_contains "$desc reports no staging failure" "Could not stage" "$git_update_output"
    assert_old_runtime "$desc"
done

swap_case term-after-publish
# shellcheck disable=SC2016 # The stub body expands when the stub runs.
mv_stub 'case "$2" in */.cortado-runtime.*) /bin/mv "$@" || exit $?; kill -TERM "$INSTALLER_PID"; exit 0 ;; esac'
run_git_update
assert_eq "TERM just after the publish rename exits 143" 143 "$git_update_status"
assert_eq "TERM just after the publish rename keeps the published release" released "$active_output"
assert_rc "TERM just after the publish rename keeps the carried config" 0 \
    cmp "${cfg%/config}/conf.before" "$active/cortado.conf"
assert_empty "TERM just after the publish rename removes the previous runtime" "$(swap_leaks "$cfg")"

swap_case int-during-restore
# shellcheck disable=SC2016 # The stub body expands when the stub runs.
mv_stub 'case "$last" in */.cortado-previous.*/runtime) /bin/mv "$@" || exit $?; kill -TERM "$INSTALLER_PID"; exit 0 ;; esac
case "$2" in */.cortado-previous.*/runtime) kill -INT "$INSTALLER_PID" ;; esac'
run_git_update
assert_eq "INT during the restore after a TERM keeps the TERM status" 143 "$git_update_status"
assert_old_runtime "INT during the restore after a TERM"

swap_case unreadable-runtime
chmod 600 "$active"
run_git_update
chmod 700 "$active"
active_output=$(printf '{}\n' | /bin/sh -c "$launcher" 2>/dev/null)
assert_eq "an unreadable runtime fails the update" 1 "$git_update_status"
assert_contains "an unreadable runtime is named" "Could not read the current runtime" "$git_update_output"
assert_old_runtime "an unreadable runtime"

remove_root=$(mktemp -d "$CLAUDE_CONFIG_DIR/remove-tree.XXXXXX")
mkdir "$remove_root/target"
printf '%s\n' 'kept' > "$remove_root/target/file"
ln -s "$remove_root/target" "$remove_root/link"
assert_rc "removing an update directory refuses a symlink" 1 _update_remove_tree "$remove_root/link"
assert_rc "a refused removal keeps the symlink" 0 test -L "$remove_root/link"
assert_eq "a refused removal keeps what the symlink points to" kept "$(cat "$remove_root/target/file")"

# --- migrate_legacy_user_config (Barista -> Cortado) ---
MIG_TMP=$(mktemp -d)
printf '%s\n' 'COLOR_THEME="vibrant"' > "$MIG_TMP/barista.conf"
chmod 600 "$MIG_TMP/barista.conf"
assert_eq "migrate reports copied path" "$MIG_TMP/cortado.conf" \
    "$(migrate_legacy_user_config "$MIG_TMP/barista.conf" "$MIG_TMP/cortado.conf")"
assert_eq "migrate copies contents" 'COLOR_THEME="vibrant"' "$(cat "$MIG_TMP/cortado.conf" 2>/dev/null)"
printf '%s\n' 'COLOR_THEME="minimal"' > "$MIG_TMP/cortado.conf"
assert_eq "migrate is silent when cortado.conf exists" "" \
    "$(migrate_legacy_user_config "$MIG_TMP/barista.conf" "$MIG_TMP/cortado.conf")"
assert_eq "migrate never overwrites cortado.conf" 'COLOR_THEME="minimal"' "$(cat "$MIG_TMP/cortado.conf")"
rm -f "$MIG_TMP/barista.conf" "$MIG_TMP/cortado.conf"
assert_rc "migrate is a no-op without barista.conf" 0 migrate_legacy_user_config "$MIG_TMP/barista.conf" "$MIG_TMP/cortado.conf"
[ -f "$MIG_TMP/cortado.conf" ] && { echo "  FAIL: migrate created cortado.conf from nothing"; FAIL=$((FAIL + 1)); }
rmdir "$MIG_TMP" 2>/dev/null

legacy_source=$(mktemp -d "$CLAUDE_CONFIG_DIR/trusted.XXXXXX") || exit 1
printf '%s\n' 'MODULE_ORDER=model' 'MODULE_MODEL=true' 'USE_ICONS=true' 'MODEL_ICON=LEGACY' \
    > "$legacy_source/override" || exit 1
chmod 600 "$legacy_source/override"
legacy_payload='{"model":{"display_name":"Opus"}}'
for scenario in writable-destination refused-source; do
    legacy_root=$(mktemp -d "$CLAUDE_CONFIG_DIR/legacy.XXXXXX") || exit 1
    if [ "$scenario" = writable-destination ]; then
        ln -s "$legacy_source/override" "$legacy_root/barista.conf" && chmod 770 "$legacy_root" || exit 1
    else
        cp "$legacy_source/override" "$legacy_root/barista.conf" && chmod 620 "$legacy_root/barista.conf" || exit 1
    fi
    legacy_install_rc=0
    legacy_install_out=$(CLAUDE_CONFIG_DIR="$legacy_root" CACHE_DIR="$legacy_root/cortado-cache" HOME="$legacy_source" \
        /bin/bash "$REPO_ROOT/install.sh" --minimal --skip-update-check --no-color 2>&1) || legacy_install_rc=$?
    assert_eq "legacy install succeeds with $scenario" 0 "$legacy_install_rc"
    if [ "$scenario" = writable-destination ]; then
        for attempt in first second; do
            legacy_render=$(printf '%s' "$legacy_payload" | CLAUDE_CONFIG_DIR="$legacy_root" CACHE_DIR="$legacy_root/cortado-cache" \
                /bin/bash "$legacy_root/cortado/cortado.sh" 2>/dev/null)
            assert_eq "installed statusline reads the trusted legacy link on the $attempt render" 'LEGACY Opus' "$legacy_render"
            assert_rc "installer and $attempt render leave the trusted legacy link unshadowed" \
                1 test -e "$legacy_root/cortado.conf"
        done
    else
        assert_contains 'Installer reports refusal of an unsafe legacy source' 'refusing to source config' "$legacy_install_out"
        assert_not_contains 'Installer does not promise to use a refused legacy config' \
            'Cortado will read the old file' "$legacy_install_out"
        assert_not_contains 'Installer does not announce in-place use of a refused legacy config' \
            'Using legacy config in place' "$legacy_install_out"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
