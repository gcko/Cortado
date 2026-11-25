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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
CONFIG_FILE="$SCRIPT_DIR/cortado.conf"

# Determine Claude config directory (respects CLAUDE_CONFIG_DIR env var)
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# =============================================================================
# DEFAULT CONFIGURATION
# =============================================================================
# cortado.conf (shipped with Cortado, sourced below by load_config) supplies the
# SEPARATOR, DISPLAY_MODE, USE_ICONS, USE_STATUS_INDICATORS, STATUS_STYLE,
# PROGRESS_BAR_*, MODULE_*, CACHE_MAX_AGE, DEBUG_MODE, LAYOUT_MODE,
# TERMINAL_WIDTH and RIGHT_SIDE_RESERVE defaults. Do not restate them here;
# every consumer below reads them with a ${VAR:-fallback} guard so a missing or
# rejected config still renders. Only the two module flags that cortado.conf
# does not define are kept here.

MODULE_VERSION="true"
MODULE_UPDATE="true"

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Succeeds unless $1 is group- or world-writable. A cortado.conf is sourced as full
# bash, so a writable one is a persistent code-exec vector (Refs #28 part 3). Mirrors
# the Darwin/Linux stat fork used in utils.sh; fails open if the mode can't be read so
# an unusual environment never breaks the statusline.
config_not_group_or_world_writable() {
    local f="$1" perms len group_digit other_digit
    if [ "$(uname)" = "Darwin" ]; then
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
        MODULE_SANDBOX|MODULE_VERSION|MODULE_UPDATE|MODULE_DIRECTORY|MODULE_CONTEXT|MODULE_GIT|\
        MODULE_PROJECT|MODULE_MODEL|MODULE_COST|MODULE_RATE_LIMITS|MODULE_TIME|MODULE_BATTERY|\
        MODULE_CPU|MODULE_MEMORY|MODULE_DISK|MODULE_NETWORK|MODULE_UPTIME|MODULE_LOAD|\
        MODULE_TEMPERATURE|MODULE_BRIGHTNESS|MODULE_PROCESSES|MODULE_DOCKER|MODULE_NODE|\
        MODULE_WEATHER|MODULE_TIMEZONE)
            [ "$val" = "false" ]
            ;;
        SEPARATOR|DISPLAY_MODE|COLOR_THEME|USE_ICONS|USE_STATUS_INDICATORS|STATUS_STYLE|\
        STATUS_GREEN|STATUS_YELLOW|STATUS_ORANGE|STATUS_RED|\
        LAYOUT_MODE|TERMINAL_WIDTH|RIGHT_SIDE_RESERVE|MODULE_ORDER|\
        PROGRESS_BAR_WIDTH|PROGRESS_BAR_FILLED|PROGRESS_BAR_EMPTY|\
        DIRECTORY_ICON|DIRECTORY_STYLE|DIRECTORY_SHOW_FULL_PATH|DIRECTORY_MAX_LENGTH|\
        CONTEXT_ICON|CONTEXT_SHOW_PROGRESS_BAR|CONTEXT_SHOW_PERCENTAGE|CONTEXT_SHOW_STATUS|\
        CONTEXT_SHOW_TOKENS_REMAINING|CONTEXT_COMPACT_ICON|CONTEXT_WARNING_THRESHOLD|\
        CONTEXT_CRITICAL_THRESHOLD|CONTEXT_COMPACT_THRESHOLD|\
        GIT_ICON|GIT_SHOW_BRANCH|GIT_SYMBOL_MODIFIED|\
        GIT_SYMBOL_UNTRACKED|GIT_SYMBOL_STAGED|GIT_FILE_ICON|GIT_COMPACT|\
        PROJECT_STYLE|PROJECT_DEV_ICON|PROJECT_BUILD_ICON|PROJECT_ICON_ASTRO|PROJECT_ICON_BUN|\
        PROJECT_ICON_DENO|PROJECT_ICON_ELIXIR|PROJECT_ICON_GO|PROJECT_ICON_JAVA|PROJECT_ICON_KOTLIN|\
        PROJECT_ICON_NEXTJS|PROJECT_ICON_NODE|PROJECT_ICON_NUXT|PROJECT_ICON_PHP|PROJECT_ICON_PYTHON|\
        PROJECT_ICON_REMIX|PROJECT_ICON_RUBY|PROJECT_ICON_RUST|PROJECT_ICON_SVELTE|\
        PROJECT_ICON_SWIFT|PROJECT_ICON_VITE|\
        MODEL_ICON|MODEL_SHOW_OUTPUT_STYLE|MODEL_COMPACT|MODEL_STYLE|MODEL_SHOW_THINKING|MODEL_THINKING_ICON|\
        COST_ICON|COST_SHOW_BURN_RATE|COST_SHOW_TPM|COST_TPM_ICON|COST_DECIMAL_PLACES|\
        COST_COMPACT|COST_MINIMUM_DISPLAY|\
        RATE_SHOW_5H|RATE_SHOW_7D|RATE_SHOW_TIME_REMAINING|RATE_SHOW_PROJECTION|RATE_SHOW_PROGRESS_BAR|\
        RATE_PROGRESS_BAR_WIDTH|RATE_WARNING_THRESHOLD|RATE_CRITICAL_THRESHOLD|RATE_COMPACT|\
        RATE_5H_LABEL|RATE_7D_LABEL|RATE_LOW_THRESHOLD|RATE_MEDIUM_THRESHOLD|RATE_HIGH_THRESHOLD|\
        RATE_SHOW_USAGE_STATUS|\
        VERSION_ICON|VERSION_SHOW_DURATION|SANDBOX_ICON|\
        TIME_DATE_ICON|TIME_CLOCK_ICON|TIME_SHOW_DATE|TIME_SHOW_TIME|TIME_DATE_FORMAT|TIME_TIME_FORMAT|TIME_COMPACT|\
        BATTERY_ICON|BATTERY_SHOW_CHARGING|BATTERY_CHARGING_ICON|BATTERY_LOW_ICON|BATTERY_CRITICAL_ICON|\
        BATTERY_LOW_THRESHOLD|BATTERY_CRITICAL_THRESHOLD|BATTERY_SHOW_PERCENTAGE|\
        CPU_ICON|CPU_SHOW_PERCENTAGE|CPU_WARNING_THRESHOLD|CPU_CRITICAL_THRESHOLD|CPU_SHOW_STATUS|\
        MEMORY_ICON|MEMORY_SHOW_PERCENTAGE|MEMORY_SHOW_USED|MEMORY_WARNING_THRESHOLD|\
        MEMORY_CRITICAL_THRESHOLD|MEMORY_SHOW_STATUS|\
        DISK_ICON|DISK_SHOW_PERCENTAGE|DISK_SHOW_FREE|DISK_WARNING_THRESHOLD|DISK_CRITICAL_THRESHOLD|DISK_SHOW_STATUS|\
        NETWORK_ICON|NETWORK_COMPACT|UPTIME_ICON|UPTIME_STYLE|\
        LOAD_ICON|LOAD_SHOW_ALL|LOAD_WARNING_THRESHOLD|LOAD_CRITICAL_THRESHOLD|LOAD_SHOW_STATUS|\
        TEMP_ICON|TEMP_UNITS|TEMP_WARNING_THRESHOLD|TEMP_CRITICAL_THRESHOLD|TEMP_SHOW_STATUS|\
        BRIGHTNESS_ICON|BRIGHTNESS_SHOW_PERCENT|BRIGHTNESS_SHOW_BAR|BRIGHTNESS_BAR_WIDTH|\
        PROC_ICON|PROC_SHOW_TOTAL|PROC_SHOW_RUNNING|PROC_WARNING_THRESHOLD|PROC_CRITICAL_THRESHOLD|PROC_SHOW_STATUS|\
        DOCKER_ICON|DOCKER_SHOW_RUNNING|DOCKER_SHOW_TOTAL|DOCKER_SHOW_STATUS|DOCKER_COMPACT|\
        NODE_ICON|NODE_SHOW_NVM|NODE_COMPACT|WEATHER_SHOW_TEMP|WEATHER_SHOW_COND|WEATHER_COMPACT|\
        TIMEZONE_FORMAT|TIMEZONE_SHOW_LABEL|TIMEZONE_LABELS|TIMEZONE_COMPACT)
            return 0
            ;;
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
# 1. Built-in defaults (cortado.conf below; plus MODULE_VERSION/MODULE_UPDATE above)
# 2. Script directory config (cortado.conf) — trusted, shipped with Cortado
# 3. User config ($CLAUDE_CONFIG_DIR/cortado.conf) — trusted, user-owned
# 4. Per-directory config (.cortado.conf in current_dir) — UNTRUSTED, uses safe parser

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
    # Drain the pipe after the first 64 KiB so verbose tools keep running.
    (
        umask 077
        if ! { LC_ALL=C head -c 65536 >| "$dir/data" &&
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
        get_icon() { echo "$1"; }
        get_status() { echo ""; }
        progress_bar() { echo ""; }
        format_number() { echo "$1"; }
        safe_int() { echo "${1:-0}"; }
        safe_percent() { echo "0"; }
        json_get() { echo "${3:-}"; }
        json_get_int() { echo "${3:-0}"; }
    fi

    for module_file in "$MODULES_DIR"/*.sh; do
        [ -f "$module_file" ] || continue
        module_name="${module_file##*/}"
        [ "$module_name" != utils.sh ] || continue
        start_module_stderr
        # shellcheck source=/dev/null
        . "$module_file" 2>|"$stderr_file"
        log_module_stderr "${module_name%.sh}"
    done
}

