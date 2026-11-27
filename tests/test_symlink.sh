#!/bin/bash
# ABOUTME: cortado.sh started through a symbolic link loads the modules, libraries
# ABOUTME: and packaged config beside the real file, never those beside the link.
# ABOUTME: Run with: /bin/bash tests/test_symlink.sh
# shellcheck disable=SC2016 # bash -c bodies expand in the shell they start.

umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented

TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
# Resolve the sandbox itself, so expected paths are physical (macOS /var -> /private/var).
TEST_BASE=$(cd "$TEST_BASE" && pwd -P) || exit 1

PAYLOAD='{"workspace":{"current_dir":"/"},"model":{"display_name":"Opus"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'
EXPECTED_LINE='CTX: 25% | MODEL: Opus'
VERSION_TEXT=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")

# A private copy of the shipped tree, in a directory whose name has a space.
TREE="$TEST_BASE/cortado tree"
mkdir -p "$TREE" || exit 1
cp -R "$REPO_ROOT/cortado.sh" "$REPO_ROOT/cortado.conf" "$REPO_ROOT/VERSION" \
    "$REPO_ROOT/lib" "$REPO_ROOT/modules" "$TREE/" || exit 1
chmod -R go-w "$TREE" || exit 1

# One sandboxed config directory per run, so no run sees another's cache.
new_config() {
    cfg=$(mktemp -d "$TEST_BASE/config.XXXXXX") || exit 1
    printf '%s\n' 'MODULE_ORDER="context,model"' 'MODULE_CONTEXT="true"' 'MODULE_MODEL="true"' \
        'COLOR_THEME="monochrome"' 'CONTEXT_SHOW_PROGRESS_BAR="false"' 'CONTEXT_SHOW_TOKENS_REMAINING="false"' \
        'USE_STATUS_INDICATORS="false"' 'TERMINAL_WIDTH=200' 'LAYOUT_MODE="none"' > "$cfg/cortado.conf"
    chmod 600 "$cfg/cortado.conf" || exit 1
}

# render <command...>: the statusline with colour escapes removed; err holds stderr.
render() {
    new_config
    printf '%s' "$PAYLOAD" | CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" \
        "$@" > "$TEST_BASE/out" 2> "$TEST_BASE/err"
    rendered_status=$?
    rendered=$(sed $'s/\x1b\\[[0-9;]*m//g' "$TEST_BASE/out")
    err=$(cat "$TEST_BASE/err")
}

# cli <command...>: run a subcommand; out holds stdout, err stderr.
cli() {
    new_config
    out=$(CLAUDE_CONFIG_DIR="$cfg" CACHE_DIR="$cfg/cortado-cache" "$@" < /dev/null 2> "$TEST_BASE/err")
    cli_status=$?
    err=$(cat "$TEST_BASE/err")
}

# check_runs <label> <command...>: render, config, version and help all work.
check_runs() {
    local label="$1"
    shift
    render "$@"
    assert_eq "$label renders the line" "$EXPECTED_LINE" "$rendered"
    assert_empty "$label renders without errors" "$err"
    cli "$@" config --path
    assert_eq "$label runs config" "$cfg/cortado.conf" "$out"
    assert_empty "$label runs config without errors" "$err"
    cli "$@" version
    assert_eq "$label runs version" "$VERSION_TEXT" "$out"
    cli "$@" help
    assert_contains "$label runs help" 'Usage:' "$out"
    assert_empty "$label runs help without errors" "$err"
}

echo "=== cortado.sh through symbolic links ==="

# The baseline: the real file, run directly.
check_runs 'the real file' /bin/bash "$TREE/cortado.sh"

# An absolute link in another directory, run the way a PATH lookup runs it.
mkdir -p "$TEST_BASE/bin" || exit 1
ln -s "$TREE/cortado.sh" "$TEST_BASE/bin/cortado" || exit 1
check_runs 'an absolute link' "$TEST_BASE/bin/cortado"
check_runs 'an absolute link run by bash' /bin/bash "$TEST_BASE/bin/cortado"

# A chain of two links: the second is relative to its own directory.
mkdir -p "$TEST_BASE/chain" || exit 1
ln -s ../bin/cortado "$TEST_BASE/chain/cortado" || exit 1
check_runs 'a chain of two links' "$TEST_BASE/chain/cortado"

