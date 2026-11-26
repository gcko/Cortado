#!/bin/bash
# Behavioral tests for bounded and verified release archive updates, with no network.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented

fixture_version=99.0.0+fixture
archive_name=Cortado-source.zip
fixture="$TEST_BASE/fixture"
package="$TEST_BASE/package"
mkdir -p "$fixture" "$package" "$TEST_BASE/bin" || exit 1
printf '%s\n' 'verified fixture' > "$fixture/expected-runtime"
cp "$fixture/expected-runtime" "$package/cortado.sh"
mkdir "$package/modules" "$package/lib" || exit 1
printf '%s\n' "# module fixture" > "$package/modules/model.sh"
# Ship every library a release ships; config-tui.sh stays a marked fixture.
cp "$REPO_ROOT/lib/"*.sh "$package/lib/" || exit 1
printf '%s\n' "# library fixture" > "$package/lib/config-tui.sh"
cat > "$package/install.sh" <<'STUB'
#!/bin/bash
printf 'Restarted installer with %s\n' "$*"
STUB
chmod +x "$package/install.sh"

fixture_git() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$package" "$@"
}

package_archive() {
    local version="$1" output="$2"
    fixture_git add -A &&
        fixture_git -c user.name=Fixture -c user.email=fixture@example.invalid \
            -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm 'Package fixture' &&
        fixture_git archive --format=zip --prefix="Cortado-$version/" -o "$output" HEAD
}

fixture_checksum() {
    local result
    if command -v sha256sum >/dev/null; then
        result=$(sha256sum < "$1") || return 1
    else
        result=$(shasum -a 256 < "$1") || return 1
    fi
    printf '%s  %s\n' "${result%% *}" "$archive_name"
}

fixture_git init -q --template= || exit 1
for version in 99.0.0 "$fixture_version" 99.0.0-rc1; do
    mkdir "$fixture/$version" || exit 1
    printf '%s\n' "$version" > "$package/VERSION"
    package_archive "$version" "$fixture/$version/$archive_name" || exit 1
    fixture_checksum "$fixture/$version/$archive_name" > "$fixture/$version/SHA256SUMS" || exit 1
done

printf '%s\n' "$fixture_version" > "$package/VERSION"
printf '%s\n' 'tampered fixture' > "$package/cortado.sh"
package_archive "$fixture_version" "$fixture/tampered.zip" || exit 1
cp "$fixture/expected-runtime" "$package/cortado.sh"
printf '%s\n' 'not a ZIP' > "$fixture/bad-zip"
fixture_checksum "$fixture/bad-zip" > "$fixture/bad-zip.sums" || exit 1
printf '%s\n' '0' > "$package/VERSION"
package_archive "$fixture_version" "$fixture/wrong-version.zip" || exit 1
fixture_checksum "$fixture/wrong-version.zip" > "$fixture/wrong-version.sums" || exit 1
printf '%s\n' "$fixture_version" > "$package/VERSION"
rm "$package/cortado.sh"
package_archive "$fixture_version" "$fixture/missing-files.zip" || exit 1
fixture_checksum "$fixture/missing-files.zip" > "$fixture/missing-files.sums" || exit 1
cp "$fixture/expected-runtime" "$package/cortado.sh"
rm "$package/VERSION"
package_archive "$fixture_version" "$fixture/missing-version.zip" || exit 1
fixture_checksum "$fixture/missing-version.zip" > "$fixture/missing-version.sums" || exit 1

cat > "$TEST_BASE/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$REQUEST_LOG"
while [ "$#" -gt 0 ]; do
    case "$1" in
        https://*) url="$1" ;;
        -o) output="$2"; shift ;;
        --connect-timeout) connect_time="$2"; shift ;;
        --max-time) max_time="$2"; shift ;;
    esac
    shift