# =============================================================================
# MODULE REGISTRY
# =============================================================================
# Maps module names to their functions (compatible with Bash 3.2+)

get_module_function() {
    local module_name="$1"
    case "$module_name" in
        directory)    echo "module_directory" ;;
        context)      echo "module_context" ;;
        git)          echo "module_git" ;;
        project)      echo "module_project" ;;
        model)        echo "module_model" ;;
        cost)         echo "module_cost" ;;
        rate-limits)  echo "module_rate_limits" ;;
        time)         echo "module_time" ;;
        battery)      echo "module_battery" ;;
        cpu)          echo "module_cpu" ;;
        memory)       echo "module_memory" ;;
        disk)         echo "module_disk" ;;
        network)      echo "module_network" ;;
        uptime)       echo "module_uptime" ;;
        load)         echo "module_load" ;;
        temperature)  echo "module_temperature" ;;
        brightness)   echo "module_brightness" ;;
        docker)       echo "module_docker" ;;
        node)         echo "module_node" ;;
        processes)    echo "module_processes" ;;
        weather)      echo "module_weather" ;;
        timezone)     echo "module_timezone" ;;
        sandbox)      echo "module_sandbox" ;;
        version)      echo "module_version" ;;
        update)       echo "module_update" ;;
        *)            echo "" ;;
    esac
}

