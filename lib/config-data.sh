# shellcheck shell=bash
# One KEY=VALUE grammar for every config scope. A config file is data: nothing
# in it is expanded, substituted or run. Shared by the statusline, the config
# CLI and the installer. Bash 3.2 compatible.
#
# A line is blank, a `#` comment, or one assignment:
#   [blanks][export blanks]NAME=VALUE[blanks[# comment]]
# VALUE joins unquoted text, backslash escapes, '...' (literal) and "..." in
# which only \$ \` \" \\ are escapes and an unescaped $ or backtick is refused.
# Anything else (expansions, $'...', functions, conditionals, continuation
# lines, several assignments on one line) is an unread line with a reason.

CONFIG_MAX_LINE_BYTES=4096

# Parse one line (callers set LC_ALL=C, so bytes are bytes). Set CONFIG_KEY
# and CONFIG_VALUE for an assignment. Return 1 for a blank or comment line, 2
# for a line the grammar refuses (CONFIG_REASON).
config_parse_line() {
    local line="$1" raw whole rest seg out c tilde sq="'"
    local bare='[^[:space:];&|<>()`"'\''\\$]'
    local single="'[^']*'" double='"([^"\\$`]|\\.)*"'
    local pattern="^[[:blank:]]*(export[[:blank:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(($bare|\\\\.|$single|$double)*)([[:blank:]]+(#.*)?)?$"
    local quote_stop='["\\]' text_stop='['\''"\\]'

    CONFIG_KEY='' CONFIG_VALUE='' CONFIG_REASON=''
    # Measure before any pattern work: Bash pattern removal is quadratic on a
    # long line, and a project config comes from an untrusted repository.
    if [ "${#line}" -gt "$CONFIG_MAX_LINE_BYTES" ]; then
        CONFIG_REASON="line longer than $CONFIG_MAX_LINE_BYTES bytes"
        return 2
    fi
    # Drop one CR from a CRLF line ending.
    [ "${line:${#line}-1}" != $'\r' ] || line="${line%?}"
    rest="${line#"${line%%[![:space:]]*}"}"
    case "$rest" in ''|\#*) return 1 ;; esac
    if ! [[ "$line" =~ $pattern ]]; then
        config_unread_reason "$line"
        return 2
    fi
    CONFIG_KEY="${BASH_REMATCH[2]}"
    raw="${BASH_REMATCH[3]}"
    whole="$raw" out='' tilde=''
    while [ -n "$raw" ]; do
        case "$raw" in
            "$sq"*)
                rest="${raw#"$sq"}"
                out="$out${rest%%"$sq"*}"
                raw="${rest#*"$sq"}"
                ;;
            \"*)
                rest="${raw#?}"
                while :; do
                    # shellcheck disable=SC2295 # quote_stop is a bracket pattern.
                    seg="${rest%%$quote_stop*}"
                    out="$out$seg"
                    rest="${rest#"$seg"}"
                    case "$rest" in
                        \\*)
                            c="${rest:1:1}"
                            case "$c" in
                                \$|\`|\"|\\) out="$out$c" ;;
                                *) out="$out\\$c" ;;
                            esac
                            rest="${rest:2}"
                            ;;
                        *)
                            rest="${rest#?}"
                            break
                            ;;
                    esac
                done
                raw="$rest"
                ;;
            \\*)
                out="$out${raw:1:1}"
                raw="${raw:2}"
                ;;
            *)
                # shellcheck disable=SC2295 # text_stop is a bracket pattern.
                seg="${raw%%$text_stop*}"
                # Bash expands an unquoted tilde at the start of the value or
                # after an unquoted colon. Quoted text never expands.
                case "$seg" in
                    *':~'*) tilde=expands ;;
                    '~'*) [ "$raw" != "$whole" ] || tilde=expands ;;
                esac
                if [ "$tilde" = expands ]; then
                    CONFIG_KEY=''
                    CONFIG_REASON='tilde expansion'
                    return 2
                fi
                out="$out$seg"
                raw="${raw#"$seg"}"
                ;;
        esac
    done
    CONFIG_VALUE="$out"
    return 0
}

# Name what kind of shell code a refused line holds, for --show and --migrate.
config_unread_reason() {
    local line="$1" word
    local function_pattern='^[[:blank:]]*(function[[:blank:]]+[^[:blank:]]|[A-Za-z_][A-Za-z0-9_-]*[[:blank:]]*\(\))'
    word="${line#"${line%%[![:blank:]]*}"}"
    word="${word%%[[:blank:];]*}"
    if [[ "$line" =~ $function_pattern ]]; then
        CONFIG_REASON='function definition'
        return
    fi
    case "$word" in
        'if'|'then'|'elif'|'else'|'fi'|'for'|'while'|'until'|'do'|'done'|'case'|'esac'|'select'|'['|'[['|'{'|'}'|'!')
            CONFIG_REASON='conditional or compound command'
            return
            ;;
    esac
    # shellcheck disable=SC2016 # These patterns name literal shell syntax.
    case "$line" in
        *'$('*|*\`*) CONFIG_REASON='command substitution' ;;
        *"\$'"*) CONFIG_REASON="ANSI-C quoting (\$'...')" ;;
        *'$'*) CONFIG_REASON='variable expansion' ;;
        *\\) CONFIG_REASON='line continuation' ;;
        *)
            case "$word" in
                *=*)
                    case "$line" in
                        *\"*|*\'*) CONFIG_REASON='unterminated quote or unsupported quoting' ;;
                        *) CONFIG_REASON='not a single KEY=VALUE assignment' ;;
                    esac
                    ;;
                *) CONFIG_REASON='shell command' ;;
            esac
            ;;
    esac
}

# Keep control bytes out of anything printed about an untrusted line.
config_printable() {
    local LC_ALL=C
    REPLY="${1//[[:cntrl:]]/?}"
}

# Read literal KEY=VALUE lines through the caller's policy and consumer.
# The optional fourth callback receives LINE_NUMBER REASON TEXT for each line
# that holds something other than a blank, a comment or an applied setting.
# A policy may set CONFIG_POLICY_REASON before refusing a setting, and
# CONFIG_POLICY_KIND (unknown or type); a refused line's kind is syntax.
read_config_kv() {
    local config_path="$1" allows_setting="$2" consume_setting="$3" report="${4:-}"
    local line number=0 status key val LC_ALL=C
    # A FIFO, device or directory is never opened.
    [ -f "$config_path" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        # Fast paths for the common shapes, decoded exactly as the grammar
        # decodes them: a comment, KEY=word, KEY="text" and KEY='text'.
        status=
        case "$line" in
            ''|\#*) continue ;;
            [A-Za-z_]*=*)
                # The grammar's length limit applies to every shape.
                [ "${#line}" -le "$CONFIG_MAX_LINE_BYTES" ] || status=long
                key="${line%%=*}"
                val="${line#*=}"
                case "$status$key" in
                    long*|*[!A-Za-z0-9_]*) ;;
                    *)
                        case "$val" in
                            *[!-A-Za-z0-9_.,:/%+@]*) ;;
                            *) status=0 ;;
                        esac
                        if [ -z "$status" ]; then
                            case "$val" in
                                \"*\")
                                    val="${val#?}"; val="${val%?}"
                                    case "$val" in *[\"\\\$\`]*) ;; *) status=0 ;; esac
                                    ;;
                                \'*\')
                                    val="${val#?}"; val="${val%?}"
                                    case "$val" in *\'*) ;; *) status=0 ;; esac
                                    ;;
                            esac
                        fi
                        ;;
                esac
                ;;
        esac
        if [ "$status" = 0 ]; then
            CONFIG_KEY="$key" CONFIG_VALUE="$val"
        else
            config_parse_line "$line" && status=0 || status=$?
            case "$status" in
                1) continue ;;
                2)
                    CONFIG_POLICY_KIND=syntax
                    [ -z "$report" ] || "$report" "$number" "$CONFIG_REASON" "$line"
                    continue
                    ;;
            esac
        fi
        CONFIG_POLICY_REASON='' CONFIG_POLICY_KIND=''
        if ! "$allows_setting" "$CONFIG_KEY" "$CONFIG_VALUE"; then
            [ -z "$report" ] ||
                "$report" "$number" "${CONFIG_POLICY_REASON:-$CONFIG_KEY is not a setting this config may change}" "$line"
            continue
        fi
        "$consume_setting" "$CONFIG_KEY" "$CONFIG_VALUE" "$line" || true
    done < "$config_path"
    return 0
}

# Core settings a trusted config may change, with their types. Module
# settings come from the module headers' @config lines (lib/module-registry.sh).
_CONFIG_CORE_KEYS='
SEPARATOR:string DISPLAY_MODE:string COLOR_THEME:string STATUS_STYLE:string
STATUS_GREEN:string STATUS_YELLOW:string STATUS_ORANGE:string STATUS_RED:string
LAYOUT_MODE:string MODULE_ORDER:string PROGRESS_BAR_FILLED:string
PROGRESS_BAR_EMPTY:string CORTADO_OS:string DISK_PATH:string
TIMEZONE_ZONES:string UPDATE_ICON:string UPDATE_REPO:string
WEATHER_LOCATION:string WEATHER_UNITS:string
USE_ICONS:bool USE_STATUS_INDICATORS:bool DEBUG_MODE:bool
GIT_SHOW_FILE_COUNT:bool GIT_SHOW_STATUS:bool NETWORK_SHOW_LAN:bool
NETWORK_SHOW_SSID:bool NETWORK_SHOW_WAN:bool NETWORK_WAN_REDACT:bool
NODE_SHOW_NPM:bool NODE_SHOW_VERSION:bool PROJECT_SHOW_BUILD:bool
PROJECT_SHOW_DEV_SERVER:bool UPTIME_SHOW_LOAD:bool
TERMINAL_WIDTH:int RIGHT_SIDE_RESERVE:int PROGRESS_BAR_WIDTH:int
CACHE_MAX_AGE:int GIT_CACHE_TTL:int RATE_BACKOFF_SECONDS:int RATE_CACHE_TTL:int
UPDATE_CHECK_INTERVAL:int WEATHER_CACHE_TTL:int
VERSION_SHOW_DURATION:int
'
# VERSION_SHOW_DURATION is seconds; modules/version.sh declares it bool, so the
# core entry, which wins, keeps the type its values have always had.
unset "${!_CORTADO_CORE_KEY_TYPE_@}"
for _config_entry in $_CONFIG_CORE_KEYS; do
    printf -v "_CORTADO_CORE_KEY_TYPE_${_config_entry%%:*}" '%s' "${_config_entry#*:}"
done
unset _config_entry

# REPLY is the type of a setting a trusted config may change: bool, int,
# number or string. Core types win, then installed modules, then MODULE_*
# flags, then a user module's settings under its own prefix.
config_key_type() {
    case "$1" in
        ''|*[!A-Z0-9_]*|[!A-Z]*) return 1 ;;
    esac
    local core="_CORTADO_CORE_KEY_TYPE_$1" builtin="_CORTADO_KEY_TYPE_$1"
    REPLY="${!core-}"
    [ -z "$REPLY" ] || return 0
    REPLY="${!builtin-}"
    [ -z "$REPLY" ] || return 0
    case "$1" in MODULE_*) REPLY=bool; return 0 ;; esac
    local user="_CORTADO_USER_KEY_TYPE_$1"
    REPLY="${!user-}"
    [ -n "$REPLY" ]
}

# An empty value leaves the setting to its default, as ${KEY:-default} reads it.
# A bool is one of the on/off spellings below, an int is optional minus and
# digits, a number may add one decimal point.
config_value_fits_type() {
    case "$1:$2" in
        *:) return 0 ;;
        string:*) return 0 ;;
        # The spellings cortado config has always read as on or off. They
        # pass through unchanged, so a render matches what sourcing gave.
        bool:true|bool:false|bool:TRUE|bool:FALSE|bool:yes|bool:no|bool:YES|\
        bool:NO|bool:on|bool:off|bool:ON|bool:OFF|bool:1|bool:0) return 0 ;;
        int:*|number:*)
            local digits="${2#-}"
            if [ "$1" = number ]; then
                case "$digits" in *.*.*) return 1 ;; esac
                digits="${digits/./}"
                case "$2" in -.|.|*.) return 1 ;; esac
            fi
            case "$digits" in
                ''|*[!0-9]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
    esac
    return 1
}

# Policy for the packaged and user configs.
trusted_config_setting_allowed() {
    local key="$1" val="$2" REPLY
    if ! config_key_type "$key"; then
        CONFIG_POLICY_REASON="$key is not a Cortado setting" CONFIG_POLICY_KIND=unknown
        return 1
    fi
    if ! config_value_fits_type "$REPLY" "$val"; then
        CONFIG_POLICY_REASON="$key expects a $REPLY value" CONFIG_POLICY_KIND=type
        return 1
    fi
    return 0
}

trusted_config_assign() {
    printf -v "$1" '%s' "$2" 2>/dev/null
}

# Lines a trusted config holds but the statusline did not apply. Shell code
# and mistyped values may change the line from what sourcing gave, so they
# also count in CONFIG_UNREAD_RENDER; an unknown name never reached a module.
CONFIG_UNREAD=()
CONFIG_UNREAD_RENDER=0
_CONFIG_UNREAD_LABEL=

# The reason names the setting or the kind of code; the line itself stays out
# of the statusline's log and the --show summary.
config_record_unread() {
    CONFIG_UNREAD+=("$_CONFIG_UNREAD_LABEL line $1: $2")
    [ "${CONFIG_POLICY_KIND:-}" = unknown ] || CONFIG_UNREAD_RENDER=$((CONFIG_UNREAD_RENDER + 1))
}

# Parse an already-checked trusted config. The label names it in reports.
load_config_data() {
    local _CONFIG_UNREAD_LABEL="${2:-$1}"
    read_config_kv "$1" trusted_config_setting_allowed trusted_config_assign config_record_unread
}

# True only when the environment Cortado started with exported the opt-in as 1.
# Call before reading any config: a config file can never turn it on.
config_bash_opt_in_from_env() {
    local names="${CORTADO_STARTUP_ENV-}"
    [ -n "$names" ] || names=$(compgen -e)
    case $'\n'"$names"$'\n' in
        *$'\n'CORTADO_CONF_ALLOW_BASH$'\n'*) [ "${CORTADO_CONF_ALLOW_BASH-}" = 1 ] ;;
        *) return 1 ;;
    esac
}
