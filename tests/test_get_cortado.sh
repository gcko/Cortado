#!/bin/bash
# ABOUTME: get-cortado.sh, the release-attached installer for people without git or
# ABOUTME: Homebrew: it installs only a release zip that matches SHA256SUMS, refuses
# ABOUTME: everything else before running anything, and always removes its temp dir.
# ABOUTME: No network: a curl shim serves fixture releases. Run with: /bin/bash tests/test_get_cortado.sh

umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented
# Mutation runs point this at a modified copy.
SCRIPT="${GET_CORTADO_UNDER_TEST:-$REPO_ROOT/get-cortado.sh}"

TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1

VERSION_TEXT=$(git -C "$REPO_ROOT" show HEAD:VERSION | tr -d '[:space:]') || exit 1
TAG="v$VERSION_TEXT"
ARCHIVE=Cortado-source.zip
ZIP_CAP=20971520
REPO_API=https://api.github.com/repos/gcko/Cortado
REPO_DOWNLOAD=https://github.com/gcko/Cortado/releases/download

fixture="$TEST_BASE/fixture"
package="$TEST_BASE/package"
shim="$TEST_BASE/shim"
mkdir -p "$fixture" "$package" "$shim" || exit 1

digest() {
    local result
    if command -v sha256sum >/dev/null 2>&1; then
        result=$(sha256sum < "$1") || return 1
    else
        result=$(shasum -a 256 < "$1") || return 1
    fi
    printf '%s\n' "${result%% *}"
}

# sums_for <zip> [name]: one SHA256SUMS line, plus the get-cortado.sh line a release carries.
sums_for() {
    printf '%s  %s\n' "$(digest "$1")" "${2:-$ARCHIVE}"
    printf '%s  %s\n' "$(digest "$REPO_ROOT/get-cortado.sh" 2>/dev/null || printf '%064d' 0)" get-cortado.sh
}

# The good release: the real tree at HEAD, packaged the way cortado-release packages it.
git -C "$REPO_ROOT" archive --format=zip --prefix="Cortado-$VERSION_TEXT/" -o "$fixture/good.zip" HEAD || exit 1
sums_for "$fixture/good.zip" > "$fixture/good.sums" || exit 1

# Variants come from a scratch repository holding the same tree.
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$package" || exit 1
fixture_git() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$package" "$@"
}
package_as() {
    local name="$1" version="$2"
    fixture_git add -A &&
        fixture_git -c user.name=Fixture -c user.email=fixture@example.invalid \
            -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm "$name" &&
        fixture_git archive --format=zip --prefix="Cortado-$version/" -o "$fixture/$name.zip" HEAD &&
        sums_for "$fixture/$name.zip" > "$fixture/$name.sums"
}
fixture_git init -q --template= || exit 1
# A marker installer: if it ever runs, the marker file appears.
cat > "$package/install.sh" <<'STUB'
#!/bin/bash
printf 'marker installer ran with %s\n' "$*" > "$MARKER"
STUB
package_as marker "$VERSION_TEXT" || exit 1
# A verified installer that signals get-cortado while it runs.
cat > "$package/install.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$MARKER.args"
ls -ld "$(cd "$(dirname "$0")/../.." && pwd)" > "$MARKER.work"
kill -"${SIGNAL:-TERM}" "$GET_PID"
sleep 0.2
# get-cortado must wait for its installer before removing the release it runs.
if [ -f "$0" ]; then echo kept > "$MARKER.after"; else echo removed > "$MARKER.after"; fi
STUB
package_as signal "$VERSION_TEXT" || exit 1
cat > "$package/install.sh" <<'STUB'
#!/bin/bash
printf 'marker installer ran with %s\n' "$*" > "$MARKER"
STUB
printf '%s\n' 0.0.1 > "$package/VERSION"
package_as wrong-version "$VERSION_TEXT" || exit 1
printf '%s\n' "$VERSION_TEXT" > "$package/VERSION"
rm "$package/install.sh"
package_as no-installer "$VERSION_TEXT" || exit 1
printf '%s\n' 'not a ZIP' > "$fixture/not-zip.zip"
sums_for "$fixture/not-zip.zip" > "$fixture/not-zip.sums"

# The curl shim: logs every request, honours -o and --max-filesize, serves by URL.
cat > "$shim/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$REQUEST_LOG"
url="" output="" cap=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        https://*|http://*) url="$1" ;;
        -o) output="$2"; shift ;;
        --max-filesize) cap="$2"; shift ;;
    esac
    shift