# A relative link, and a link whose own path has spaces.
mkdir -p "$TEST_BASE/rel" "$TEST_BASE/my bin dir" || exit 1
ln -s "../cortado tree/cortado.sh" "$TEST_BASE/rel/cortado" || exit 1
check_runs 'a relative link' "$TEST_BASE/rel/cortado"
ln -s "$TREE/cortado.sh" "$TEST_BASE/my bin dir/cortado here" || exit 1
check_runs 'a link whose path has spaces' "$TEST_BASE/my bin dir/cortado here"

# Started by a relative path, and by bare name from the link's directory.
check_runs 'a link run by a relative path' /bin/bash -c 'cd "$1" && exec ./cortado "${@:2}"' -- "$TEST_BASE/rel"
check_runs 'a link run by bash with no directory' /bin/bash -c 'cd "$1" && exec /bin/bash cortado "${@:2}"' -- "$TEST_BASE/rel"

# --- what a link can make Cortado load ---------------------------------------
# A link beside decoy lib/, modules/ and cortado.conf loads none of them.
decoy="$TEST_BASE/decoy"
mkdir -p "$decoy/lib" "$decoy/modules" || exit 1
for lib_file in "$TREE"/lib/*.sh; do
    printf '%s\n' "printf 'DECOY-LIB\\n' >&2" > "$decoy/lib/${lib_file##*/}"
done
printf '%s\n' "printf 'DECOY-MODULE\\n' >&2" > "$decoy/modules/utils.sh"
printf '%s\n' 'MODULE_ORDER="model"' > "$decoy/cortado.conf"
# A file for a wrong resolution to land on; bash never runs it.
printf '%s\n' "printf 'DECOY-SCRIPT\\n' >&2" > "$decoy/cortado.sh"
chmod 600 "$decoy/cortado.conf" || exit 1
ln -s "$TREE/cortado.sh" "$decoy/cortado" || exit 1
render "$decoy/cortado"
assert_eq 'a link beside a decoy tree renders from the real tree' "$EXPECTED_LINE" "$rendered"
assert_not_contains 'a link never sources a lib/ beside it' 'DECOY-LIB' "$err"
assert_not_contains 'a link never sources modules beside it' 'DECOY-MODULE' "$err"

# A relative target resolves against the link's physical directory, as the
# kernel does. Reached through a linked directory at another depth, "../../"
# read logically would land on the decoy instead of the real tree.
mkdir -p "$TEST_BASE/real/deep/bin" "$TEST_BASE/shallow" || exit 1
ln -s "$TREE" "$TEST_BASE/real/tree-link" || exit 1
ln -s "$decoy" "$TEST_BASE/tree-link" || exit 1
ln -s ../../tree-link/cortado.sh "$TEST_BASE/real/deep/bin/cortado" || exit 1
ln -s ../real/deep/bin "$TEST_BASE/shallow/bin" || exit 1
check_runs 'a relative link reached through a linked directory' "$TEST_BASE/shallow/bin/cortado"
render "$TEST_BASE/shallow/bin/cortado"
assert_not_contains 'a relative link through a linked directory never loads the logical neighbour' 'DECOY' "$err"

# The same decoys in the working directory are not loaded either.
render /bin/bash -c 'cd "$1" && exec "$2"' -- "$decoy" "$TEST_BASE/bin/cortado"
assert_eq 'a link run from a decoy directory renders from the real tree' "$EXPECTED_LINE" "$rendered"
assert_not_contains 'a link never sources a lib/ in the working directory' 'DECOY-LIB' "$err"

# The packaged config's trust check runs on the resolved file.
unsafe="$TEST_BASE/unsafe tree"
cp -R "$TREE" "$unsafe" || exit 1
chmod -R go-w "$unsafe" || exit 1
printf '%s\n' 'MODULE_ORDER="model"' > "$unsafe/cortado.conf"
chmod 666 "$unsafe/cortado.conf" || exit 1
mkdir -p "$TEST_BASE/unsafe-bin" || exit 1
ln -s "$unsafe/cortado.sh" "$TEST_BASE/unsafe-bin/cortado" || exit 1
render "$TEST_BASE/unsafe-bin/cortado"
assert_contains 'a link to a tree with a writable packaged config is refused by name' \
    "refusing to source config $(printf '%q' "$unsafe/cortado.conf")" "$err"
assert_contains 'the refused packaged config is reported as group- or world-writable' \
    'group- or world-writable' "$err"
