# shellcheck shell=bash
# @cortado-module git
# @default true
# @args dir
# @ttl 2
# @timeout-ms 0
# @platforms darwin,linux
# @menu core 6
# @description Git branch/status
# @config GIT_ICON:string
# @config GIT_SHOW_BRANCH:bool
# @config GIT_SYMBOL_MODIFIED:string
# @config GIT_SYMBOL_UNTRACKED:string
# @config GIT_SYMBOL_STAGED:string
# @config GIT_FILE_ICON:string
# @config GIT_COMPACT:bool
# =============================================================================
# Git Module - Shows branch, status, and file count
# =============================================================================
# Configuration options:
#   GIT_ICON              - Icon before branch name (default: 🌿)
#   GIT_SHOW_BRANCH       - Show branch name (default: true)
#   GIT_SHOW_STATUS       - Show status symbols (default: true)
#   GIT_SHOW_FILE_COUNT    - Show modified file count (default: true)
#   GIT_SYMBOL_MODIFIED    - Symbol for modified files (default: ●)
#   GIT_SYMBOL_UNTRACKED  - Symbol for untracked files (default: +)
#   GIT_SYMBOL_STAGED      - Symbol for staged files (default: ✓)
#   GIT_FILE_ICON          - Icon before file count (default: 📝)
#   GIT_COMPACT            - Compact mode (default: false)
#   GIT_CACHE_TTL          - Seconds to TTL-cache git subprocess output (default: 2).
#                           Set 0 to disable. Cache busts early if .git/HEAD or
#                           .git/index is newer than the cache entry (issue #26).
# =============================================================================

# The key, age, and Git metadata can be read in one process on a warm render.
_git_cache_snapshot() {
    perl -MCwd=abs_path -MDigest::SHA=sha256_hex -e '
        my ($gitdir, $dir, $ttl) = @ARGV;
        $gitdir = abs_path($gitdir) // $gitdir;
        my $key = "git_" . substr(sha256_hex($gitdir), 0, 16);
        print "$key\n";
        exit 0 unless defined $ttl;
        my $cache = "$dir/$key";
        if (!-f $cache || !open(my $file, "<", $cache)) {
            print "miss\n";
            exit 0;
        } else {
            my $stamp = (stat($file))[9];
            if (!defined $stamp || time - $stamp > $ttl) {
                print "miss\n";
                exit 0;
            }
            for my $name (qw(HEAD index)) {
                my @entry = stat("$gitdir/$name");
                if (@entry && $entry[9] > $stamp) {
                    print "stale\n";
                    exit 0;
                }
            }
            print "hit\n";
            print while <$file>;
        }
    ' -- "$@" 2>/dev/null
}

_git_cache_key_for_dir() {
    _git_cache_snapshot "$1"
}

