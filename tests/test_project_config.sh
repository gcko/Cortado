#!/bin/bash
# ABOUTME: Tests project config policy through the statusline and config CLI.
# ABOUTME: Run with: bash tests/test_project_config.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORTADO="$SCRIPT_DIR/cortado.sh"
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
# Each case opts into startup protection by exporting its own setting.
unset COLOR_THEME DISPLAY_MODE LAYOUT_MODE MODULE_ORDER MODEL_ICON SANDBOX_ICON \
    SEPARATOR STATUS_STYLE TERMINAL_WIDTH RIGHT_SIDE_RESERVE USE_ICONS MODULE_DIRECTORY \
    MODULE_MODEL MODULE_SANDBOX MODULE_WEATHER MODULE_CPU RATE_5H_LABEL \
    APP_SANDBOX_CONTAINER_ID USE_EMOJI NO_COLOR COLUMNS CORTADO_TEST_MENU CORTADO_TEST_FAIL_THEME
PROJECT="$TEST_BASE/project"
export CLAUDE_CONFIG_DIR="$TEST_BASE/claude"
export CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
mkdir -p "$PROJECT" "$CACHE_DIR" "$TEST_BASE/bin"
PROJECT_FILE="$PROJECT/.cortado.conf"
# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/tests/lib/assert.sh" indented

render() {
    printf '%s' '{"workspace":{"current_dir":"'"$PROJECT"'"},"model":{"display_name":"Test"}}' \
        | /bin/bash "$CORTADO" | sed $'s/\x1b\\[[0-9;]*m//g'
}

project_config() {
    (cd "$PROJECT" && /bin/bash "$CORTADO" config --project "$@")
}

# Feed the real menu functions deterministic keys after normal CLI loading.
# The fixture bypasses the TTY check so the suite needs no terminal driver.
project_menu() {
    local keys="$1"
    printf '%s' "$keys" > "$TEST_BASE/menu-keys"
    CORTADO_TEST_MENU=true project_config --path < "$TEST_BASE/menu-keys"
}

cat > "$TEST_BASE/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' called >> "$CLAUDE_CONFIG_DIR/curl-calls"
printf '☀️+72°F'
EOF
chmod +x "$TEST_BASE/bin/curl"
export PATH="$TEST_BASE/bin:$PATH"

cat > "$CLAUDE_CONFIG_DIR/cortado.conf" <<'EOF'
MODULE_ORDER="model"
MODULE_WEATHER="false"
COLOR_THEME="monochrome"
EOF
chmod 600 "$CLAUDE_CONFIG_DIR/cortado.conf"

echo "=== project reads ==="
# A trusted config can observe selected variables after either entry point.
# Report only markers from the fixture.
cat >> "$CLAUDE_CONFIG_DIR/cortado.conf" <<'EOF'
report_project_markers() {
    local probe_key
    for probe_key in UPDATE_REPO WEATHER_LOCATION WEATHER_UNITS RATE_CACHE_TTL DEBUG_MODE \
        CACHE_MAX_AGE DISK_PATH NETWORK_SHOW_WAN NODE_SHOW_NPM GIT_FOO \
        PATH IFS HOME MODEL_ICON TIME_CLOCK_ICON DISPLAY_MODE; do
        case "${!probe_key-}" in
            *project-fixture*) printf 'loaded %s\n' "$probe_key" ;;
        esac
    done
    [ "${MODULE_FOO-}" != false ] || printf 'loaded MODULE_FOO\n'
    [ "${DISPLAY_MODE-}" != DISPLAY_MODE ] || printf 'loaded bare DISPLAY_MODE\n'
}
trap report_project_markers EXIT
EOF
printf '%s\n' \
    'UPDATE_REPO=project-fixture' 'WEATHER_LOCATION=project-fixture' \
    'WEATHER_UNITS=project-fixture' 'RATE_CACHE_TTL=project-fixture' \
    'DEBUG_MODE=project-fixture' 'CACHE_MAX_AGE=project-fixture' 'DISK_PATH=project-fixture' \
    'NETWORK_SHOW_WAN=project-fixture' 'NODE_SHOW_NPM=project-fixture' \
    'GIT_FOO=project-fixture' 'MODULE_FOO=false' \
    "PATH=$PATH:/project-fixture" 'IFS=project-fixture' 'HOME=/project-fixture' \
    'MODEL_ICON="project-fixture;"' $'TIME_CLOCK_ICON="project-fixture\033"' 'DISPLAY_MODE' \
    'MODULE_ORDER=model,weather' 'MODULE_WEATHER=true' > "$PROJECT_FILE"

