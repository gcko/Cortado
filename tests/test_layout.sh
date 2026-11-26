#!/bin/bash
# Exercise layout through Cortado's rendered stdout, including raw color bytes.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$TEST_DIR/lib/assert.sh"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
workspace="$TEST_BASE/tmp"
mkdir "$workspace" || exit 1
workspace_json=$(jq -nc --arg cwd "$workspace" '{current_dir:$cwd}') || exit 1

# Escape bytes reach the config as raw bytes in single quotes: config is data (#33).
render() (
    local render_locale="$1" payload="$2" sb
    shift 2
    sb=$(mktemp -d "$TEST_BASE/render.XXXXXX") || return 1
    mkdir -m 700 "$sb/cortado-cache" &&
        printf '%s\n' 'MODULE_ORDER=directory,model' 'RIGHT_SIDE_RESERVE=0' "$@" > "$sb/cortado.conf" &&
        chmod 600 "$sb/cortado.conf" || return 1
    cd "$workspace" || return 1
    printf '%s' "$payload" |
        LC_ALL="$render_locale" CLAUDE_CONFIG_DIR="$sb" CACHE_DIR="$sb/cortado-cache" \
        /bin/bash "$PROJECT_ROOT/cortado.sh"
)

payload='{"workspace":'"$workspace_json"',"model":{"display_name":"Opus"}}'
assert_eq 'smart breaks between modules when the icons push them past 15 columns' \
    $'📁 tmp\n🤖 Opus' "$(render C.UTF-8 "$payload" 'TERMINAL_WIDTH=15')"
# The tput hook is Bash, so it needs the environment's opt-in (#33).
assert_eq 'smart fits the same modules in exactly 16 columns' \
    '📁 tmp | 🤖 Opus' "$(COLUMNS=16 CORTADO_CONF_ALLOW_BASH=1 render C.UTF-8 "$payload" 'tput() { return 1; }')"

mixed='{"workspace":'"$workspace_json"',"model":{"display_name":"é⚡️‍漢"}}'
assert_eq 'smart fits a narrow letter, selector, joiner and wide characters in 17 columns' \
    '📁 tmp | 🤖 é⚡️‍漢' "$(render C.UTF-8 "$mixed" 'TERMINAL_WIDTH=17')"
assert_eq 'smart breaks before the mixed-width module at 16 columns' \
    $'📁 tmp\n🤖 é⚡️‍漢' "$(render C.UTF-8 "$mixed" 'TERMINAL_WIDTH=16')"

assert_eq 'smart ignores the separator color and counts its wide glyph' \
    $'📁 tmp\n🤖 Opus' "$(render C.UTF-8 "$payload" 'TERMINAL_WIDTH=16' \
        $'SEPARATOR=\' \033[36m界\033[0m \'')"
assert_eq 'wrap pads a directory with a wide icon to the 16-column boundary' \
    "$(printf '%s%10s' '📁 tmp' '')" \
    "$(render C.UTF-8 "$payload" 'MODULE_ORDER=directory' 'LAYOUT_MODE=wrap' 'TERMINAL_WIDTH=16')"

assert_eq 'smart wraps before an emoji-presentation sun at 14 columns' \
    $'D tmp\n☀️ Opus' "$(render C.UTF-8 "$payload" 'DIRECTORY_ICON=D' 'MODEL_ICON=☀️' 'TERMINAL_WIDTH=14')"
assert_eq 'smart fits the emoji-presentation sun at 15 columns' \
    'D tmp | ☀️ Opus' "$(render C.UTF-8 "$payload" 'DIRECTORY_ICON=D' 'MODEL_ICON=☀️' 'TERMINAL_WIDTH=15')"
assert_eq 'wrap pads the emoji-presentation watch with exactly ten spaces' \
    "$(printf '%s%10s' '⏱️ tmp' '')" "$(render C.UTF-8 "$payload" 'MODULE_ORDER=directory' \
        'DIRECTORY_ICON=⏱️' 'LAYOUT_MODE=wrap' 'TERMINAL_WIDTH=16')"
assert_eq 'truncate retains the watch and its selector in five columns' \
    $'⏱️...\033[0m' "$(render C.UTF-8 "$payload" 'MODULE_ORDER=model' 'MODEL_ICON=⏱️' \
        'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=5')"
assert_eq 'truncate keeps an exactly fitting decomposed spelling' \
    '🤖 caféXYZ' "$(render C.UTF-8 '{"model":{"display_name":"caféXYZ"}}' \
        'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=10')"
assert_eq 'truncate leaves the accent attached to the last retained letter' \
    $'🤖 café...\033[0m' "$(render C.UTF-8 '{"model":{"display_name":"caféWXYZ"}}' \
        'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=10')"
assert_eq 'truncate keeps an exactly fitting joined emoji and model name' \
    '👩‍💻 Opus' "$(render C.UTF-8 "$payload" 'MODULE_ORDER=model' 'MODEL_ICON=👩‍💻' \
        'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=8')"
assert_eq 'truncate retains the entire joined emoji before the marker' \
    $'A 👨‍💻...\033[0m' "$(render C.UTF-8 '{"model":{"display_name":"👨‍💻WXYZ"}}' \
        'MODULE_ORDER=model' 'MODEL_ICON=A' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=7')"
assert_eq 'truncate discards the entire joined emoji when it cannot fit' \
    $'A ...\033[0m' "$(render C.UTF-8 '{"model":{"display_name":"👨‍💻WXYZ"}}' \
        'MODULE_ORDER=model' 'MODEL_ICON=A' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=6')"

