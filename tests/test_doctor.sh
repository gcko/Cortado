#!/bin/bash
# ABOUTME: cortado doctor: breaks each check on purpose (jq, Perl, settings.json, the
# ABOUTME: statusLine command, config trust, platform, log, PATH) and asserts the report line,
# ABOUTME: the fix command and the exit code; proves it changes no file and makes no network call.
# ABOUTME: Run with: /bin/bash tests/test_doctor.sh

# shellcheck disable=SC2016,SC2088 # Literal $HOME and ~ in settings.json text are the point.
umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented

TEST_BASE=$(mktemp -d) || exit 1
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1
trap 'chmod -R u+w "$TEST_BASE" 2>/dev/null; rm -rf "$TEST_BASE"' EXIT

# A private copy of the tree: the checkout's own permissions (a group-writable
# parent on CI, say) must not decide whether its packaged config is trusted.
COPY="$TEST_BASE/copy"
mkdir -p "$COPY" || exit 1
for item in cortado.sh cortado.conf VERSION lib modules; do
    cp -R "$REPO_ROOT/$item" "$COPY/" || exit 1
done
chmod 600 "$COPY/cortado.conf"
chmod 755 "$COPY/cortado.sh"

# Tool directories: the real jq, perl and bc, found before PATH is narrowed.
JQ_BIN=$(command -v jq) || { echo "jq is required to run this suite"; exit 1; }
PERL_BIN=$(command -v perl) || { echo "perl is required to run this suite"; exit 1; }
BC_BIN=$(command -v bc || true)

# A PATH of only the tools Cortado and the doctor need, so a test can leave one out.
TOOLS="$TEST_BASE/tools"
mkdir -p "$TOOLS" || exit 1
for tool in cat ls stat readlink date mktemp rm tr tail head id mkdir dirname basename sed \
    grep wc cp uname sort cut env mv chmod find sleep ln sh bash awk getconf cksum touch tee dd mkfifo \
    uniq hostname df ps; do
    path=$(command -v "$tool") || continue
    ln -sf "$path" "$TOOLS/$tool"
done
SHIMS="$TEST_BASE/shims"
mkdir -p "$SHIMS" || exit 1
for tool in curl wget; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 1\n' "$tool" "$TEST_BASE/network-calls" > "$SHIMS/$tool"
    chmod 755 "$SHIMS/$tool"
done
: > "$TEST_BASE/network-calls"

# new_case: fresh HOME, Claude config dir, project dir, bin dir and TMPDIR.
new_case() {
    root=$(mktemp -d "$TEST_BASE/case.XXXXXX") || exit 1
    home="$root/home"
    cfg="$root/claude config"
    proj="$root/project"
    bin="$root/bin"
    tmp="$root/tmp"
    unset DOCTOR_PATH DOCTOR_ENV
    mkdir -p "$home/.local/bin" "$proj" "$bin" "$tmp" || exit 1
    mkdir -m 700 "$cfg" || exit 1
    settings="$cfg/settings.json"
    ln -s "$COPY/cortado.sh" "$bin/cortado"
}

quoted() { printf "'%s'" "$1"; }

# write_settings <command text>: a settings.json whose statusLine runs that text.
write_settings() {
    local text="$1"
    text=${text//\\/\\\\}
    text=${text//\"/\\\"}
    printf '{"theme":"dark","statusLine":{"type":"command","command":"%s"}}\n' "$text" > "$settings"
    chmod 600 "$settings"
}

healthy_settings() { write_settings "$(quoted "$COPY/cortado.sh")"; }

# doctor: run this copy's doctor in the sandbox. PATH is $DOCTOR_PATH.
doctor() {
    out=$(cd "$proj" && HOME="$home" CLAUDE_CONFIG_DIR="$cfg" TMPDIR="$tmp" LC_ALL=C \
        PATH="${DOCTOR_PATH:-$SHIMS:$bin:$TOOLS:$(dirname "$JQ_BIN"):$(dirname "$PERL_BIN")}" \
        ${DOCTOR_ENV:+env $DOCTOR_ENV} \
        /bin/bash "${DOCTOR_SCRIPT:-$COPY/cortado.sh}" doctor --no-color --no-emoji 2>&1 < /dev/null)
    status=$?
}

tools_path() {
    # A narrow PATH: the shims, the doctor's own bin dir and the plain tools, plus the named extras.
    local extra
    DOCTOR_PATH="$SHIMS:$bin:$TOOLS"
    for extra in "$@"; do DOCTOR_PATH="$DOCTOR_PATH:$extra"; done
}

# fresh_tool_dir <name...>: a directory holding links to the named real tools.
fresh_tool_dir() {
    local dir="$root/only" t
    mkdir -p "$dir"
    for t in "$@"; do
        case "$t" in
            jq) ln -sf "$JQ_BIN" "$dir/jq" ;;
            perl) ln -sf "$PERL_BIN" "$dir/perl" ;;
            bc) [ -z "$BC_BIN" ] || ln -sf "$BC_BIN" "$dir/bc" ;;
        esac
    done
    REPLY="$dir"
}

