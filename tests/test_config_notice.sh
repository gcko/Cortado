#!/bin/bash
# The Config refused and Config partly read notices name the command that
# explains each (cortado doctor, cortado config --show), and still fit every layout without breaking the line.
# Run with: /bin/bash tests/test_config_notice.sh
# Fixtures are literal shell text that must stay unexpanded.
# shellcheck disable=SC2016

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented
unset CORTADO_CONF_ALLOW_BASH COLOR_THEME DISPLAY_MODE MODULE_ORDER SEPARATOR USE_ICONS \
    DEBUG_MODE TERMINAL_WIDTH LAYOUT_MODE RIGHT_SIDE_RESERVE APP_SANDBOX_CONTAINER_ID

REFUSED='Config refused: run cortado doctor'
PARTLY='Config partly read: run cortado config --show'

# render <kind> <theme> <display mode> <layout> <width>
# kind: refused (a group-writable user config), partly (a user config line that
# runs a command), both, or none. Layout settings come from the project config,
# which the safe parser applies even when the user config is refused.
render() {
    local kind="$1" theme="$2" mode="$3" layout="$4" width="$5" sb proj tree="$REPO_ROOT"
    sb=$(mktemp -d "$TEST_BASE/sb.XXXXXX") || return 1
    proj=$(mktemp -d "$TEST_BASE/proj.XXXXXX") || return 1
    mkdir -p "$sb/cortado-cache" && chmod 700 "$sb/cortado-cache"
    printf '%s\n' 'MODULE_ORDER="context,model"' 'MODULE_CONTEXT="true"' 'MODULE_MODEL="true"' \
        "COLOR_THEME=\"$theme\"" "DISPLAY_MODE=\"$mode\"" "LAYOUT_MODE=\"$layout\"" \
        "TERMINAL_WIDTH=$width" > "$proj/.cortado.conf"
    chmod 600 "$proj/.cortado.conf"
    case "$kind" in
        refused) printf '%s\n' 'MODEL_ICON=x' > "$sb/cortado.conf"; chmod 666 "$sb/cortado.conf" ;;
        partly) printf '%s\n' 'MODEL_ICON="$(true)"' > "$sb/cortado.conf"; chmod 600 "$sb/cortado.conf" ;;
        both)
            # The packaged config is read as data too, so an unread line there
            # plus a refused user config shows both notices.
            tree="$sb/tree"
            mkdir "$tree" && cp -R "$REPO_ROOT/cortado.sh" "$REPO_ROOT/cortado.conf" "$REPO_ROOT/VERSION" \
                "$REPO_ROOT/lib" "$REPO_ROOT/modules" "$tree/" || return 1
            printf '%s\n' 'MODEL_ICON="$(true)"' >> "$tree/cortado.conf"
            chmod 600 "$tree/cortado.conf"
            printf '%s\n' 'MODEL_ICON=x' > "$sb/cortado.conf"; chmod 666 "$sb/cortado.conf" ;;
    esac
    printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}' "$proj" \
        | CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" 2>/dev/null \
        | sed $'s/\x1b\\[[0-9;]*m//g'
}

# Compact mode joins sections with no spaces around the separator.
sep_for() { if [ "$1" = compact ]; then printf '|'; else printf ' | '; fi; }

first_line() { printf '%s\n' "$1" | head -n 1; }

echo "=== wording, in every theme and display mode (width 200, layout none) ==="
for theme in default monochrome; do
    for mode in normal compact; do
        sep=$(sep_for "$mode")
        out=$(render refused "$theme" "$mode" none 200)
        assert_contains "refused $theme/$mode names cortado doctor" "$REFUSED$sep" "$out"
        assert_contains "refused $theme/$mode still renders the model" 'Opus' "$out"
        out=$(render partly "$theme" "$mode" none 200)
        assert_contains "partly $theme/$mode names cortado doctor" "$PARTLY$sep" "$out"
        assert_contains "partly $theme/$mode still renders the model" 'Opus' "$out"
    done
done

echo "=== monochrome notices stay ASCII ==="
for kind in refused partly; do
    out=$(render "$kind" monochrome normal none 200)
    notice=$(printf '%s' "$out" | sed 's/ | .*//')
    if printf '%s' "$notice" | LC_ALL=C grep -q '[^ -~]'; then
        fail "$kind notice in monochrome is ASCII only ($notice)"
    else
        pass "$kind notice in monochrome is ASCII only"
    fi
done

echo "=== no notice, no hint ==="
out=$(render none default normal none 200)
assert_not_contains 'a clean config shows no notice' 'Config' "$out"
assert_not_contains 'a clean config shows no doctor hint' 'cortado doctor' "$out"
assert_not_contains 'a clean config shows no config hint' 'cortado config' "$out"

echo "=== both notices keep their own hint ==="
out=$(render both default normal none 200)
assert_contains 'both notices render joined, each with its own hint' \
    "$REFUSED | $PARTLY | " "$out"

echo "=== narrow terminal (width 60), every layout ==="
for kind in refused partly; do
    case "$kind" in refused) notice="$REFUSED" ;; *) notice="$PARTLY" ;; esac
    for theme in default monochrome; do
        for mode in normal compact; do
            sep=$(sep_for "$mode")
            for layout in smart newline wrap truncate none; do
                label="$kind $theme/$mode/$layout at 60"
                out=$(render "$kind" "$theme" "$mode" "$layout" 60)
                first=$(first_line "$out")
                case "$layout" in
                    smart)
                        # A section moves whole to a new line; it is never split.
                        assert_eq "$label keeps the notice whole on its own line" "$notice" "$first"
                        assert_contains "$label still renders the model" 'Opus' "$out"
                        ;;
                    truncate)
                        # Truncate is a hard cut at width minus the reserve (40 here).
                        assert_contains "$label leads with its label and the start of the hint" "${notice%%: *}: run" "$first"
                        assert_match "$label ends with an ellipsis" '\.\.\.$' "$first"
                        ;;
                    *)
                        assert_contains "$label leads with the whole notice" "$notice$sep" "$first"
                        assert_contains "$label still renders the model" 'Opus' "$out"
                        ;;
                esac
            done
        done
    done
done

echo "=== a width narrower than the notice does not split it (smart) ==="
out=$(render refused default normal smart 45)
assert_eq 'the notice stays whole when it alone is wider than the line' "$REFUSED" "$(first_line "$out")"
out=$(render partly default normal smart 45)
assert_eq 'the longer notice stays whole too' "$PARTLY" "$(first_line "$out")"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