done
case "$url" in
    https://api.github.com/*)
        printf '%s\n200\n' "$RELEASE_BODY"
        exit "${RELEASE_STATUS:-0}"
        ;;
    */SHA256SUMS)
        case "$DOWNLOAD_CASE" in
            interrupted)
                printf '%s\n' part > "$output"
                kill -TERM "$PPID"
                exit 1
                ;;
            manifest-stall) sleep 0.01; exit 28 ;;
            missing-manifest) printf '%s\n' 'HTTP 404' > "$output"; exit 22 ;;
            manifest-http-error) cp "$RELEASE_ASSETS/SHA256SUMS" "$output"; exit 22 ;;
            bad-zip|wrong-version|missing-files|missing-version) cp "$FIXTURE/$DOWNLOAD_CASE.sums" "$output" ;;
            no-entry) sed 's/Cortado-source.zip/unrelated.zip/' "$RELEASE_ASSETS/SHA256SUMS" > "$output" ;;
            null-hash) printf '%s  Cortado-source.zip\n' null > "$output" ;;
            zero-hash) printf '%s  Cortado-source.zip\n' 0 > "$output" ;;
            nonhex-hash) printf '%064d  Cortado-source.zip\n' 0 | tr 0 z > "$output" ;;
            extra-field) sed 's/$/ extra/' "$RELEASE_ASSETS/SHA256SUMS" > "$output" ;;
            duplicate) cat "$RELEASE_ASSETS/SHA256SUMS" "$RELEASE_ASSETS/SHA256SUMS" > "$output" ;;
            binary-entry) tr 'a-f' 'A-F' < "$RELEASE_ASSETS/SHA256SUMS" | sed 's/  .*/ *Cortado-source.zip/' > "$output" ;;
            *) cp "$RELEASE_ASSETS/SHA256SUMS" "$output" ;;
        esac
        ;;
    */Cortado-source.zip|*/archive/refs/tags/*.zip)
        case "$DOWNLOAD_CASE" in
            stall|connect-stall)
                # The stall never yields an archive. Scale curl's deadlines to
                # a short sleep, with a fallback error to keep a red test bounded.
                case "$DOWNLOAD_CASE" in
                    stall) deadline="$max_time" ;;
                    connect-stall) deadline="$connect_time" ;;
                esac
                if [ "${deadline:-0}" -gt 0 ] && [ "$deadline" -le 60 ]; then
                    sleep 0.01
                    exit 28
                fi
                sleep 0.2
                exit 7
                ;;
            http-error) cp "$RELEASE_ASSETS/Cortado-source.zip" "$output"; exit 22 ;;
            tampered|wrong-version|missing-files|missing-version) cp "$FIXTURE/$DOWNLOAD_CASE.zip" "$output" ;;
            bad-zip) cp "$FIXTURE/bad-zip" "$output" ;;
            *) cp "$RELEASE_ASSETS/Cortado-source.zip" "$output" ;;
        esac
        ;;
    *) exit 7 ;;
esac
STUB
unzip_bin=$(command -v unzip) || exit 1
mktemp_bin=$(command -v mktemp) || exit 1
cat > "$TEST_BASE/bin/unzip" <<'STUB'
#!/bin/bash
printf '%s\n' 'unzip' >> "$UNZIP_LOG"
exec "$UNZIP_BIN" "$@"
STUB
cat > "$TEST_BASE/bin/mktemp" <<'STUB'
#!/bin/bash
# Deliver TERM while the staging directory exists but before its name returns.
created=$("$MKTEMP_BIN" "$@") || exit 1
printf '%s\n' "$created"
if [ "$DOWNLOAD_CASE" = staging-term ]; then
    case "$created" in */cortado-update.*) kill -TERM "$INSTALLER_PID" ;; esac
fi
STUB
cat > "$TEST_BASE/bin/cp" <<'STUB'
#!/bin/bash
case "$DOWNLOAD_CASE" in
    backup-term|backup-fail)
        for dest in "$@"; do :; done
        case "$dest" in
            */source.backup.*)
                mkdir -p "$dest" || exit 1
                printf '%s\n' 'partial backup' > "$dest/partial"
                [ "$DOWNLOAD_CASE" = backup-fail ] || kill -TERM "$INSTALLER_PID"
                exit 1
                ;;
        esac
        ;;
esac
if [ "$DOWNLOAD_CASE" = copy-term ]; then
    for dest in "$@"; do :; done
    case "$dest" in */source/) kill -TERM "$INSTALLER_PID"; exit 1 ;; esac