# =============================================================================
# MODULE EXECUTION
# =============================================================================

run_module() {
    local module_name="$1"
    local current_dir="$2"
    local input_json="$3"

    # Get function name from registry
    local func_name
    func_name=$(get_module_function "$module_name")

    if [ -z "$func_name" ]; then
        log_debug "Unknown module: $module_name"
        return
    fi

    # Check if function exists
    if ! type "$func_name" >/dev/null 2>&1; then
        log_debug "Module function not found: $func_name"
        return
    fi

    # Call the appropriate module function with correct arguments
    case "$module_name" in
        directory)
            "$func_name" "$current_dir"
            ;;
        context|model|cost|rate-limits|version)
            "$func_name" "$input_json"
            ;;
        git|project)
            "$func_name" "$current_dir"
            ;;
        *)
            # Modules that take no arguments or handle their own
            "$func_name"
            ;;
    esac
}

# Check if a module is enabled
# Uses a static lookup instead of eval to avoid code injection
is_module_enabled() {
    local module_name="$1"
    local enabled="false"

    case "$module_name" in
        directory)    enabled="${MODULE_DIRECTORY:-false}" ;;
        context)      enabled="${MODULE_CONTEXT:-false}" ;;
        git)          enabled="${MODULE_GIT:-false}" ;;
        project)      enabled="${MODULE_PROJECT:-false}" ;;
        model)        enabled="${MODULE_MODEL:-false}" ;;
        cost)         enabled="${MODULE_COST:-false}" ;;
        rate-limits)  enabled="${MODULE_RATE_LIMITS:-false}" ;;
        time)         enabled="${MODULE_TIME:-false}" ;;
        battery)      enabled="${MODULE_BATTERY:-false}" ;;
        cpu)          enabled="${MODULE_CPU:-false}" ;;
        memory)       enabled="${MODULE_MEMORY:-false}" ;;
        disk)         enabled="${MODULE_DISK:-false}" ;;
        network)      enabled="${MODULE_NETWORK:-false}" ;;
        uptime)       enabled="${MODULE_UPTIME:-false}" ;;
        load)         enabled="${MODULE_LOAD:-false}" ;;
        temperature)  enabled="${MODULE_TEMPERATURE:-false}" ;;
        brightness)   enabled="${MODULE_BRIGHTNESS:-false}" ;;
        docker)       enabled="${MODULE_DOCKER:-false}" ;;
        node)         enabled="${MODULE_NODE:-false}" ;;
        processes)    enabled="${MODULE_PROCESSES:-false}" ;;
        weather)      enabled="${MODULE_WEATHER:-false}" ;;
        timezone)     enabled="${MODULE_TIMEZONE:-false}" ;;
        sandbox)      enabled="${MODULE_SANDBOX:-false}" ;;
        version)      enabled="${MODULE_VERSION:-false}" ;;
        update)       enabled="${MODULE_UPDATE:-false}" ;;
        *)            enabled="false" ;;
    esac

    [ "$enabled" = "true" ]
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
        func_name=$(get_module_function "$module")
        if [ -z "$func_name" ]; then
            log_debug "Warning: Unknown module in MODULE_ORDER: $module"
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

