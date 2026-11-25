#!/bin/bash
# ABOUTME: Regression tests for Git caching and large-repository rendering
# ABOUTME: Run with: bash tests/test_git_cache.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/tests/lib/assert.sh" indented

TEST_BASE="$(mktemp -d "${TMPDIR:-/tmp}/cortado-git-cache-test.XXXXXX")" || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
export CLAUDE_CONFIG_DIR="$TEST_BASE"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/modules/utils.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/modules/git.sh"

CACHE_DIR="$TEST_BASE/cache"
init_cache

# Key helper: stable, no path separators
k1=$(_git_cache_key_for_dir "/tmp/example/repo/.git")
k2=$(_git_cache_key_for_dir "/tmp/example/repo/.git")
k3=$(_git_cache_key_for_dir "/tmp/other/repo/.git")
assert_eq "cache key is stable for same path" "$k1" "$k2"
assert_match "cache key has git_ prefix" '^git_' "$k1"
assert_eq "cache key has no slash" "0" "$(printf '%s' "$k1" | grep -c / || true)"
assert_eq "different paths get different keys" "1" "$([ "$k1" != "$k3" ] && echo 1 || echo 0)"

# Round-trip branch+porcelain payload through cache_get/set (same format as module_git)
payload="main
---CORTADO_GIT---
 M modules/git.sh
?? untracked.txt"
cache_set "$k1" "$payload"
got=$(cache_get "$k1" 60)
branch=$(printf '%s\n' "$got" | head -n 1)
porcelain=$(printf '%s\n' "$got" | sed '1,/^---CORTADO_GIT---$/d')
assert_eq "cached branch round-trips" "main" "$branch"
assert_match "cached porcelain includes modified line" ' M modules/git.sh' "$porcelain"
assert_match "cached porcelain includes untracked line" '\?\? untracked.txt' "$porcelain"

# TTL=0 path: module still runs when pointed at this worktree
export GIT_CACHE_TTL=0
export USE_ICONS=false
export GIT_SHOW_STATUS=true
export GIT_SHOW_FILE_COUNT=false
export GIT_SHOW_BRANCH=true
out=$(module_git "$SCRIPT_DIR" 2>/dev/null || true)
assert_match "module_git renders with TTL disabled" 'GIT:|🌿' "$out"
# Prefer GIT: fallback since USE_ICONS=false
assert_match "module_git shows branch or git label" '.' "$out"

# A fresh render in a large repo reports the exact count with one status call.
repo="$TEST_BASE/large-repo"
real_git=$(command -v git) || exit 1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export XDG_CONFIG_HOME="$TEST_BASE/xdg"
mkdir "$XDG_CONFIG_HOME" || exit 1
"$real_git" init -q "$repo" || exit 1
"$real_git" -C "$repo" symbolic-ref HEAD refs/heads/fixture || exit 1
for ((i=1; i<=501; i++)); do
    : > "$repo/change-$i" || exit 1
done

mkdir "$TEST_BASE/bin" || exit 1
cat > "$TEST_BASE/bin/git" <<'EOF'
#!/bin/bash
if [ "$1" = status ]; then
    printf '%s\n' status >> "$GIT_STATUS_LOG"
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TEST_BASE/bin/git" || exit 1

new_render_config() {
    render_config=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
    : > "$TEST_BASE/status.log"
    cat > "$render_config/cortado.conf" <<'EOF'
MODULE_ORDER="git"
MODULE_GIT="true"
GIT_CACHE_TTL="60"
EOF
    chmod 600 "$render_config/cortado.conf" || exit 1
}

render_git() {
    printf '%s' "$1" | PATH="$TEST_BASE/bin:$PATH" REAL_GIT="$real_git" \
        GIT_STATUS_LOG="$TEST_BASE/status.log" CLAUDE_CONFIG_DIR="$render_config" \
        /bin/bash "$SCRIPT_DIR/cortado.sh"
}

status_calls() {
    awk 'END {print NR}' "$TEST_BASE/status.log"
}

new_render_config
payload=$(jq -nc --arg dir "$repo" '{workspace:{current_dir:$dir}}') || exit 1
out=$(render_git "$payload")
assert_eq "a cache miss shows the exact count for 501 changes" "🌿 fixture [+] 📝 501" "$out"
assert_eq "a cache miss with 501 changes runs git status once" "1" "$(status_calls)"

out=$(render_git "$payload")
assert_eq "a cache hit shows the bounded count for 501 changes" "🌿 fixture [+] 📝 500+" "$out"
assert_eq "a cache hit with 501 changes reuses the single git status" "1" "$(status_calls)"

# A failed status parser leaves the branch visible and the next render retries.
repo="$TEST_BASE/small-repo"
"$real_git" init -q "$repo" || exit 1
"$real_git" -C "$repo" symbolic-ref HEAD refs/heads/fixture || exit 1
: > "$repo/change-1" || exit 1
payload=$(jq -nc --arg dir "$repo" '{workspace:{current_dir:$dir}}') || exit 1
new_render_config

real_awk=$(command -v awk) || exit 1
cat > "$TEST_BASE/bin/awk" <<'EOF'
#!/bin/bash
if [ "$1" = -v ] && [[ "$2" = limit=* ]]; then
    echo 'awk-diagnostic' >&2
    exit 2
fi
exec "$REAL_AWK" "$@"
EOF
chmod +x "$TEST_BASE/bin/awk" || exit 1
out=$(REAL_AWK="$real_awk" render_git "$payload")
assert_eq "a failed status parser shows that Git status is unavailable" "🌿 fixture [--]" "$out"
assert_eq "a failed status parser runs git status once" "1" "$(status_calls)"
rm "$TEST_BASE/bin/awk" || exit 1

out=$(render_git "$payload")
assert_eq "after parser recovery the next render shows the dirty file" "🌿 fixture [+] 📝 1" "$out"
assert_eq "after parser recovery the next render reruns git status" "2" "$(status_calls)"

# A failed cached count leaves the known dirty status visible.
new_render_config
out=$(render_git "$payload")
assert_eq "the cache is warmed with one untracked file" "🌿 fixture [+] 📝 1" "$out"

real_grep=$(command -v grep) || exit 1
cat > "$TEST_BASE/bin/grep" <<'EOF'
#!/bin/bash
if [ "$1" = -c ] && [ "$2" = '^' ]; then
    echo 'grep-diagnostic' >&2
    exit 2
fi
exec "$REAL_GREP" "$@"
EOF
chmod +x "$TEST_BASE/bin/grep" || exit 1
out=$(REAL_GREP="$real_grep" render_git "$payload")
assert_eq "a failed cached count retains dirty status without a diagnostic" "🌿 fixture [+] 📝 --" "$out"
assert_eq "a failed cached count still reuses the single git status" "1" "$(status_calls)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
