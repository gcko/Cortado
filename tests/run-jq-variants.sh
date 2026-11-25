#!/bin/bash
# Run the requested suites, or all standalone suites, with the jq on PATH
# and with the bundled jq on macOS.
set -u

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then
    set -- "$test_dir"/test_*.sh
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

variants=("$path_jq")
if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/jq ] && ! [ "$path_jq" -ef /usr/bin/jq ]; then
    variants+=(/usr/bin/jq)
fi

test_bin=$(mktemp -d) || exit 1
trap 'rm -rf "$test_bin"' EXIT
failed=0
for jq_bin in "${variants[@]}"; do
    ln -sf "$jq_bin" "$test_bin/jq" || exit 1
    printf '\n=== %s (%s) ===\n' "$jq_bin" "$("$jq_bin" --version)"
    for suite in "$@"; do
        # Bound each suite so a hang names itself instead of stalling CI.
        status=0
        PATH="$test_bin:$PATH" perl -e 'alarm shift; exec @ARGV' "${SUITE_TIMEOUT:-300}" \
            /bin/bash "$suite" > "$test_bin/output" 2>&1 || status=$?
        if [ "$status" -eq 0 ]; then
            printf 'PASS: %s\n' "${suite##*/}"
        elif [ "$status" -eq 142 ]; then
            printf 'TIMEOUT: %s (over %ss)\n' "${suite##*/}" "${SUITE_TIMEOUT:-300}"
            cat "$test_bin/output"
            failed=1
        else
            printf 'FAIL: %s\n' "${suite##*/}"
            cat "$test_bin/output"
            failed=1
        fi
    done
done
exit "$failed"
