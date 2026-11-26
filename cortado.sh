#!/bin/bash

# =============================================================================
# Cortado - Serving up fresh stats for Claude Code
# =============================================================================
# A feature-rich, modular statusline for Claude Code CLI
#
# Configuration: Edit cortado.conf to enable/disable modules
# Modules: Add/remove files in the modules/ directory
# Per-directory: Create .cortado.conf in any project for overrides
#
# Copyright 2026 Jared Scott. Licensed under the Apache License, Version 2.0.
# Originally brewed as Barista by Patrick D. Stuart (https://github.com/pstuart/Barista);
# see NOTICE for the upstream MIT notice.
# Requires: jq
# =============================================================================

# Remember which settings were inherited before loading trusted defaults.
CORTADO_STARTUP_ENV=$(compgen -e)

# Determine script directory (handles symlinks)
script_path="${BASH_SOURCE[0]:-$0}"
case "$script_path" in
    */../*|*/./*|*//*) SCRIPT_DIR="$(CDPATH='' cd -- "${script_path%/*}/" && pwd)" ;;
    /*) SCRIPT_DIR="${script_path%/*}"; SCRIPT_DIR="${SCRIPT_DIR:-/}" ;;
    */*) SCRIPT_DIR="$(CDPATH='' cd -- "${script_path%/*}/" && pwd)" ;;
    *) SCRIPT_DIR="$PWD" ;;
esac
MODULES_DIR="$SCRIPT_DIR/modules"
CONFIG_FILE="$SCRIPT_DIR/cortado.conf"

# Determine Claude config directory (respects CLAUDE_CONFIG_DIR env var)
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# shellcheck source=lib/config-permissions.sh
. "$SCRIPT_DIR/lib/config-permissions.sh"
# shellcheck source=lib/module-registry.sh
. "$SCRIPT_DIR/lib/module-registry.sh"

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Succeeds unless $1 is group- or world-writable. A cortado.conf is sourced as full
# bash, so a writable one is a persistent code-exec vector (Refs #28 part 3). Mirrors
# the Darwin/Linux stat fork used in utils.sh; fails open if the mode can't be read so
# an unusual environment never breaks the statusline.
config_not_group_or_world_writable() {
    local f="$1" perms len group_digit other_digit
    if [[ "${BASH_VERSINFO[5]}" == *-darwin* ]]; then
        perms=$(/usr/bin/stat -f '%Lp' "$f" 2>/dev/null)
    else
        perms=$(stat -c '%a' "$f" 2>/dev/null)
    fi
    [ -n "$perms" ] || return 0
    len=${#perms}
    group_digit="${perms:len-2:1}"
    other_digit="${perms:len-1:1}"
    # octal write bit is 2 (present in digits 2,3,6,7)
    if (( (group_digit & 2) != 0 || (other_digit & 2) != 0 )); then
        return 1
    fi
    return 0
}

# Load a trusted config file by sourcing it (only for configs we ship or the user owns)
load_config() {
    local config_path="$1"
    if [ -f "$config_path" ]; then
        # The file is sourced as full bash; refuse a group/world-writable one so a
        # weak umask or shared install dir can't turn it into a code-exec path (#28).
        if ! config_not_group_or_world_writable "$config_path"; then
            [ "${DEBUG_MODE:-false}" = "true" ] && \
                echo "cortado: refusing to source group/world-writable config: $config_path" >&2
            return 1
        fi
        # shellcheck source=/dev/null
        . "$config_path"
        return 0
    fi
    return 1
}

# Read literal KEY=VALUE lines through the caller's policy and consumer.
read_config_kv() {
    local config_path="$1" allows_setting="$2" consume_setting="$3"
    local line key val
    [ -f "$config_path" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        case "$line" in
            ""|\#*) continue ;;
            *=*) ;;
            *) continue ;;
        esac

        key="${line%%=*}"
        val="${line#*=}"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac

        # Allow a pipe for the default separator.
        case "$val" in
            *\`*|*\$*|*\;*|*\&*|*\>*|*\<*|*'*'*|*'?'*|*'['*) continue ;;
        esac

        "$allows_setting" "$key" "$val" || continue
        "$consume_setting" "$key" "$val" "$line" || true
    done < "$config_path"
    return 0
}

# Shared project allowlist for the renderer and config CLI.
project_config_setting_allowed() {
    local key="$1" val="$2"
    case "$val" in *[[:cntrl:]]*) return 1 ;; esac
    case "$key" in
        SEPARATOR|DISPLAY_MODE|COLOR_THEME|USE_ICONS|USE_STATUS_INDICATORS|STATUS_STYLE|\
        STATUS_GREEN|STATUS_YELLOW|STATUS_ORANGE|STATUS_RED|\
        LAYOUT_MODE|TERMINAL_WIDTH|RIGHT_SIDE_RESERVE|MODULE_ORDER|\
        PROGRESS_BAR_WIDTH|PROGRESS_BAR_FILLED|PROGRESS_BAR_EMPTY)
            return 0
            ;;
        ''|*[!A-Z0-9_]*) return 1 ;;
        MODULE_*)
            [ "$val" = false ] || return 1
            case "$_CORTADO_MODULE_FLAGS" in *" $key "*) return 0 ;; *) return 1 ;; esac
            ;;
    esac
    case "$_CORTADO_PROJECT_KEYS" in
        *" $key "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Match complete exported names, including names with empty values.
project_config_inherited() {
    case $'\n'"${CORTADO_STARTUP_ENV}"$'\n' in
        *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    return 1
}

# Call only with a validated project setting.
project_config_assign() {
    if project_config_inherited "$1"; then
        return 1
    fi
    printf -v "$1" '%s' "$2" 2>/dev/null
}

load_config_safe() {
    read_config_kv "$1" project_config_setting_allowed "${2:-project_config_assign}"
}

# A project-selected theme may fill empty settings or force monochrome. Preserve
# inherited settings as they would look after applying the trusted theme alone.
apply_render_theme() {
    local trusted_theme="$1" key setting
    if [ "$trusted_theme" = "${COLOR_THEME:-default}" ]; then
        apply_theme
        return
    fi

    {
        apply_theme
        while IFS= read -r -d '' setting; do
            case "$setting" in
                *=*)
                    key="${setting%%=*}"
                    # Unchanged settings may be read-only in trusted configuration.
                    if [ -z "${!key+x}" ] || [ "${!key}" != "${setting#*=}" ]; then
                        printf -v "$key" '%s' "${setting#*=}"
                    fi
                    ;;
                *) unset "$setting" ;;
            esac
        done
    } < <(
        # This subshell starts before apply_theme changes anything in the parent.
        # The project loader has already left inherited inputs untouched.
        COLOR_THEME="$trusted_theme"
        apply_theme
        while IFS= read -r key; do
            project_config_setting_allowed "$key" '' || continue
            if [ "${!key+x}" ]; then
                printf '%s=%s\0' "$key" "${!key}"
            else
                printf '%s\0' "$key"
            fi
        done <<< "$CORTADO_STARTUP_ENV"
    )
}

# Load configuration in order of precedence:
# 1. Module defaults from the installed headers
# 2. Script directory config (cortado.conf) — trusted, shipped with Cortado
# 3. User config ($CLAUDE_CONFIG_DIR/cortado.conf) — trusted, user-owned
# 4. Per-directory config (.cortado.conf in current_dir) — UNTRUSTED, uses safe parser

_CORTADO_MODULE_REGISTRY_UNAVAILABLE=false
if ! discover_module_registry "$MODULES_DIR" "$CLAUDE_CONFIG_DIR/cortado-modules" true; then
    _CORTADO_MODULE_REGISTRY_UNAVAILABLE=true
fi
load_config "$CONFIG_FILE"

USER_CONFIG="$CLAUDE_CONFIG_DIR/cortado.conf"
# One-time carry-over from Barista (the project Cortado was forked from): if the user
# still has $CLAUDE_CONFIG_DIR/barista.conf and no cortado.conf yet, copy it across with
# its permissions intact (cp -p keeps 600, and load_config still runs its writable
# check). The original is left in place. If the copy can't be written, read the legacy
# file directly so the user's settings still apply.
LEGACY_USER_CONFIG="$CLAUDE_CONFIG_DIR/barista.conf"
if [ ! -f "$USER_CONFIG" ] && [ -f "$LEGACY_USER_CONFIG" ]; then
    cp -p "$LEGACY_USER_CONFIG" "$USER_CONFIG" 2>/dev/null || USER_CONFIG="$LEGACY_USER_CONFIG"
fi
load_config "$USER_CONFIG"

# =============================================================================
# LOAD MODULES
# =============================================================================

create_module_stderr() (
    local dir
    umask 077
    dir=$(mktemp -d "$1/cortado-stderr.XXXXXX") || return 1
    if ! mkfifo "$dir/pipe"; then
        rmdir -- "$dir"
        return 1
    fi
    printf '%s\n' "$dir"
) 2>/dev/null

start_module_stderr() {
    [ -n "$CORTADO_STDERR_CAPTURE" ] || return 0
    local dir="$CORTADO_STDERR_CAPTURE"
    # Read exactly the prefix: BSD head can consume bytes past its output limit
    # on a pipe. Buffer dd's writes, then count the rest as the pipe drains.
    (
        umask 077
        if ! { LC_ALL=C dd ibs=1 obs=4096 count=65536 >| "$dir/data" &&
            LC_ALL=C wc -c >| "$dir/omitted"; }; then
            cat > /dev/null
            exit 1
        fi
    ) 2>/dev/null < "$dir/pipe" &
    CORTADO_STDERR_READER=$!
}

log_module_stderr() {
    local module_name="$1" dir="$CORTADO_STDERR_CAPTURE" reader="$CORTADO_STDERR_READER"
    [ -n "$reader" ] || return 0
    local status=0
    wait "$reader" 2>/dev/null || status=$?
    CORTADO_STDERR_READER=
    [ "$status" -eq 0 ] || return 0

    local omitted line diagnostics
    IFS=' ' read -r omitted 2>/dev/null < "$dir/omitted" || return 0
    [ -s "$dir/data" ] || [ "$omitted" -gt 0 ] || return 0
    diagnostics=$(
        while IFS= read -r line || [ -n "$line" ]; do
            printf '%s: %s\n' "$module_name" "$line"
        done < "$dir/data"
        if [ "$omitted" -gt 0 ]; then
            printf '%s: [truncated %s bytes]\n' "$module_name" "$omitted"
        fi
    )
    log_debug "$diagnostics"
}

cleanup_module_stderr() {
    if [ -n "$CORTADO_STDERR_READER" ]; then
        kill "$CORTADO_STDERR_READER" 2>/dev/null || :
    fi
    rm -rf -- "$CORTADO_STDERR_CAPTURE" 2>/dev/null || :
}

# The fallback helpers are invoked by the sourced modules.
# shellcheck disable=SC2329
load_modules() {
    local stderr_file="$1" module_file module_name

    # Fallbacks for incomplete installations. utils.sh normally defines these.
    log_debug() { :; }
    if [ -f "$MODULES_DIR/utils.sh" ]; then
        start_module_stderr
        # shellcheck source=/dev/null
        . "$MODULES_DIR/utils.sh" 2>|"$stderr_file"
        log_module_stderr utils
    else
        CACHE_DIR="$CLAUDE_CONFIG_DIR/cortado-cache"
        cache_get() { return 1; }
        cache_set() { :; }
        cached_probe() { REPLY=; }
        _snapshot_probe_cache() { :; }
        init_cache() { return 1; }
        _file_mtime() { printf '0\n'; }
        is_compact() { [[ "${DISPLAY_MODE:-normal}" == compact || "${1:-}" == true ]]; }
        get_icon() { echo "$1"; }
        get_icon_reply() { REPLY="$1"; }
        get_status() { echo ""; }
        get_status_reply() { REPLY=; }
        get_status_4level() { echo ""; }
        get_status_4level_reply() { REPLY=; }
        progress_bar() { echo ""; }
        progress_bar_reply() { REPLY=; }
        format_number() { echo "$1"; }
        format_number_reply() { REPLY="$1"; }
        # A complete payload helper is also loaded by utils.sh.
        with_payload_context() { local -r CTX_READY=true; "$@"; }
    fi

    for module_file in "$MODULES_DIR"/*.sh; do
        [ -f "$module_file" ] || continue
        module_name="${module_file##*/}"
        [ "$module_name" != utils.sh ] || continue
        if [ "$module_name" = payload.sh ] && [ -f "$MODULES_DIR/utils.sh" ]; then continue; fi
        start_module_stderr
        # shellcheck source=/dev/null
        . "$module_file" 2>|"$stderr_file"
        log_module_stderr "${module_name%.sh}"
    done
}

