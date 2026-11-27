# shellcheck shell=bash
# shellcheck disable=SC2016,SC2088,SC1003 # Words like '$HOME' and '~/' are matched as literal text.
# =============================================================================
# cortado doctor - check an install end to end
# =============================================================================
# Sourced by cortado.sh for `cortado doctor [--no-color] [--no-emoji]`. Each
# check prints one pass, FAIL or info line, and a failure carries the command
# that fixes it. Exit 0 when every check passes, 1 otherwise.
#
# Read-only: no network request, no file written. The one thing it runs is a
# render of THIS copy against a built-in sample payload, in a temporary
# CLAUDE_CONFIG_DIR that is removed afterwards. The command found in
# settings.json is arbitrary user text: it is split into words and looked up
# as a path, and never run, expanded by a shell or evaluated.
#
# Needs from cortado.sh: SCRIPT_DIR, CLAUDE_CONFIG_DIR, CORTADO_OS (resolved),
# and lib/config-permissions.sh, lib/config-data.sh and lib/platform.sh loaded.
# =============================================================================

_DOCTOR_CHECKS=0
_DOCTOR_FAILS=0
_DOCTOR_SELF=
_DOCTOR_PLATFORM_OK=0

_doctor_init_style() {
    local color=true emoji=true arg
    for arg in "$@"; do
        case "$arg" in
            --no-color) color=false ;;
            --no-emoji) emoji=false ;;
        esac
    done
    if [ "$color" = true ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${USE_COLOR:-true}" != false ]; then
        _DOCTOR_GREEN=$'\033[32m' _DOCTOR_RED=$'\033[31m' _DOCTOR_DIM=$'\033[2m' _DOCTOR_NC=$'\033[0m'
    else
        _DOCTOR_GREEN='' _DOCTOR_RED='' _DOCTOR_DIM='' _DOCTOR_NC=''
    fi
    if [ "$emoji" = true ]; then
        _DOCTOR_TAG_OK='✓    ' _DOCTOR_TAG_FAIL='✗    ' _DOCTOR_TAG_INFO='-    '
    else
        _DOCTOR_TAG_OK='ok   ' _DOCTOR_TAG_FAIL='FAIL ' _DOCTOR_TAG_INFO='info '
    fi
}

# Text from a file, a command or the environment is printed with its control
# bytes replaced, so it cannot drive the terminal. Sets REPLY.
_doctor_clean() {
    local text="$1" max="${2:-0}"
    {
        local LC_ALL=C
        text="${text//[[:cntrl:]]/?}"
    }
    # Cut by characters, in the caller's locale, so a multibyte one stays whole.
    if [ "$max" -gt 0 ] && [ "${#text}" -gt "$max" ]; then
        text="${text:0:$((max - 3))}..."
    fi
    REPLY="$text"
}

# Single-quote a word for a command the user may paste. Sets REPLY.
_doctor_quote() {
    local q="'"
    REPLY="'${1//$q/$q\\$q$q}'"
}

# _doctor_emit <tag> <colour> <text> [detail...]
_doctor_emit() {
    local tag="$1" colour="$2" text="$3" detail
    shift 3
    printf '%s%s%s %s\n' "$colour" "$tag" "$_DOCTOR_NC" "$text"
    for detail in "$@"; do
        printf '      %s%s%s\n' "$_DOCTOR_DIM" "$detail" "$_DOCTOR_NC"
    done
}

_doctor_ok() {
    _DOCTOR_CHECKS=$((_DOCTOR_CHECKS + 1))
    _doctor_emit "$_DOCTOR_TAG_OK" "$_DOCTOR_GREEN" "$@"
}

_doctor_info() {
    _doctor_emit "$_DOCTOR_TAG_INFO" "$_DOCTOR_DIM" "$@"
}

# _doctor_fail <text> <fix command, or empty> [detail...]
_doctor_fail() {
    local text="$1" fix="$2"
    shift 2
    _DOCTOR_CHECKS=$((_DOCTOR_CHECKS + 1))
    _DOCTOR_FAILS=$((_DOCTOR_FAILS + 1))
    _doctor_emit "$_DOCTOR_TAG_FAIL" "$_DOCTOR_RED" "$text" "$@" ${fix:+"fix: $fix"}
}

