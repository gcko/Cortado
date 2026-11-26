#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" docker

unset DOCKER_HOST DOCKER_CONTEXT
export DOCKER_CONFIG="$TEST_BASE/docker-config" DOCKER_CALLS="$TEST_BASE/docker.calls"
mkdir "$DOCKER_CONFIG"
cat > "$TEST_BASE/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_CALLS"
case "$*" in
    info) exit 2 ;;
    'ps -q'|'ps -aq')
        case "$TEST_SAMPLE" in
            normal)
                printf '%s\n' a123 b456
                if [ "$*" = 'ps -aq' ]; then printf '%s\n' c789; fi ;;
            selection)
                if [ "${DOCKER_CONTEXT:-}" = second ] || [ "${DOCKER_HOST:-}" = tcp://second ] ||
                    { [ -z "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}" ] &&
                        grep -q '"second"' "$DOCKER_CONFIG/config.json"; }; then
                    exit 0
                fi
                printf '%s\n' a123 b456 ;;
            zero) exit 0 ;;
            total-only)
                if [ "$*" = 'ps -aq' ]; then printf '%s\n' a123; else exit 1; fi ;;
            running-only)
                if [ "$*" = 'ps -q' ]; then printf '%s\n' a123; else exit 1; fi ;;
            *) exit 1 ;;
        esac ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$TEST_BASE/bin/docker"

# An unusable context name is absence, with no Docker CLI call. Each case
# renders cold now and again at the end of the suite, so the rest of the suite
# runs inside its refresh window. The window lasts at least 1.6 s.
mkdir "$TEST_BASE/bad-docker-config"
printf '%s\n' '{"currentContext":"bad context!"}' > "$TEST_BASE/bad-docker-config/config.json"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
no_call_render() {
    DOCKER_CONFIG="$TEST_BASE/bad-docker-config" DOCKER_CALLS="$1/docker.calls" \
        render normal '' "CLAUDE_CONFIG_DIR='$1'"
}
start_no_docker_call() {
    local sb="$1"
    : > "$sb/docker.calls"
    no_call_render "$sb" > "$sb/first"
    now > "$sb/started"
}
finish_no_docker_call() {
    local desc="$1" sb="$2" wait
    # The ternary is parenthesized: bare, BSD awk reads `>` as output redirection.
    if ! wait=$(LC_NUMERIC=C awk -v started="$(cat "$sb/started")" -v now="$(now)" \
            'BEGIN { left = started + 1.6 - now; printf "%.3f\n", (left > 0 ? left : 0) }') ||
        ! sleep "$wait"; then
        fail "$desc (refresh window wait failed)"
    fi
    assert_eq "$desc (cold)" 'DOCKER: --' "$(cat "$sb/first")"
    assert_eq "$desc (after a refresh window)" 'DOCKER: --' "$(no_call_render "$sb")"
    assert_eq "$desc makes no Docker CLI call" '' "$(cat "$sb/docker.calls")"
}
invalid_context=$(mktemp -d "$TEST_BASE/invalid-context.XXXXXX") || exit 1
start_no_docker_call "$invalid_context"
metadata=$(mktemp -d "$TEST_BASE/metadata.XXXXXX") || exit 1
mkdir -m 700 "$metadata/cortado-cache"
(umask 077; printf '%s\n' stale > "$metadata/cortado-cache/docker")
start_no_docker_call "$metadata"

# A cold render schedules the probe. Observe its result in the same cache.
check_probe() {
    local desc="$1" expected="$2" sample="$3" sb i entry
    shift 3
    sb=$(mktemp -d "$TEST_BASE/probe.XXXXXX") || exit 1
    render "$sample" '' "CLAUDE_CONFIG_DIR='$sb'" "$@" >/dev/null || { fail "$desc (cold render failed)"; return; }
    for ((i=0; i<60; i++)); do
        for entry in "$sb"/cortado-cache/docker-*; do
            case "${entry##*/}" in *-lock|*.*) continue ;; esac
            [ ! -s "$entry" ] || break 2
        done
        sleep 0.05
    done
    [ "$i" -lt 60 ] || { fail "$desc (refresh did not publish)"; return; }
    check_render "$desc" "$expected" "$sample" '' "CLAUDE_CONFIG_DIR='$sb'" "$@"
}