out=$(render)
assert_eq "renderer rejects every forbidden assignment" "" "$(printf '%s\n' "$out" | sed -n '/^loaded /p')"
assert_eq "renderer skips weather when only the project enables it" "MODEL: Test" "$(printf '%s\n' "$out" | sed '/^loaded /d')"
assert_eq "disabled weather never calls curl" "" "$(cat "$CLAUDE_CONFIG_DIR/curl-calls" 2>/dev/null)"

out=$(project_config --show)
assert_eq "project show rejects every forbidden assignment" "" "$(printf '%s\n' "$out" | sed -n '/^loaded /p')"
assert_eq "project show keeps weather off" "[off] weather" "$(printf '%s\n' "$out" | awk '$2 == "weather" {print $1, $2}')"

for value in yes 1 on; do
    printf '%s\n' "MODULE_WEATHER=$value" > "$PROJECT_FILE"
    out=$(project_config --show)
    assert_eq "project show rejects MODULE_WEATHER=$value" "[off] weather" "$(printf '%s\n' "$out" | awk '$2 == "weather" {print $1, $2}')"
done

printf '%s\n' 'MODULE_ORDER=model,directory,sandbox' 'MODULE_DIRECTORY=false' \
    'SANDBOX_ICON=PROJECT-LOCK' 'SEPARATOR=~' 'COLOR_THEME=default' > "$PROJECT_FILE"
out=$(APP_SANDBOX_CONTAINER_ID=fixture SANDBOX_ICON=ENV-LOCK render)
assert_eq "renderer preserves an inherited icon and applies project display and disable settings" "🤖 Test~ENV-LOCK" "$out"
out=$(APP_SANDBOX_CONTAINER_ID=fixture SANDBOX_ICON='' render)
assert_eq "an exported empty icon is protected" "🤖 Test~🔒" "$out"
out=$(APP_SANDBOX_CONTAINER_ID=fixture render)
assert_eq "project can set an icon absent at startup" "🤖 Test~PROJECT-LOCK" "$out"

out=$(COLOR_THEME=vibrant project_config --show)
assert_eq "project show preserves trusted theme when name was exported at startup" "COLOR_THEME=monochrome" "$(printf '%s\n' "$out" | awk '/^COLOR_THEME=/ {print $1}')"

echo "=== project theme and spacing ==="
cp "$CLAUDE_CONFIG_DIR/cortado.conf" "$TEST_BASE/trusted.conf"
cat > "$CLAUDE_CONFIG_DIR/cortado.conf" <<'EOF'
MODULE_ORDER=model,sandbox
MODULE_SANDBOX=true
SEPARATOR=" x "
USE_ICONS=true
STATUS_STYLE=dots
MODEL_ICON=""
trap 'printf "USE_ICONS=%s STATUS_STYLE=%s MODEL_ICON=<%s> SEPARATOR=<%s>\n" "$USE_ICONS" "$STATUS_STYLE" "${MODEL_ICON-unset}" "$SEPARATOR"' EXIT
EOF
cp "$CLAUDE_CONFIG_DIR/cortado.conf" "$TEST_BASE/theme.conf"
for theme in default monochrome; do
    cp "$TEST_BASE/theme.conf" "$CLAUDE_CONFIG_DIR/cortado.conf"
    printf 'COLOR_THEME=%s\n' "$theme" >> "$CLAUDE_CONFIG_DIR/cortado.conf"
    rm -f "$PROJECT_FILE"
    trusted=$(APP_SANDBOX_CONTAINER_ID=fixture USE_ICONS=true STATUS_STYLE=dots MODEL_ICON='' render)
    case "$theme" in
        default)
            assert_eq "trusted default renders icons and leaves the empty model override alone" \
                $'🤖 Test x 🔒\nUSE_ICONS=true STATUS_STYLE=dots MODEL_ICON=<> SEPARATOR=< x >' "$trusted"
            project_theme=monochrome
            ;;
        monochrome)
            assert_eq "trusted monochrome still sets its effective icon and status values" \
                $'MODEL: Test x SANDBOX\nUSE_ICONS=false STATUS_STYLE=ascii MODEL_ICON=<AI:> SEPARATOR=< x >' "$trusted"
            project_theme=minimal
            ;;
    esac
    printf 'COLOR_THEME=%s\n' "$project_theme" > "$PROJECT_FILE"
    out=$(APP_SANDBOX_CONTAINER_ID=fixture USE_ICONS=true STATUS_STYLE=dots MODEL_ICON='' render)
    assert_eq "project $project_theme preserves effective protected values from trusted $theme" "$trusted" "$out"