fi
if [ "$DOWNLOAD_CASE" = partial-copy ]; then
    for arg in "$@"; do
        case "$arg" in
            */cortado-update.*/Cortado-*/VERSION) version="$arg" ;;
            */cortado-update.*/Cortado-*/cortado.sh) fail_copy=true ;;
        esac
        dest="$arg"
    done
    if [ "${fail_copy:-false}" = true ]; then
        if [ -n "${version:-}" ]; then /bin/cp "$version" "$dest"; fi
        printf '%s\n' 'simulated copy failure' >&2
        exit 1
    fi
fi
exec /bin/cp "$@"
STUB
chmod +x "$TEST_BASE/bin/curl" "$TEST_BASE/bin/unzip" "$TEST_BASE/bin/cp" "$TEST_BASE/bin/mktemp"

run_archive_update() {
    local download_case="$1" flag="${2:---update}" version="${3:-$fixture_version}" sandbox
    sandbox=$(mktemp -d "$TEST_BASE/update.XXXXXX") || exit 1
    mkdir -p "$sandbox/source" "$sandbox/config/cortado" "$sandbox/tmp"
    cp -R "$REPO_ROOT/install.sh" "$REPO_ROOT/VERSION" "$REPO_ROOT/lib" "$sandbox/source/"
    printf '%s\n' 'installed fixture' > "$sandbox/config/cortado/cortado.sh"
    printf '%s\n' '{"statusLine":{"type":"command","command":"fixture"}}' > "$sandbox/config/settings.json"
    case "$download_case" in
        managed|managed-stale|managed-obsolete)
            # shellcheck disable=SC2016 # $path is a jq variable.
            jq -n --arg path "$sandbox/config/cortado/cortado.sh" \
                '{statusLine:{type:"command",command:($path|@sh)},padding:11}' > "$sandbox/config/settings.json"
            printf '%s\n' 'custom generated config' > "$sandbox/config/cortado/cortado.conf"
            chmod 600 "$sandbox/config/cortado/cortado.conf"
            cp "$REPO_ROOT/VERSION" "$sandbox/config/cortado/"
            if [ "$download_case" = managed-obsolete ]; then
                mkdir -p "$sandbox/source/modules" "$sandbox/config/cortado/modules"
                printf '%s\n' '# retired module' > "$sandbox/source/modules/zz-retired.sh"
                cp "$sandbox/source/modules/zz-retired.sh" "$sandbox/config/cortado/modules/"
            fi
            if [ "$download_case" = managed-stale ]; then
                printf '%s\n' "$version" > "$sandbox/source/VERSION"
                cp -R "$package/modules" "$package/lib" "$sandbox/source/"
                cp "$fixture/expected-runtime" "$sandbox/source/cortado.sh"
            fi
            ;;
    esac
    chmod 600 "$sandbox/config/settings.json"
    cp -R "$sandbox/source" "$sandbox/source.before"
    cp -R "$sandbox/config" "$sandbox/config.before"
    request_log="$sandbox/requests"
    : > "$request_log"
    unzip_log="$sandbox/unzip"
    : > "$unzip_log"
    local temp_parent="$sandbox/tmp"
    if [ "$download_case" = no-temp ]; then
        temp_parent="$sandbox/absent-parent"
    fi
    local args=(--no-color --no-emoji)
    [ "$flag" != interactive ] && args=("$flag" "${args[@]}")
    update_output=$(printf '%s\n%s\n' "${UPDATE_REPLY:-}" "${UPDATE_REPLY:-}" |
        CLAUDE_CONFIG_DIR="$sandbox/config" CACHE_DIR="$sandbox/config/cortado-cache" TMPDIR="$temp_parent" \
        PATH="$TEST_BASE/bin:${UPDATE_PATH:-$PATH}" FIXTURE="$fixture" REQUEST_LOG="$request_log" \
        UNZIP_BIN="$unzip_bin" UNZIP_LOG="$unzip_log" MKTEMP_BIN="$mktemp_bin" \
        RELEASE_BODY="{\"tag_name\":\"v$version\"}" RELEASE_ASSETS="$fixture/$version" DOWNLOAD_CASE="$download_case" \
        /bin/bash -c 'export INSTALLER_PID=$$; exec /bin/bash "$@"' -- "$sandbox/source/install.sh" "${args[@]}" 2>&1)
    update_status=$?
    update_sandbox="$sandbox"
}