line_of() { printf '%s\n' "$out" | grep -E "$1" | head -1; }

# ---------------------------------------------------------------------------
echo "== a healthy install"
new_case
healthy_settings
doctor
assert_eq 'a healthy install exits 0' 0 "$status"
assert_match 'jq passes' '^ok +jq: found' "$out"
assert_match 'Perl passes' '^ok +perl: found' "$out"
assert_match 'bc is an info line' '^info +bc: (found|not found) \(optional' "$out"
assert_match 'settings.json passes' '^ok +settings\.json: found and valid JSON' "$out"
assert_match 'statusLine passes and names this copy' '^ok +statusLine: runs this copy' "$out"
assert_contains 'the statusLine line names the cortado.sh it found' "$COPY/cortado.sh" "$out"
assert_match 'the sample render passes' '^ok +render: this copy draws a sample statusline' "$out"
assert_match 'the packaged config is trusted' '^ok +packaged config: trusted' "$out"
assert_match 'a missing user config is not a failure' '^info +user config: none' "$out"
assert_match 'the platform is named' '^ok +platform: (darwin|linux)' "$out"
assert_match 'with no log the report says so' '^info +log: no log' "$out"
assert_match 'the cortado command is found on PATH' '^ok +cortado command: ' "$out"
assert_match 'the summary says all checks passed' '^All [0-9]+ checks passed\.$' "$out"
assert_not_contains 'a passing run prints no fix' 'fix:' "$out"
assert_eq 'it made no network request' '' "$(cat "$TEST_BASE/network-calls")"
assert_eq 'it left no temporary directory behind' '' "$(ls "$tmp")"
long=$(printf '%s\n' "$out" | grep -v '^ ' | grep -v '/' | LC_ALL=C awk 'length($0) > 80')
assert_eq 'report lines fit in 80 columns (paths are on their own indented lines)' '' "$long"

echo "== style flags"
doctor
assert_not_contains 'piped output has no color escapes' "$(printf '\033')" "$out"
out=$(cd "$proj" && HOME="$home" CLAUDE_CONFIG_DIR="$cfg" TMPDIR="$tmp" PATH="$SHIMS:$bin:$TOOLS:$(dirname "$JQ_BIN"):$(dirname "$PERL_BIN")" \
    /bin/bash "$COPY/cortado.sh" doctor 2>&1 < /dev/null)
assert_match 'with emoji, a pass is marked with a check mark' '^✓ +jq: found' "$out"
out=$(cd "$proj" && HOME="$home" CLAUDE_CONFIG_DIR="$cfg" TMPDIR="$tmp" PATH="$SHIMS:$bin:$TOOLS:$(dirname "$JQ_BIN"):$(dirname "$PERL_BIN")" \
    /bin/bash "$COPY/cortado.sh" doctor --no-emoji --no-color 2>&1 < /dev/null)
assert_match '--no-emoji marks a pass with words' '^ok +jq: found' "$out"
out=$(cd "$proj" && HOME="$home" CLAUDE_CONFIG_DIR="$cfg" PATH="$bin:$TOOLS:$(dirname "$JQ_BIN")" \
    /bin/bash "$COPY/cortado.sh" doctor --bogus 2>&1 < /dev/null)