# =============================================================================
# MODULE REGISTRY
# =============================================================================
get_module_function() {
    REPLY=
    registered_module_key "$1" || return 0
    REPLY="module_${1//-/_}"
}

# Call the module function using the argument kind in its header. The caller
# already runs this in a subshell so user source and module side effects stay local.
run_module() {
    local module_name="$1" current_dir="$2" input_json="$3"
    local func_name path dispatch args platforms platform
    registered_module_key "$module_name" || return 0
    path="_CORTADO_SOURCE_${REPLY#_CORTADO_MODULE_}"
    dispatch="${!REPLY}"
    dispatch="${dispatch#*|}"
    args="${dispatch%%|*}"
    platforms="${dispatch#*|}"
    case "$render_os" in
        Darwin) platform=darwin ;;
        Linux) platform=linux ;;
        *) platform= ;;
    esac
    if [ -n "$platform" ]; then
        case ",$platforms," in *",$platform,"*) ;; *) return 0 ;; esac
    fi
    if [ -n "${!path-}" ]; then
        # An untrusted project may suppress or reorder already selected user
        # modules. Only the trusted order can authorize sourcing a new one.
        case ",$trusted_module_order," in *",$module_name,"*) ;; *) return 0 ;; esac
        # A false last command in the file is not a failure. The function
        # check below decides whether the module can run.
        # shellcheck source=/dev/null
        . "${!path}" || log_debug "User module $module_name: sourcing returned status $?"
    fi
    func_name="module_${module_name//-/_}"
    if ! declare -F "$func_name" >/dev/null; then
        log_debug "Module function not found: $func_name"
        return
    fi
    case "$args" in
        dir) "$func_name" "$current_dir" ;;
        payload) "$func_name" "$input_json" ;;
        none) "$func_name" ;;
    esac
}

is_module_enabled() {
    local record flag
    registered_module_key "$1" || return 1
    record="${!REPLY}"
    flag="${record%%|*}"
    [ "${!flag:-false}" = true ]
}

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

remove_render_spaces() {
    local name="$1" value="${!1}"
    case "$value" in
        # Preserve echo's handling of options and escapes in trusted configs.
        -*|*\\*|*$'\n'*) value=$(echo "$value" | tr -d ' ') ;;
        *) value=${value// /} ;;
    esac
    printf -v "$name" '%s' "$value"
}

