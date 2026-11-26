#!/bin/bash
# Run the requested suites, or all standalone suites, with the jq on PATH and,
# on macOS, the JSON suites again with Apple's /usr/bin/jq.
#
#   /bin/bash tests/run-jq-variants.sh [--variant path|apple|all] [suite...]
#   /bin/bash tests/run-jq-variants.sh --list path|apple [suite...]
#
# The path variant runs every requested suite. The apple variant runs only the
# requested suites named in tests/jq-suites.txt (CORTADO_JQ_SUITES_FILE
# overrides it), because only their results depend on how jq parses JSON.
# The default, all, runs the path variant and then, when /usr/bin/jq exists on
# macOS, the apple variant. --list prints the suites a variant would run.
# Each variant runs its suites in parallel through tests/run-suites.sh.
set -u

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jq_list="${CORTADO_JQ_SUITES_FILE:-$test_dir/jq-suites.txt}"

variant=all
list=false
case "${1:-}" in
    --variant|--list)
        [ "$1" = --list ] && list=true
        variant="${2:-}"
        shift 2 2>/dev/null || shift $#
        ;;
esac
case "$list:$variant" in
    false:all|false:path|false:apple|true:path|true:apple) ;;
    *)
        echo "usage: run-jq-variants.sh [--variant path|apple|all | --list path|apple] [suite...]" >&2
        exit 2 ;;
esac
if [ "$#" -eq 0 ]; then
    set -- "$test_dir"/test_*.sh
fi
# A missing suite is a usage error in every mode, before any filtering could
# drop it from the apple variant or a listing.
for suite in "$@"; do
    [ -f "$suite" ] || { echo "run-jq-variants: no such suite: $suite" >&2; exit 2; }
done

# The JSON suites: the first word of each line, without comments, blank lines
# or "!" exclusions.
json_suites=" "
if [ "$variant" != path ]; then
    [ -r "$jq_list" ] || { echo "jq suite list missing: $jq_list" >&2; exit 1; }
    while read -r name _ || [ -n "${name:-}" ]; do
        case "$name" in ''|'#'*|'!'*) ;; *) json_suites="$json_suites$name " ;; esac
        name=
    done < "$jq_list"
fi

apple_suites=()
for suite in "$@"; do
    case "$json_suites" in *" ${suite##*/} "*) apple_suites+=("$suite") ;; esac
done

if [ "$list" = true ]; then
    if [ "$variant" = path ]; then
        for suite in "$@"; do printf '%s\n' "${suite##*/}"; done
    else
        for suite in ${apple_suites[@]+"${apple_suites[@]}"}; do printf '%s\n' "${suite##*/}"; done
    fi
    exit 0
fi

path_jq=$(type -P jq) || { echo "jq missing from PATH" >&2; exit 1; }
if [ "$(uname -s)" = Darwin ] && [ "$path_jq" -ef /usr/bin/jq ]; then
    # Apple's jq may be first on PATH even with Homebrew installed.
    while IFS= read -r candidate; do
        if ! [ "$candidate" -ef /usr/bin/jq ]; then
            path_jq="$candidate"
            break
        fi
    done < <(type -ap jq)
fi
case "$path_jq" in
    /*) ;;
    *) path_jq="$PWD/$path_jq" ;;
esac

apple_available=false
if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/jq ]; then
    apple_available=true
fi
if [ "$variant" = apple ] && [ "$apple_available" != true ]; then
    echo "Apple jq (/usr/bin/jq on macOS) is not available" >&2
    exit 1
fi
if [ "$variant" = path ] && [ "$path_jq" -ef /usr/bin/jq ] && [ "$apple_available" = true ]; then
    echo "only Apple jq is on PATH; install Homebrew jq for the path variant" >&2
    exit 1
fi

test_bin=$(mktemp -d) || exit 1
trap 'rm -rf "$test_bin"' EXIT
failed=0
run_variant() {
    local jq_bin="$1"
    shift
    ln -sf "$jq_bin" "$test_bin/jq" || exit 1
    printf '\n=== %s (%s): %s suites ===\n' "$jq_bin" "$("$jq_bin" --version)" "$#"
    PATH="$test_bin:$PATH" /bin/bash "$test_dir/run-suites.sh" "$@" || failed=1
}

if [ "$variant" != apple ]; then
    run_variant "$path_jq" "$@"
fi
if [ "$variant" = apple ] || { [ "$variant" = all ] && [ "$apple_available" = true ] &&
    ! [ "$path_jq" -ef /usr/bin/jq ]; }; then
    if [ "${#apple_suites[@]}" -gt 0 ]; then
        run_variant /usr/bin/jq "${apple_suites[@]}"
    else
        printf '\n=== /usr/bin/jq: no JSON suites requested ===\n'
    fi
fi
exit "$failed"