assert_eq 'an unknown option exits 2' 2 "$?"
assert_contains 'an unknown option prints usage' 'Usage: cortado doctor' "$out"

# ---------------------------------------------------------------------------
echo "== jq, Perl and bc"
new_case; healthy_settings
fresh_tool_dir perl bc; tools_path "$REPLY"
doctor
assert_eq 'missing jq exits 1' 1 "$status"
assert_match 'missing jq is a FAIL line' '^FAIL +jq: not found' "$out"
assert_match 'missing jq comes with an install command' 'fix: (brew|sudo apt) install jq' "$out"
assert_match 'the summary counts the failures' '^[0-9]+ of [0-9]+ checks failed' "$out"

new_case; healthy_settings
fresh_tool_dir jq bc; tools_path "$REPLY"
doctor
assert_eq 'missing perl exits 1' 1 "$status"
assert_match 'missing perl is a FAIL line' '^FAIL +perl: not found' "$out"
assert_match 'missing perl comes with an install command' 'fix: (brew|sudo apt) install perl' "$out"

new_case; healthy_settings
fresh_tool_dir jq perl; tools_path "$REPLY"
doctor
assert_eq 'missing bc alone still exits 0' 0 "$status"
assert_match 'missing bc is an info line' '^info +bc: not found \(optional' "$out"

# ---------------------------------------------------------------------------
echo "== settings.json"
new_case
doctor
assert_eq 'no settings.json exits 1' 1 "$status"
assert_match 'a missing settings.json is a FAIL line' '^FAIL +settings\.json: not found' "$out"
assert_contains 'the fix is cortado setup' 'fix: cortado setup' "$out"
assert_match 'the statusLine is not judged without a settings.json' '^FAIL +statusLine: cannot check' "$out"

new_case
printf '{"statusLine": {oops\n' > "$settings"
doctor
assert_eq 'invalid settings.json exits 1' 1 "$status"
assert_match 'invalid JSON is a FAIL line' '^FAIL +settings\.json: does not parse' "$out"
assert_match 'invalid JSON says how to fix it' 'fix: .*settings\.json' "$out"

new_case
printf '[1,2]\n' > "$settings"
doctor
assert_eq 'a settings.json that is not an object exits 1' 1 "$status"
assert_match 'a non-object is a FAIL line' '^FAIL +settings\.json: does not parse' "$out"

new_case
printf '{"theme":"dark"}\n' > "$settings"
doctor
assert_eq 'no statusLine key exits 1' 1 "$status"
assert_match 'a missing statusLine is a FAIL line' '^FAIL +statusLine: not set' "$out"
assert_contains 'its fix is cortado setup' 'fix: cortado setup' "$out"

new_case
printf '{"statusLine":{"type":"static","text":"hi"}}\n' > "$settings"
doctor
assert_eq 'a statusLine that is not a command exits 1' 1 "$status"
assert_match 'a non-command statusLine is a FAIL line' '^FAIL +statusLine: is not a command' "$out"

# --- the command in settings.json is never run
new_case
write_settings "/no/such/dir/cortado.sh"
doctor
assert_eq 'a command that cannot be found exits 1' 1 "$status"
assert_match 'a missing cortado.sh is a FAIL line' '^FAIL +statusLine: .*/no/such/dir/cortado\.sh not found' "$out"

new_case
marker="$root/was-run"
write_settings "touch $(quoted "$marker") && /no/such/dir/cortado.sh"
doctor
assert_eq 'a command that starts with something else exits 1' 1 "$status"
assert_match 'a command that runs something else first is not a cortado.sh' '^FAIL +statusLine: does not run a cortado\.sh' "$out"
assert_eq 'the settings.json command was never executed' no "$([ -e "$marker" ] && echo yes || echo no)"

new_case
write_settings "echo hello"
doctor
assert_eq 'a command with no cortado.sh exits 1' 1 "$status"
assert_match 'a command that is not cortado is a FAIL line' '^FAIL +statusLine: does not run a cortado\.sh' "$out"
assert_contains 'the command text is shown' 'command: echo hello' "$out"