# Set REPLY to the physical path a path finally names, following every link.
_doctor_resolve() {
    local path="$1" dir target hops=0
    case "$path" in */*) ;; *) path="./$path" ;; esac
    while :; do
        dir=$(CDPATH='' builtin cd -P -- "${path%/*}/" 2>/dev/null && pwd) || return 1
        path="${dir%/}/${path##*/}"
        [ -L "$path" ] || break
        [ "$hops" -lt 40 ] || return 1
        hops=$((hops + 1))
        target=$(command readlink "$path") || return 1
        case "$target" in
            /*) path="$target" ;;
            *) path="${path%/*}/$target" ;;
        esac
    done
    REPLY="$path"
}

# How to start this copy in a fix: by name when the cortado command is this
# copy, else by its path. Sets _DOCTOR_SELF.
_doctor_find_self() {
    local found self="$SCRIPT_DIR/cortado.sh" REPLY
    _DOCTOR_SELF=
    if found=$(command -v cortado 2>/dev/null) && [ -n "$found" ] && [ "$found" -ef "$self" ]; then
        _DOCTOR_SELF=cortado
        return
    fi
    _doctor_quote "$self"
    _DOCTOR_SELF="$REPLY"
}

# Where a tool comes from, by platform. Sets REPLY.
_doctor_install_hint() {
    case "${CORTADO_OS:-}" in
        darwin) REPLY="brew install $1" ;;
        *) REPLY="sudo apt install $1" ;;
    esac
}

# --- tools -------------------------------------------------------------------

_doctor_check_tools() {
    local version REPLY
    if command -v jq >/dev/null 2>&1; then
        version=$(jq --version 2>/dev/null)
        _doctor_clean "${version:-version unknown}" 40
        _doctor_ok "jq: found ($REPLY)"
    else
        _doctor_install_hint jq
        _doctor_fail 'jq: not found' "$REPLY" 'Cortado needs jq to read the data Claude Code sends.'
    fi
    if command -v perl >/dev/null 2>&1; then
        version=$(perl -e 'printf "%vd", $^V' 2>/dev/null)
        _doctor_clean "${version:-version unknown}" 40
        _doctor_ok "perl: found ($REPLY)"
    else
        _doctor_install_hint perl
        _doctor_fail 'perl: not found' "$REPLY" 'Cortado needs Perl for file locks and checksums.'
    fi
    if command -v bc >/dev/null 2>&1; then
        _doctor_info 'bc: found (optional: only the temperature module uses it)'
    else
        _doctor_info 'bc: not found (optional: only the temperature module uses it)'
    fi
}

# --- settings.json -----------------------------------------------------------

# Split command text into words the way a shell would for plain commands, set
# in _DOCTOR_WORDS. Quotes group, a backslash escapes, and an unquoted
# ; | & < > ( ) ends a word (and is dropped). Text that a shell would take
# literally (inside single quotes, or escaped) has its $, ` and ~ swapped for
# placeholder bytes, so only unquoted text can start an expansion. Nothing is run.
_DOCTOR_DOLLAR=$'\001' _DOCTOR_TICK=$'\002' _DOCTOR_TILDE=$'\003'
_doctor_split() {
    local text="$1" i c word='' state=none have=false
    _DOCTOR_WORDS=()
    for ((i = 0; i < ${#text}; i++)); do
        c="${text:i:1}"
        case "$state" in
            single)
                if [ "$c" = "'" ]; then state=none; else _doctor_literal "$c"; word+="$REPLY"; fi
                ;;
            double)
                case "$c" in
                    '"') state=none ;;
                    '\')
                        i=$((i + 1))
                        _doctor_literal "${text:i:1}"; word+="$REPLY"
                        ;;
                    '~') word+="$_DOCTOR_TILDE" ;;
                    *) word+="$c" ;;
                esac
                ;;
            *)
                case "$c" in
                    "'") state=single have=true ;;
                    '"') state=double have=true ;;
                    '\')
                        i=$((i + 1))
                        _doctor_literal "${text:i:1}"; word+="$REPLY" have=true
                        ;;
                    [[:space:]\;\|\&\<\>\(\)])
                        if [ "$have" = true ] || [ -n "$word" ]; then _DOCTOR_WORDS+=("$word"); fi
                        word='' have=false
                        ;;
                    *) word+="$c" have=true ;;
                esac
                ;;
        esac
    done
    if [ "$have" = true ] || [ -n "$word" ]; then _DOCTOR_WORDS+=("$word"); fi
}

# REPLY is $1, with a character that would expand replaced by its placeholder.
_doctor_literal() {
    case "$1" in
        '$') REPLY="$_DOCTOR_DOLLAR" ;;
        '`') REPLY="$_DOCTOR_TICK" ;;
        '~') REPLY="$_DOCTOR_TILDE" ;;
        *) REPLY="$1" ;;
    esac
}

# Expand a leading ~ or $HOME or ${HOME}, $CLAUDE_CONFIG_DIR or
# ${CLAUDE_CONFIG_DIR} in a word, by plain text replacement, then restore the
# placeholders. Sets REPLY; fails (REPLY empty) when an unquoted expansion is
# left that this does not understand.
_doctor_expand_word() {
    local w="$1" home="${HOME:-}" cfg="${CLAUDE_CONFIG_DIR:-}"
    case "$w" in
        '~') w="$home" ;;
        '~/'*) w="$home/${w#\~/}" ;;
    esac
    case "$w" in
        '$HOME'|'$HOME/'*) w="$home${w#\$HOME}" ;;
        '${HOME}'|'${HOME}/'*) w="$home${w#\$\{HOME\}}" ;;
        '$CLAUDE_CONFIG_DIR'|'$CLAUDE_CONFIG_DIR/'*) w="$cfg${w#\$CLAUDE_CONFIG_DIR}" ;;
        '${CLAUDE_CONFIG_DIR}'|'${CLAUDE_CONFIG_DIR}/'*) w="$cfg${w#\$\{CLAUDE_CONFIG_DIR\}}" ;;
    esac
    # What the expansion above produced is data too, but a $ left in unquoted
    # text is an expansion this cannot do.
    case "$w" in
        *'$'*|*'`'*) REPLY=''; return 1 ;;
    esac
    w="${w//$_DOCTOR_DOLLAR/$}"
    w="${w//$_DOCTOR_TICK/\`}"
    REPLY="${w//$_DOCTOR_TILDE/\~}"
}

# Find the cortado.sh (or cortado command) a statusLine command runs. It is the
# command only as the first word (after NAME=value words and env), or as the
# script a shell is given (bash, sh and the like, with or without a path).
# Anything later (echo X, X after &&, a comment) is not run as Cortado.
# Sets _DOCTOR_TARGET, _DOCTOR_TARGET_IS_COMMAND (the word itself must be
# executable) and _DOCTOR_TARGET_RELATIVE (a path Claude Code would read from
# its own working directory, not this one). Fails when none is named.
_doctor_find_target() {
    local -a words=()
    local word n idx=0 cmd base REPLY
    _doctor_split "$1"
    _DOCTOR_TARGET='' _DOCTOR_TARGET_IS_COMMAND=false _DOCTOR_TARGET_RELATIVE=false
    for word in ${_DOCTOR_WORDS[@]+"${_DOCTOR_WORDS[@]}"}; do
        # A word with an expansion that cannot be followed matches nothing.
        if _doctor_expand_word "$word"; then words+=("$REPLY"); else words+=($'\004'); fi
    done
    n=${#words[@]}
    while [ "$idx" -lt "$n" ]; do
        case "${words[idx]}" in [A-Za-z_]*=*) idx=$((idx + 1)) ;; *) break ;; esac
    done
    [ "$idx" -lt "$n" ] || return 1
    cmd="${words[idx]}"
    base="${cmd##*/}"
    if [ "$base" = env ]; then
        idx=$((idx + 1))
        while [ "$idx" -lt "$n" ]; do
            case "${words[idx]}" in -*|*=*) idx=$((idx + 1)) ;; *) break ;; esac
        done
        [ "$idx" -lt "$n" ] || return 1
        cmd="${words[idx]}"
        base="${cmd##*/}"
    fi
    case "$base" in
        cortado.sh|cortado)
            _DOCTOR_TARGET="$cmd"
            _DOCTOR_TARGET_IS_COMMAND=true
            ;;
        bash|sh|dash|zsh|ksh)
            idx=$((idx + 1))
            while [ "$idx" -lt "$n" ]; do
                case "${words[idx]}" in
                    --) idx=$((idx + 1)); break ;;
                    --*) idx=$((idx + 1)) ;;
                    # -c reads a command string, not a script.
                    -*c*) return 1 ;;
                    -*) idx=$((idx + 1)) ;;
                    *) break ;;
                esac
            done
            [ "$idx" -lt "$n" ] || return 1
            cmd="${words[idx]}"
            case "${cmd##*/}" in cortado.sh|cortado) ;; *) return 1 ;; esac
            _DOCTOR_TARGET="$cmd"
            ;;
        *) return 1 ;;
    esac
    case "$_DOCTOR_TARGET" in
        /*) ;;
        */*) _DOCTOR_TARGET_RELATIVE=true ;;
        *)
            # A bare cortado as the command is looked up on PATH; any other
            # bare name is a file in whatever directory Claude Code runs from.
            if [ "$_DOCTOR_TARGET_IS_COMMAND" = true ] && [ "$_DOCTOR_TARGET" = cortado ]; then
                _DOCTOR_TARGET=$(command -v cortado 2>/dev/null) || _DOCTOR_TARGET=cortado
                case "$_DOCTOR_TARGET" in /*) ;; *) _DOCTOR_TARGET=cortado ;; esac
            else
                _DOCTOR_TARGET_RELATIVE=true
            fi
            ;;
    esac
    return 0
}

_doctor_check_settings() {
    local settings="$CLAUDE_CONFIG_DIR/settings.json" REPLY command kind target resolved dir self_resolved q
    local setup_fix="$_DOCTOR_SELF setup"

    if [ ! -e "$settings" ] && [ ! -L "$settings" ]; then
        _doctor_fail 'settings.json: not found' "$setup_fix" "$settings"
        _doctor_fail 'statusLine: cannot check without settings.json' "$setup_fix"
        return
    fi
    if [ ! -f "$settings" ]; then
        _doctor_quote "$settings"
        _doctor_fail 'settings.json: is not a regular file' \
            "mv $REPLY ${REPLY%\'}.old' && $setup_fix" "$settings"
        _doctor_fail 'statusLine: cannot check without settings.json' ''
        return
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _doctor_fail 'settings.json: cannot be read without jq' '' "$settings"
        _doctor_fail 'statusLine: cannot check without jq' ''
        return
    fi
    if ! jq -es 'length == 1 and (.[0] | type == "object")' "$settings" 2>/dev/null | grep -qx true; then
        _doctor_quote "$settings"
        _doctor_fail 'settings.json: does not parse as one JSON object' \
            "edit $REPLY to hold one JSON object, then run $setup_fix" "$settings"
        _doctor_fail 'statusLine: cannot check without a readable settings.json' ''
        return
    fi
    _doctor_ok 'settings.json: found and valid JSON' "$settings"

    kind=$(jq -r '.statusLine | if . == null then "unset" elif type == "object" then (.type // "") else "other" end' "$settings" 2>/dev/null)
    case "$kind" in
        unset)
            _doctor_fail 'statusLine: not set in settings.json' "$setup_fix"
            return
            ;;
        command) ;;
        *)
            _doctor_fail 'statusLine: is not a command' "$setup_fix"
            return
            ;;
    esac
    command=$(jq -r '.statusLine.command | if type == "string" then . else "" end' "$settings" 2>/dev/null)
    if ! _doctor_find_target "$command"; then
        _doctor_clean "$command" 200
        _doctor_fail 'statusLine: does not run a cortado.sh' "$setup_fix" "command: $REPLY"
        return
    fi
    target="$_DOCTOR_TARGET"
    _doctor_clean "$target" 200
    q="$REPLY"
    if [ "$_DOCTOR_TARGET_RELATIVE" = true ]; then
        _doctor_fail "statusLine: $q is a relative path, so it only works from one directory" "$setup_fix" \
            'Claude Code runs the command from the project directory.'
        return
    fi
    if [ ! -e "$target" ]; then
        _doctor_fail "statusLine: $q not found" "$setup_fix"
        return
    fi
    if [ -d "$target" ] || [ ! -f "$target" ]; then
        _doctor_fail "statusLine: $q is not a file" "$setup_fix"
        return
    fi
    if [ "$_DOCTOR_TARGET_IS_COMMAND" = true ] && [ ! -x "$target" ]; then
        _doctor_quote "$target"
        _doctor_fail "statusLine: $q is not executable" "chmod +x $REPLY"
        return
    fi
    if [ ! -r "$target" ]; then
        _doctor_quote "$target"
        _doctor_fail "statusLine: $q is not readable" "chmod u+r $REPLY"
        return
    fi
    resolved="$target"
    if _doctor_resolve "$target"; then resolved="$REPLY"; fi
    dir="${resolved%/*}"
    if [ ! -f "$dir/modules/utils.sh" ] || [ ! -f "$dir/lib/platform.sh" ]; then
        _doctor_fail "statusLine: $q is an incomplete copy (no modules/ or lib/ beside it)" "$setup_fix" \
            "Re-run ./install.sh from your Cortado clone to restore it."
        return
    fi
    self_resolved="$SCRIPT_DIR/cortado.sh"
    if [ "$target" -ef "$self_resolved" ]; then
        _doctor_ok 'statusLine: runs this copy' "$q"
    else
        _doctor_clean "$self_resolved" 200
        _doctor_ok 'statusLine: runs another copy' "$q" "this copy: $SCRIPT_DIR ($REPLY)"
    fi
}

# --- render ------------------------------------------------------------------

_doctor_render() {
    local sandbox payload out status line errline dir warning REPLY
    if ! sandbox=$(mktemp -d "${TMPDIR:-/tmp}/cortado-doctor.XXXXXX" 2>/dev/null); then
        _doctor_fail 'render: could not make a temporary directory to test in' \
            'export TMPDIR="$HOME/tmp" && mkdir -p "$TMPDIR"'
        return
    fi
    mkdir "$sandbox/sample" 2>/dev/null
    # Only modules that need no network or other tools: the update check, for
    # one, would call GitHub. The point is that this copy loads, reads the
    # payload and draws.
    printf '%s\n' 'MODULE_ORDER="directory,context,model"' > "$sandbox/cortado.conf" 2>/dev/null
    dir="${sandbox//\\/\\\\}/sample"
    dir="${dir//\"/\\\"}"
    payload='{"workspace":{"current_dir":"'"$dir"'"},"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":10000}}}'
    status=0
    out=$(cd "$sandbox" && printf '%s' "$payload" | env CLAUDE_CONFIG_DIR="$sandbox" CACHE_DIR="$sandbox/cortado-cache" \
        HOME="$sandbox" TMPDIR="$sandbox" "${BASH:-bash}" "$SCRIPT_DIR/cortado.sh" 2>"$sandbox/stderr") || status=$?
    errline=$(head -n 1 "$sandbox/stderr" 2>/dev/null)
    rm -rf -- "$sandbox"
    line="${out%%$'\n'*}"
    # Drop ANSI color sequences before the line is shown.
    line=$(printf '%s' "$line" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
    case "$out" in
        ''|'cortado:'*)
            status=1
            ;;
    esac
    if [ "$status" -ne 0 ]; then
        _doctor_clean "${out:-${errline:-no output}}" 100
        if ! command -v jq >/dev/null 2>&1; then
            # The jq line above is the cause; an update would not help.
            _doctor_fail 'render: this copy could not draw a sample statusline' '' "$REPLY" \
                'See the jq line above.'
        else
            _doctor_fail 'render: this copy could not draw a sample statusline' \
                "$_DOCTOR_SELF update" "$REPLY"
        fi
        return
    fi
    case "$line" in
        'Config refused'*|'Config partly read'*)
            warning="Config refused"
            case "$line" in 'Config partly read'*) warning="Config partly read" ;; esac
            _doctor_clean "$line" 60
            _doctor_fail "render: the sample line starts with \"$warning\"" '' "$REPLY" \
                'See the config lines below for the file and how to fix it.'
            return
            ;;
    esac
    _doctor_clean "$line" 60
    _doctor_ok 'render: this copy draws a sample statusline' "$REPLY"
}

# --- config trust ------------------------------------------------------------

# The command that fixes a refused config. $1 is the path, $2 the reason from
# lib/config-permissions.sh. Sets REPLY (empty when no command applies).
_doctor_trust_fix() {
    local path="$1" reason="$2" file="$1" dir qf qd
    if [ -L "$path" ] && [ ! -e "$path" ]; then
        # A dangling link: whatever the reason says, the link is what to fix.
        _doctor_quote "$path"
        REPLY="rm $REPLY"
        return
    fi
    if _doctor_resolve "$path"; then file="$REPLY"; fi
    dir="${file%/*}"
    [ -n "$dir" ] || dir=/
    _doctor_quote "$file"; qf="$REPLY"
    _doctor_quote "$dir"; qd="$REPLY"
    case "$reason" in
        *'unexpected owner'*) REPLY="sudo chown $(id -un) $qf" ;;
        *'file is group- or world-writable'*) REPLY="chmod 600 $qf" ;;
        *'parent is group- or world-writable'*) REPLY="chmod go-w $qd" ;;
        *'access control'*) REPLY="chmod -N $qf $qd" ;;
        *'cannot search'*) REPLY="chmod 700 $qd" ;;
        *'parent must belong'*) REPLY="mv $qf \"\$HOME/\"   # move it somewhere you own" ;;
        *) REPLY="ls -ld $qf $qd" ;;
    esac
}

# Count the lines of a config the parser skips, with the parser's own reader
# (read_config_kv): the same policy the statusline applies, and nothing applied.
# A trusted config's setting Cortado does not have never reaches a module, so
# it is counted apart; every other skipped line changes what is read.
_DOCTOR_SKIPPED=()
_DOCTOR_SKIPPED_N=0
_DOCTOR_UNKNOWN_N=0
_doctor_note_skipped() {
    local REPLY
    if [ "${CONFIG_POLICY_KIND:-}" = unknown ] && [ "$_DOCTOR_SCAN_SCOPE" != project ]; then
        _DOCTOR_UNKNOWN_N=$((_DOCTOR_UNKNOWN_N + 1))
        return 0
    fi
    _DOCTOR_SKIPPED_N=$((_DOCTOR_SKIPPED_N + 1))
    if [ "${#_DOCTOR_SKIPPED[@]}" -lt 3 ]; then
        _doctor_clean "line $1: $2" 80
        _DOCTOR_SKIPPED+=("$REPLY")
    fi
}

# _doctor_scan_config <path> <packaged|user|project>
_doctor_scan_config() {
    local policy=trusted_config_setting_allowed
    _DOCTOR_SCAN_SCOPE="$2"
    _DOCTOR_SKIPPED=() _DOCTOR_SKIPPED_N=0 _DOCTOR_UNKNOWN_N=0
    [ "$2" != project ] || policy=project_config_setting_allowed
    read_config_kv "$1" "$policy" : _doctor_note_skipped 2>/dev/null || :
}

# The line count and the command that lists the lines, for a config that was
# trusted. Sets REPLY to the summary, or fails when nothing was skipped.
_doctor_skipped_summary() {
    [ "$_DOCTOR_SKIPPED_N" -gt 0 ] || return 1
    if [ "$_DOCTOR_SKIPPED_N" -eq 1 ]; then REPLY='1 line skipped'; else REPLY="$_DOCTOR_SKIPPED_N lines skipped"; fi
}

# _doctor_check_config <label> <path> <scope>
_doctor_check_config() {
    local label="$1" path="$2" scope="$3" reason REPLY fix shown
    _doctor_clean "$path" 200
    shown="$REPLY"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        if ! check_config_searchable "$path" >/dev/null 2>&1; then
            _doctor_trust_fix "$path" 'cannot search the directory that holds it'
            _doctor_fail "$label: refused (cannot search the directory that holds it)" "$REPLY" "$shown"
            return
        fi
        case "$scope" in
            user) _doctor_info "$label: none (built-in defaults apply)" "$shown" ;;
            *) _doctor_info "$label: not present" "$shown" ;;
        esac
        return
    fi
    if reason=$(_trusted_config_path "$path" "$scope" 2>/dev/null); then
        _doctor_scan_config "$path" "$scope"
        if _doctor_skipped_summary; then
            fix="$_DOCTOR_SELF config --migrate --dry-run"
            [ "$scope" != packaged ] || fix="$_DOCTOR_SELF update"
            _doctor_fail "$label: trusted, but $REPLY" "$fix" "$shown" "${_DOCTOR_SKIPPED[@]}"
        elif [ "$_DOCTOR_UNKNOWN_N" -gt 0 ]; then
            _doctor_ok "$label: trusted" "$shown" "$_DOCTOR_UNKNOWN_N setting name(s) Cortado does not have, ignored"
        else
            _doctor_ok "$label: trusted" "$shown"
        fi
        return
    fi
    _doctor_clean "$reason" 100
    reason="$REPLY"
    _doctor_trust_fix "$path" "$reason"
    fix="$REPLY"
    if [ -L "$path" ] && [ ! -e "$path" ]; then
        _doctor_clean "$(command readlink "$path" 2>/dev/null)" 120
        _doctor_fail "$label: refused ($reason)" "$fix" "$shown" "a link to $REPLY, which does not exist" \
            'Remove the link, or point it at a file: ln -sfn FILE LINK'
        return
    fi
    _doctor_fail "$label: refused ($reason)" "$fix" "$shown"
}

_doctor_check_configs() {
    local user="$CLAUDE_CONFIG_DIR/cortado.conf" legacy="$CLAUDE_CONFIG_DIR/barista.conf" project REPLY
    _doctor_check_config 'packaged config' "$SCRIPT_DIR/cortado.conf" packaged
    if [[ ! -e "$user" && ! -L "$user" ]] && [[ -e "$legacy" || -L "$legacy" ]]; then
        # Cortado reads the pre-rename file in place until it can copy it.
        _doctor_check_config 'user config (barista.conf, pre-rename)' "$legacy" user
    else
        _doctor_check_config 'user config' "$user" user
    fi
    project="$PWD/.cortado.conf"
    [ -f "$project" ] || project="$PWD/.barista.conf"
    if [ -f "$project" ]; then
        _doctor_clean "$project" 200
        local shown="$REPLY"
        _doctor_scan_config "$project" project
        if _doctor_skipped_summary; then
            _doctor_fail "project config: $REPLY" "$_DOCTOR_SELF config --migrate --dry-run --project" \
                "$shown" "${_DOCTOR_SKIPPED[@]}"
        else
            _doctor_ok 'project config: read as data, never run' "$shown"
        fi
    else
        _doctor_info 'project config: none in this directory' "$PWD"
    fi
}

# --- platform ----------------------------------------------------------------

# Sets REPLY to the platform line and _DOCTOR_PLATFORM_OK to 1 or 0.
_doctor_platform_report() {
    local host triple="${BASH_VERSINFO[5]:-unknown}"
    _DOCTOR_PLATFORM_OK=0
    if [ -n "${CORTADO_OS_REFUSED:-}" ]; then
        _doctor_clean "$CORTADO_OS_REFUSED" 40
        REPLY="CORTADO_OS=$REPLY is not darwin or linux; set it to one of them, or unset it"
        return
    fi
    case "${CORTADO_OS:-}" in
        darwin|linux)
            _DOCTOR_PLATFORM_OK=1
            cortado_host_os
            host="$REPLY"
            if [ "$host" = "$CORTADO_OS" ]; then
                REPLY="$CORTADO_OS (supported)"
            else
                REPLY="$CORTADO_OS (forced by CORTADO_OS; this host is ${host:-unsupported})"
            fi
            ;;
        *)
            _doctor_clean "$triple" 60
            REPLY="unsupported (this host is $REPLY); Cortado runs on macOS and Linux"
            ;;
    esac
}

_doctor_check_platform() {
    local REPLY
    _doctor_platform_report
    if [ "$_DOCTOR_PLATFORM_OK" = 1 ]; then
        _doctor_ok "platform: $REPLY"
    else
        _doctor_fail "platform: $REPLY" ''
    fi
}

# --- cortado.log -------------------------------------------------------------

_doctor_check_log() {
    local log="$CLAUDE_CONFIG_DIR/cortado.log" lines='' part line count=0 shown='' REPLY
    local detail=()
    for part in "$log.1" "$log"; do
        [ -f "$part" ] && [ ! -L "$part" ] || continue
        lines="$lines$(tail -n 5 "$part" 2>/dev/null)"$'\n'
    done
    lines=$(printf '%s' "$lines" | grep -v '^$' | tail -n 5)
    if [ -z "$lines" ]; then
        _doctor_info 'log: no log (set DEBUG_MODE="true" to record module errors)'
        return
    fi
    while IFS= read -r line; do
        _doctor_clean "$line" 76
        detail+=("$REPLY")
        count=$((count + 1))
    done <<< "$lines"
    if [ "$count" -eq 1 ]; then
        _doctor_info 'log: last line of cortado.log' "${detail[@]}"
    else
        _doctor_info "log: last $count lines of cortado.log" "${detail[@]}"
    fi
}

# --- the cortado command -----------------------------------------------------

_doctor_check_command() {
    local found q resolved rq link="${HOME:-}/.local/bin/cortado" self="$SCRIPT_DIR/cortado.sh" REPLY qs
    local rc
    _doctor_quote "$self"; qs="$REPLY"
    if found=$(command -v cortado 2>/dev/null) && [ -n "$found" ]; then
        _doctor_clean "$found" 200
        q="$REPLY"
        resolved="$found"
        if _doctor_resolve "$found"; then resolved="$REPLY"; fi
        if [ "${resolved##*/}" != cortado.sh ]; then
            _doctor_clean "$resolved" 200
            rq="$REPLY"
            _doctor_fail "cortado command: another program named cortado" 'type -a cortado' \
                "$q resolves to $rq, which is not a Cortado cortado.sh." \
                'Check what it is. Cortado may be shadowed by it, or installed under another name.'
            return
        fi
        if [ "$found" -ef "$self" ]; then
            _doctor_ok "cortado command: $q" 'this copy'
        else
            _doctor_ok "cortado command: $q" 'another copy of cortado; this copy is run by its own path'
        fi
        return
    fi
    if [ -n "${HOME:-}" ] && [ -L "$link" ] && [ -e "$link" ]; then
        # shellcheck disable=SC2016 # The line is printed for the user's shell to expand.
        _doctor_fail 'cortado command: not on PATH' 'export PATH="$HOME/.local/bin:$PATH"' \
            "$link exists, but its directory is not on PATH." \
            'Add the line to ~/.zshrc (zsh) or ~/.bashrc or ~/.bash_profile (bash), then open a new terminal.'
        return
    fi
    rc="mkdir -p \"\$HOME/.local/bin\" && ln -s $qs \"\$HOME/.local/bin/cortado\""
    _doctor_fail 'cortado command: not on PATH' "$rc" \
        'Make sure ~/.local/bin is on your PATH too.'
}