layout_codepoint_width() {
    local codepoint="$1" low=0 high="${#layout_wide_boundaries[@]}" mid
    if (( codepoint == 0x200D || (codepoint >= 0xFE00 && codepoint <= 0xFE0F) )); then
        printf -v "$2" '%d' 0
        return
    fi

    # An odd insertion index means the code point lies inside a wide range.
    while (( low < high )); do
        mid=$(((low + high) / 2))
        if (( codepoint < layout_wide_boundaries[mid] )); then
            high=$mid
        else
            low=$((mid + 1))
        fi
    done
    printf -v "$2" '%d' "$((1 + low % 2))"
}

# With no limit, return the width. With a limit, return the longest original
# prefix that fits. Use byte offsets so this also works in the C locale.
scan_layout() {
    local LC_ALL=C
    local remaining="$1" destination="$2" limit="${3:--1}"
    local columns=0 consumed=0 size width plain glyph codepoint byte i
    local utf8=$'^([\302-\337][\200-\277]|[\340-\357][\200-\277]{2}|[\360-\364][\200-\277]{3})'
    # CSI (including SGR), OSC, other control strings, and short escapes.
    local ansi=$'^\033(\\[[0-?]*[ -/]*[@-~]|\\][^\033\007]*(\007|\033\\\\)|[PX^_][^\033]*\033\\\\|[ -/]*[0-~])'

    while [ -n "$remaining" ]; do
        plain=${remaining%%[![:print:]]*}
        if [ -n "$plain" ]; then
            # Handle an entire printable ASCII run at once.
            size=${#plain}
            width=$size
            if (( limit >= 0 && columns + width > limit )); then
                consumed=$((consumed + limit - columns))
                break
            fi
        elif [[ "$remaining" == $'\033'* && "$remaining" =~ $ansi ]]; then
            size=${#BASH_REMATCH[0]}
            width=0
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
        else
            size=1
            width=1
            [[ "$remaining" == [[:cntrl:]]* ]] && width=0
        fi
        if (( limit >= 0 && columns + width > limit )); then
            break
        fi
        columns=$((columns + width))
        consumed=$((consumed + size))
        remaining=${remaining:size}
    done

    if (( limit < 0 )); then
        printf -v "$destination" '%d' "$columns"
    else
        printf -v "$destination" '%s' "${1:0:consumed}"
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
    scan_layout "$text" "$2"
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
            projected_len=$((current_len + sep_len + section_len))

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

    # Read input JSON from Claude Code
    local input
    input=$(cat)

    # Extract current directory
    local current_dir
    current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "."' 2>/dev/null)

    # Load per-directory config if it exists
    # This allows project-specific statusline customization
    # Uses safe parser — project configs are untrusted and must not be sourced
    local trusted_theme="${COLOR_THEME:-default}"
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

    # Issue #31 will replace render_os with CORTADO_OS.
    local render_os
    if [[ "${OSTYPE:-}" == darwin* && "${BASH_VERSINFO[5]}" == *-darwin* ]]; then
        render_os=Darwin
    elif [[ "${OSTYPE:-}" == linux* && "${BASH_VERSINFO[5]}" == *-linux* ]]; then
        render_os=Linux
    else
        render_os=$(uname -s 2>/dev/null)
    fi

    # Build status line sections
    local sections=""

    # Process modules in specified order. Split MODULE_ORDER with IFS scoped to
    # the read alone: modules run inside this loop, and a comma IFS here broke
    # every read-based split inside them (each status indicator printed all of
    # its glyphs at once). The array also keeps a "*" in MODULE_ORDER from
    # glob-expanding.
    local modules module
    IFS=',' read -r -a modules <<< "$module_order"
    for module in "${modules[@]}"; do
        remove_render_spaces module

        # Skip empty entries
        [ -z "$module" ] && continue

        # Check if module is enabled
        if is_module_enabled "$module"; then
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
            local output_len
            scan_layout "$output" output_len
            if [ "$output_len" -gt "$available_width" ]; then
                local ellipsis='...'
                if (( available_width < 3 )); then
                    (( available_width >= 0 )) || available_width=0
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
            if [ ! -f "$SCRIPT_DIR/lib/config-tui.sh" ]; then
                echo "cortado: missing lib/config-tui.sh (incomplete install)." >&2
                echo "Re-run ./install.sh from your Cortado checkout." >&2
                exit 1
            fi
            if [ -f "$MODULES_DIR/utils.sh" ]; then
                # shellcheck source=/dev/null
                . "$MODULES_DIR/utils.sh"
            fi
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
