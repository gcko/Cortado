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
check_render_gap 'docker shows absence when both listings fail' 'DOCKER: --' 'DOCKER: 0 running / 0 total [-]' \
    failed '' 'DOCKER_SHOW_TOTAL="true"'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