assert_archive_staged_in_tmpdir() {
    local desc="$1" request
    request=$(grep -F "/$archive_name" "$request_log")
    assert_contains "$desc stages the archive below TMPDIR" " -o $update_sandbox/tmp/" "$request"
    assert_empty "$desc removes its staging directory" "$(ls -A "$update_sandbox/tmp")"
}

assert_archived_release() {
    local desc="$1" version="$2" asset
    assert_eq "$desc exits 0" 0 "$update_status"
    assert_contains "$desc reports the full version" "Updated to version $version" "$update_output"
    assert_eq "$desc copies the full VERSION" "$version" "$(cat "$update_sandbox/source/VERSION")"
    assert_rc "$desc installs the checked runtime bytes" 0 cmp "$fixture/expected-runtime" "$update_sandbox/source/cortado.sh"
    for asset in SHA256SUMS "$archive_name"; do
        assert_contains "$desc requests $asset for the exact tag" \
            "/releases/download/v$version/$asset" "$(cat "$request_log")"
    done
}

assert_refused() {
    local desc="$1" message="$2"
    assert_eq "$desc exits 1" 1 "$update_status"
    assert_contains "$desc explains the refusal" "$message" "$update_output"
    assert_not_contains "$desc never announces success" 'Updated to version' "$update_output"
    assert_not_contains "$desc never starts installation" 'Checking requirements...' "$update_output"
    assert_rc "$desc preserves source files" 0 diff -rq "$update_sandbox/source.before" "$update_sandbox/source"
    assert_rc "$desc preserves installed files and settings" 0 diff -rq "$update_sandbox/config.before" "$update_sandbox/config"
    assert_empty "$desc removes temporary downloads" "$(ls -A "$update_sandbox/tmp")"
}

run_archive_update stall
assert_refused 'a silent archive server' 'Download timed out for Cortado-source.zip'
run_archive_update connect-stall
assert_refused 'a server that never connects' 'Download timed out for Cortado-source.zip'
run_archive_update manifest-stall
assert_refused 'a checksum transfer that times out' 'Download timed out for SHA256SUMS'
run_archive_update tampered
assert_refused 'a tampered but valid ZIP' 'Checksum mismatch for Cortado-source.zip'
assert_archive_staged_in_tmpdir 'a refused archive'
assert_empty 'a checksum mismatch stops before extraction' "$(cat "$unzip_log")"
run_archive_update missing-manifest
assert_refused 'a release without SHA256SUMS' 'Could not download SHA256SUMS'
assert_not_contains 'a missing manifest stops before the archive request' "$archive_name" "$(cat "$request_log")"
run_archive_update manifest-http-error
assert_refused 'a failed checksum transfer with valid-looking bytes' 'Could not download SHA256SUMS'
assert_not_contains 'a failed checksum transfer stops before the archive request' "$archive_name" "$(cat "$request_log")"
run_archive_update no-entry
assert_refused 'a manifest without the archive entry' 'SHA256SUMS must contain one valid checksum for Cortado-source.zip'
assert_not_contains 'a manifest without the archive entry stops before the archive request' "$archive_name" "$(cat "$request_log")"
run_archive_update null-hash
assert_refused 'a null hash' 'SHA256SUMS must contain one valid checksum for Cortado-source.zip'
run_archive_update zero-hash
assert_refused 'a zero hash' 'SHA256SUMS must contain one valid checksum for Cortado-source.zip'
run_archive_update nonhex-hash
assert_refused 'a 64-character nonhex hash' 'SHA256SUMS must contain one valid checksum for Cortado-source.zip'
run_archive_update extra-field
assert_refused 'an archive entry with extra fields' 'SHA256SUMS must contain one valid checksum for Cortado-source.zip'
run_archive_update duplicate
assert_refused 'duplicate archive entries' 'SHA256SUMS must contain one valid checksum for Cortado-source.zip'
run_archive_update http-error
assert_refused 'a failed archive transfer with valid-looking bytes' 'Could not download Cortado-source.zip'
run_archive_update bad-zip
assert_refused 'a matching checksum with invalid ZIP bytes' 'Downloaded file is not a valid ZIP archive'
run_archive_update wrong-version
assert_refused 'a verified ZIP with a mismatched version' 'Archive VERSION (0) does not match release'
run_archive_update missing-files
assert_refused 'a verified ZIP without the runtime script' 'Downloaded archive is missing essential files'
run_archive_update missing-version
assert_refused 'a verified ZIP without VERSION' 'Downloaded archive is missing essential files'
run_archive_update no-temp
assert_refused 'an unavailable temporary directory' 'Could not create a temporary directory for the update'
assert_not_contains 'an unavailable temporary directory stops before downloads' '/releases/download/' "$(cat "$request_log")"

