#!/bin/bash
# Render a session's version notice against a clock controlled by the test.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir "$TEST_BASE/bin"
cat > "$TEST_BASE/bin/date" <<'STUB'
#!/bin/bash
if [ "$*" = "+%s" ]; then
    printf '%s\n' "$TEST_NOW"
else
    /bin/date "$@"
fi
STUB
chmod +x "$TEST_BASE/bin/date"

sb=$(mktemp -d "$TEST_BASE/render.XXXXXX")
printf '%s\n' 'MODULE_ORDER="version"' 'MODULE_VERSION="true"' \
    'COLOR_THEME="monochrome"' 'TERMINAL_WIDTH=200' 'VERSION_SHOW_DURATION=10' > "$sb/cortado.conf"
version="Cortado v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
now=$(/bin/date +%s)

check() {
    local desc="$1" expected="$2" payload="$3" elapsed="$4" actual
    actual=$(printf '%s' "$payload" | PATH="$TEST_BASE/bin:$PATH" TEST_NOW="$((now + elapsed))" \
        CLAUDE_CONFIG_DIR="$sb" /bin/bash "$PROJECT_ROOT/cortado.sh" 2>&1)
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (expected [%s] got [%s])\n' "$desc" "$expected" "$actual"
    fi
}

a='{"cwd":"/nonexistent","session_id":"fixture-a"}'
b='{"cwd":"/nonexistent","session_id":"fixture-b"}'
check "no session ID keeps the version hidden" "" '{"cwd":"/nonexistent"}' 0
check "a null session ID keeps the version hidden" "" '{"cwd":"/nonexistent","session_id":null}' 0
check "a numeric session ID keeps the version hidden" "" '{"cwd":"/nonexistent","session_id":0}' 0
check "the first session opens with the version notice" "$version" "$a" 0
check "the same session shows the notice during its window" "$version" "$a" 9
check "the first session hides the notice at expiry" "" "$a" 10
check "the second session gets its own notice" "$version" "$b" 11
check "returning to the first session does not restart its notice" "" "$a" 12
check "the second session keeps its own expiry" "$version" "$b" 20
check "the second session expires even with interleaved renders" "" "$b" 21

printf '%s\n' 'VERSION_SHOW_DURATION=abc' >> "$sb/cortado.conf"
c='{"cwd":"/nonexistent","session_id":"fixture-c"}'
check "invalid duration uses the default without printing a diagnostic" "$version" "$c" 30
check "default duration expires after 120 seconds" "" "$c" 150

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
