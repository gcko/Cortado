#!/bin/bash
# ABOUTME: Tests project config policy through the statusline and config CLI.
# ABOUTME: Run with: bash tests/test_project_config.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORTADO="$SCRIPT_DIR/cortado.sh"
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
PROJECT="$TEST_BASE/project"
export CLAUDE_CONFIG_DIR="$TEST_BASE/claude"
export CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
mkdir -p "$PROJECT" "$CACHE_DIR" "$TEST_BASE/bin"
PROJECT_FILE="$PROJECT/.cortado.conf"
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

render() {
    printf '%s' '{"workspace":{"current_dir":"'"$PROJECT"'"},"model":{"display_name":"Test"}}' \
        | /bin/bash "$CORTADO" | sed $'s/\x1b\\[[0-9;]*m//g'
}

project_config() {
    (cd "$PROJECT" && /bin/bash "$CORTADO" config --project "$@")
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