mkdir "$TEST_BASE/no-hash"
for tool in awk cat cp dirname jq mktemp rm sed tail tr; do
    ln -s "$(command -v "$tool")" "$TEST_BASE/no-hash/$tool"
done
UPDATE_PATH="$TEST_BASE/no-hash" run_archive_update valid
assert_refused 'an unavailable checksum tool' 'Could not compute SHA-256 for Cortado-source.zip'
if command -v shasum >/dev/null; then
    ln -s "$(command -v shasum)" "$TEST_BASE/no-hash/shasum"
    UPDATE_PATH="$TEST_BASE/no-hash" run_archive_update binary-entry
    assert_archived_release 'an uppercase binary entry with shasum alone' "$fixture_version"
    rm "$TEST_BASE/no-hash/shasum"
fi
if command -v sha256sum >/dev/null; then
    ln -s "$(command -v sha256sum)" "$TEST_BASE/no-hash/sha256sum"
    UPDATE_PATH="$TEST_BASE/no-hash" run_archive_update binary-entry
    assert_eq 'sha256sum verifies an uppercase binary-mode entry when shasum is absent' 0 "$update_status"
    assert_file_contains 'the sha256sum fallback installs the checked bytes' 'verified fixture' "$update_sandbox/source/cortado.sh"
fi

mkdir "$TEST_BASE/failing-hash"
cat > "$TEST_BASE/failing-hash/shasum" <<'STUB'
#!/bin/bash
# A tool can emit a matching digest and still fail.
cat "$RELEASE_ASSETS/SHA256SUMS"
exit 1
STUB
chmod +x "$TEST_BASE/failing-hash/shasum"
UPDATE_PATH="$TEST_BASE/failing-hash:$PATH" run_archive_update valid
assert_refused 'a checksum tool that fails after printing a digest' 'Could not compute SHA-256 for Cortado-source.zip'

run_archive_update partial-copy
assert_eq 'a partial source copy exits unsuccessfully' 1 "$update_status"
assert_contains 'a partial source copy diagnoses the copy failure' 'Could not copy the release' "$update_output"
assert_not_contains 'a partial source copy does not announce an update' 'Updated to version' "$update_output"
assert_rc 'a partial source copy leaves the source version eligible for retry' 0 \
    cmp "$update_sandbox/source.before/VERSION" "$update_sandbox/source/VERSION"
assert_empty 'a failed source copy removes staging' "$(ls -A "$update_sandbox/tmp")"

assert_eq 'a partial source copy keeps one completed recovery backup' 1 \
    "$(find "$update_sandbox" -maxdepth 1 -name 'source.backup.*' | awk 'END {print NR}')"
assert_rc 'the recovery backup of a partial source copy holds the original source' 0 \
    diff -r "$update_sandbox/source.before" "$(find "$update_sandbox" -maxdepth 1 -name 'source.backup.*')"

run_archive_update interrupted
assert_eq 'TERM during a release download preserves the signal status' 143 "$update_status"
assert_empty 'TERM during a release download removes staging' "$(ls -A "$update_sandbox/tmp")"

assert_unwound() {
    local desc="$1" status="$2"
    assert_eq "$desc exits $status" "$status" "$update_status"
    assert_empty "$desc removes staging" "$(ls -A "$update_sandbox/tmp")"
    assert_empty "$desc leaves no partial source backup" \
        "$(find "$update_sandbox" -maxdepth 1 -name 'source.backup.*')"
    assert_rc "$desc keeps the original source" 0 diff -r "$update_sandbox/source.before" "$update_sandbox/source"
    assert_not_contains "$desc never announces success" 'Updated to version' "$update_output"
}
run_archive_update staging-term
assert_unwound 'TERM while the staging directory is allocated' 143
run_archive_update backup-term
assert_unwound 'TERM during the source backup' 143
run_archive_update backup-fail
assert_unwound 'a failed source backup' 1
assert_contains 'a failed source backup explains the refusal' 'Could not back up the source' "$update_output"