# --- main --------------------------------------------------------------------

cortado_doctor_main() {
    local arg version=unknown
    for arg in "$@"; do
        case "$arg" in
            --no-color|--no-emoji) ;;
            -h|--help)
                printf 'Usage: cortado doctor [--no-color] [--no-emoji]\n'
                return 0
                ;;
            *)
                printf 'Usage: cortado doctor [--no-color] [--no-emoji]\n' >&2
                return 2
                ;;
        esac
    done
    _doctor_init_style "$@"
    _DOCTOR_CHECKS=0
    _DOCTOR_FAILS=0
    if [ -f "$SCRIPT_DIR/VERSION" ]; then
        version=$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION" 2>/dev/null)
    fi
    _doctor_clean "${version:-unknown}" 30
    printf 'Cortado doctor (version %s)\n' "$REPLY"
    printf 'This copy: %s\n\n' "$SCRIPT_DIR"

    _doctor_find_self
    _doctor_check_tools
    _doctor_check_settings
    _doctor_render
    _doctor_check_configs
    _doctor_check_platform
    _doctor_check_log
    _doctor_check_command

    printf '\n'
    if [ "$_DOCTOR_FAILS" -eq 0 ]; then
        printf 'All %d checks passed.\n' "$_DOCTOR_CHECKS"
        return 0
    fi
    printf '%d of %d checks failed. Run the fix commands above, then run cortado doctor again.\n' \
        "$_DOCTOR_FAILS" "$_DOCTOR_CHECKS"
    return 1
}
