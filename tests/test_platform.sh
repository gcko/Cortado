#!/bin/bash
# ABOUTME: One place decides the platform (CORTADO_OS), and modules run only where they declare.
# ABOUTME: Run with: bash tests/test_platform.sh
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" battery

cat > "$TEST_BASE/bin/pmset" <<'STUB'
#!/bin/bash
[ "$*" = "-g batt" ] || exit 2
printf "Now drawing from 'AC Power'\n -InternalBattery-0 64%%; charging\n"
STUB
chmod +x "$TEST_BASE/bin/pmset"

case "${BASH_VERSINFO[5]}" in
    *-darwin*) host_os=darwin ;;
    *-linux*) host_os=linux ;;
    *) host_os= ;;
esac

payload='{"model":{"display_name":"Opus"},"cwd":"/nonexistent"}'
order='MODULE_ORDER="sandbox,model,battery"'
mac_line='SANDBOX | MODEL: Opus | BAT: 64% ⚡'
export APP_SANDBOX_CONTAINER_ID=platform-test

echo "=== no module asks uname ==="
uname_calls=$(cd "$PROJECT_ROOT" && grep -nw uname cortado.sh modules/*.sh lib/*.sh)
assert_empty 'cortado.sh, modules and lib never call uname' "$uname_calls"

echo "=== a forced platform decides which modules run ==="
check_render 'forced darwin runs the macOS-only modules' "$mac_line" - "$payload" "$order" 'CORTADO_OS=darwin'
check_render 'forced linux leaves out the macOS-only battery and sandbox' 'MODEL: Opus' - "$payload" "$order" \
    'CORTADO_OS=linux'
assert_eq 'the environment can force linux too' 'MODEL: Opus' \
    "$(CORTADO_OS=linux render - "$payload" "$order")"

project=$(mktemp -d "$TEST_BASE/project.XXXXXX") || exit 1
printf '%s\n' 'CORTADO_OS=linux' > "$project/.cortado.conf"
project_payload=$(jq -cn --arg cwd "$project" '{model: {display_name: "Opus"}, workspace: {current_dir: $cwd}}')
check_render 'an untrusted project config cannot change the platform' "$mac_line" - "$project_payload" "$order" \
    'CORTADO_OS=darwin'

echo "=== an unsupported value is never treated as Linux ==="
case "$host_os" in
    darwin) host_line="$mac_line" ;;
    *) host_line='MODEL: Opus' ;;
esac
check_render 'an unsupported forced value falls back to the detected platform' "$host_line" - "$payload" "$order" \
    'CORTADO_OS=msys'
check_render 'a capitalised platform name is not a supported value either' "$host_line" - "$payload" "$order" \
    'CORTADO_OS=Linux'

log_render() (
    local sb
    sb=$(mktemp -d "$TEST_BASE/log.XXXXXX") || exit 1
    printf '%s\n' "$order" 'COLOR_THEME="monochrome"' 'DEBUG_MODE=true' 'CORTADO_OS=msys' > "$sb/cortado.conf"
    chmod 600 "$sb/cortado.conf"
    printf '%s' "$payload" | PATH="$TEST_BASE/bin:$PATH" CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" \
        /bin/bash "$PROJECT_ROOT/cortado.sh" >/dev/null 2>&1
    cat "$sb/cortado.log" 2>/dev/null
)
assert_contains 'debug mode names the refused value and the platform used' \
    "CORTADO_OS=msys is not a supported platform; using ${host_os:-none}" "$(log_render)"

# The host hook is Bash, so these renders opt the user config in (#33).
unsupported_host='cortado_host_os() { REPLY=; }'
CORTADO_CONF_ALLOW_BASH=1 check_render 'an unsupported host states it instead of running Linux code' 'cortado: unsupported platform' - \
    "$payload" "$order" "$unsupported_host"
CORTADO_CONF_ALLOW_BASH=1 check_render 'an unsupported host can opt into the Linux modules explicitly' 'MODEL: Opus' - \
    "$payload" "$order" "$unsupported_host" 'CORTADO_OS=linux'

echo "=== host triples map to the two supported platforms ==="
# shellcheck source=lib/platform.sh
. "$PROJECT_ROOT/lib/platform.sh"
triple_os() { cortado_os_from_triple "$1"; printf '%s' "$REPLY"; }
assert_eq 'Intel macOS is darwin' darwin "$(triple_os x86_64-apple-darwin23.6.0)"
assert_eq 'Apple silicon macOS is darwin' darwin "$(triple_os aarch64-apple-darwin24.0.0)"
assert_eq 'glibc Linux (and WSL) is linux' linux "$(triple_os x86_64-pc-linux-gnu)"
assert_eq 'musl Linux is linux' linux "$(triple_os aarch64-unknown-linux-musl)"
assert_empty 'Git Bash (MSYS) is unsupported' "$(triple_os x86_64-pc-msys)"
assert_empty 'Cygwin is unsupported' "$(triple_os x86_64-unknown-cygwin)"
assert_empty 'FreeBSD is unsupported' "$(triple_os amd64-portbld-freebsd14.0)"
assert_empty 'an empty triple is unsupported' "$(triple_os '')"

resolved() (
    unset CORTADO_OS CORTADO_OS_REFUSED
    if [ "$#" -gt 0 ]; then CORTADO_OS="$1"; fi
    cortado_resolve_os
    printf '%s|%s' "${CORTADO_OS-unset}" "${CORTADO_OS_REFUSED:-}"
)
assert_eq 'an unset value resolves to the host' "$host_os|" "$(resolved)"
assert_eq 'an empty value resolves to the host' "$host_os|" "$(resolved '')"
assert_eq 'a forced darwin is kept' 'darwin|' "$(resolved darwin)"
assert_eq 'a forced linux is kept' 'linux|' "$(resolved linux)"
assert_eq 'a forced wsl is refused and falls back' "$host_os|wsl" "$(resolved wsl)"

# A module sourced with utils.sh alone (no cortado.sh) must still know the host.
# shellcheck disable=SC2016
standalone_os() { env -u CORTADO_OS ${1:+CORTADO_OS="$1"} /bin/bash -c '. "$1/modules/utils.sh"; printf %s "${CORTADO_OS-unset}"' _ "$PROJECT_ROOT"; }
assert_eq 'utils.sh on its own resolves the host platform' "$host_os" "$(standalone_os)"
assert_eq 'utils.sh on its own keeps a forced linux' linux "$(standalone_os linux)"

echo "=== BSD and GNU helpers follow the host, not a forced platform ==="
probe="$TEST_BASE/probe"
: > "$probe"
chmod 640 "$probe"
TZ=UTC touch -t 202001010000 "$probe"
for forced in darwin linux; do
    assert_eq "file mtime reads with CORTADO_OS=$forced" 1577836800 "$(CORTADO_OS=$forced _file_mtime "$probe")"
    assert_eq "file mode reads with CORTADO_OS=$forced" 640 "$(CORTADO_OS=$forced cortado_file_mode "$probe")"
done
assert_eq 'a missing file has mtime 0' 0 "$(_file_mtime "$TEST_BASE/missing")"
assert_rc 'a missing file has no mode' 1 cortado_file_mode "$TEST_BASE/missing"
mkdir "$TEST_BASE/statbin"
printf '#!/bin/sh\nprintf "bogus\\n"\n' > "$TEST_BASE/statbin/stat"
chmod 700 "$TEST_BASE/statbin/stat"
if [ "$host_os" = darwin ]; then
    assert_eq 'a stat earlier in PATH cannot shadow BSD stat for the mode' 640 \
        "$(PATH="$TEST_BASE/statbin:$PATH" cortado_file_mode "$probe")"
    assert_eq 'a stat earlier in PATH cannot shadow BSD stat for the mtime' 1577836800 \
        "$(PATH="$TEST_BASE/statbin:$PATH" _file_mtime "$probe")"
else
    # shellcheck disable=SC2016
    assert_rc 'a non-octal mode from stat is refused' 1 \
        env PATH="$TEST_BASE/statbin:$PATH" /bin/bash -c '. "$1"; cortado_file_mode "$2"' _ \
        "$PROJECT_ROOT/lib/platform.sh" "$probe"
fi
assert_eq 'a UTC timestamp converts to epoch seconds' 1767225600 "$(cortado_utc_epoch 2026-01-01T00:00:00)"
assert_eq 'an unparsable timestamp converts to 0' 0 "$(cortado_utc_epoch not-a-time)"

echo "=== an install missing utils.sh still reads file times through lib/platform.sh ==="
partial="$TEST_BASE/partial"
mkdir "$partial"
cp "$PROJECT_ROOT/cortado.sh" "$PROJECT_ROOT/cortado.conf" "$partial/"
cp -R "$PROJECT_ROOT/modules" "$PROJECT_ROOT/lib" "$partial/"
rm "$partial/modules/utils.sh"
printf '%s\n' '# @cortado-module probe' '# @default true' '# @platforms darwin,linux' \
    "module_probe() { printf 'mtime=%s\\n' \"\$(_file_mtime '$probe')\"; }" > "$partial/modules/probe.sh"
partial_cfg=$(mktemp -d "$TEST_BASE/partial-cfg.XXXXXX") || exit 1
chmod 700 "$partial_cfg"
printf '%s\n' 'MODULE_ORDER="probe"' > "$partial_cfg/cortado.conf"
chmod 600 "$partial_cfg/cortado.conf"
assert_eq 'a missing utils.sh does not stub the mtime helper to 0' 'mtime=1577836800' \
    "$(printf '{}' | CLAUDE_CONFIG_DIR="$partial_cfg" CACHE_DIR="$partial_cfg/cortado-cache" /bin/bash "$partial/cortado.sh" 2>/dev/null)"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