run_archive_update copy-term
assert_eq 'TERM while copying the release into the source exits 143' 143 "$update_status"
assert_eq 'TERM while copying the release into the source keeps the completed backup' 1 \
    "$(find "$update_sandbox" -maxdepth 1 -name 'source.backup.*' | awk 'END {print NR}')"
assert_rc 'the backup kept after TERM during the release copy holds the original source' 0 \
    diff -r "$update_sandbox/source.before" "$(find "$update_sandbox" -maxdepth 1 -name 'source.backup.*')"
assert_empty 'TERM while copying the release into the source removes staging' "$(ls -A "$update_sandbox/tmp")"

# TERM part-way through removing the finished source backup, once.
mkdir "$TEST_BASE/rm-term" || exit 1
cat > "$TEST_BASE/rm-term/rm" <<'STUB'
#!/bin/bash
for last in "$@"; do :; done
case "$last" in
    */source.backup.*)
        if [ ! -e "$RM_TERM_MARK" ]; then
            : > "$RM_TERM_MARK"
            /bin/rm -f "$last/VERSION"
            kill -TERM "$INSTALLER_PID"
            exit 143
        fi
        ;;
esac
exec /bin/rm "$@"
STUB
chmod +x "$TEST_BASE/rm-term/rm"
export RM_TERM_MARK="$TEST_BASE/rm-term.mark"
UPDATE_PATH="$TEST_BASE/rm-term:$PATH" run_archive_update valid
assert_eq 'TERM while removing the finished source backup exits 143' 143 "$update_status"
assert_empty 'TERM while removing the finished source backup leaves no partial backup' \
    "$(find "$update_sandbox" -maxdepth 1 -name 'source.backup.*')"
assert_empty 'TERM while removing the finished source backup removes staging' "$(ls -A "$update_sandbox/tmp")"

for scenario in managed managed-stale managed-obsolete; do
    run_archive_update "$scenario"
    assert_eq "explicit update succeeds for $scenario" 0 "$update_status"
    assert_rc "explicit update refreshes the active runtime for $scenario" 0 \
        cmp "$fixture/expected-runtime" "$update_sandbox/config/cortado/cortado.sh"
    assert_eq "explicit update refreshes the active version for $scenario" "$fixture_version" \
        "$(cat "$update_sandbox/config/cortado/VERSION")"
    assert_rc "explicit update preserves settings for $scenario" 0 \
        cmp "$update_sandbox/config.before/settings.json" "$update_sandbox/config/settings.json"
    assert_rc "explicit update preserves the generated config for $scenario" 0 \
        cmp "$update_sandbox/config.before/cortado/cortado.conf" "$update_sandbox/config/cortado/cortado.conf"
    assert_eq "explicit update installs exactly the release modules for $scenario" model.sh \
        "$(ls "$update_sandbox/config/cortado/modules" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
done