validate_module_order() {
    local order="$1"

    if [ -z "$order" ]; then
        return 0
    fi

    local modules module func_name
    IFS=',' read -r -a modules <<< "$order"
    for module in "${modules[@]}"; do
        remove_render_spaces module
        get_module_function "$module"
        func_name=$REPLY
        if [ -z "$func_name" ]; then
            case "$_CORTADO_MODULE_REFUSED_IDS" in
                *" $module "*) log_debug "Warning: Refused module in MODULE_ORDER (unsafe owner or permissions): $module" ;;
                *) log_debug "Warning: Unknown module in MODULE_ORDER: $module" ;;
            esac
        fi
    done
}

# Discovery runs before config sets DEBUG_MODE, so it only collects refusals.
# Like a refused cortado.conf, they are reported only in debug mode.
report_module_refusals() {
    local entry message
    [ "${DEBUG_MODE:-false}" = true ] || return 0
    [ "${#_CORTADO_MODULE_REFUSALS[@]}" -gt 0 ] || return 0
    for entry in "${_CORTADO_MODULE_REFUSALS[@]}"; do
        message=$(config_refusal_message "${entry#*:}" "${entry%%:*}")
        printf '%s\n' "$message" >&2
        if declare -F log_debug >/dev/null; then
            log_debug "$message"
        fi
    done
}

# =============================================================================
# SMART LINE WRAPPING
# =============================================================================
# Joins modules with separator, wrapping to new lines at separator boundaries
# when content would exceed available terminal width

# East Asian Width W/F intervals from the Unicode Character Database. Each
# pair is the inclusive start and exclusive end of a two-column range.
layout_wide_boundaries=(
    0x1100 0x1160  0x231A 0x231C  0x2329 0x232B  0x23E9 0x23ED
    0x23F0 0x23F1  0x23F3 0x23F4  0x25FD 0x25FF  0x2614 0x2616
    0x2630 0x2638  0x2648 0x2654  0x267F 0x2680  0x268A 0x2690
    0x2693 0x2694  0x26A1 0x26A2  0x26AA 0x26AC  0x26BD 0x26BF
    0x26C4 0x26C6  0x26CE 0x26CF  0x26D4 0x26D5  0x26EA 0x26EB
    0x26F2 0x26F4  0x26F5 0x26F6  0x26FA 0x26FB  0x26FD 0x26FE
    0x2705 0x2706  0x270A 0x270C  0x2728 0x2729  0x274C 0x274D
    0x274E 0x274F  0x2753 0x2756  0x2757 0x2758  0x2795 0x2798
    0x27B0 0x27B1  0x27BF 0x27C0  0x2B1B 0x2B1D  0x2B50 0x2B51
    0x2B55 0x2B56  0x2E80 0x2E9A  0x2E9B 0x2EF4  0x2F00 0x2FD6
    0x2FF0 0x303F  0x3041 0x3097  0x3099 0x3100  0x3105 0x3130
    0x3131 0x318F  0x3190 0x31E6  0x31EF 0x321F  0x3220 0x3248
    0x3250 0xA48D  0xA490 0xA4C7  0xA960 0xA97D  0xAC00 0xD7A4
    0xF900 0xFB00  0xFE10 0xFE1A  0xFE30 0xFE53  0xFE54 0xFE67
    0xFE68 0xFE6C  0xFF01 0xFF61  0xFFE0 0xFFE7  0x16FE0 0x16FE5
    0x16FF0 0x16FF7  0x17000 0x18CD6  0x18CFF 0x18D1F  0x18D80 0x18DF3
    0x1AFF0 0x1AFF4  0x1AFF5 0x1AFFC  0x1AFFD 0x1AFFF  0x1B000 0x1B123
    0x1B132 0x1B133  0x1B150 0x1B153  0x1B155 0x1B156  0x1B164 0x1B168
    0x1B170 0x1B2FC  0x1D300 0x1D357  0x1D360 0x1D377  0x1F004 0x1F005
    0x1F0CF 0x1F0D0  0x1F18E 0x1F18F  0x1F191 0x1F19B  0x1F200 0x1F203
    0x1F210 0x1F23C  0x1F240 0x1F249  0x1F250 0x1F252  0x1F260 0x1F266
    0x1F300 0x1F321  0x1F32D 0x1F336  0x1F337 0x1F37D  0x1F37E 0x1F394
    0x1F3A0 0x1F3CB  0x1F3CF 0x1F3D4  0x1F3E0 0x1F3F1  0x1F3F4 0x1F3F5
    0x1F3F8 0x1F43F  0x1F440 0x1F441  0x1F442 0x1F4FD  0x1F4FF 0x1F53E
    0x1F54B 0x1F54F  0x1F550 0x1F568  0x1F57A 0x1F57B  0x1F595 0x1F597
    0x1F5A4 0x1F5A5  0x1F5FB 0x1F650  0x1F680 0x1F6C6  0x1F6CC 0x1F6CD
    0x1F6D0 0x1F6D3  0x1F6D5 0x1F6D9  0x1F6DC 0x1F6E0  0x1F6EB 0x1F6ED
    0x1F6F4 0x1F6FD  0x1F7E0 0x1F7EC  0x1F7F0 0x1F7F1  0x1F90C 0x1F93B
    0x1F93C 0x1F946  0x1F947 0x1FA00  0x1FA70 0x1FA7D  0x1FA80 0x1FA8B
    0x1FA8E 0x1FAC7  0x1FAC8 0x1FAC9  0x1FACD 0x1FADD  0x1FADF 0x1FAEB
    0x1FAEF 0x1FAF9  0x20000 0x2FFFE  0x30000 0x3FFFE
)

