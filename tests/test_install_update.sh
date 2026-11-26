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

rm -f "$FAKE_ROOT/.git" 2>/dev/null
rmdir "$FAKE_ROOT/.git" 2>/dev/null
rmdir "$FAKE_ROOT" 2>/dev/null

# --- copy_runtime_files ships lib/config-tui.sh (from-source install) ---
# do_update cds into FAKE_ROOT; use the repo root captured at the top.
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