done
serve() {
    if [ -n "$cap" ] && [ "$(wc -c < "$1")" -gt "$cap" ]; then exit 63; fi
    if [ -n "$output" ]; then cat "$1" > "$output"; else cat "$1"; fi
}
case "$url" in
    "$REPO_API/releases/latest"|"$REPO_API/releases/tags/"*)
        [ "$CASE" = api-http-error ] && exit 22
        serve "$API_BODY"
        ;;
    "$REPO_DOWNLOAD/$SERVE_TAG/SHA256SUMS")
        [ "$CASE" = sums-http-error ] && exit 22
        serve "$SUMS"
        ;;
    "$REPO_DOWNLOAD/$SERVE_TAG/Cortado-source.zip")
        case "$CASE" in
            zip-http-error) exit 22 ;;
            zip-timeout) exit 28 ;;
            zip-too-large) exit 63 ;;
            zip-unbounded)
                # A server that announces no length: curl cannot stop at the cap.
                dd if=/dev/null of="$output" bs=1 seek="$((ZIP_CAP + 1))" 2>/dev/null
                exit 0
                ;;
            zip-term|zip-int|zip-hup)
                printf '%s\n' partial > "$output"
                case "$CASE" in
                    zip-term) kill -TERM "$GET_PID" ;;
                    zip-int) kill -INT "$GET_PID" ;;
                    zip-hup) kill -HUP "$GET_PID" ;;
                esac
                sleep 0.2
                exit 1
                ;;
        esac
        serve "$ZIP"
        ;;
    *) exit 7 ;;
esac
STUB
# A mktemp that signals get-cortado after its temp dir exists, before the name returns.
MKTEMP_BIN=$(command -v mktemp) || exit 1
cat > "$shim/mktemp" <<'STUB'
#!/bin/bash
created=$("$MKTEMP_BIN" "$@") || exit 1
printf '%s\n' "$created"
case "$CASE:$created" in
    mktemp-term:*/get-cortado.*) kill -TERM "$GET_PID"; sleep 0.2 ;;
esac
STUB
chmod +x "$shim/curl" "$shim/mktemp"

# A PATH holding only the named tools (plus the curl shim unless curl is left out).
tools_dir() {
    local name="$1" tool path dir="$TEST_BASE/tools-$1"
    shift
    mkdir "$dir" || exit 1
    for tool in "$@"; do
        if [ "$tool" = curl ]; then
            ln -s "$shim/curl" "$dir/curl"
        elif path=$(command -v "$tool" 2>/dev/null) && [ -n "$path" ]; then
            ln -s "$path" "$dir/$tool"
        fi
    done
    printf '%s\n' "$dir"
}
BASE_TOOLS="bash env mktemp rm rmdir chmod mkdir cat awk sed tr wc head grep dd sleep kill perl"

api_body() {
    # api_body <tag> [draft] [prerelease]
    printf '{"tag_name":"%s","draft":%s,"prerelease":%s,"assets":[]}\n' "$1" "${2:-false}" "${3:-false}"
}