# Unicode 17.0 Grapheme_Cluster_Break=Extend, including marks and selectors.
layout_extend_boundaries=(
    0x300 0x370  0x483 0x48A  0x591 0x5BE  0x5BF 0x5C0  0x5C1 0x5C3  0x5C4 0x5C6
    0x5C7 0x5C8  0x610 0x61B  0x64B 0x660  0x670 0x671  0x6D6 0x6DD  0x6DF 0x6E5
    0x6E7 0x6E9  0x6EA 0x6EE  0x711 0x712  0x730 0x74B  0x7A6 0x7B1  0x7EB 0x7F4
    0x7FD 0x7FE  0x816 0x81A  0x81B 0x824  0x825 0x828  0x829 0x82E  0x859 0x85C
    0x897 0x8A0  0x8CA 0x8E2  0x8E3 0x903  0x93A 0x93B  0x93C 0x93D  0x941 0x949
    0x94D 0x94E  0x951 0x958  0x962 0x964  0x981 0x982  0x9BC 0x9BD  0x9BE 0x9BF
    0x9C1 0x9C5  0x9CD 0x9CE  0x9D7 0x9D8  0x9E2 0x9E4  0x9FE 0x9FF  0xA01 0xA03
    0xA3C 0xA3D  0xA41 0xA43  0xA47 0xA49  0xA4B 0xA4E  0xA51 0xA52  0xA70 0xA72
    0xA75 0xA76  0xA81 0xA83  0xABC 0xABD  0xAC1 0xAC6  0xAC7 0xAC9  0xACD 0xACE
    0xAE2 0xAE4  0xAFA 0xB00  0xB01 0xB02  0xB3C 0xB3D  0xB3E 0xB40  0xB41 0xB45
    0xB4D 0xB4E  0xB55 0xB58  0xB62 0xB64  0xB82 0xB83  0xBBE 0xBBF  0xBC0 0xBC1
    0xBCD 0xBCE  0xBD7 0xBD8  0xC00 0xC01  0xC04 0xC05  0xC3C 0xC3D  0xC3E 0xC41
    0xC46 0xC49  0xC4A 0xC4E  0xC55 0xC57  0xC62 0xC64  0xC81 0xC82  0xCBC 0xCBD
    0xCBF 0xCC1  0xCC2 0xCC3  0xCC6 0xCC9  0xCCA 0xCCE  0xCD5 0xCD7  0xCE2 0xCE4
    0xD00 0xD02  0xD3B 0xD3D  0xD3E 0xD3F  0xD41 0xD45  0xD4D 0xD4E  0xD57 0xD58
    0xD62 0xD64  0xD81 0xD82  0xDCA 0xDCB  0xDCF 0xDD0  0xDD2 0xDD5  0xDD6 0xDD7
    0xDDF 0xDE0  0xE31 0xE32  0xE34 0xE3B  0xE47 0xE4F  0xEB1 0xEB2  0xEB4 0xEBD
    0xEC8 0xECF  0xF18 0xF1A  0xF35 0xF36  0xF37 0xF38  0xF39 0xF3A  0xF71 0xF7F
    0xF80 0xF85  0xF86 0xF88  0xF8D 0xF98  0xF99 0xFBD  0xFC6 0xFC7  0x102D 0x1031
    0x1032 0x1038  0x1039 0x103B  0x103D 0x103F  0x1058 0x105A  0x105E 0x1061  0x1071 0x1075
    0x1082 0x1083  0x1085 0x1087  0x108D 0x108E  0x109D 0x109E  0x135D 0x1360  0x1712 0x1716
    0x1732 0x1735  0x1752 0x1754  0x1772 0x1774  0x17B4 0x17B6  0x17B7 0x17BE  0x17C6 0x17C7
    0x17C9 0x17D4  0x17DD 0x17DE  0x180B 0x180E  0x180F 0x1810  0x1885 0x1887  0x18A9 0x18AA
    0x1920 0x1923  0x1927 0x1929  0x1932 0x1933  0x1939 0x193C  0x1A17 0x1A19  0x1A1B 0x1A1C
    0x1A56 0x1A57  0x1A58 0x1A5F  0x1A60 0x1A61  0x1A62 0x1A63  0x1A65 0x1A6D  0x1A73 0x1A7D
    0x1A7F 0x1A80  0x1AB0 0x1ADE  0x1AE0 0x1AEC  0x1B00 0x1B04  0x1B34 0x1B3E  0x1B42 0x1B45
    0x1B6B 0x1B74  0x1B80 0x1B82  0x1BA2 0x1BA6  0x1BA8 0x1BAE  0x1BE6 0x1BE7  0x1BE8 0x1BEA
    0x1BED 0x1BEE  0x1BEF 0x1BF4  0x1C2C 0x1C34  0x1C36 0x1C38  0x1CD0 0x1CD3  0x1CD4 0x1CE1
    0x1CE2 0x1CE9  0x1CED 0x1CEE  0x1CF4 0x1CF5  0x1CF8 0x1CFA  0x1DC0 0x1E00  0x200C 0x200D
    0x20D0 0x20F1  0x2CEF 0x2CF2  0x2D7F 0x2D80  0x2DE0 0x2E00  0x302A 0x3030  0x3099 0x309B
    0xA66F 0xA673  0xA674 0xA67E  0xA69E 0xA6A0  0xA6F0 0xA6F2  0xA802 0xA803  0xA806 0xA807
    0xA80B 0xA80C  0xA825 0xA827  0xA82C 0xA82D  0xA8C4 0xA8C6  0xA8E0 0xA8F2  0xA8FF 0xA900
    0xA926 0xA92E  0xA947 0xA952  0xA953 0xA954  0xA980 0xA983  0xA9B3 0xA9B4  0xA9B6 0xA9BA
    0xA9BC 0xA9BE  0xA9C0 0xA9C1  0xA9E5 0xA9E6  0xAA29 0xAA2F  0xAA31 0xAA33  0xAA35 0xAA37
    0xAA43 0xAA44  0xAA4C 0xAA4D  0xAA7C 0xAA7D  0xAAB0 0xAAB1  0xAAB2 0xAAB5  0xAAB7 0xAAB9
    0xAABE 0xAAC0  0xAAC1 0xAAC2  0xAAEC 0xAAEE  0xAAF6 0xAAF7  0xABE5 0xABE6  0xABE8 0xABE9
    0xABED 0xABEE  0xFB1E 0xFB1F  0xFE00 0xFE10  0xFE20 0xFE30  0xFF9E 0xFFA0  0x101FD 0x101FE
    0x102E0 0x102E1  0x10376 0x1037B  0x10A01 0x10A04  0x10A05 0x10A07  0x10A0C 0x10A10  0x10A38 0x10A3B
    0x10A3F 0x10A40  0x10AE5 0x10AE7  0x10D24 0x10D28  0x10D69 0x10D6E  0x10EAB 0x10EAD  0x10EFA 0x10F00
    0x10F46 0x10F51  0x10F82 0x10F86  0x11001 0x11002  0x11038 0x11047  0x11070 0x11071  0x11073 0x11075
    0x1107F 0x11082  0x110B3 0x110B7  0x110B9 0x110BB  0x110C2 0x110C3  0x11100 0x11103  0x11127 0x1112C
    0x1112D 0x11135  0x11173 0x11174  0x11180 0x11182  0x111B6 0x111BF  0x111C0 0x111C1  0x111C9 0x111CD
    0x111CF 0x111D0  0x1122F 0x11232  0x11234 0x11238  0x1123E 0x1123F  0x11241 0x11242  0x112DF 0x112E0
    0x112E3 0x112EB  0x11300 0x11302  0x1133B 0x1133D  0x1133E 0x1133F  0x11340 0x11341  0x1134D 0x1134E
    0x11357 0x11358  0x11366 0x1136D  0x11370 0x11375  0x113B8 0x113B9  0x113BB 0x113C1  0x113C2 0x113C3
    0x113C5 0x113C6  0x113C7 0x113CA  0x113CE 0x113D1  0x113D2 0x113D3  0x113E1 0x113E3  0x11438 0x11440
    0x11442 0x11445  0x11446 0x11447  0x1145E 0x1145F  0x114B0 0x114B1  0x114B3 0x114B9  0x114BA 0x114BB
    0x114BD 0x114BE  0x114BF 0x114C1  0x114C2 0x114C4  0x115AF 0x115B0  0x115B2 0x115B6  0x115BC 0x115BE
    0x115BF 0x115C1  0x115DC 0x115DE  0x11633 0x1163B  0x1163D 0x1163E  0x1163F 0x11641  0x116AB 0x116AC
    0x116AD 0x116AE  0x116B0 0x116B8  0x1171D 0x1171E  0x1171F 0x11720  0x11722 0x11726  0x11727 0x1172C
    0x1182F 0x11838  0x11839 0x1183B  0x11930 0x11931  0x1193B 0x1193F  0x11943 0x11944  0x119D4 0x119D8
    0x119DA 0x119DC  0x119E0 0x119E1  0x11A01 0x11A0B  0x11A33 0x11A39  0x11A3B 0x11A3F  0x11A47 0x11A48
    0x11A51 0x11A57  0x11A59 0x11A5C  0x11A8A 0x11A97  0x11A98 0x11A9A  0x11B60 0x11B61  0x11B62 0x11B65
    0x11B66 0x11B67  0x11C30 0x11C37  0x11C38 0x11C3E  0x11C3F 0x11C40  0x11C92 0x11CA8  0x11CAA 0x11CB1
    0x11CB2 0x11CB4  0x11CB5 0x11CB7  0x11D31 0x11D37  0x11D3A 0x11D3B  0x11D3C 0x11D3E  0x11D3F 0x11D46
    0x11D47 0x11D48  0x11D90 0x11D92  0x11D95 0x11D96  0x11D97 0x11D98  0x11EF3 0x11EF5  0x11F00 0x11F02
    0x11F36 0x11F3B  0x11F40 0x11F43  0x11F5A 0x11F5B  0x13440 0x13441  0x13447 0x13456  0x1611E 0x1612A
    0x1612D 0x16130  0x16AF0 0x16AF5  0x16B30 0x16B37  0x16F4F 0x16F50  0x16F8F 0x16F93  0x16FE4 0x16FE5
    0x16FF0 0x16FF2  0x1BC9D 0x1BC9F  0x1CF00 0x1CF2E  0x1CF30 0x1CF47  0x1D165 0x1D16A  0x1D16D 0x1D173
    0x1D17B 0x1D183  0x1D185 0x1D18C  0x1D1AA 0x1D1AE  0x1D242 0x1D245  0x1DA00 0x1DA37  0x1DA3B 0x1DA6D
    0x1DA75 0x1DA76  0x1DA84 0x1DA85  0x1DA9B 0x1DAA0  0x1DAA1 0x1DAB0  0x1E000 0x1E007  0x1E008 0x1E019
    0x1E01B 0x1E022  0x1E023 0x1E025  0x1E026 0x1E02B  0x1E08F 0x1E090  0x1E130 0x1E137  0x1E2AE 0x1E2AF
    0x1E2EC 0x1E2F0  0x1E4EC 0x1E4F0  0x1E5EE 0x1E5F0  0x1E6E3 0x1E6E4  0x1E6E6 0x1E6E7  0x1E6EE 0x1E6F0
    0x1E6F5 0x1E6F6  0x1E8D0 0x1E8D7  0x1E944 0x1E94B  0x1F3FB 0x1F400  0xE0020 0xE0080  0xE0100 0xE01F0
)

