#!/bin/bash
# Behavioral tests for bounded and verified release archive updates, with no network.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented

fixture_version=99.99.99
fixture_tag="v$fixture_version+fixture"
archive_name=Cortado-source.zip
fixture="$TEST_BASE/fixture"
mkdir -p "$fixture/Cortado-$fixture_version" "$TEST_BASE/bin" || exit 1
printf '%s\n' "$fixture_version" > "$fixture/Cortado-$fixture_version/VERSION"
printf '%s\n' 'verified fixture' > "$fixture/Cortado-$fixture_version/cortado.sh"
cat > "$fixture/Cortado-$fixture_version/install.sh" <<'STUB'
#!/bin/bash
printf 'Restarted installer with %s\n' "$*"
STUB
chmod +x "$fixture/Cortado-$fixture_version/install.sh"
fixture_checksum() {
    local result
    if command -v sha256sum >/dev/null; then
        result=$(sha256sum < "$fixture/$1") || return 1
    else
        result=$(shasum -a 256 < "$fixture/$1") || return 1
    fi
    printf '%s  %s\n' "${result%% *}" "$archive_name"
}
(cd "$fixture" && zip -qr "$archive_name" "Cortado-$fixture_version") || exit 1
fixture_checksum "$archive_name" > "$fixture/SHA256SUMS" || exit 1
printf '%s\n' 'tampered fixture' > "$fixture/Cortado-$fixture_version/cortado.sh"
(cd "$fixture" && zip -qr tampered.zip "Cortado-$fixture_version") || exit 1
printf '%s\n' 'not a ZIP' > "$fixture/bad-zip"
fixture_checksum bad-zip > "$fixture/bad-zip.sums" || exit 1
printf '%s\n' '0' > "$fixture/Cortado-$fixture_version/VERSION"
(cd "$fixture" && zip -qr wrong-version.zip "Cortado-$fixture_version") || exit 1
fixture_checksum wrong-version.zip > "$fixture/wrong-version.sums" || exit 1
rm "$fixture/Cortado-$fixture_version/cortado.sh"
(cd "$fixture" && zip -qr missing-files.zip "Cortado-$fixture_version") || exit 1
fixture_checksum missing-files.zip > "$fixture/missing-files.sums" || exit 1

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
            manifest-stall) sleep 0.01; exit 28 ;;
            missing-manifest) printf '%s\n' 'HTTP 404' > "$output"; exit 22 ;;
            manifest-http-error) cp "$FIXTURE/SHA256SUMS" "$output"; exit 22 ;;
            bad-zip|wrong-version|missing-files) cp "$FIXTURE/$DOWNLOAD_CASE.sums" "$output" ;;
            no-entry) sed 's/Cortado-source.zip/unrelated.zip/' "$FIXTURE/SHA256SUMS" > "$output" ;;
            null-hash) printf '%s  Cortado-source.zip\n' null > "$output" ;;
            zero-hash) printf '%s  Cortado-source.zip\n' 0 > "$output" ;;
            nonhex-hash) printf '%064d  Cortado-source.zip\n' 0 | tr 0 z > "$output" ;;
            extra-field) sed 's/$/ extra/' "$FIXTURE/SHA256SUMS" > "$output" ;;
            duplicate) cat "$FIXTURE/SHA256SUMS" "$FIXTURE/SHA256SUMS" > "$output" ;;
            binary-entry) tr 'a-f' 'A-F' < "$FIXTURE/SHA256SUMS" | sed 's/  .*/ *Cortado-source.zip/' > "$output" ;;
            *) cp "$FIXTURE/SHA256SUMS" "$output" ;;
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
            http-error) cp "$FIXTURE/Cortado-source.zip" "$output"; exit 22 ;;
            tampered|wrong-version|missing-files) cp "$FIXTURE/$DOWNLOAD_CASE.zip" "$output" ;;
            bad-zip) cp "$FIXTURE/bad-zip" "$output" ;;
            *) cp "$FIXTURE/Cortado-source.zip" "$output" ;;
        esac
        ;;
    *) exit 7 ;;
esac
STUB
unzip_bin=$(command -v unzip) || exit 1
cat > "$TEST_BASE/bin/unzip" <<'STUB'
#!/bin/bash
printf '%s\n' 'unzip' >> "$UNZIP_LOG"
exec "$UNZIP_BIN" "$@"
STUB
chmod +x "$TEST_BASE/bin/curl" "$TEST_BASE/bin/unzip"