caller_umask=$(umask)
umask 002
run_archive_update managed
umask "$caller_umask"
assert_eq 'a refresh under umask 002 succeeds' 0 "$update_status"
for path in "$update_sandbox/config/cortado" "$update_sandbox/config/cortado/modules" \
    "$update_sandbox/config/cortado/lib" "$update_sandbox/config/cortado/cortado.sh" \
    "$update_sandbox/config/cortado/VERSION" "$update_sandbox/config/cortado/modules/model.sh" \
    "$update_sandbox/config/cortado/lib/config-tui.sh"; do
    mode=$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")
    if [ -n "$mode" ] && (( (8#$mode & 8#022) == 0 )); then
        pass "a refresh under umask 002 publishes ${path##*/config/} without group or other write"
    else
        fail "a refresh under umask 002 publishes ${path##*/config/} without group or other write ($mode)"
    fi
done
assert_eq 'a refresh keeps the generated config owner-only' 600 \
    "$(stat -f '%Lp' "$update_sandbox/config/cortado/cortado.conf" 2>/dev/null ||
        stat -c '%a' "$update_sandbox/config/cortado/cortado.conf")"

run_archive_update managed --check
assert_eq 'an update accepted from --check exits 0' 0 "$update_status"
assert_rc 'an update accepted from --check publishes the release runtime' 0 \
    cmp "$fixture/expected-runtime" "$update_sandbox/config/cortado/cortado.sh"
assert_eq 'an update accepted from --check publishes the release VERSION' "$fixture_version" \
    "$(cat "$update_sandbox/config/cortado/VERSION")"
assert_rc 'an update accepted from --check keeps settings byte-identical' 0 \
    cmp "$update_sandbox/config.before/settings.json" "$update_sandbox/config/settings.json"
assert_rc 'an update accepted from --check keeps the generated config' 0 \
    cmp "$update_sandbox/config.before/cortado/cortado.conf" "$update_sandbox/config/cortado/cortado.conf"
UPDATE_REPLY=n run_archive_update managed --check
assert_eq 'an update declined at --check exits 0' 0 "$update_status"
assert_rc 'an update declined at --check changes no source file' 0 \
    diff -r "$update_sandbox/source.before" "$update_sandbox/source"
assert_rc 'an update declined at --check leaves the installed runtime and settings' 0 \
    diff -r "$update_sandbox/config.before" "$update_sandbox/config"

run_archive_update binary-entry
assert_archived_release 'a verified uppercase binary entry' "$fixture_version"

for version in 99.0.0 99.0.0-rc1 "$fixture_version"; do
    run_archive_update valid --update "$version"
    assert_archived_release "verified release v$version" "$version"
done
assert_archive_staged_in_tmpdir 'a successful update'
assert_contains 'a verified release restarts with the original flags' \
    'Restarted installer with --update --no-color --no-emoji' "$update_output"
assert_match 'release lookup ignores curlrc overrides' '^-q .*api\.github\.com' "$(head -1 "$request_log")"
for asset in SHA256SUMS "$archive_name"; do
    request=$(grep -F "/$asset" "$request_log")
    assert_match "$asset ignores curlrc and rejects HTTP errors" '^-q -fsL ' "$request"
    assert_contains "$asset restricts downloads to HTTPS" '--proto =https' "$request"
    assert_contains "$asset restricts redirects to HTTPS" '--proto-redir =https' "$request"
    assert_contains "$asset limits redirects" '--max-redirs 3' "$request"
    assert_contains "$asset enforces a connection deadline" '--connect-timeout 5' "$request"
    assert_contains "$asset enforces a transfer deadline" '--max-time 60' "$request"
done

run_archive_update tampered --check
assert_refused 'a failed update accepted from --check' 'Checksum mismatch for Cortado-source.zip'
run_archive_update tampered interactive
assert_refused 'a failed update accepted at installer startup' 'Checksum mismatch for Cortado-source.zip'
run_archive_update tampered --defaults
assert_refused 'a failed update accepted before a default install' 'Checksum mismatch for Cortado-source.zip'

# Exercise the real interactive prompt with controlled API responses and no install.
partial_release="{\"tag_name\":\"v$fixture_version\"}"
for body in '{}' '{"tag_name":null}' '{"tag_name":0}' '{"tag_name":"v9.9.9invalid"}' "$partial_release"; do
    release_status=0
    [ "$body" = "$partial_release" ] && release_status=28
    sandbox=$(mktemp -d "$TEST_BASE/interactive.XXXXXX") || exit 1
    output=$(printf '\nn\n' |
        CLAUDE_CONFIG_DIR="$sandbox" CACHE_DIR="$sandbox/cortado-cache" \
        PATH="$TEST_BASE/bin:$PATH" REQUEST_LOG="$sandbox/requests" RELEASE_BODY="$body" \
        RELEASE_STATUS="$release_status" \
        /bin/bash -c '. "$1"; USE_COLOR=false; USE_EMOJI=false; setup_colors; interactive_update_check' \
        -- "$REPO_ROOT/install.sh" 2>&1)
    assert_contains "interactive lookup reports an unavailable release ($body, curl exit $release_status)" \
        'Could not check for updates' "$output"
    assert_not_contains "interactive lookup offers no update ($body)" 'Available:' "$output"
done

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