done

printf '%s\n' 'COLOR_THEME=default' 'unset MODEL_ICON' >> "$CLAUDE_CONFIG_DIR/cortado.conf"
printf '%s\n' 'COLOR_THEME=minimal' > "$PROJECT_FILE"
out=$(APP_SANDBOX_CONTAINER_ID=fixture MODEL_ICON=ENV-ICON render)
assert_eq "a project theme cannot fill an inherited icon the trusted config unsets" \
    $'🤖 Test x 🔒\nUSE_ICONS=true STATUS_STYLE=dots MODEL_ICON=<unset> SEPARATOR=< x >' "$out"
out=$(APP_SANDBOX_CONTAINER_ID=fixture render)
assert_eq "a project theme can still fill an unprotected empty icon" \
    $'◈ Test x 🔒\nUSE_ICONS=true STATUS_STYLE=dots MODEL_ICON=<◈> SEPARATOR=< x >' "$out"

printf '%s\n' 'COLOR_THEME=nerd' 'readonly SEPARATOR BASH_COMMAND' >> "$CLAUDE_CONFIG_DIR/cortado.conf"
printf '%s\n' 'COLOR_THEME=default' > "$PROJECT_FILE"
out=$(APP_SANDBOX_CONTAINER_ID=fixture MODEL_ICON=ENV-ICON SEPARATOR=' x ' BASH_COMMAND=fixture render 2>&1)
assert_eq "a trusted theme's empty icon stays defined and read-only settings stay quiet" \
    $'🤖 Test x 🔒\nUSE_ICONS=true STATUS_STYLE=dots MODEL_ICON=<> SEPARATOR=< x >' "$out"
printf '%s\n' 'COLOR_THEME=default' >> "$CLAUDE_CONFIG_DIR/cortado.conf"

printf '%s\n' 'DISPLAY_MODE=compact' > "$PROJECT_FILE"
for layout in smart newline wrap truncate none; do
    printf 'LAYOUT_MODE=%s\n' "$layout" >> "$PROJECT_FILE"
    out=$(APP_SANDBOX_CONTAINER_ID=fixture SEPARATOR=' x ' render)
    assert_eq "compact $layout renders without separator padding" "🤖 Testx🔒" \
        "$(printf '%s\n' "$out" | sed -n '1s/ *$//p')"
    assert_eq "compact $layout preserves the inherited padded separator" \
        'USE_ICONS=true STATUS_STYLE=dots MODEL_ICON=<unset> SEPARATOR=< x >' "${out##*$'\n'}"
done
cp "$TEST_BASE/trusted.conf" "$CLAUDE_CONFIG_DIR/cortado.conf"

echo "=== project writes ==="
rm -f "$PROJECT_FILE"
for setting in UPDATE_REPO=example WEATHER_LOCATION=example WEATHER_UNITS=m RATE_CACHE_TTL=60 \
    DEBUG_MODE=true CACHE_MAX_AGE=60 DISK_PATH=/ NETWORK_SHOW_WAN=true NODE_SHOW_NPM=true \
    GIT_FOO=example MODULE_FOO=false PATH=example IFS=example HOME=example \
    'MODEL_ICON=example;' $'TIME_CLOCK_ICON=example\033' \
    MODULE_WEATHER=true MODULE_WEATHER=yes MODULE_WEATHER=1 MODULE_WEATHER=on; do
    rc=0
    project_config --set "$setting" >/dev/null 2>&1 || rc=$?
    assert_eq "project set rejects $(printf '%q' "$setting")" "2" "$rc"
done
assert_eq "rejected edits leave no project file" "absent" "$(if [ ! -e "$PROJECT_FILE" ]; then echo absent; fi)"
rm -f "$PROJECT_FILE"

