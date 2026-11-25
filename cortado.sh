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

log_module_stderr() {
    local stderr_file="$1" module_name="$2"
    [ "$stderr_file" != /dev/null ] && [ -s "$stderr_file" ] || return 0

    local line diagnostics
    diagnostics=$(
        while IFS= read -r line || [ -n "$line" ]; do
            printf '%s: %s\n' "$module_name" "$line"
        done < "$stderr_file"
    )
    log_debug "$diagnostics"
}

# The fallback helpers are invoked by the sourced modules.
# shellcheck disable=SC2329
load_modules() {
    local stderr_file="$1" module_file module_name

    # Fallbacks for incomplete installations. utils.sh normally defines these.
    log_debug() { :; }
    if [ -f "$MODULES_DIR/utils.sh" ]; then
        # shellcheck source=/dev/null
        . "$MODULES_DIR/utils.sh" 2>"$stderr_file"
        log_module_stderr "$stderr_file" utils
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
        # shellcheck source=/dev/null
        . "$module_file" 2>"$stderr_file"
        log_module_stderr "$stderr_file" "${module_name%.sh}"
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
        context|model|cost|rate-limits)
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

validate_module_order() {
    local order="$1"

    if [ -z "$order" ]; then
        return 0
    fi

    local modules module func_name
    IFS=',' read -r -a modules <<< "$order"
    for module in "${modules[@]}"; do
        module=$(echo "$module" | tr -d ' ')
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

    # Calculate visible separator length (strip ANSI codes)
    local sep_visible
    sep_visible=$(echo "$separator" | sed $'s/\033\[[0-9;]*m//g')
    local sep_len=${#sep_visible}

    # Process each section (newline-separated input)
    while IFS= read -r section || [ -n "$section" ]; do
        [ -z "$section" ] && continue

        # Calculate visible length (strip ANSI codes)
        local section_visible
        section_visible=$(echo "$section" | sed $'s/\033\[[0-9;]*m//g')
        local section_len=${#section_visible}

        if [ -z "$current_line" ]; then
            # First section on this line
            current_line="$section"
        else
            # Calculate what line would look like with this section added
            local current_visible
            current_visible=$(echo "$current_line" | sed $'s/\033\[[0-9;]*m//g')
            local current_len=${#current_visible}
            local projected_len=$((current_len + sep_len + section_len))

            if [ "$projected_len" -le "$max_line_width" ]; then
                # Fits on current line - add with separator
                current_line="${current_line}${separator}${section}"
            else
                # Doesn't fit - output current line and start new one
                if [ -n "$output" ]; then
                    output="${output}"$'\n'"${current_line}"
                else
                    output="$current_line"
                fi
                current_line="$section"
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
    if [ "${DEBUG_MODE:-false}" = "true" ]; then
        module_stderr=$(mktemp "${TMPDIR:-/tmp}/cortado-stderr.XXXXXX" 2>/dev/null) || module_stderr=/dev/null
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
        render_separator=$(echo "$render_separator" | tr -d ' ')
    fi

    # Default module order if not specified
    local DEFAULT_ORDER="sandbox,version,update,directory,context,git,project,model,cost,rate-limits,time,battery"

    # Use custom order if specified, otherwise use default
    local module_order="${MODULE_ORDER:-$DEFAULT_ORDER}"

    # Validate module order
    validate_module_order "$module_order"

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
        # Trim whitespace
        module=$(echo "$module" | tr -d ' ')

        # Skip empty entries
        [ -z "$module" ] && continue

        # Check if module is enabled
        if is_module_enabled "$module"; then
            # Wrap module execution in a subshell with error handling.
            # This prevents a single module crash from killing the entire statusline.
            local output
            output=$(run_module "$module" "$current_dir" "$input" 2>"$module_stderr") || {
                log_debug "Module $module failed with exit code $?"
                output=""
            }
            log_module_stderr "$module_stderr" "$module"

            if [ -n "$output" ]; then
                if [ -n "$sections" ]; then
                    sections="${sections}"$'\n'"${output}"
                else
                    sections="$output"
                fi
            fi
        fi
    done
    if [ "$module_stderr" != /dev/null ]; then
        rm -f -- "$module_stderr" 2>/dev/null
    fi

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
            local visible_output
            visible_output=$(echo "$output" | sed $'s/\033\[[0-9;]*m//g')
            local output_len=${#visible_output}
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
            local visible_output
            visible_output=$(echo "$output" | sed $'s/\033\[[0-9;]*m//g')
            local output_len=${#visible_output}
            if [ "$output_len" -gt "$available_width" ]; then
                local truncate_at=$((available_width - 3))  # Room for "..."
                if [ "$truncate_at" -gt 0 ]; then
                    output="${output:0:$truncate_at}..."
                fi
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