# get <case> [args...]: run get-cortado.sh in a fresh sandbox.
# Knobs: ZIP_NAME, SUMS_NAME, API_TEXT, SERVE (tag the assets are served for), RUN_PATH.
get() {
    local case_name="$1"
    shift
    sandbox=$(mktemp -d "$TEST_BASE/case.XXXXXX") || exit 1
    home="$sandbox/home"
    cfg="$sandbox/claude config"
    tmp="$sandbox/tmp"
    mkdir -p "$home" "$tmp" || exit 1
    request_log="$sandbox/requests"
    : > "$request_log"
    marker="$sandbox/marker"
    printf '%s' "${API_TEXT:-$(api_body "$TAG")}" > "$sandbox/api.json"
    out=$(HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" TMPDIR="$tmp" \
        PATH="${RUN_PATH:-$shim:$PATH}" REQUEST_LOG="$request_log" MARKER="$marker" CASE="$case_name" \
        API_BODY="$sandbox/api.json" ZIP="$fixture/${ZIP_NAME:-good}.zip" SUMS="$fixture/${SUMS_NAME:-${ZIP_NAME:-good}}.sums" \
        SERVE_TAG="${SERVE:-$TAG}" MKTEMP_BIN="$MKTEMP_BIN" SIGNAL="${SIGNAL:-TERM}" REPO_API="$REPO_API" REPO_DOWNLOAD="$REPO_DOWNLOAD" ZIP_CAP="$ZIP_CAP" \
        /bin/bash -c 'export GET_PID=$$; exec /bin/bash "$@"' -- "$SCRIPT" "$@" 2>&1 < /dev/null)
    status=$?
}

# Every refusal: non-zero, nothing ran, nothing installed, no temp left.
assert_refused() {
    local desc="$1" message="$2"
    assert_eq "$desc: exits 1" 1 "$status"
    assert_contains "$desc: says why" "$message" "$out"
    assert_eq "$desc: runs no installer" "absent" "$([ -e "$marker" ] && echo present || echo absent)"
    assert_eq "$desc: installs nothing" "absent" "$([ -e "$cfg" ] || [ -e "$home/.local" ] && echo present || echo absent)"
    assert_empty "$desc: leaves no temp dir" "$(ls -A "$tmp")"
}

PAYLOAD='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Fixture Model"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'

echo "=== get-cortado.sh ==="

assert_rc 'get-cortado.sh is valid Bash 3.2' 0 /bin/bash -n "$SCRIPT"

# --- a good latest release installs, and the statusline renders ----------------
get good --defaults --no-color --no-emoji
assert_eq 'a good release: exits 0' 0 "$status"
assert_contains 'a good release: names the release it installs' "Cortado $TAG" "$out"
assert_contains 'a good release: says the checksum matched' "Checksum OK" "$out"
assert_contains 'a good release: runs the installer' "Installed" "$out"
assert_contains 'a good release: asks releases/latest' "$REPO_API/releases/latest" "$(cat "$request_log")"
assert_contains 'a good release: downloads the zip for the exact tag' "$REPO_DOWNLOAD/$TAG/$ARCHIVE" "$(cat "$request_log")"
assert_contains 'a good release: downloads SHA256SUMS for the exact tag' "$REPO_DOWNLOAD/$TAG/SHA256SUMS" "$(cat "$request_log")"
assert_eq 'a good release: installs the release VERSION' "$VERSION_TEXT" "$(tr -d '[:space:]' < "$cfg/cortado/VERSION" 2>/dev/null)"
assert_eq 'a good release: creates the cortado command' "$cfg/cortado/cortado.sh" "$(readlink "$home/.local/bin/cortado" 2>/dev/null)"
assert_not_contains 'a good release: settings.json never names the temp dir' "$tmp" "$(cat "$cfg/settings.json" 2>/dev/null)"
assert_contains 'a good release: settings.json runs the installed copy' "cortado/cortado.sh" "$(cat "$cfg/settings.json" 2>/dev/null)"
assert_empty 'a good release: leaves no temp dir' "$(ls -A "$tmp")"
rendered=$(printf '%s' "$PAYLOAD" | HOME="$home" CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" \
    /bin/bash "$cfg/cortado/cortado.sh" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')
assert_contains 'a good release: the installed statusline renders' "Fixture Model" "$rendered"
# get-cortado's own requests write into its temp dir; the installer's preview
# runs the statusline, whose update module makes one more.
grep -F -- "-o $tmp/get-cortado." "$request_log" > "$sandbox/own-requests"
requests=$(cat "$sandbox/own-requests")
assert_eq 'a good release: makes exactly three requests of its own' 3 "$(grep -c . "$sandbox/own-requests")"
for flag in '--proto =https' '--proto-redir =https' '--connect-timeout 5' '--max-time' '--max-filesize' '--max-redirs 3'; do
    assert_eq "every request carries $flag" 3 "$(grep -cF -- "$flag" "$sandbox/own-requests")"
done
assert_not_contains 'no request is plain http' 'http://' "$requests"

# --- a specific version asks for that tag ---------------------------------------
get specific "$VERSION_TEXT" --minimal
assert_eq 'a named version: exits 0' 0 "$status"
assert_contains 'a named version: asks for that tag' "$REPO_API/releases/tags/$TAG" "$(cat "$request_log")"
assert_not_contains 'a named version: never asks for latest' "releases/latest" "$(cat "$request_log")"
assert_empty 'a named version: leaves no temp dir' "$(ls -A "$tmp")"
get specific-v "$TAG" --minimal
assert_eq 'a named version with a leading v: exits 0' 0 "$status"

# --- installer options pass through; the update check is skipped -----------------
ZIP_NAME=signal get pass-through --minimal --no-emoji
assert_eq 'the installer gets the options and --skip-update-check' "--minimal --no-emoji --skip-update-check" \
    "$(cat "$marker.args" 2>/dev/null)"
assert_match 'the temp dir is readable only by its owner' '^drwx------' "$(cat "$marker.work" 2>/dev/null)"
for sig in TERM:143 INT:130 HUP:129; do
    if [ "${sig%%:*}" != TERM ]; then SIGNAL="${sig%%:*}" ZIP_NAME=signal get "installer-${sig%%:*}" --minimal; fi
    assert_eq "a ${sig%%:*} while the installer runs: exits ${sig#*:}" "${sig#*:}" "$status"
    assert_eq "a ${sig%%:*} while the installer runs: waits for the installer to finish" kept "$(cat "$marker.after" 2>/dev/null)"
    assert_empty "a ${sig%%:*} while the installer runs: leaves no temp dir" "$(ls -A "$tmp")"
done

# --- arguments that refuse before any request ------------------------------------
for bad in 2.1 1.2.3.4 ../2.1.0 'v2.1.0;id' 2.1.0-rc1 '' x; do
    get bad-arg "$bad"
    assert_refused "version argument [$bad]" "Not a release version"
    assert_empty "version argument [$bad]: makes no request" "$(cat "$request_log")"
done
for bad in --update --uninstall --check-update --help-me -x; do
    get bad-option "$bad"
    assert_refused "option $bad" "not an installer option"
    assert_empty "option $bad: makes no request" "$(cat "$request_log")"
done
get help --help
assert_eq '--help: exits 0' 0 "$status"
assert_contains '--help: prints usage' "Usage: bash get-cortado.sh" "$out"
assert_empty '--help: makes no request' "$(cat "$request_log")"
get two-versions 2.1.0 2.0.0
assert_refused 'two versions' "Only one version"

# --- untrusted API responses -----------------------------------------------------
API_TEXT=$(api_body "$TAG" true) get draft
assert_refused 'a draft release' "did not return a published release"
API_TEXT=$(api_body "$TAG" false true) get prerelease
assert_refused 'a prerelease' "did not return a published release"
API_TEXT='{"tag_name":"'"$TAG"'"}' get no-flags
assert_refused 'a release without draft and prerelease fields' "did not return a published release"
API_TEXT="[$(api_body "$TAG")]" get array
assert_refused 'a JSON array' "did not return a published release"
API_TEXT='not json' get not-json
assert_refused 'a body that is not JSON' "did not return a published release"
API_TEXT='{"tag_name":7,"draft":false,"prerelease":false}' get number-tag
assert_refused 'a numeric tag' "Unexpected release tag"
# shellcheck disable=SC2016 # A literal $( ) in a tag must never run.
for bad in v2.1.0-rc1 2.1.0 'v2.1.0/../../x' 'v2.1.0$(touch marker)' 'v2.1' "v2.1.0
v9.9.9" ''; do
    label=$(printf '%s' "$bad" | tr '\n' '|')
    API_TEXT=$(jq -cn --arg t "$bad" '{tag_name:$t,draft:false,prerelease:false}') SERVE="$bad" get bad-tag
    assert_refused "tag [$label]" "Unexpected release tag"
    assert_not_contains "tag [$label]: downloads nothing" "/releases/download/" "$(cat "$request_log")"
done
API_TEXT=$(api_body v0.0.1) SERVE=v0.0.1 get other-tag "$VERSION_TEXT"
assert_refused 'a tag other than the one asked for' "Unexpected release tag"
get api-http-error
assert_refused 'a failed release lookup' "Could not download the release information"

# --- downloads and verification ---------------------------------------------------
ZIP_NAME=marker SUMS_NAME=good get tampered
assert_refused 'a tampered zip' "Checksum mismatch"
printf '%s\n' "$(grep -v " $ARCHIVE\$" "$fixture/marker.sums")" > "$fixture/no-line.sums"
ZIP_NAME=marker SUMS_NAME=no-line get no-line
assert_refused 'SHA256SUMS without the zip line' "SHA256SUMS must contain one valid checksum"
cat "$fixture/marker.sums" "$fixture/marker.sums" > "$fixture/dup.sums"
ZIP_NAME=marker SUMS_NAME=dup get duplicate
assert_refused 'SHA256SUMS with the line twice' "SHA256SUMS must contain one valid checksum"
sed "s/^[0-9a-f]*  $ARCHIVE\$/null  $ARCHIVE/" "$fixture/marker.sums" > "$fixture/null.sums"
ZIP_NAME=marker SUMS_NAME=null get null-digest
assert_refused 'a digest that is not 64 hex digits' "SHA256SUMS must contain one valid checksum"
sed "s/  $ARCHIVE\$/  other-$ARCHIVE/" "$fixture/marker.sums" > "$fixture/other.sums"
ZIP_NAME=marker SUMS_NAME=other get other-name
assert_refused 'a line for a different file name' "SHA256SUMS must contain one valid checksum"
ZIP_NAME=marker get sums-http-error
assert_refused 'a failed SHA256SUMS download' "Could not download SHA256SUMS"
ZIP_NAME=marker get zip-http-error
assert_refused 'a failed zip download' "Could not download $ARCHIVE"
ZIP_NAME=marker get zip-timeout
assert_refused 'a zip download that times out' "timed out"
ZIP_NAME=marker get zip-too-large
assert_refused 'a zip over the size cap' "too large"
ZIP_NAME=marker get zip-unbounded
assert_refused 'a zip over the cap with no announced length' "too large"
ZIP_NAME=wrong-version get wrong-version
assert_refused 'a zip whose VERSION is not the release' "does not match release"
ZIP_NAME=no-installer get no-installer
assert_refused 'a zip without install.sh' "missing essential files"
ZIP_NAME=not-zip get not-zip
assert_refused 'a file that is not a zip' "not a valid ZIP"

# --- missing tools -----------------------------------------------------------------
for missing in curl unzip jq sha; do
    tools=""
    for tool in curl unzip jq shasum sha256sum; do
        case "$missing:$tool" in
            curl:curl|unzip:unzip|jq:jq|sha:shasum|sha:sha256sum) ;;
            *) tools="$tools $tool" ;;
        esac
    done
    # shellcheck disable=SC2086 # Word splitting builds the tool list.
    RUN_PATH=$(tools_dir "$missing" $BASE_TOOLS $tools) ZIP_NAME=marker get "missing-$missing"
    case "$missing" in
        sha) assert_refused 'no shasum or sha256sum' "needs shasum or sha256sum" ;;
        *) assert_refused "no $missing" "needs $missing" ;;
    esac
    assert_empty "no $missing: makes no request" "$(cat "$request_log")"