check_probe 'docker shows measured running and total counts' 'DOCKER: 2 running / 3 total [OK]' \
    normal 'DOCKER_SHOW_TOTAL="true"'
check_probe 'docker shows absence when the daemon is offline' 'DOCKER: --' \
    offline 'DOCKER_SHOW_TOTAL="true"'
check_probe 'docker preserves a measured zero count' 'DOCKER: 0 running / 0 total [-]' \
    zero 'DOCKER_SHOW_TOTAL="true"'
check_probe 'docker shows absence when both listings fail' 'DOCKER: --' \
    failed 'DOCKER_SHOW_TOTAL="true"'
check_probe 'docker shows the total with no running reading or status' 'DOCKER: -- running / 1 total' \
    total-only 'DOCKER_SHOW_TOTAL="true"'
check_probe 'docker shows the running count and status with no total' 'DOCKER: 1 running / -- total [OK]' \
    running-only 'DOCKER_SHOW_TOTAL="true"'
check_probe 'docker shows absence when counting two successful listings fails' 'DOCKER: --' \
    normal 'DOCKER_SHOW_TOTAL=true' 'awk() { return 1; }; export -f awk'
check_probe 'docker shows absence when counting the running listing fails' 'DOCKER: --' \
    normal 'awk() { return 1; }; export -f awk'
check_probe 'docker rejects a noninteger count from a successful counter' 'DOCKER: --' \
    normal 'awk() { printf "%s\n" unknown; }; export -f awk'
check_render 'docker preserves the icon when every field is disabled' 'DOCKER:' \
    normal '' 'DOCKER_SHOW_RUNNING=false' 'DOCKER_SHOW_TOTAL=false' 'DOCKER_SHOW_STATUS=false'

sb=$(mktemp -d "$TEST_BASE/selection.XXXXXX") || exit 1
printf '%s\n' '{"currentContext":"first"}' > "$DOCKER_CONFIG/config.json"
selection_output() {
    render selection '' "CLAUDE_CONFIG_DIR='$sb'" "$@"
}
expect_selection() {
    local desc="$1" expected="$2" actual i
    shift 2
    for ((i=0; i<45; i++)); do
        actual=$(selection_output "$@")
        [ "$actual" = 'DOCKER: --' ] || break
        sleep 0.05
    done
    assert_eq "$desc" "$expected" "$actual"
}
expect_selection 'the initial Docker context warms' 'DOCKER: 2 running [OK]'
printf '%s\n' '{"currentContext":"second"}' > "$DOCKER_CONFIG/config.json"
expect_selection 'an on-disk context switch immediately drops the old count' 'DOCKER: 0 running [-]'
DOCKER_HOST=tcp://first expect_selection 'an exported host overrides the on-disk context' 'DOCKER: 2 running [OK]'
DOCKER_HOST=tcp://first DOCKER_CONTEXT=second expect_selection 'an exported context overrides the host' 'DOCKER: 0 running [-]'
mkdir "$TEST_BASE/other-docker-config"
printf '%s\n' '{"currentContext":"first"}' > "$TEST_BASE/other-docker-config/config.json"
DOCKER_CONFIG="$TEST_BASE/other-docker-config" expect_selection 'a different config directory selects its own context' 'DOCKER: 2 running [OK]'
for entry in "$sb"/cortado-cache/docker-*; do
    case "${entry##*/}" in *-lock|*-failed|*.*) continue ;; esac
    printf '%s\n' '-- 5' > "$entry"
done
assert_eq 'a status-only cache requires a running count' 'DOCKER: --' "$(selection_output 'DOCKER_SHOW_RUNNING=false')"

finish_no_docker_call 'an invalid currentContext shows absence' "$invalid_context"
finish_no_docker_call 'a cache file named docker cannot supply the Docker selection' "$metadata"
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