# Narrow bases with an emoji presentation sequence in Unicode 9.0.
layout_vs16_boundaries=(
    0x23 0x24  0x2A 0x2B  0x30 0x3A  0xA9 0xAA  0xAE 0xAF  0x203C 0x203D
    0x2049 0x204A  0x2122 0x2123  0x2139 0x213A  0x2194 0x219A  0x21A9 0x21AB  0x2328 0x2329
    0x23CF 0x23D0  0x23ED 0x23F0  0x23F1 0x23F3  0x23F8 0x23FB  0x24C2 0x24C3  0x25AA 0x25AC
    0x25B6 0x25B7  0x25C0 0x25C1  0x25FB 0x25FD  0x2600 0x2605  0x260E 0x260F  0x2611 0x2612
    0x2618 0x2619  0x261D 0x261E  0x2620 0x2621  0x2622 0x2624  0x2626 0x2627  0x262A 0x262B
    0x262E 0x2630  0x2638 0x263B  0x2640 0x2641  0x2642 0x2643  0x265F 0x2661  0x2663 0x2664
    0x2665 0x2667  0x2668 0x2669  0x267B 0x267C  0x267E 0x267F  0x2692 0x2693  0x2694 0x2698
    0x2699 0x269A  0x269B 0x269D  0x26A0 0x26A1  0x26A7 0x26A8  0x26B0 0x26B2  0x26C8 0x26C9
    0x26CF 0x26D0  0x26D1 0x26D2  0x26D3 0x26D4  0x26E9 0x26EA  0x26F0 0x26F2  0x26F4 0x26F5
    0x26F7 0x26FA  0x2702 0x2703  0x2708 0x270A  0x270C 0x270E  0x270F 0x2710  0x2712 0x2713
    0x2714 0x2715  0x2716 0x2717  0x271D 0x271E  0x2721 0x2722  0x2733 0x2735  0x2744 0x2745
    0x2747 0x2748  0x2763 0x2765  0x27A1 0x27A2  0x2934 0x2936  0x2B05 0x2B08  0x1F170 0x1F172
    0x1F17E 0x1F180  0x1F321 0x1F322  0x1F324 0x1F32D  0x1F336 0x1F337  0x1F37D 0x1F37E  0x1F396 0x1F398
    0x1F399 0x1F39C  0x1F39E 0x1F3A0  0x1F3CB 0x1F3CF  0x1F3D4 0x1F3E0  0x1F3F3 0x1F3F4  0x1F3F5 0x1F3F6
    0x1F3F7 0x1F3F8  0x1F43F 0x1F440  0x1F441 0x1F442  0x1F4FD 0x1F4FE  0x1F549 0x1F54B  0x1F56F 0x1F571
    0x1F573 0x1F57A  0x1F587 0x1F588  0x1F58A 0x1F58E  0x1F590 0x1F591  0x1F5A5 0x1F5A6  0x1F5A8 0x1F5A9
    0x1F5B1 0x1F5B3  0x1F5BC 0x1F5BD  0x1F5C2 0x1F5C5  0x1F5D1 0x1F5D4  0x1F5DC 0x1F5DF  0x1F5E1 0x1F5E2
    0x1F5E3 0x1F5E4  0x1F5E8 0x1F5E9  0x1F5EF 0x1F5F0  0x1F5F3 0x1F5F4  0x1F5FA 0x1F5FB  0x1F6CB 0x1F6CC
    0x1F6CD 0x1F6D0  0x1F6E0 0x1F6E6  0x1F6E9 0x1F6EA  0x1F6F0 0x1F6F1  0x1F6F3 0x1F6F4
)