run_archive_update() {
    local download_case="$1" flag="${2:---update}" sandbox
    sandbox=$(mktemp -d "$TEST_BASE/update.XXXXXX") || exit 1
    mkdir -p "$sandbox/source" "$sandbox/config/cortado" "$sandbox/tmp"
    cp "$REPO_ROOT/install.sh" "$REPO_ROOT/VERSION" "$sandbox/source/"
    printf '%s\n' 'installed fixture' > "$sandbox/config/cortado/cortado.sh"
    printf '%s\n' '{"statusLine":{"type":"command","command":"fixture"}}' > "$sandbox/config/settings.json"
    chmod 600 "$sandbox/config/settings.json"
    cp -R "$sandbox/source" "$sandbox/source.before"
    cp -R "$sandbox/config" "$sandbox/config.before"
    request_log="$sandbox/requests"
    : > "$request_log"
    unzip_log="$sandbox/unzip"
    : > "$unzip_log"
    local temp_parent="$sandbox/tmp" stub_path=""
    if [ "$download_case" = no-temp ]; then
        # BSD mktemp falls back to the system temp dir when TMPDIR is unusable,
        # so force the failure: only a bare `mktemp -d` (the update path) fails.
        stub_path="$sandbox/no-temp-bin"
        mkdir -p "$stub_path"
        cat > "$stub_path/mktemp" <<STUB
#!/bin/bash
if [ "\$#" -eq 1 ] && [ "\$1" = -d ]; then exit 1; fi
exec "$(command -v mktemp)" "\$@"
STUB
        chmod +x "$stub_path/mktemp"
    fi
    local args=(--no-color --no-emoji)
    [ "$flag" != interactive ] && args=("$flag" "${args[@]}")
    update_output=$(printf '\n\n' |
        CLAUDE_CONFIG_DIR="$sandbox/config" CACHE_DIR="$sandbox/config/cortado-cache" TMPDIR="$temp_parent" \
        PATH="${stub_path:+$stub_path:}$TEST_BASE/bin:${UPDATE_PATH:-$PATH}" FIXTURE="$fixture" REQUEST_LOG="$request_log" \
        UNZIP_BIN="$unzip_bin" UNZIP_LOG="$unzip_log" \
        RELEASE_BODY="{\"tag_name\":\"$fixture_tag\"}" DOWNLOAD_CASE="$download_case" \
        /bin/bash "$sandbox/source/install.sh" "${args[@]}" 2>&1)
    update_status=$?
    update_sandbox="$sandbox"
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
assert_empty 'a checksum mismatch stops before extraction' "$(cat "$unzip_log")"
run_archive_update missing-manifest
assert_refused 'a release without SHA256SUMS' 'Could not download SHA256SUMS'
assert_not_contains 'a missing manifest stops before the archive request' "$archive_name" "$(cat "$request_log")"
run_archive_update manifest-http-error
assert_refused 'a failed checksum transfer with valid-looking bytes' 'Could not download SHA256SUMS'
assert_not_contains 'a failed checksum transfer stops before the archive request' "$archive_name" "$(cat "$request_log")"
run_archive_update no-entry
assert_refused 'a manifest without the archive entry' 'SHA256SUMS must contain one valid checksum for Cortado-source.zip'
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
run_archive_update no-temp
assert_refused 'an unavailable temporary directory' 'Could not create a temporary directory for the update'
assert_not_contains 'an unavailable temporary directory stops before downloads' '/releases/download/' "$(cat "$request_log")"

mkdir "$TEST_BASE/no-hash"
for tool in awk cat cp dirname jq mktemp rm sed tail tr; do
    ln -s "$(command -v "$tool")" "$TEST_BASE/no-hash/$tool"
done
UPDATE_PATH="$TEST_BASE/no-hash" run_archive_update valid
assert_refused 'an unavailable checksum tool' 'Could not compute SHA-256 for Cortado-source.zip'
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
cat "$FIXTURE/SHA256SUMS"
exit 1
STUB
chmod +x "$TEST_BASE/failing-hash/shasum"
UPDATE_PATH="$TEST_BASE/failing-hash:$PATH" run_archive_update valid
assert_refused 'a checksum tool that fails after printing a digest' 'Could not compute SHA-256 for Cortado-source.zip'

run_archive_update valid
assert_eq 'a verified release exits 0' 0 "$update_status"
assert_contains 'a verified release restarts with the original flags' \
    'Restarted installer with --update --no-color --no-emoji' "$update_output"
assert_file_contains 'a verified release installs the checked bytes' 'verified fixture' "$update_sandbox/source/cortado.sh"
assert_match 'release lookup ignores curlrc overrides' '^-q .*api\.github\.com' "$(head -1 "$request_log")"
for asset in SHA256SUMS "$archive_name"; do
    request=$(grep -F "/$asset" "$request_log")
    assert_contains "$asset comes from the exact release tag" "/releases/download/$fixture_tag/$asset" "$request"
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
partial_release="{\"tag_name\":\"$fixture_tag\"}"
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