new_case
marker="$root/was-run"
write_settings "\$(touch $(quoted "$marker")) $(quoted "$COPY/cortado.sh")"
doctor
assert_eq 'a command with a substitution never runs it' no "$([ -e "$marker" ] && echo yes || echo no)"

new_case
cp -R "$COPY" "$root/dead"
chmod -x "$root/dead/cortado.sh"
write_settings "$(quoted "$root/dead/cortado.sh")"
doctor
assert_eq 'a cortado.sh that is not executable exits 1' 1 "$status"
assert_match 'it is a FAIL line' '^FAIL +statusLine: .*dead/cortado\.sh is not executable' "$out"
assert_contains 'its fix is chmod +x' "fix: chmod +x $(quoted "$root/dead/cortado.sh")" "$out"

new_case
write_settings "/bin/bash $(quoted "$root/dead/cortado.sh")"
cp -R "$COPY" "$root/dead"; chmod -x "$root/dead/cortado.sh"
doctor
assert_match 'an interpreter before the script does not need the executable bit' '^ok +statusLine: runs another copy' "$out"

new_case
mkdir -p "$root/half"; cp "$COPY/cortado.sh" "$root/half/"
write_settings "$(quoted "$root/half/cortado.sh")"
doctor
assert_eq 'an incomplete copy exits 1' 1 "$status"
assert_match 'an incomplete copy is a FAIL line' '^FAIL +statusLine: .*incomplete' "$out"

new_case
cp -R "$COPY" "$root/other"
write_settings "$(quoted "$root/other/cortado.sh")"
doctor
assert_eq 'another working copy is not a failure' 0 "$status"
assert_match 'it says another copy is configured' '^ok +statusLine: runs another copy' "$out"
assert_contains 'it also names this copy' "this copy: $COPY" "$out"

new_case
ln -s "$COPY" "$home/c"
write_settings '~/c/cortado.sh'
doctor
assert_eq 'a ~ path in settings.json is expanded without a shell' 0 "$status"
assert_match 'the expanded path is this copy' '^ok +statusLine: runs this copy' "$out"
write_settings '"$HOME/c/cortado.sh"'
doctor
assert_match '$HOME in settings.json is expanded without a shell' '^ok +statusLine: runs this copy' "$out"
write_settings "CLAUDE_CONFIG_DIR=/x $(quoted "$COPY/cortado.sh")"
doctor
assert_match 'a variable assignment before the script is skipped' '^ok +statusLine: runs this copy' "$out"

new_case
write_settings "$(quoted "$bin/cortado")"
doctor
assert_match 'a link to cortado.sh is this copy' '^ok +statusLine: runs this copy' "$out"

# --- the render proves this copy works
new_case; healthy_settings
mkdir -p "$root/nomods"; cp -R "$COPY/lib" "$COPY/cortado.sh" "$COPY/cortado.conf" "$COPY/VERSION" "$root/nomods/"
DOCTOR_SCRIPT="$root/nomods/cortado.sh" doctor
unset DOCTOR_SCRIPT
assert_eq 'a copy that cannot render exits 1' 1 "$status"
assert_match 'a failed render is a FAIL line' '^FAIL +render: ' "$out"

# ---------------------------------------------------------------------------
echo "== config trust"
new_case; healthy_settings
printf 'MODULE_TIME="true"\n' > "$cfg/cortado.conf"; chmod 666 "$cfg/cortado.conf"
doctor
assert_eq 'a group-writable user config exits 1' 1 "$status"
assert_match 'it is a FAIL line with the reason' '^FAIL +user config: refused \(file is group- or world-writable\)' "$out"
assert_contains 'the fix is chmod 600' "fix: chmod 600 $(quoted "$cfg/cortado.conf")" "$out"

chmod 600 "$cfg/cortado.conf"
doctor
assert_eq 'a private user config exits 0' 0 "$status"
assert_match 'a private user config is trusted' '^ok +user config: trusted' "$out"

new_case; healthy_settings
chmod 666 "$COPY/cortado.conf"
doctor
chmod 600 "$COPY/cortado.conf"
assert_eq 'a group-writable packaged config exits 1' 1 "$status"
assert_match 'the packaged config is a FAIL line' '^FAIL +packaged config: refused \(file is group- or world-writable\)' "$out"
assert_contains 'its fix is chmod 600' "fix: chmod 600 $(quoted "$COPY/cortado.conf")" "$out"