tab_config=( 'DIRECTORY_ICON=D' 'MODEL_ICON=M' $'SEPARATOR=\'\t\'' )
assert_eq 'smart wraps before a tab-separated model at 11 columns' \
    $'D tmp\nM Opus' "$(render C.UTF-8 "$payload" "${tab_config[@]}" 'TERMINAL_WIDTH=11')"
assert_eq 'smart wraps before a tab-separated model at 13 columns' \
    $'D tmp\nM Opus' "$(render C.UTF-8 "$payload" "${tab_config[@]}" 'TERMINAL_WIDTH=13')"
assert_eq 'smart fits the tab-separated model at 14 columns' \
    $'D tmp\tM Opus' "$(render C.UTF-8 "$payload" "${tab_config[@]}" 'TERMINAL_WIDTH=14')"
assert_eq 'wrap pads the tab-separated line with exactly two spaces' \
    $'D tmp\tM Opus  ' "$(render C.UTF-8 "$payload" "${tab_config[@]}" 'LAYOUT_MODE=wrap' 'TERMINAL_WIDTH=16')"
assert_eq 'truncate stops before a tab whose next stop cannot fit' \
    $'D tmp...\033[0m' "$(render C.UTF-8 "$payload" "${tab_config[@]}" 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=9')"

colored='{"model":{"display_name":"OpusABCDE"}}'
color_config=$'MODEL_ICON=\'\033[38;5;196m🤖\033[0m\''
assert_eq 'truncate preserves the complete colored icon and ends in a reset' \
    $'\033[38;5;196m🤖\033[0m Op...\033[0m' \
    "$(render C.UTF-8 "$colored" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=8' "$color_config")"
caller="$TEST_BASE/caller"
mkdir "$caller" || exit 1
printf '%s\n' 'MODULE_MODEL=false' > "$caller/.cortado.conf"
chmod 600 "$caller/.cortado.conf"
assert_eq 'truncate preserves exactly fitting colored output even from a caller that disables model' \
    $'\033[38;5;196m🤖\033[0m OpusABCDE' \
    "$(cd "$caller" && render C.UTF-8 "$colored" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' \
        'TERMINAL_WIDTH=12' "$color_config")"

assert_eq 'truncate preserves whole UTF-8 characters under the C locale' \
    $'🤖 ...\033[0m' "$(render C '{"model":{"display_name":"漢字XYZ"}}' \
        'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=6')"
assert_eq 'truncate fits the ellipsis to a two-column budget' \
    $'..\033[0m' "$(render C.UTF-8 "$colored" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=2')"
assert_eq 'truncate drops the color opener of a discarded separator' \
    $'📁 tmp ...\033[0m' "$(render C.UTF-8 "$payload" 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=10' \
        $'SEPARATOR=\' \033[36m|\033[0m \'')"
assert_eq 'truncate emits only two dots and a reset when a colored first glyph cannot fit' \
    $'..\033[0m' "$(render C.UTF-8 "$colored" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' \
        'TERMINAL_WIDTH=2' "$color_config")"
assert_eq 'truncate emits only a newline when all modules are empty with a negative budget' \
    $'\n.' "$(render C.UTF-8 "$payload" 'MODULE_ORDER=model' 'MODULE_MODEL=false' \
        'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=10' 'RIGHT_SIDE_RESERVE=20' && printf '.')"

link_icon=$'MODEL_ICON=\'AB\033]8;;https://example.invalid/\aLink\033]8;;\a\''
assert_eq 'truncate discards the hyperlink opener when no linked text fits' \
    $'AB...\033[0m' "$(render C.UTF-8 "$payload" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' \
        'TERMINAL_WIDTH=5' "$link_icon")"
assert_eq 'truncate closes a retained hyperlink before the marker and reset' \
    $'AB\033]8;;https://example.invalid/\aL\033]8;;\a...\033[0m' \
    "$(render C.UTF-8 "$payload" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' \
        'TERMINAL_WIDTH=6' "$link_icon")"
assert_eq 'truncate closes a retained hyperlink that uses an ESC-backslash terminator' \
    $'AB\033]8;id=test;https://example.invalid/\033\134L\033]8;;\033\134...\033[0m' \
    "$(render C.UTF-8 "$payload" 'MODULE_ORDER=model' 'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=6' \
        $'MODEL_ICON=\'AB\033]8;id=test;https://example.invalid/\033\134Link\033]8;;\033\134\'')"

# Count width work rather than setting a wall-clock deadline for shared CI.
long_label=$(printf '%1024s' '' | sed 's/ /漢/g')
long_payload=$(jq -nc --arg label "$long_label" '{model:{display_name:$label}}')
BASH_ENV="$TEST_BASE/trace.sh"
# A literal PS4 keeps the trace parser independent of the caller's PS4.
printf '%s\n' "PS4='+ '" 'set -x' > "$BASH_ENV"
long_output=$(export BASH_ENV; render C "$long_payload" 'MODULE_ORDER=model' \
    'LAYOUT_MODE=truncate' 'TERMINAL_WIDTH=16' 2>"$TEST_BASE/width-trace")
unset BASH_ENV
assert_eq 'a long CJK label truncates on a whole character' $'🤖 漢漢漢漢漢...\033[0m' "$long_output"
scans=$(grep -cE '^\++ layout_codepoint_width ' "$TEST_BASE/width-trace")
if [ "$scans" -gt 0 ] && [ "$scans" -le 20 ]; then
    pass 'narrow truncation measures only the visible start of a long CJK label'
else
    fail "narrow truncation measures only the visible start of a long CJK label (scanned $scans code points)"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
