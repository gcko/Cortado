# shellcheck shell=bash
# Standalone suites can select their existing diagnostic style when sourcing this file.
ASSERT_STYLE="${1:-indented}"
PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    case "$ASSERT_STYLE" in
        indented*) printf '  PASS: %s\n' "$1" ;;
        *) printf 'PASS: %s\n' "$1" ;;
    esac
}

fail() {
    FAIL=$((FAIL + 1))
    case "$ASSERT_STYLE" in
        indented*) printf '  FAIL: %s\n' "$1" ;;
        *) printf 'FAIL: %s\n' "$1" ;;
    esac
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
        return
    fi

    case "$ASSERT_STYLE" in
        indented)
            fail "$desc"
            printf "    expected: '%s'\n    actual:   '%s'\n" "$expected" "$actual"
            ;;
        indented-unquoted)
            fail "$desc"
            printf '    expected: %s\n    actual:   %s\n' "$expected" "$actual"
            ;;
        plain-comma) fail "$desc (expected [$expected], got [$actual])" ;;
        plain-dash) fail "$desc — expected [$expected] got [$actual]" ;;
        *) fail "$desc (expected [$expected] got [$actual])" ;;
    esac
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *)
            if [ "$ASSERT_STYLE" = indented ]; then
                fail "$desc (missing '$needle')"
                printf '    in: %s\n' "$haystack"
            else
                fail "$desc (missing [$needle] in [$haystack])"
            fi
            ;;
    esac
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) fail "$desc (unexpected [$needle] in [$haystack])" ;;
        *) pass "$desc" ;;
    esac
}

assert_file_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF "$needle" "$file" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc (missing '$needle' in $file)"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -Eq "$pattern"; then
        pass "$desc"
    else
        fail "$desc"
        printf "    pattern: '%s'\n    actual:  '%s'\n" "$pattern" "$actual"
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        pass "$desc"
    else
        fail "$desc"
        printf "    expected empty, got: '%s'\n" "$actual"
    fi
}

assert_rc() {
    local desc="$1" expected="$2"
    shift 2
    "$@"
    assert_eq "$desc" "$expected" "$?"
}