# Unicode 17.0 Extended_Pictographic, used on both sides of an emoji joiner.
layout_pictograph_boundaries=(
    0xA9 0xAA  0xAE 0xAF  0x203C 0x203D  0x2049 0x204A  0x2122 0x2123  0x2139 0x213A
    0x2194 0x219A  0x21A9 0x21AB  0x231A 0x231C  0x2328 0x2329  0x23CF 0x23D0  0x23E9 0x23F4
    0x23F8 0x23FB  0x24C2 0x24C3  0x25AA 0x25AC  0x25B6 0x25B7  0x25C0 0x25C1  0x25FB 0x25FF
    0x2600 0x2605  0x260E 0x260F  0x2611 0x2612  0x2614 0x2616  0x2618 0x2619  0x261D 0x261E
    0x2620 0x2621  0x2622 0x2624  0x2626 0x2627  0x262A 0x262B  0x262E 0x2630  0x2638 0x263B
    0x2640 0x2641  0x2642 0x2643  0x2648 0x2654  0x265F 0x2661  0x2663 0x2664  0x2665 0x2667
    0x2668 0x2669  0x267B 0x267C  0x267E 0x2680  0x2692 0x2698  0x2699 0x269A  0x269B 0x269D
    0x26A0 0x26A2  0x26A7 0x26A8  0x26AA 0x26AC  0x26B0 0x26B2  0x26BD 0x26BF  0x26C4 0x26C6
    0x26C8 0x26C9  0x26CE 0x26D0  0x26D1 0x26D2  0x26D3 0x26D5  0x26E9 0x26EB  0x26F0 0x26F6
    0x26F7 0x26FB  0x26FD 0x26FE  0x2702 0x2703  0x2705 0x2706  0x2708 0x270E  0x270F 0x2710
    0x2712 0x2713  0x2714 0x2715  0x2716 0x2717  0x271D 0x271E  0x2721 0x2722  0x2728 0x2729
    0x2733 0x2735  0x2744 0x2745  0x2747 0x2748  0x274C 0x274D  0x274E 0x274F  0x2753 0x2756
    0x2757 0x2758  0x2763 0x2765  0x2795 0x2798  0x27A1 0x27A2  0x27B0 0x27B1  0x27BF 0x27C0
    0x2934 0x2936  0x2B05 0x2B08  0x2B1B 0x2B1D  0x2B50 0x2B51  0x2B55 0x2B56  0x3030 0x3031
    0x303D 0x303E  0x3297 0x3298  0x3299 0x329A  0x1F004 0x1F005  0x1F02C 0x1F030  0x1F094 0x1F0A0
    0x1F0AF 0x1F0B1  0x1F0C0 0x1F0C1  0x1F0CF 0x1F0D1  0x1F0F6 0x1F100  0x1F170 0x1F172  0x1F17E 0x1F180
    0x1F18E 0x1F18F  0x1F191 0x1F19B  0x1F1AE 0x1F1E6  0x1F201 0x1F210  0x1F21A 0x1F21B  0x1F22F 0x1F230
    0x1F232 0x1F23B  0x1F23C 0x1F240  0x1F249 0x1F260  0x1F266 0x1F322  0x1F324 0x1F394  0x1F396 0x1F398
    0x1F399 0x1F39C  0x1F39E 0x1F3F1  0x1F3F3 0x1F3F6  0x1F3F7 0x1F3FB  0x1F400 0x1F4FE  0x1F4FF 0x1F53E
    0x1F549 0x1F54F  0x1F550 0x1F568  0x1F56F 0x1F571  0x1F573 0x1F57B  0x1F587 0x1F588  0x1F58A 0x1F58E
    0x1F590 0x1F591  0x1F595 0x1F597  0x1F5A4 0x1F5A6  0x1F5A8 0x1F5A9  0x1F5B1 0x1F5B3  0x1F5BC 0x1F5BD
    0x1F5C2 0x1F5C5  0x1F5D1 0x1F5D4  0x1F5DC 0x1F5DF  0x1F5E1 0x1F5E2  0x1F5E3 0x1F5E4  0x1F5E8 0x1F5E9
    0x1F5EF 0x1F5F0  0x1F5F3 0x1F5F4  0x1F5FA 0x1F650  0x1F680 0x1F6C6  0x1F6CB 0x1F6D3  0x1F6D5 0x1F6E6
    0x1F6E9 0x1F6EA  0x1F6EB 0x1F6F1  0x1F6F3 0x1F700  0x1F7DA 0x1F800  0x1F80C 0x1F810  0x1F848 0x1F850
    0x1F85A 0x1F860  0x1F888 0x1F890  0x1F8AE 0x1F8B0  0x1F8BC 0x1F8C0  0x1F8C2 0x1F8D0  0x1F8D9 0x1F900
    0x1F90C 0x1F93B  0x1F93C 0x1F946  0x1F947 0x1FA00  0x1FA58 0x1FA60  0x1FA6E 0x1FB00  0x1FC00 0x1FFFE
)

layout_in_ranges() {
    local point="$1" ranges="$2" low=0 high="$3" mid boundary
    # An odd insertion index means the code point lies inside a range.
    while (( low < high )); do
        mid=$(((low + high) / 2))
        boundary="${ranges}[$mid]"
        if (( point < ${!boundary} )); then
            high=$mid
        else
            low=$((mid + 1))
        fi
    done
    (( low % 2 ))
}

layout_codepoint_width() {
    local point="$1"
    if (( point == 0x200D )) ||
        { (( point >= 0x300 )) && layout_in_ranges "$point" layout_extend_boundaries "${#layout_extend_boundaries[@]}"; }; then
        printf -v "$2" '%d' 0
    elif (( point >= 0x1100 )) && layout_in_ranges "$point" layout_wide_boundaries "${#layout_wide_boundaries[@]}"; then
        printf -v "$2" '%d' 2
    else
        printf -v "$2" '%d' 1
    fi
}

# With no limit, return the ending column (starting at $4 or zero). With a
# limit, return the visible prefix that fits, with any retained OSC 8 link
# closed. Use byte offsets so this also works in the C locale.
scan_layout() {
    local LC_ALL=C
    local remaining="$1" destination="$2" limit="${3:--1}"
    local columns="${4:-0}" consumed=0 size width plain glyph codepoint byte i
    local base_point=0 base_width=0 join_pending=0 keep
    local kept=0 kept_link='' before_base=0 before_base_link='' active_link=''
    local utf8=$'^([\302-\337][\200-\277]|[\340-\357][\200-\277]{2}|[\360-\364][\200-\277]{3})'
    # CSI (including SGR), OSC, other control strings, and short escapes.
    local ansi=$'^\033(\\[[0-?]*[ -/]*[@-~]|\\][^\033\007]*(\007|\033\\\\)|[PX^_][^\033]*\033\\\\|[ -/]*[0-~])'
    local osc8=$'\033]8;' sequence fields terminator

    while [ -n "$remaining" ]; do
        plain=${remaining%%[![:print:]]*}
        keep=1
        if [ -n "$plain" ]; then
            # Handle an entire printable ASCII run at once.
            size=${#plain}
            width=$size
            if (( limit >= 0 )); then
                if (( columns + width > limit )); then
                    if (( columns < limit )); then
                        kept=$((consumed + limit - columns))
                        kept_link=$active_link
                    fi
                    break
                fi
                if (( size > 1 )); then
                    before_base=$((consumed + size - 1))
                    before_base_link=$active_link
                else
                    before_base=$kept
                    before_base_link=$kept_link
                fi
            fi
            join_pending=0
            base_width=1
            base_point=0
            if [[ "${remaining:size}" == $'\357\270\217'* ]]; then
                printf -v base_point '%d' "'${plain:size-1:1}"
            fi
        elif [[ "$remaining" == $'\033'* && "$remaining" =~ $ansi ]]; then
            sequence=${BASH_REMATCH[0]}
            size=${#sequence}
            width=0
            keep=0
            if (( limit >= 0 )); then
                # Adjacent resets and link closers belong to retained text.
                # Openers only become part of the cut when visible text fits.
                case "$sequence" in
                    $'\033[m'|$'\033[0m')
                        (( kept > 0 && kept == consumed )) && keep=1
                        ;;
                    "$osc8"*)
                        case "$sequence" in
                            *$'\a') terminator=$'\a' ;;
                            *) terminator=$'\033\\' ;;
                        esac
                        fields=${sequence#"$osc8"}
                        fields=${fields%"$terminator"}
                        case "$fields" in
                            *';'*)
                                if [ -z "${fields#*;}" ]; then
                                    active_link=''
                                    (( kept > 0 && kept == consumed )) && keep=1
                                else
                                    active_link="$osc8;$terminator"
                                fi
                                ;;
                        esac
                        ;;
                esac
            fi
        elif [[ "$remaining" =~ $utf8 ]]; then
            glyph=${BASH_REMATCH[0]}
            size=${#glyph}
            printf -v byte '%d' "'$glyph"
            codepoint=$((byte & (0x7f >> size)))
            for ((i = 1; i < size; i++)); do
                printf -v byte '%d' "'${glyph:i:1}"
                codepoint=$(((codepoint << 6) | (byte & 0x3f)))
            done
            layout_codepoint_width "$codepoint" width
            if (( codepoint == 0x200D )); then
                join_pending=1
                keep=0
            elif (( width > 0 )); then
                if (( join_pending && base_width > 0 )) &&
                    layout_in_ranges "$base_point" layout_pictograph_boundaries "${#layout_pictograph_boundaries[@]}" &&
                    layout_in_ranges "$codepoint" layout_pictograph_boundaries "${#layout_pictograph_boundaries[@]}"; then
                    # The linked pictographs share one two-cell glyph.
                    width=$((2 - base_width))
                    if (( limit >= 0 && columns + width > limit )); then
                        kept=$before_base
                        kept_link=$before_base_link
                        break
                    fi
                    base_width=2
                else
                    before_base=$kept
                    before_base_link=$kept_link
                    base_width=$width
                fi
                base_point=$codepoint
                join_pending=0
            elif (( codepoint == 0xFE0F && base_width == 1 )) &&
                layout_in_ranges "$base_point" layout_vs16_boundaries "${#layout_vs16_boundaries[@]}"; then
                if (( limit >= 0 && columns == limit )); then
                    # The selector widens the base, so discard the whole glyph.
                    kept=$before_base
                    kept_link=$before_base_link
                    break
                fi
                width=1
                base_width=2
            elif (( base_width == 0 || join_pending )); then
                keep=0
            fi
        else
            size=1
            width=1
            case "$remaining" in
                $'\t'*) width=$((8 - columns % 8)) ;;
                [[:cntrl:]]*) width=0; keep=0 ;;
            esac
            base_point=0
            base_width=0
            join_pending=0
        fi
        if (( limit >= 0 && columns + width > limit )); then
            break
        fi
        columns=$((columns + width))
        consumed=$((consumed + size))
        if (( limit >= 0 && keep )); then
            kept=$consumed
            kept_link=$active_link
        fi
        remaining=${remaining:size}
    done

    if (( limit < 0 )); then
        printf -v "$destination" '%d' "$columns"
    else
        printf -v "$destination" '%s%s' "${1:0:kept}" "$kept_link"
    fi
}

