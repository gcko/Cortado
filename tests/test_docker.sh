#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/render.sh
. "$PROJECT_ROOT/tests/lib/render.sh" docker

cat > "$TEST_BASE/bin/docker" <<'STUB'
#!/bin/bash
case "$*" in
    info) [ "$TEST_SAMPLE" != offline ] ;;
    'ps -q'|'ps -aq')
        case "$TEST_SAMPLE" in
            normal)
                printf '%s\n' a123 b456
                if [ "$*" = 'ps -aq' ]; then printf '%s\n' c789; fi ;;
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

check_render 'docker shows measured running and total counts' 'DOCKER: 2 running / 3 total [OK]' \
    normal '' 'DOCKER_SHOW_TOTAL="true"'
check_render 'docker shows absence when the daemon is offline' 'DOCKER: --' \
    offline '' 'DOCKER_SHOW_TOTAL="true"'
check_render 'docker preserves a measured zero count' 'DOCKER: 0 running / 0 total [-]' \
    zero '' 'DOCKER_SHOW_TOTAL="true"'
check_render 'docker shows absence when both listings fail' 'DOCKER: --' \
    failed '' 'DOCKER_SHOW_TOTAL="true"'
check_render 'docker shows the total with no running reading or status' 'DOCKER: -- running / 1 total' \
    total-only '' 'DOCKER_SHOW_TOTAL="true"'
check_render 'docker shows the running count and status with no total' 'DOCKER: 1 running / -- total [OK]' \
    running-only '' 'DOCKER_SHOW_TOTAL="true"'
check_render 'docker shows absence when counting two successful listings fails' 'DOCKER: --' \
    normal '' 'DOCKER_SHOW_TOTAL=true' 'awk() { return 1; }'
check_render 'docker shows absence when counting the running listing fails' 'DOCKER: --' \
    normal '' 'awk() { return 1; }'
check_render 'docker rejects a noninteger count from a successful counter' 'DOCKER: --' \
    normal '' 'awk() { printf "%s\n" unknown; }'
check_render 'docker preserves the icon when every field is disabled' 'DOCKER:' \
    normal '' 'DOCKER_SHOW_RUNNING=false' 'DOCKER_SHOW_TOTAL=false' 'DOCKER_SHOW_STATUS=false'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