rc=0
COLOR_THEME=vibrant project_config --set COLOR_THEME=minimal >/dev/null 2>&1 || rc=$?
assert_eq "project set rejects a startup environment key" "2" "$rc"
assert_eq "protected edit leaves no project file" "absent" "$(if [ ! -e "$PROJECT_FILE" ]; then echo absent; fi)"

rc=0
project_config --toggle weather >/dev/null 2>&1 || rc=$?
assert_eq "project toggle cannot turn weather on" "2" "$rc"
assert_eq "rejected toggle leaves no project file" "absent" "$(if [ ! -e "$PROJECT_FILE" ]; then echo absent; fi)"

printf '%s\n' 'MODULE_WEATHER="true"' 'GIT_FOO=project-fixture' 'UPDATE_REPO=project-fixture' \
    'MODEL_ICON="project-fixture;"' 'RATE_5H_LABEL="quota"' 'SEPARATOR=" ~ "' \
    'MODULE_ORDER=model,directory,weather' > "$PROJECT_FILE"
rc=0
project_config --toggle directory >/dev/null 2>&1 || rc=$?
assert_eq "project toggle can disable an enabled module" "0" "$rc"
assert_eq "project toggle saves only explicit valid overrides" \
    $'RATE_5H_LABEL="quota"\nSEPARATOR=" ~ "\nMODULE_ORDER=model,directory,weather\nMODULE_DIRECTORY="false"' \
    "$(sed -n '/^[A-Z_0-9]*=/p' "$PROJECT_FILE")"
assert_eq "project order still skips both disabled modules" "MODEL: Test" "$(render)"

rm -f "$PROJECT_FILE"
printf '%s\n' 'MODULE_WEATHER=true' 'GIT_FOO=project-fixture' 'SEPARATOR=legacy' > "$PROJECT/.barista.conf"
rc=0
project_config --set MODULE_WEATHER=true >/dev/null 2>&1 || rc=$?
assert_eq "invalid legacy edit is rejected" "2" "$rc"
assert_eq "invalid legacy edit leaves no project file" "absent" "$(if [ ! -e "$PROJECT_FILE" ]; then echo absent; fi)"

rc=0
project_config --set COLOR_THEME=minimal >/dev/null 2>&1 || rc=$?
assert_eq "valid legacy edit succeeds" "0" "$rc"
assert_eq "legacy edit migrates only allowed settings" $'SEPARATOR=legacy\nCOLOR_THEME="minimal"' \
    "$(sed -n '/^[A-Z_0-9]*=/p' "$PROJECT_FILE")"

echo "=== first and empty project saves ==="
rm -f "$PROJECT_FILE" "$PROJECT/.barista.conf"
cat > "$TEST_BASE/menu.conf" <<'EOF'
if [ "${CORTADO_TEST_MENU:-}" = true ]; then
    # Run menu functions outside the active EXIT trap so their statuses are
    # independent of the status from --path.
    run_project_menu() (
        local path="$PWD/.cortado.conf"
        _cfg_load_into_shell "$path" project
        if [ "${CORTADO_TEST_FAIL_THEME:-}" = true ]; then
            project_config_assign() { return 1; }
        fi
        _cfg_run_interactive "$path" project
    )
    trap 'run_project_menu; exit $?' EXIT
fi
EOF
cp "$TEST_BASE/menu.conf" "$CLAUDE_CONFIG_DIR/cortado.conf"
printf '%s\n' 'set -u' >> "$CLAUDE_CONFIG_DIR/cortado.conf"
header='# Cortado project configuration'
rc=0
project_config --set COLOR_THEME=minimal > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "first edit succeeds with nounset" "0" "$rc"
assert_eq "first edit writes exactly one assignment" "$header"$'\nCOLOR_THEME="minimal"' \
    "$(cat "$PROJECT_FILE" 2>/dev/null)"

printf '%s\n' "$header" 'COLOR_THEME="minimal"' > "$PROJECT_FILE"
rc=0
project_config --set COLOR_THEME=vibrant > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "replacing the sole assignment succeeds with nounset" "0" "$rc"
assert_eq "replacement writes exactly one assignment" "$header"$'\nCOLOR_THEME="vibrant"' \
    "$(cat "$PROJECT_FILE" 2>/dev/null)"