measure_wrap_width() {
    local text="$1"
    case "$text" in
        *$'\n'|*\\*|-*)
            # Match the renderer's echo option and escape handling.
            # shellcheck disable=SC2116
            text=$(echo "$text")
            ;;
    esac
    scan_layout "$text" "$2" -1 "${3:-0}"
}

wrap_at_separators() {
    local sections="$1"
    local separator="$2"
    local right_reserve="${3:-20}"

    # Get terminal width
    local term_width
    if [ -n "${TERMINAL_WIDTH:-}" ]; then
        term_width="$TERMINAL_WIDTH"
    else
        term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-200}")
        term_width=${term_width:-200}
    fi

    local max_line_width=$((term_width - right_reserve))

    local output=""
    local current_line=""
    local current_len=0 section section_len sep_len projected_len
    local sgr_prefix=$'\033''(\[[0-9;]*)?$'
    measure_wrap_width "$separator" sep_len

    # Process each section (newline-separated input)
    while IFS= read -r section || [ -n "$section" ]; do
        [ -z "$section" ] && continue

        measure_wrap_width "$section" section_len

        if [ -z "$current_line" ]; then
            # First section on this line
            current_line="$section"
            current_len=$section_len
        else
            if [[ "$separator$section" == *$'\t'* ]]; then
                measure_wrap_width "$separator$section" projected_len "$current_len"
            else
                projected_len=$((current_len + sep_len + section_len))
            fi

            if [ "$projected_len" -le "$max_line_width" ]; then
                # A partial SGR sequence can become complete at a join. Echo
                # options, backslashes and multiline separators can also make
                # the joined width differ from the sum of the parts.
                current_len=$projected_len
                if [[ "$current_line" =~ $sgr_prefix || "$separator" =~ $sgr_prefix ||
                      "$current_line" == -* || "$separator" == -* || "$section" == -* ||
                      "$separator" == *$'\n'* || "$current_line$separator$section" == *\\* ]]; then
                    current_len=
                fi
                current_line="${current_line}${separator}${section}"
                [ -n "$current_len" ] || measure_wrap_width "$current_line" current_len
            else
                # Doesn't fit - output current line and start new one
                if [ -n "$output" ]; then
                    output="${output}"$'\n'"${current_line}"
                else
                    output="$current_line"
                fi
                current_line="$section"
                current_len=$section_len
            fi
        fi
    done <<< "$sections"

    # Output the last line
    if [ -n "$current_line" ]; then
        if [ -n "$output" ]; then
            output="${output}"$'\n'"${current_line}"
        else
            output="$current_line"
        fi
    fi

    echo "$output"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' 'cortado: jq missing'
        return 0
    fi

    if [ "${_CORTADO_MODULE_REGISTRY_UNAVAILABLE:-false}" = true ]; then
        printf '%s\n' 'cortado: module catalog unavailable'
        return 0
    fi

    # Keep a private capture for sequential source and run calls. Flush it in
    # the caller after each call so log entries are available when main returns.
    local module_stderr=/dev/null
    CORTADO_STDERR_CAPTURE=
    CORTADO_STDERR_READER=
    if [ "${DEBUG_MODE:-false}" = "true" ]; then
        if CORTADO_STDERR_CAPTURE=$(create_module_stderr "${TMPDIR:-/tmp}") ||
            CORTADO_STDERR_CAPTURE=$(create_module_stderr "$CLAUDE_CONFIG_DIR"); then
            trap cleanup_module_stderr EXIT
            trap 'exit 143' TERM
            trap 'exit 130' INT
            trap 'exit 129' HUP
            module_stderr="$CORTADO_STDERR_CAPTURE/pipe"
        fi
    fi
    load_modules "$module_stderr"
    report_module_refusals

    # Resolve the OS in main so trusted configs can supply a uname hook.
    # Issue #31 will replace render_os with CORTADO_OS.
    local render_os
    if [[ "${OSTYPE:-}" == darwin* && "${BASH_VERSINFO[5]}" == *-darwin* ]]; then
        render_os=Darwin
    elif [[ "${OSTYPE:-}" == linux* && "${BASH_VERSINFO[5]}" == *-linux* ]]; then
        render_os=Linux
    else
        render_os=$(uname -s 2>/dev/null)
    fi

    # Keep the original JSON argument for module hooks. A raw NUL is invalid
    # JSON and read stops there. Strip trailing newlines as command substitution did.
    local input
    if IFS= read -r -d '' input; then
        input=
    fi
    while [[ "$input" == *$'\n' ]]; do input=${input%$'\n'}; done
    with_payload_context render_statusline "$module_stderr" "$input" <<< "$input"
}

