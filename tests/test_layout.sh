#!/bin/bash
# Exercise layout through Cortado's rendered stdout, including raw color bytes.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$TEST_DIR/lib/assert.sh"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT

render() {
    local render_locale="$1" payload="$2" sb
    shift 2
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX") || return 1
    mkdir -m 700 "$sb/cortado-cache" &&
        printf '%s\n' 'MODULE_ORDER=directory,model' 'RIGHT_SIDE_RESERVE=0' "$@" > "$sb/cortado.conf" &&
        chmod 600 "$sb/cortado.conf" || return 1
    printf '%s' "$payload" |
        LC_ALL="$render_locale" CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" \
        /bin/bash "$PROJECT_ROOT/cortado.sh"
}

payload='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"}}'
assert_eq 'smart breaks between modules when the icons push them past 15 columns' \
    $'📁 tmp\n🤖 Opus' "$(render C.UTF-8 "$payload" 'TERMINAL_WIDTH=15')"
assert_eq 'smart fits the same modules in exactly 16 columns' \
    '📁 tmp | 🤖 Opus' "$(COLUMNS=16 render C.UTF-8 "$payload" 'tput() { return 1; }')"

mixed='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"é⚡️‍漢"}}'
assert_eq 'smart fits a narrow letter, selector, joiner and wide characters in 17 columns' \
    '📁 tmp | 🤖 é⚡️‍漢' "$(render C.UTF-8 "$mixed" 'TERMINAL_WIDTH=17')"
assert_eq 'smart breaks before the mixed-width module at 16 columns' \
    $'📁 tmp\n🤖 é⚡️‍漢' "$(render C.UTF-8 "$mixed" 'TERMINAL_WIDTH=16')"

assert_eq 'smart ignores the separator color and counts its wide glyph' \
    $'📁 tmp\n🤖 Opus' "$(render C.UTF-8 "$payload" 'TERMINAL_WIDTH=16' \
        "SEPARATOR=\$' \033[36m界\033[0m '")"
assert_eq 'wrap pads a directory with a wide icon to the 16-column boundary' \
    "$(printf '%s%10s' '📁 tmp' '')" \
    "$(render C.UTF-8 "$payload" 'MODULE_ORDER=directory' 'LAYOUT_MODE=wrap' 'TERMINAL_WIDTH=16')"

colored='{"model":{"display_name":"OpusABCDE"}}'
color_config="MODEL_ICON=\$'\033[38;5;196m🤖\033[0m'"
assert_eq 'truncate preserves the complete colored icon and ends in a reset' \
    $'\033[38;5;196m🤖\033[0m Op...\033[0m' \
    "$(render C.UTF-8 "$colored" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=8' "$color_config")"
assert_eq 'truncate preserves the original bytes when colored output fits exactly' \
    $'\033[38;5;196m🤖\033[0m OpusABCDE' \
    "$(render C.UTF-8 "$colored" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=12' "$color_config")"

assert_eq 'truncate preserves whole UTF-8 characters under the C locale' \
    $'🤖 ...\033[0m' "$(render C '{"model":{"display_name":"漢字XYZ"}}' \
        'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=6')"
assert_eq 'truncate fits the ellipsis to a two-column budget' \
    $'..\033[0m' "$(render C.UTF-8 "$colored" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=2')"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