done
# Either SHA tool is enough.
for only in shasum sha256sum; do
    if command -v "$only" >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        RUN_PATH=$(tools_dir "only-$only" $BASE_TOOLS curl unzip jq "$only") ZIP_NAME=marker SUMS_NAME=good get "only-$only"
        assert_refused "with only $only, a tampered zip" "Checksum mismatch"
    fi
done

# --- signals while downloading -----------------------------------------------------
for sig in term:143 int:130 hup:129; do
    ZIP_NAME=marker get "zip-${sig%%:*}"
    assert_eq "a ${sig%%:*} signal while downloading: exits ${sig#*:}" "${sig#*:}" "$status"
    assert_eq "a ${sig%%:*} signal while downloading: runs no installer" absent "$([ -e "$marker" ] && echo present || echo absent)"
    assert_empty "a ${sig%%:*} signal while downloading: leaves no temp dir" "$(ls -A "$tmp")"
done

ZIP_NAME=marker get mktemp-term
assert_eq 'a TERM as the temp dir is made: exits 143' 143 "$status"
assert_eq 'a TERM as the temp dir is made: runs no installer' absent "$([ -e "$marker" ] && echo present || echo absent)"
assert_empty 'a TERM as the temp dir is made: leaves no temp dir' "$(ls -A "$tmp")"
assert_empty 'a TERM as the temp dir is made: makes no request' "$(cat "$request_log")"

# --- install.sh --update still reads a SHA256SUMS with the get-cortado.sh line ------
installer_expected=$(
    # shellcheck source=install.sh
    . "$REPO_ROOT/install.sh" >/dev/null 2>&1
    stage="$TEST_BASE/stage"
    mkdir "$stage" || exit 1
    # Bash 3.2 cannot parse case patterns inside $( ), so this uses if.
    # shellcheck disable=SC2329 # Replaces install.sh's downloader, which _stage_release_archive calls.
    _download_release_asset() {
        if [ "$2" = SHA256SUMS ]; then cp "$fixture/good.sums" "$3"; else cp "$fixture/good.zip" "$3"; fi
    }
    _stage_release_archive "$TAG" "$stage" "$stage/Cortado-$VERSION_TEXT" && echo staged
)
assert_eq 'install.sh --update accepts SHA256SUMS with a get-cortado.sh line' staged "$installer_expected"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