rm -f "$PROJECT_FILE"
rc=0
project_menu 's' > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "saving an empty project succeeds with nounset" "0" "$rc"
printf '%s\n' "$header" > "$TEST_BASE/header"
assert_eq "an empty save writes only its header and newline" "0" \
    "$(cmp -s "$TEST_BASE/header" "$PROJECT_FILE"; echo "$?")"
assert_rc "a menu save releases its edit lock" 1 test -d "$PROJECT_FILE.cortado-lock"

rm -f "$PROJECT_FILE"
mkdir "$PROJECT_FILE"
printf '%s\n' 'MODULE_ORDER=model' > "$CLAUDE_CONFIG_DIR/cortado.conf"
rc=0
project_config --set COLOR_THEME=minimal > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "writing to a project config directory fails" "1" "$rc"
assert_eq "writer reports no successful set for a directory" "" "$(sed -n '/^Set /p' "$TEST_BASE/result")"
assert_eq "writer leaves the destination directory empty" "" "$(ls -A "$PROJECT_FILE")"

echo "=== project module state and theme menu ==="
rmdir "$PROJECT_FILE"
cp "$TEST_BASE/menu.conf" "$CLAUDE_CONFIG_DIR/cortado.conf"
printf '%s\n' 'COLOR_THEME=monochrome' 'MODULE_CPU=yes' 'unset MODULE_DIRECTORY' \
    'MODULE_ORDER=model,cpu,directory' >> "$CLAUDE_CONFIG_DIR/cortado.conf"
out=$(project_config --show)
for name in cpu directory; do
    assert_eq "project show matches the renderer when trusted $name is disabled" "[off] $name" \
        "$(printf '%s\n' "$out" | awk -v name="$name" '$2 == name {print $1, $2}')"
done
assert_eq "project show omits global WAN settings" "" "$(printf '%s\n' "$out" | sed -n '/^NETWORK_SHOW_WAN=/p')"
out=$(/bin/bash "$CORTADO" config --show)
assert_eq "global show still recognizes the trusted CPU alias" "[on ] cpu" \
    "$(printf '%s\n' "$out" | awk '/\] cpu / {print $1, $2, $3}')"
rc=0
project_config --toggle cpu > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "project toggle rejects enabling the CPU alias" "2" "$rc"
assert_eq "rejected CPU toggle leaves no project file" "absent" "$(if [ ! -e "$PROJECT_FILE" ]; then echo absent; fi)"
printf '%s\n' 'MODULE_ORDER=model,cpu,directory' > "$PROJECT_FILE"
assert_eq "project order cannot run trusted CPU or directory when off" "MODEL: Test" "$(render)"

rm -f "$PROJECT_FILE"
rc=0
COLOR_THEME=vibrant project_menu $'\n\n\n\nn\n' > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "cancelling from the inherited theme menu exits without saving" "1" "$rc"
assert_eq "the menu explains an inherited theme is read-only" "Color theme is read-only (set in the startup environment)." \
    "$(sed -n '/^Color theme is read-only/p' "$TEST_BASE/result")"
assert_eq "the menu omits the protected theme choice and reports no save" "" \
    "$(sed -n '/Select$/p; /Saved /p' "$TEST_BASE/result")"
assert_eq "a protected theme alone does not create a project file" "absent" \
    "$(if [ ! -e "$PROJECT_FILE" ]; then echo absent; fi)"
assert_eq "the final project preview includes the enabled model sample" "Claude" \
    "$(sed -n 's/^Preview: .*\(Claude\).*/\1/p' "$TEST_BASE/result")"
assert_eq "the project preview omits the disabled CPU sample" "" \
    "$(sed -n '/Preview:.*12%/p' "$TEST_BASE/result")"
assert_eq "the project menu shows CPU unchecked" "] cpu" \
    "$(sed -n 's/.*\[ \] cpu CPU usage$/] cpu/p' "$TEST_BASE/result")"

printf '%s\n' 'COLOR_THEME=minimal' > "$PROJECT_FILE"
rc=0
COLOR_THEME=vibrant project_menu $' \n\n\n\ny\n' > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "a valid disable still saves alongside the read-only theme" "0" "$rc"
assert_eq "another project menu edit preserves the stored theme" \
    "$header"$'\nCOLOR_THEME=minimal\nMODULE_SANDBOX="false"' "$(cat "$PROJECT_FILE" 2>/dev/null)"