render_statusline() {
    local module_stderr="$1" input="$2" current_dir="${CTX_CURRENT_DIR:-}"

    # Load per-directory config if it exists
    # This allows project-specific statusline customization
    # Uses safe parser — project configs are untrusted and must not be sourced
    local trusted_theme="${COLOR_THEME:-default}"
    local trusted_module_order="${MODULE_ORDER%%$'\n'*}"
    trusted_module_order=${trusted_module_order// /}
    if [ -n "$current_dir" ] && [ -d "$current_dir" ]; then
        local dir_config="$current_dir/.cortado.conf"
        # Pre-rename name: honor a project's .barista.conf until it gains a .cortado.conf
        [ -f "$dir_config" ] || dir_config="$current_dir/.barista.conf"
        if [ -f "$dir_config" ]; then
            log_debug "Loading per-directory config (safe parser): $dir_config"
            load_config_safe "$dir_config"
        fi
    fi

    # Apply color theme settings (must be after all config loading)
    if type apply_theme >/dev/null 2>&1; then
        apply_render_theme "$trusted_theme"
    fi

    # Sanitize the untrusted-config width numerics before the layout arithmetic below.
    # TERMINAL_WIDTH / RIGHT_SIDE_RESERVE are allowlisted from the untrusted project
    # .cortado.conf (loaded just above via the safe parser); a non-positive-integer or
    # leading-zero ("octal") value would break the wrap math — e.g. TERMINAL_WIDTH="0"
    # is a modulo-by-zero in the wrap layout, and "08" is a bash arithmetic error. Clamp
    # once, after all configs load (mirrors the cost/battery config-sink validation).
    case "${TERMINAL_WIDTH:-}" in
        ''|*[!0-9]*|0*) TERMINAL_WIDTH="" ;;     # invalid → fall back to auto-detect
    esac
    case "${RIGHT_SIDE_RESERVE:-}" in
        0) ;;                                     # zero is valid (no reserve)
        ''|*[!0-9]*|0*) RIGHT_SIDE_RESERVE=20 ;;  # invalid/leading-zero → default
    esac

    # Compact removes spaces only when joining the rendered sections.
    local render_separator="${SEPARATOR-}"
    if [ "${DISPLAY_MODE:-normal}" = "compact" ]; then
        remove_render_spaces render_separator
    fi

    # Default module order if not specified
    local DEFAULT_ORDER="sandbox,version,update,directory,context,git,project,model,cost,rate-limits,time,battery"

    # Use custom order if specified, otherwise use default
    local module_order="${MODULE_ORDER:-$DEFAULT_ORDER}"

    if [ "${DEBUG_MODE:-false}" = "true" ]; then
        validate_module_order "$module_order"
    fi

    # Build status line sections
    local sections=""

    # Process modules in specified order. Split MODULE_ORDER with IFS scoped to
    # the read alone: modules run inside this loop, and a comma IFS here broke
    # every read-based split inside them (each status indicator printed all of
    # its glyphs at once). The array also keeps a "*" in MODULE_ORDER from
    # glob-expanding.
    local modules module probe_snapshot=false
    IFS=',' read -r -a modules <<< "$module_order"
    for module in "${modules[@]}"; do
        remove_render_spaces module

        # Skip empty entries
        [ -z "$module" ] && continue

        # Check if module is enabled
        if is_module_enabled "$module"; then
            case "$module:$probe_snapshot" in
                brightness:false|cpu:false|docker:false|load:false|network:false|node:false|processes:false|weather:false)
                    _snapshot_probe_cache
                    probe_snapshot=true ;;
            esac
            # Wrap module execution in a subshell with error handling.
            # This prevents a single module crash from killing the entire statusline.
            local output
            start_module_stderr
            output=$(run_module "$module" "$current_dir" "$input" 2>|"$module_stderr") || {
                log_debug "Module $module failed with exit code $?"
                output=""
            }
            log_module_stderr "$module"

            if [ -n "$output" ]; then
                if [ -n "$sections" ]; then
                    sections="${sections}"$'\n'"${output}"
                else
                    sections="$output"
                fi
            fi
        fi
    done
    # =============================================================================
    # TERMINAL-WIDTH-AWARE OUTPUT
    # =============================================================================

    local layout_mode="${LAYOUT_MODE:-smart}"
    local right_reserve="${RIGHT_SIDE_RESERVE:-20}"
    local output=""

    case "$layout_mode" in
        smart)
            # Smart mode (default): join with separator, wrap at separator boundaries
            # when content would exceed terminal width minus reserve
            output=$(wrap_at_separators "$sections" "$render_separator" "$right_reserve")
            ;;
        newline)
            # Newline mode: join all with separator, add newline at end
            # Forces Claude's right-side to next line
            local first=true
            while IFS= read -r section || [ -n "$section" ]; do
                [ -z "$section" ] && continue
                if [ "$first" = true ]; then
                    output="$section"
                    first=false
                else
                    output="${output}${render_separator}${section}"
                fi
            done <<< "$sections"
            output="${output}"$'\n'
            ;;
        wrap)
            # Wrap mode: join all with separator, pad to next line boundary
            local first=true
            while IFS= read -r section || [ -n "$section" ]; do
                [ -z "$section" ] && continue
                if [ "$first" = true ]; then
                    output="$section"
                    first=false
                else
                    output="${output}${render_separator}${section}"
                fi
            done <<< "$sections"
            local term_width
            if [ -n "${TERMINAL_WIDTH:-}" ]; then
                term_width="$TERMINAL_WIDTH"
            else
                term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-200}")
                term_width=${term_width:-200}
            fi
            local output_len
            measure_wrap_width "$output" output_len
            local remainder=$((output_len % term_width))
            if [ "$remainder" -ne 0 ]; then
                local padding_needed=$((term_width - remainder))
                local padding
                padding=$(printf "%${padding_needed}s" "")
                output="${output}${padding}"
            fi
            ;;
        truncate)
            # Truncate mode: join all with separator, cut to fit with Claude's right-side
            local first=true
            while IFS= read -r section || [ -n "$section" ]; do
                [ -z "$section" ] && continue
                if [ "$first" = true ]; then
                    output="$section"
                    first=false
                else
                    output="${output}${render_separator}${section}"
                fi
            done <<< "$sections"
            local term_width
            if [ -n "${TERMINAL_WIDTH:-}" ]; then
                term_width="$TERMINAL_WIDTH"
            else
                term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-200}")
                term_width=${term_width:-200}
            fi
            local available_width=$((term_width - right_reserve))
            (( available_width >= 0 )) || available_width=0
            local output_len
            scan_layout "$output" output_len
            if [ "$output_len" -gt "$available_width" ]; then
                local ellipsis='...'
                if (( available_width < 3 )); then
                    ellipsis=${ellipsis:0:available_width}
                fi
                scan_layout "$output" output "$((available_width - ${#ellipsis}))"
                output="${output}${ellipsis}"$'\033[0m'
            fi
            ;;
        none)
            # No layout adjustments - just join with separator
            local first=true
            while IFS= read -r section || [ -n "$section" ]; do
                [ -z "$section" ] && continue
                if [ "$first" = true ]; then
                    output="$section"
                    first=false
                else
                    output="${output}${render_separator}${section}"
                fi
            done <<< "$sections"
            ;;
    esac

    echo "$output"
}

# =============================================================================
# CLI subcommands (when not invoked as Claude Code statusline via stdin JSON)
# =============================================================================
# Claude Code invokes this script with no args and JSON on stdin. Subcommands
# are only taken when $1 is present so statusline rendering stays unchanged.
cortado_cli_dispatch() {
    case "${1:-}" in
        config|--config)
            shift
            if [ "${_CORTADO_MODULE_REGISTRY_UNAVAILABLE:-false}" = true ]; then
                printf '%s\n' 'cortado: module catalog unavailable' >&2
                exit 1
            fi
            if [ ! -f "$SCRIPT_DIR/lib/config-tui.sh" ]; then
                echo "cortado: missing lib/config-tui.sh (incomplete install)." >&2
                echo "Re-run ./install.sh from your Cortado checkout." >&2
                exit 1
            fi
            if [ -f "$MODULES_DIR/utils.sh" ]; then
                # shellcheck source=/dev/null
                . "$MODULES_DIR/utils.sh"
            fi
            report_module_refusals
            # shellcheck disable=SC1091
            . "$SCRIPT_DIR/lib/config-tui.sh"
            cortado_config_main "$@"
            exit $?
            ;;
        version|--version|-v)
            if [ -f "$SCRIPT_DIR/VERSION" ]; then
                tr -d '[:space:]' < "$SCRIPT_DIR/VERSION"
                echo
            else
                echo "unknown"
            fi
            exit 0
            ;;
        help|--help|-h)
            cat <<EOF
Cortado — modular Claude Code statusline

Usage:
  cortado.sh                 # statusline (JSON on stdin; Claude Code default)
  cortado.sh config […]      # post-install config TUI / CLI (see --help)
  cortado.sh version         # print VERSION
  cortado.sh help            # this message

Install / update: ./install.sh --help
Source: https://github.com/gcko/Cortado (a fork of pstuart/Barista)
EOF
            exit 0
            ;;
    esac
}

if [ "$#" -gt 0 ]; then
    cortado_cli_dispatch "$@"
fi

# Run main function
main