module_git() {
    local current_dir="$1"
    local icon
    local show_branch="${GIT_SHOW_BRANCH:-true}"
    local show_status="${GIT_SHOW_STATUS:-true}"
    local show_count="${GIT_SHOW_FILE_COUNT:-true}"
    local sym_modified="${GIT_SYMBOL_MODIFIED:-●}"
    local sym_untracked="${GIT_SYMBOL_UNTRACKED:-+}"
    local sym_staged="${GIT_SYMBOL_STAGED:-✓}"
    local file_icon
    local compact="${GIT_COMPACT:-false}"
    local show_file_count=false
    if [ "$show_count" = "true" ] && ! is_compact "$compact"; then
        show_file_count=true
    fi
    # TTL default 2s; 0 disables (scoping note #26 Phase 1)
    local git_ttl="${GIT_CACHE_TTL:-2}"

    # Safety check: ensure directory exists and is accessible
    if [ -z "$current_dir" ] || [ ! -d "$current_dir" ]; then
        return
    fi

    # Save current directory and change to target
    local orig_dir="$PWD"
    cd "$current_dir" 2>/dev/null || return

    # Quick check: are we in a git repo?
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || {
        cd "$orig_dir" 2>/dev/null || return
        return
    }

    # A workspace outside a repository has no Git segment to format.
    get_icon_reply "${GIT_ICON:-🌿}" "GIT:"; icon=$REPLY
    if [ "$show_file_count" = "true" ]; then
        get_icon_reply "${GIT_FILE_ICON:-📝}" ""; file_icon=$REPLY
    fi
    local cache_key=""
    local use_cache=false
    local git_branch=""
    local git_porcelain=""
    local from_cache=false
    local max_lines=500
    local status_count=0
    local status_available=true

    # Numeric TTL > 0 enables cache (non-numeric → treat as disabled)
    case "$git_ttl" in
        ''|*[!0-9]*) git_ttl=0 ;;
    esac
    if [ "$git_ttl" -gt 0 ] 2>/dev/null; then
        local snapshot cached
        if snapshot=$(_git_cache_snapshot "$git_dir" "$CACHE_DIR" "$git_ttl"); then
            use_cache=true
            cache_key=${snapshot%%$'\n'*}
            cached=${snapshot#*$'\n'}
            case "$cached" in
                stale)
                    # Git owns this namespace. Its invalidation does not
                    # wait for an unrelated probe to publish a reading.
                    rm -f -- "$CACHE_DIR/$cache_key" 2>/dev/null ;;
                hit$'\n'*)
                    cached=${cached#*$'\n'}
                    git_branch=${cached%%$'\n'*}
                    if [ -n "$git_branch" ]; then
                        from_cache=true
                        if [[ "$cached" == *$'\n---CORTADO_GIT---\n'* ]]; then
                            git_porcelain=${cached#*$'\n---CORTADO_GIT---\n'}
                        fi
                    fi ;;
            esac
        fi
    fi

    if [ "$from_cache" != "true" ]; then
        # Get branch name (handles detached HEAD)
        git_branch=$(git symbolic-ref --short HEAD 2>/dev/null) || git_branch=""
        if [ -z "$git_branch" ]; then
            # Detached HEAD - show short SHA
            git_branch=$(git rev-parse --short HEAD 2>/dev/null) || git_branch=""
            if [ -n "$git_branch" ]; then
                git_branch="($git_branch)"
            fi
        fi

        if [ "$show_status" = "true" ] || [ "$show_file_count" = "true" ]; then
            # Bound the sample, but drain the stream so Git can exit normally.
            local status_output
            if status_output=$(
                set -o pipefail
                git status --porcelain 2>/dev/null |
                    awk -v limit="$max_lines" '
                        NR <= limit { print }
                        END { printf "%.0f\n", NR }
                    ' 2>/dev/null
            ); then
                status_count=${status_output##*$'\n'}
                git_porcelain=${status_output%"$status_count"}
                git_porcelain=${git_porcelain%$'\n'}
                if [ "$use_cache" = "true" ] && [ -n "$git_branch" ]; then
                    # Store the complete branch + porcelain snapshot.
                    cache_set "$cache_key" "${git_branch}
---CORTADO_GIT---
${git_porcelain}"
                fi
            else
                status_available=false
            fi
        fi
    fi

    local result="$icon"

    # Branch name
    if [ "$show_branch" = "true" ]; then
        result="$result ${git_branch:---}"
    fi

    if [ "$status_available" = "false" ]; then
        result="$result [--]"
    else
        if [ "$show_status" = "true" ]; then
            local has_modified=false
            local has_untracked=false
            local has_staged=false

            # Parse porcelain output efficiently
            # Format: XY filename
            # X = index status, Y = worktree status
            while IFS= read -r line; do
                [ -z "$line" ] && continue

                local index_status="${line:0:1}"
                local worktree_status="${line:1:1}"

                # Staged changes (index has changes)
                case "$index_status" in
                    [MADRC]) has_staged=true ;;
                esac

                # Modified in worktree
                case "$worktree_status" in
                    [MD]) has_modified=true ;;
                esac

                # Untracked files
                if [ "$index_status" = "?" ]; then
                    has_untracked=true
                fi

                # Early exit if we found all types
                if [ "$has_modified" = "true" ] && [ "$has_untracked" = "true" ] && [ "$has_staged" = "true" ]; then
                    break
                fi
            done <<< "$git_porcelain"

            # Build status string
            local git_status=""
            [ "$has_modified" = "true" ] && git_status="${git_status}${sym_modified}"
            [ "$has_untracked" = "true" ] && git_status="${git_status}${sym_untracked}"
            [ "$has_staged" = "true" ] && git_status="${git_status}${sym_staged}"

            if [ -n "$git_status" ]; then
                result="$result [$git_status]"
            fi
        fi

        # File count (skip in compact mode)
        if [ "$show_file_count" = "true" ]; then
            local count_display=""
            if [ "$from_cache" = "true" ] && [ -n "$git_porcelain" ]; then
                while IFS= read -r line; do
                    status_count=$((status_count + 1))
                done <<< "$git_porcelain"
            fi
            if [ "$status_count" -gt 0 ] 2>/dev/null; then
                count_display="$status_count"
                # A full cached sample may have been truncated.
                if [ "$from_cache" = "true" ] && [ "$status_count" -ge "$max_lines" ]; then
                    count_display="${status_count}+"
                fi
            fi
            if [ -n "$count_display" ]; then
                if [ -n "$file_icon" ]; then
                    result="$result $file_icon $count_display"
                else
                    result="$result $count_display files"
                fi
            fi
        fi
    fi

    # Return to original directory (best-effort; the result must still print)
    cd "$orig_dir" 2>/dev/null || true

    echo "$result"
}