echo "=== project policy probes ==="
printf '%s\n' 'MODULE_ORDER=model,sandbox' 'MODULE_SANDBOX=true' 'MODEL_ICON=TRUSTED' \
    'NETWORK_SHOW_WAN=true' 'WEATHER_LOCATION=Lisbon' > "$CLAUDE_CONFIG_DIR/cortado.conf"
for value in 'x`y' "x\$y" 'x;y' 'x&y' 'x>y' 'x<y' 'x*y' 'x?y' 'x[y'; do
    printf '%s\n' "MODEL_ICON=$value" > "$PROJECT_FILE"
    assert_eq "the project reader rejects literal $value" 'TRUSTED Test' "$(render)"
done
printf '%s\n' 'SANDBOX_ICON=PROJECT-LOCK' 'SEPARATOR=" | "' > "$PROJECT_FILE"
assert_eq "a longer inherited name leaves the project icon editable and the pipe works" \
    'TRUSTED Test | PROJECT-LOCK' "$(MY_SANDBOX_ICON=inherited APP_SANDBOX_CONTAINER_ID=fixture render)"

printf '%s\n' 'HOME=/project-fixture' 'PATH=/project-fixture' 'IFS=project-fixture' > "$PROJECT_FILE"
rc=0
project_config --set 'SEPARATOR= | ' > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "the editor accepts a quoted pipe separator" "0" "$rc"
# Even protected environment keys would be retained by a later edit if admitted
# by the parser. Check persistence separately from effective environment values.
assert_eq "saving never retains project HOME, PATH or IFS assignments" \
    "$header"$'\nSEPARATOR=" | "' "$(cat "$PROJECT_FILE" 2>/dev/null)"

printf '%s\n' 'COLOR_THEME=default' 'SEPARATOR=" | "' 'COLOR_THEME=monochrome' > "$PROJECT_FILE"
rc=0
project_config --set COLOR_THEME=minimal > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "replacing a duplicated project setting succeeds" "0" "$rc"
assert_eq "replacing a duplicate stores exactly one new preference" \
    "$header"$'\nSEPARATOR=" | "\nCOLOR_THEME="minimal"' "$(cat "$PROJECT_FILE" 2>/dev/null)"

echo "=== project menu saves ==="
cat "$TEST_BASE/menu.conf" >> "$CLAUDE_CONFIG_DIR/cortado.conf"
for save in early final; do
    printf '%s\n' 'NETWORK_SHOW_WAN=true' 'WEATHER_LOCATION=Lisbon' 'SEPARATOR=" | "' > "$PROJECT_FILE"
    case "$save" in
        early) keys=' s'; expected="$header"$'\nSEPARATOR=" | "\nMODULE_SANDBOX="false"' ;;
        final)
            keys=$' \n\n\n\n\e[B\ny\n'
            expected="$header"$'\nSEPARATOR=" | "\nMODULE_SANDBOX="false"\nCOLOR_THEME="monochrome"'
            ;;
    esac
    rc=0
    project_menu "$keys" > "$TEST_BASE/result" 2>&1 || rc=$?
    assert_eq "$save project menu save succeeds" "0" "$rc"
    assert_eq "$save project menu save reports the path" "Saved $PROJECT_FILE" \
        "$(sed -n 's/^.*\(Saved .*\)$/\1/p' "$TEST_BASE/result")"
    assert_eq "$save project menu stores only explicit allowed settings" "$expected" \
        "$(cat "$PROJECT_FILE" 2>/dev/null)"
    assert_eq "$save project menu omits the WAN menu" "" "$(sed -n '/WAN IP (privacy)/p' "$TEST_BASE/result")"
done

rm -f "$PROJECT_FILE"
rc=0
CORTADO_TEST_FAIL_THEME=true project_menu $'\n\n\n\n\e[B\ny\n' > "$TEST_BASE/result" 2>&1 || rc=$?
assert_eq "a failed project theme edit exits with an error" "2" "$rc"
assert_eq "a failed project theme edit explains the failure" "config: could not set the project color theme" \
    "$(sed -n '/^config: could not set the project color theme/p' "$TEST_BASE/result")"
assert_eq "a failed project theme edit writes no project file" "absent" \
    "$(if [ ! -e "$PROJECT_FILE" ]; then echo absent; fi)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