new_case; healthy_settings
mkdir "$root/wide"; chmod 777 "$root/wide"
printf 'MODULE_TIME="true"\n' > "$root/wide/real.conf"; chmod 600 "$root/wide/real.conf"
ln -s "$root/wide/real.conf" "$cfg/cortado.conf"
doctor
assert_eq 'a config linked into a shared directory exits 1' 1 "$status"
assert_match 'the parent is named as the problem' '^FAIL +user config: refused \(parent is group- or world-writable' "$out"
assert_contains 'the fix names the resolved parent' "fix: chmod go-w $(quoted "$root/wide")" "$out"

new_case; healthy_settings
printf 'MODULE_TIME="false"\n' > "$proj/.cortado.conf"
doctor
assert_match 'a project config is read as data' '^ok +project config: read as data' "$out"
assert_eq 'a project config does not change the exit code' 0 "$status"

new_case; healthy_settings
printf 'MODULE_TIME="false"\n' > "$cfg/barista.conf"; chmod 666 "$cfg/barista.conf"
doctor
assert_eq 'a group-writable Barista config exits 1' 1 "$status"
assert_match 'the legacy config is checked when it is the one Cortado would read' '^FAIL +user config \(barista\.conf.*: refused' "$out"

# ---------------------------------------------------------------------------
echo "== platform"
new_case; healthy_settings
DOCTOR_ENV="CORTADO_OS=plan9" doctor
assert_eq 'a forced unknown platform exits 1' 1 "$status"
assert_match 'a refused CORTADO_OS is a FAIL line' '^FAIL +platform: CORTADO_OS=plan9 is not darwin or linux' "$out"

new_case; healthy_settings
DOCTOR_ENV="CORTADO_OS=linux" doctor
assert_match 'a forced platform is reported as forced' '^(ok +platform: linux \(forced by CORTADO_OS\)|ok +platform: linux)' "$out"