assert_not_contains 'a refused packaged config does not set the module order' 'MODEL: Opus' "${rendered%% | *}"

# --- links that cannot be followed stop, and load nothing ----------------------
assert_refused() {
    local label="$1"
    shift
    render "$@"
    assert_eq "$label exits 1" 1 "$rendered_status"
    assert_empty "$label prints no line" "$rendered"
    assert_contains "$label says why" 'cortado: could not follow the link to cortado.sh' "$err"
    assert_not_contains "$label sources nothing" 'DECOY' "$err"
}

# A loop or an over-long chain cannot be executed at all (the kernel refuses
# it), so these arise only when a link changes after bash opened the script.
# A readlink shim on PATH plays that change.
shim_dir="$TEST_BASE/shim"
mkdir -p "$shim_dir" || exit 1
REAL_READLINK=$(command -v readlink) || exit 1
export REAL_READLINK
cat > "$shim_dir/readlink" <<'SHIM'
#!/bin/bash
printf 'call\n' >> "$READLINK_LOG"
case "$READLINK_CASE" in
    fail) printf '%s' cortado.sh; exit 1 ;;
    self) last="${!#}"; printf '%s' "${last##*/}" ;;
    missing) printf '%s' 'no-such-cortado.sh' ;;
    directory) printf '%s' '/' ;;
    *) exec "$REAL_READLINK" "$@" ;;
esac
SHIM
chmod 700 "$shim_dir/readlink" || exit 1
# The link sits beside decoys, and runs from a decoy working directory.
ln -s "$TREE/cortado.sh" "$decoy/cortado-raced" || exit 1
READLINK_LOG="$TEST_BASE/readlink.log"
export READLINK_LOG
for case_name in fail self missing directory; do
    : > "$READLINK_LOG"
    case "$case_name" in
        fail) label='a link that cannot be read' ;;
        self) label='a link that loops past the hop limit' ;;
        missing) label='a link to a missing file' ;;
        directory) label='a link to a directory' ;;
    esac
    render /usr/bin/env PATH="$shim_dir:$PATH" READLINK_CASE="$case_name" \
        /bin/bash -c 'cd "$1" && exec /bin/bash "$2"' -- "$decoy" "$decoy/cortado-raced"
    assert_eq "$label exits 1" 1 "$rendered_status"
    assert_empty "$label prints no line" "$rendered"
    assert_contains "$label says why" 'cortado: could not follow the link to cortado.sh' "$err"
    assert_not_contains "$label sources nothing beside the link or in the working directory" 'DECOY' "$err"
    if [ "$case_name" = self ]; then
        assert_eq 'a looping link is read 40 times, then refused' 40 "$(wc -l < "$READLINK_LOG" | tr -d ' ')"
    fi
done
# The shim passes a real lookup through, so the guard above is not vacuous.
render /usr/bin/env PATH="$shim_dir:$PATH" READLINK_CASE=pass \
    /bin/bash -c 'cd "$1" && exec /bin/bash "$2"' -- "$decoy" "$decoy/cortado-raced"
assert_eq 'a readable link through the shim renders the line' "$EXPECTED_LINE" "$rendered"

# A chain of 30 links is followed. The hop limit (40) matches Linux's and is
# above macOS's (32), so no chain a kernel accepts is refused.
mkdir -p "$TEST_BASE/long" || exit 1
ln -s "$TREE/cortado.sh" "$TEST_BASE/long/link0" || exit 1
i=1
while [ "$i" -lt 30 ]; do
    ln -s "link$((i - 1))" "$TEST_BASE/long/link$i" || exit 1
    i=$((i + 1))
done
render /bin/bash "$TEST_BASE/long/link29"
assert_eq 'a chain of 30 links renders the line' "$EXPECTED_LINE" "$rendered"

# A link whose target ends in a newline, in a chain: the readlink sentinel keeps
# the newline, so the next hop names the real file.
mkdir -p "$TEST_BASE/nl" || exit 1
ln -s "$TREE/cortado.sh" "$TEST_BASE/nl/mid"$'\n' || exit 1
ln -s "mid"$'\n' "$TEST_BASE/nl/start" || exit 1
render /bin/bash "$TEST_BASE/nl/start"
assert_eq 'a link whose target ends in a newline renders the line' "$EXPECTED_LINE" "$rendered"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
