#!/bin/bash
# ABOUTME: Regression tests for Git caching and large-repository rendering
# ABOUTME: Run with: bash tests/test_git_cache.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -Eq "$pattern"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    pattern: '$pattern'"
        echo "    actual:  '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

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
"$real_git" init -q "$repo" || exit 1
"$real_git" -C "$repo" symbolic-ref HEAD refs/heads/fixture || exit 1
for ((i=1; i<=501; i++)); do
    : > "$repo/change-$i" || exit 1
done

render_config=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
mkdir "$TEST_BASE/bin" || exit 1
cat > "$TEST_BASE/bin/git" <<'EOF'
#!/bin/bash
if [ "$1" = status ]; then
    printf '%s\n' status >> "$GIT_STATUS_LOG"
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TEST_BASE/bin/git" || exit 1
: > "$TEST_BASE/status.log"
cat > "$render_config/cortado.conf" <<'EOF'
MODULE_ORDER="git"
MODULE_GIT="true"
GIT_CACHE_TTL="60"
EOF
chmod 600 "$render_config/cortado.conf" || exit 1
payload=$(jq -nc --arg dir "$repo" '{workspace:{current_dir:$dir}}') || exit 1
out=$(printf '%s' "$payload" | PATH="$TEST_BASE/bin:$PATH" REAL_GIT="$real_git" \
    GIT_STATUS_LOG="$TEST_BASE/status.log" CLAUDE_CONFIG_DIR="$render_config" \
    /bin/bash "$SCRIPT_DIR/cortado.sh")
assert_eq "a cache miss shows the exact count for 501 changes" "🌿 fixture [+] 📝 501" "$out"
assert_eq "a cache miss with 501 changes runs git status once" "1" \
    "$(awk 'END {print NR}' "$TEST_BASE/status.log")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