# An unsupported host: the resolved platform is empty.
unsupported=$(cd "$COPY" && SCRIPT_DIR="$COPY" CLAUDE_CONFIG_DIR="$cfg" HOME="$home" PATH="$SHIMS:$TOOLS:$(dirname "$JQ_BIN"):$(dirname "$PERL_BIN")" \
    /bin/bash -c '
        . lib/config-permissions.sh; . lib/config-data.sh; . lib/platform.sh; . lib/doctor.sh
        cortado_host_os() { REPLY=; }
        _doctor_platform_report; printf "%s|%s\n" "$_DOCTOR_PLATFORM_OK" "$REPLY"
    ' 2>&1)
assert_match 'an unsupported host is reported as unsupported' '^0\|.*unsupported' "$unsupported"

# ---------------------------------------------------------------------------
echo "== cortado.log"
new_case; healthy_settings
for i in 1 2 3 4 5 6 7; do printf '[2026-11-27 10:00:0%s] git: error number %s\n' "$i" "$i"; done > "$cfg/cortado.log"
doctor
assert_match 'a log is reported' '^info +log: last 5 lines of cortado\.log' "$out"
assert_contains 'the newest line is shown' 'error number 7' "$out"
assert_not_contains 'older lines are left out' 'error number 2' "$out"
assert_eq 'a log never fails the check' 0 "$status"

new_case; healthy_settings
printf '[2026-11-27 09:00:00] older: from the previous file\n' > "$cfg/cortado.log.1"
printf '[2026-11-27 10:00:00] newer: from the current file\n' > "$cfg/cortado.log"
doctor
assert_contains 'the rotated log fills in older lines' 'from the previous file' "$out"
assert_contains 'the current log is shown' 'from the current file' "$out"

new_case; healthy_settings
printf '[t] odd: \033[31mred\033[0m and %s\n' "$(printf 'x%.0s' $(seq 1 200))" > "$cfg/cortado.log"
doctor
assert_not_contains 'control characters in the log are not printed raw' "$(printf '\033')" "$out"
long=$(printf '%s\n' "$out" | grep -v '/' | awk 'length($0) > 100')
assert_eq 'long log lines are cut' '' "$long"

# ---------------------------------------------------------------------------
echo "== the cortado command"
new_case; healthy_settings
rm "$bin/cortado"
doctor
assert_eq 'no cortado command exits 1' 1 "$status"
assert_match 'a missing command is a FAIL line' '^FAIL +cortado command: not on PATH' "$out"
assert_match 'its fix links it' "fix: mkdir -p .*\.local/bin.* && ln -s .*cortado\.sh.* .*\.local/bin/cortado" "$out"
new_case
rm "$bin/cortado"
doctor
assert_contains 'with no cortado on PATH, a fix names this copy by path' "fix: $(quoted "$COPY/cortado.sh") setup" "$out"

new_case; healthy_settings
rm "$bin/cortado"
ln -s "$COPY/cortado.sh" "$home/.local/bin/cortado"
doctor
assert_eq 'a command that is not on PATH exits 1' 1 "$status"
assert_contains 'the fix adds ~/.local/bin to PATH' 'export PATH="$HOME/.local/bin:$PATH"' "$out"

new_case; healthy_settings
cp -R "$COPY" "$root/other"
rm "$bin/cortado"; ln -s "$root/other/cortado.sh" "$bin/cortado"
doctor
assert_eq 'a cortado on PATH from another copy exits 0' 0 "$status"
assert_match 'the command is found' '^ok +cortado command: ' "$out"
assert_contains 'it says another copy is on PATH' 'another copy of cortado' "$out"

# ---------------------------------------------------------------------------
echo "== lines a config skips"
new_case; healthy_settings
printf 'MODULE_TIME=false\nfoo bar baz\n' > "$cfg/cortado.conf"; chmod 600 "$cfg/cortado.conf"
doctor
assert_eq 'a partly read user config exits 1' 1 "$status"
assert_match 'it is not reported as simply trusted' '^FAIL +user config: .*1 line skipped' "$out"
assert_contains 'the skipped line is named by number' 'line 2:' "$out"
assert_contains 'its fix lists the lines' 'fix: cortado config --migrate --dry-run' "$out"
assert_not_contains 'the config does not get an ok line' 'ok    user config' "$out"

new_case; healthy_settings
printf 'DEBUG_MODE=maybe\nMODULE_TIME=false\n$(touch x)\n' > "$cfg/cortado.conf"; chmod 600 "$cfg/cortado.conf"
doctor
assert_match 'a mistyped value and shell code are counted' '^FAIL +user config: .*2 lines skipped' "$out"

new_case; healthy_settings
printf 'NOT_A_CORTADO_SETTING=1\nMODULE_TIME=false\n' > "$cfg/cortado.conf"; chmod 600 "$cfg/cortado.conf"
doctor
assert_eq 'an unknown setting name does not change the render, so it does not fail' 0 "$status"
assert_match 'it is still trusted' '^ok +user config: trusted' "$out"

new_case; healthy_settings
printf 'MODULE_TIME=false\nfoo bar baz\n' > "$cfg/barista.conf"; chmod 600 "$cfg/barista.conf"
doctor
assert_match 'a partly read Barista config is reported too' '^FAIL +user config \(barista\.conf.*1 line skipped' "$out"

new_case; healthy_settings
marker="$root/was-run"
printf 'MODULE_ORDER=;;\n$(touch %s)\nMODULE_TIME=false\n' "$(quoted "$marker")" > "$proj/.cortado.conf"
doctor
assert_eq 'a partly read project config exits 1' 1 "$status"
assert_match 'the project config reports its skipped lines' '^FAIL +project config: .*2 lines skipped' "$out"
assert_contains 'its fix lists them for the project' 'fix: cortado config --migrate --dry-run --project' "$out"
assert_not_contains 'it is not called read as data' 'read as data' "$out"
assert_eq 'the project config was never run' no "$([ -e "$marker" ] && echo yes || echo no)"

new_case; healthy_settings
cp -R "$COPY" "$root/pkg"
printf 'foo bar baz\n' >> "$root/pkg/cortado.conf"
DOCTOR_SCRIPT="$root/pkg/cortado.sh" doctor
unset DOCTOR_SCRIPT
assert_eq 'a partly read packaged config exits 1' 1 "$status"
assert_match 'the packaged config reports it' '^FAIL +packaged config: .*1 line skipped' "$out"
assert_match 'a sample line that starts with Config partly read fails the render' '^FAIL +render: .*Config partly read' "$out"

new_case; healthy_settings
cp -R "$COPY" "$root/pkg"
chmod 666 "$root/pkg/cortado.conf"
DOCTOR_SCRIPT="$root/pkg/cortado.sh" doctor
unset DOCTOR_SCRIPT
assert_match 'a sample line that starts with Config refused fails the render' '^FAIL +render: .*Config refused' "$out"

# ---------------------------------------------------------------------------
echo "== which command settings.json runs"
for text in "echo $(quoted "$COPY/cortado.sh")" "# $(quoted "$COPY/cortado.sh")" \
    "false && $(quoted "$COPY/cortado.sh")" "cd /tmp && $(quoted "$COPY/cortado.sh")" \
    "sh -c $(quoted "$COPY/cortado.sh")" "ls $(quoted "$COPY/cortado.sh")"; do
    new_case
    write_settings "$text"
    doctor
    assert_eq "not run by: $text (exit)" 1 "$status"
    assert_match "not run by: $text" '^FAIL +statusLine: does not run a cortado\.sh' "$out"
    assert_contains "not run by: $text (fix)" 'fix: cortado setup' "$out"
done
for text in "bash $(quoted "$COPY/cortado.sh")" "/bin/sh $(quoted "$COPY/cortado.sh")" \
    "env bash $(quoted "$COPY/cortado.sh")" "env FOO=1 /bin/bash -x $(quoted "$COPY/cortado.sh")" \
    "FOO=1 $(quoted "$COPY/cortado.sh") 2>/dev/null"; do
    new_case
    write_settings "$text"
    doctor
    assert_match "run by: $text" '^ok +statusLine: runs this copy' "$out"
done

new_case
printf '#!/bin/bash\nexit 0\n' > "$proj/cortado.sh"; chmod 755 "$proj/cortado.sh"
for text in './cortado.sh' 'cortado.sh' 'bash ./cortado.sh' 'bash cortado.sh' 'bin/cortado.sh'; do
    write_settings "$text"
    doctor
    assert_eq "relative: $text (exit)" 1 "$status"
    assert_match "relative: $text" '^FAIL +statusLine: .*relative path' "$out"
    assert_contains "relative: $text (fix)" 'fix: cortado setup' "$out"
    assert_not_contains "relative: $text is not resolved against doctor's directory" 'runs this copy' "$out"
done

new_case
weird="$root/it's \$HOME x"
cp -R "$COPY" "$weird"
jq -n --arg c "$(jq -nr --arg p "$weird/cortado.sh" '$p | @sh')" '{statusLine:{type:"command",command:$c}}' > "$settings"
DOCTOR_SCRIPT="$weird/cortado.sh" doctor
unset DOCTOR_SCRIPT
assert_eq 'a path with a quote and a $ that setup wrote is accepted' 0 "$status"
assert_match 'it is this copy' '^ok +statusLine: runs this copy' "$out"
doctor
assert_match 'it is found as another copy from a different one' '^ok +statusLine: runs another copy' "$out"

# ---------------------------------------------------------------------------
echo "== a program named cortado"
new_case; healthy_settings
rm "$bin/cortado"; ln -s /bin/echo "$bin/cortado"
doctor
assert_eq 'a cortado that is another program exits 1' 1 "$status"
assert_match 'it is a FAIL line' '^FAIL +cortado command: another program named cortado' "$out"
assert_contains 'its fix only looks' 'fix: type -a cortado' "$out"
assert_not_contains 'it never suggests removing it' 'rm ' "$out"

new_case; healthy_settings
rm "$bin/cortado"; printf '#!/bin/bash\nexit 0\n' > "$bin/cortado"; chmod 755 "$bin/cortado"
doctor
assert_match 'a stub script named cortado fails too' '^FAIL +cortado command: another program named cortado' "$out"

# ---------------------------------------------------------------------------
echo "== fixes that point somewhere useful"
new_case; healthy_settings
fresh_tool_dir perl bc; tools_path "$REPLY"
doctor
render_block=$(printf '%s\n' "$out" | awk '/^FAIL +render/ {p=1; next} /^(ok|FAIL|info) / {p=0} p')
assert_match 'with jq missing the render fails' '^FAIL +render' "$out"
assert_not_contains 'the render failure does not suggest an update' 'update' "$render_block"

new_case; healthy_settings
ln -s /nonexistent/gone.conf "$cfg/cortado.conf"
doctor
assert_eq 'a dangling config link exits 1' 1 "$status"
assert_contains 'the fix removes the named link' "fix: rm $(quoted "$cfg/cortado.conf")" "$out"
assert_not_contains 'it does not suggest ls -ld' 'ls -ld' "$out"
assert_contains 'it says where the link points' '/nonexistent/gone.conf' "$out"

# ---------------------------------------------------------------------------
echo "== changes nothing, asks nothing"
# A listing that notices any change: names, contents, modes, and mtimes
# (every entry is set to an old time first, so anything touched is newer).
snapshot() {
    ( cd "$1" && find . | sort && find . -type f -exec cksum {} + | sort && find . -exec ls -ld {} + | awk '{print $1, $3}' | sort )
    find "$1" -newer "$ref" 2>/dev/null | sort
}
ref="$TEST_BASE/ref"; : > "$ref"; touch -t 200101020000 "$ref"

new_case; healthy_settings
# TMPDIR lies outside the listed tree: the render's scratch directory is the one
# thing doctor creates, and it is removed again.
tmp="$TEST_BASE/scratch"; mkdir -m 700 "$tmp"
printf 'MODULE_TIME="false"\n' > "$cfg/barista.conf"
printf 'MODULE_TIME="false"\n' > "$proj/.cortado.conf"
printf '[t] note\n' > "$cfg/cortado.log"
chmod 600 "$cfg/barista.conf" "$proj/.cortado.conf"
find "$root" -exec touch -h -t 200101010000 {} + 2>/dev/null
before=$(snapshot "$root")
doctor
after=$(snapshot "$root")
printf '%s\n' "$before" > "$TEST_BASE/before.txt"; printf '%s\n' "$after" > "$TEST_BASE/after.txt"
assert_eq 'doctor changed no file (writable sandbox)' '' "$(diff "$TEST_BASE/before.txt" "$TEST_BASE/after.txt")"
assert_eq 'its scratch directory is gone afterwards' '' "$(ls "$tmp")"
assert_eq 'doctor did not copy barista.conf to cortado.conf' no "$([ -e "$cfg/cortado.conf" ] && echo yes || echo no)"
assert_eq 'doctor did not create a cache directory' no "$([ -e "$cfg/cortado-cache" ] && echo yes || echo no)"
assert_match 'the Barista config is reported, not migrated' 'barista\.conf' "$out"
writable_out="$out"; writable_status=$status

# The same run with every sandbox path read-only: the report must not change.
new_ro_tmp="$TEST_BASE/ro-tmp"; mkdir -m 700 "$new_ro_tmp"
chmod -R a-w "$home" "$cfg" "$proj"
before=$(snapshot "$root")
tmp="$new_ro_tmp"
doctor
after=$(snapshot "$root")
assert_eq 'doctor changed no file (read-only sandbox)' "$before" "$after"
assert_eq 'the exit code is the same on a read-only sandbox' "$writable_status" "$status"
assert_eq 'the report is the same on a read-only sandbox' \
    "$(printf '%s\n' "$writable_out" | sed "s#$root#ROOT#g")" "$(printf '%s\n' "$out" | sed "s#$root#ROOT#g")"
chmod -R u+w "$home" "$cfg" "$proj"
assert_eq 'no network request was made in any run' '' "$(cat "$TEST_BASE/network-calls")"

# ---------------------------------------------------------------------------
echo "== help"
help_out=$(HOME="$TEST_BASE" CLAUDE_CONFIG_DIR="$TEST_BASE/h" /bin/bash "$COPY/cortado.sh" help 2>&1)
assert_contains 'cortado help lists doctor' 'cortado doctor' "$help_out"

echo
echo "doctor tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
