#!/bin/bash
# =============================================================================
# Cortado runtime config TUI (Refs #24)
# =============================================================================
# Sourced by cortado.sh when invoked as: cortado.sh config [options]
# Bash 3.2 compatible. No side effects on source beyond function definitions.
# =============================================================================

# Colors (TTY only)
_cfg_init_colors() {
    if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ] && [ "${USE_COLOR:-true}" != "false" ]; then
        CFG_BOLD=$'\033[1m'
        CFG_DIM=$'\033[2m'
        CFG_CYAN=$'\033[36m'
        CFG_GREEN=$'\033[32m'
        CFG_MAGENTA=$'\033[35m'
        CFG_NC=$'\033[0m'
    else
        CFG_BOLD=""; CFG_DIM=""; CFG_CYAN=""; CFG_GREEN=""; CFG_MAGENTA=""; CFG_NC=""
    fi
}

# Keep the category arrays expected by the menus and writer.
_cfg_init_catalog() {
    local record
    _CFG_CORE_MODULES=()
    _CFG_SYSTEM_MODULES=()
    _CFG_DEV_MODULES=()
    _CFG_EXTRA_MODULES=()
    _CFG_ALL_MODULES=("${_CORTADO_MODULE_CATALOG[@]}")
    for record in "${_CFG_ALL_MODULES[@]}"; do
        case "${record#*:*:}" in
            core:*) _CFG_CORE_MODULES+=("$record") ;;
            system:*) _CFG_SYSTEM_MODULES+=("$record") ;;
            dev:*) _CFG_DEV_MODULES+=("$record") ;;
            extra:*) _CFG_EXTRA_MODULES+=("$record") ;;
        esac
    done
}

_cfg_module_var() {
    # name -> MODULE_NAME (hyphens to underscores, upper)
    echo "MODULE_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')"
}

# A key the global config may set: the same typed allowlist the renderer reads.
_cfg_is_global_key() {
    local REPLY
    config_key_type "$1"
}

# Values that would break KEY="value" or inject when the user config is sourced.
# Allow `|` so SEPARATOR=" | " (the shipped default) can be --set.
# Reject glob chars so MODULE_ORDER=* cannot expand cwd names on toggle.
_cfg_value_is_safe() {
    local val="$1"
    case "$val" in
        *\`*|*\$*|*\;*|*\&*|*\>*|*\<*|*\"*|*\'*|*\\*|*\(*|*\)*|*'*'*|*'?'*|*'['*)
            return 1
            ;;
    esac
    case "$val" in
        *[[:cntrl:]]*) return 1 ;;
    esac
    return 0
}

_cfg_shell_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//\$/\\\$}
    s=${s//\`/\\\`}
    printf '%s' "$s"
}

_cfg_module_enabled() {
    local name="$1" scope="${2:-global}" var val
    if [ "$scope" = "project" ]; then
        is_module_enabled "$name"
        return
    fi
    var=$(_cfg_module_var "$name")
    val="${!var:-false}"
    case "$val" in
        true|TRUE|1|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

_cfg_set_module() {
    local name="$1" state="$2" scope="${3:-global}" var
    var=$(_cfg_module_var "$name")
    if [ "$scope" = "project" ]; then
        _cfg_set_project_value "$var" "$state"
    else
        printf -v "$var" '%s' "$state"
    fi
}

_cfg_toggle_module() {
    local name="$1" scope="${2:-global}" state=true
    if _cfg_module_enabled "$name" "$scope"; then
        state=false
    fi
    _cfg_set_module "$name" "$state" "$scope"
}

_cfg_mod_name() { echo "$1" | cut -d: -f1; }
_cfg_mod_default() { echo "$1" | cut -d: -f2; }
_cfg_mod_desc() { echo "$1" | cut -d: -f4-; }

# Resolve config path to edit (user global by default)
_cfg_resolve_path() {
    local scope="${1:-global}"
    case "$scope" in
        global|user)
            echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cortado.conf"
            ;;
        project|dir|local)
            echo "${PWD}/.cortado.conf"
            ;;
        *)
            echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cortado.conf"
            ;;
    esac
}

# Project settings overlay the same trusted values that the renderer loaded.
_cfg_load_into_shell() {
    local path="$1" REPLY
    local scope="${2:-global}"
    if [ "$scope" = "project" ]; then
        _CFG_PROJECT_SETTINGS=()
        _CFG_PROJECT_ORIGINAL=()
        [ ! -f "$path" ] || load_config_safe "$path" _cfg_load_project_value
    else
        # cortado.sh already reported a packaged refusal at startup. The
        # renderer already read these once; report this load's lines only.
        CONFIG_UNREAD=() CONFIG_UNREAD_RENDER=0
        load_config "$SCRIPT_DIR/cortado.conf" packaged 2>/dev/null
        if [[ -e "$path" || -L "$path" ]]; then
            # The trust check follows a link itself; read exactly what it judged.
            if check_trusted_config "$path" 2>/dev/null; then
                load_checked_config "$REPLY" user "$path"
            else
                _CFG_GLOBAL_CONFIG_REFUSED=true
                # Read literal settings from the file the link resolves to, as
                # the writer edits it; a dangling link has nothing to read.
                if _cfg_resolve_target "$path" && [ -f "$REPLY" ]; then
                    load_config_data "$REPLY" "$path"
                fi
            fi
        fi
        # Start from the order the renderer falls back to, never an empty one.
        MODULE_ORDER="${MODULE_ORDER:-${CORTADO_DEFAULT_MODULE_ORDER:-}}"
        # The global editor fills catalog defaults for missing flags. In project
        # scope, an unset flag has the same meaning as it does in the renderer.
        local mod_def name var def
        for mod_def in "${_CFG_ALL_MODULES[@]}"; do
            name=$(_cfg_mod_name "$mod_def")
            def=$(_cfg_mod_default "$mod_def")
            var=$(_cfg_module_var "$name")
            if [ -z "${!var+x}" ]; then
                printf -v "$var" '%s' "$def"
            fi
        done
    fi
    COLOR_THEME="${COLOR_THEME:-default}"
    SEPARATOR="${SEPARATOR:- | }"
    DISPLAY_MODE="${DISPLAY_MODE:-normal}"
    LAYOUT_MODE="${LAYOUT_MODE:-smart}"
    USE_ICONS="${USE_ICONS:-true}"
    USE_STATUS_INDICATORS="${USE_STATUS_INDICATORS:-true}"
    STATUS_STYLE="${STATUS_STYLE:-emoji}"
    NETWORK_SHOW_WAN="${NETWORK_SHOW_WAN:-false}"
    NETWORK_WAN_REDACT="${NETWORK_WAN_REDACT:-true}"
}

_cfg_load_project_value() {
    # Keep a valid preference on disk even if this invocation inherited the key.
    _CFG_PROJECT_SETTINGS+=("$3")
    _CFG_PROJECT_ORIGINAL+=("$3")
    project_config_assign "$1" "$2"
}

_cfg_set_project_value() {
    local key="$1" val="$2" line
    local settings=()
    project_config_setting_allowed "$key" "$val" || return 1
    project_config_assign "$key" "$val" || return 1
    # Bash 3.2 treats an empty array as unset under nounset.
    for line in "${_CFG_PROJECT_SETTINGS[@]+"${_CFG_PROJECT_SETTINGS[@]}"}"; do
        [ "${line%%=*}" = "$key" ] || settings+=("$line")
    done
    _CFG_PROJECT_SETTINGS=("${settings[@]+"${settings[@]}"}" "$key=\"$val\"")
}

_cfg_rebuild_module_order() {
    local order="" mod_def name
    for mod_def in "${_CFG_ALL_MODULES[@]}"; do
        name=$(_cfg_mod_name "$mod_def")
        if _cfg_module_enabled "$name"; then
            if [ -n "$order" ]; then
                order="${order},${name}"
            else
                order="$name"
            fi
        fi
    done
    MODULE_ORDER="$order"
}

_cfg_order_add() {
    local name="$1"
    case ",${MODULE_ORDER}," in
        *",${name},"*) return 0 ;;
    esac
    if [ -n "${MODULE_ORDER:-}" ]; then
        MODULE_ORDER="${MODULE_ORDER},${name}"
    else
        MODULE_ORDER="$name"
    fi
}

_cfg_order_remove() {
    local name="$1" new="" m old_ifs had_noglob=""
    old_ifs="$IFS"
    case "$-" in *f*) had_noglob=1 ;; esac
    set -f
    IFS=','
    for m in ${MODULE_ORDER:-}; do
        m="${m#"${m%%[![:space:]]*}"}"
        m="${m%"${m##*[![:space:]]}"}"
        [ -z "$m" ] && continue
        [ "$m" = "$name" ] && continue
        if [ -n "$new" ]; then
            new="${new},${m}"
        else
            new="$m"
        fi
    done
    IFS="$old_ifs"
    if [ -n "$had_noglob" ]; then
        set -f
    else
        set +f
    fi
    MODULE_ORDER="$new"
}

_cfg_sync_module_order() {
    local name="$1"
    if _cfg_module_enabled "$name"; then
        _cfg_order_add "$name"
    else
        _cfg_order_remove "$name"
    fi
}

# REPLY is the catalog module whose flag variable is exactly $1.
_cfg_module_name_for_var() {
    local key="$1" mod_def name
    for mod_def in "${_CFG_ALL_MODULES[@]}"; do
        name="${mod_def%%:*}"
        if [ "$(_cfg_module_var "$name")" = "$key" ]; then
            REPLY="$name"
            return 0
        fi
    done
    return 1
}

# Recognize a standalone assignment, retaining its optional export and comment.
# The caller checks the surrounding shell syntax before replacing the line.
_cfg_assignment() {
    local bare='[^[:space:];&|<>()`"'\''\\]'
    local single="'[^']*'" double='"([^"\\]|\\.)*"'
    local ansi="[$]'([^'\\\\]|\\\\.)*'"
    local pattern="^([[:blank:]]*(export[[:blank:]]+)?)([A-Za-z_][A-Za-z0-9_]*)=($bare|\\\\.|$single|$double|$ansi)*([[:blank:]]+(#.*)?)?$"
    [[ "$1" =~ $pattern ]]
}

# True when the next line starts a new command. An unfinished quote or compound
# command fails the first parse. A lone `if` on the next line cannot parse at a
# boundary; it parses when a heredoc body or a line continuation absorbs it.
_cfg_at_shell_boundary() {
    local prefix="$1" separator=$'\n'
    printf '%s' "$prefix" | BASH_ENV='' /bin/bash -n 2>/dev/null || return 1
    case "$prefix" in ''|*$'\n') separator="" ;; esac
    if printf '%s%sif\n' "$prefix" "$separator" | BASH_ENV='' /bin/bash -n 2>/dev/null; then
        return 1
    fi
    return 0
}

_cfg_render_global_conf() {
    local source="$1"
    shift
    local edits=("$@") lines=() locations=() replacements=() later=()
    local prefix="" line newline index=0 i text key ending chosen pattern
    local LC_ALL=C

    if [ -n "$source" ]; then
        while :; do
            newline=$'\n'
            if ! IFS= read -r line; then
                [ -n "$line" ] || break
                newline=""
            fi
            text="${line%$'\r'}"
            chosen=""
            if _cfg_assignment "$text"; then
                key="${BASH_REMATCH[3]}"
                ending="${BASH_REMATCH[7]-}${line#"$text"}$newline"
                for ((i=0; i<${#edits[@]}; i++)); do
                    [ "${edits[i]%%=*}" = "$key" ] || continue
                    # Preserve earlier duplicates and replace the last assignment.
                    if _cfg_at_shell_boundary "$prefix"; then
                        locations[i]="$index"
                        replacements[i]="${BASH_REMATCH[1]}$key=\"$(_cfg_shell_quote "${edits[i]#*=}")\"$ending"
                        unset 'later[i]'
                        chosen="$i"
                    fi
                    break
                done
            fi
            # Any later mention outside a whole-line comment may assign the key
            # again (a conditional, a heredoc), so the edit must come after it.
            if [ "${#locations[@]}" -gt 0 ] && ! [[ "$text" =~ ^[[:blank:]]*(#|$) ]]; then
                for ((i=0; i<${#edits[@]}; i++)); do
                    if [ -n "${locations[i]+x}" ] && [ "$i" != "$chosen" ]; then
                        pattern="(^|[^A-Za-z0-9_])${edits[i]%%=*}="
                        if [[ "$text" =~ $pattern ]]; then
                            later[i]=$((index + 1))
                        fi
                    fi
                done
            fi
            lines[index]="$line$newline"
            prefix="$prefix$line$newline"
            index=$((index + 1))
        done < "$source" || return 1
    fi

    local appended="" location warnings=""
    for ((i=0; i<${#edits[@]}; i++)); do
        key="${edits[i]%%=*}"
        if [ -n "${later[i]+x}" ]; then
            warnings="${warnings}config: $key is also assigned at line ${later[i]}; appended the new value so it takes effect"$'\n'
        elif [ -n "${locations[i]+x}" ]; then
            location="${locations[i]}"
            lines[location]="${replacements[i]}"
            continue
        fi
        appended="$appended$key=\"$(_cfg_shell_quote "${edits[i]#*=}")\""$'\n'
    done
    if [ -n "$appended" ] && ! _cfg_at_shell_boundary "$prefix"; then
        printf '%s\n' 'config: cannot append a setting to incomplete shell syntax' >&2
        return 1
    fi
    printf '%s' "$warnings" >&2
    printf '%s' "${lines[@]+"${lines[@]}"}" || return 1
    if [ -n "$appended" ]; then
        case "$prefix" in ''|*$'\n') ;; *) printf '\n' || return 1 ;; esac
        printf '%s' "$appended" || return 1
    fi
    return 0
}

_cfg_render_project_conf() {
    local source="$1" line original kept
    local header='# Cortado project configuration'
    local number=0
    if [ -n "$source" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            number=$((number + 1))
            [ "$line" != "$header" ] || continue
            kept=false
            for original in "${_CFG_PROJECT_ORIGINAL[@]+"${_CFG_PROJECT_ORIGINAL[@]}"}"; do
                if [ "$line" = "$original" ]; then
                    kept=true
                    break
                fi
            done
            if [ "$kept" = false ]; then
                printf 'config: project save omits or reformats line %s (original in .bak)\n' "$number" >&2
            fi
        done < "$source" || return 1
    fi
    printf '%s\n' "$header" "${_CFG_PROJECT_SETTINGS[@]+"${_CFG_PROJECT_SETTINGS[@]}"}"
}

# Resolve relative links against the link's parent, including links in a chain.
_cfg_resolve_target() {
    local path="$1" link hops=0
    case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
    while [ -L "$path" ]; do
        if [ "$hops" -ge 40 ]; then return 1; fi
        # The marker preserves any trailing newlines in the link's name.
        link=$(readlink "$path" && printf '.') || return 1
        link="${link%$'\n.'}"
        case "$link" in
            /*) path="$link" ;;
            *) path="${path%/*}/$link" ;;
        esac
        hops=$((hops + 1))
    done
    if [ "$hops" -gt 0 ] && [ ! -e "$path" ]; then return 1; fi
    REPLY="$path"
}

_cfg_target_mode() {
    local target="$1" mode
    mode=$(cortado_file_mode "$target") || return 1
    case "$mode" in ''|*[!0-7]*) return 1 ;; esac
    printf '%s' "$mode"
}

_cfg_write_conf() (
    local path="$1" scope="$2"
    shift 2
    local target lock snapshot="" tmp="" status=0

    # A project file comes from an untrusted repository, so never follow its link.
    if [ "$scope" = project ] && [ -L "$path" ]; then
        printf 'config: project config is a symlink; edit its target directly: %s\n' "$path" >&2
        return 1
    fi
    # This function runs in a subshell, so the mask covers a new config
    # directory and the lock without leaking to the caller.
    umask 077
    mkdir -p -- "${path%/*}" || return 1
    if ! _cfg_resolve_target "$path"; then
        printf 'config: could not resolve config destination: %s\n' "$path" >&2
        return 1
    fi
    target="$REPLY"
    # Refuse a directory before its lock would be made inside it.
    if [ -e "$target" ] && [ ! -f "$target" ]; then
        printf 'config: config destination is not a regular file: %s\n' "$target" >&2
        return 1
    fi
    lock="$target.cortado-lock"
    if ! mkdir -- "$lock" 2>/dev/null; then
        if [ -e "$lock" ]; then
            printf 'config: could not lock %s; if no other cortado config is running, remove it: %s\n' "$target" "$lock" >&2
        else
            printf 'config: could not create the edit lock: %s\n' "$lock" >&2
        fi
        return 1
    fi
    trap 'rm -f -- "${tmp:-}" "${snapshot:-}"; rmdir -- "$lock"' EXIT

    _cfg_stage_conf "$target" "$scope" "$@" || status=$?
    # Bash 3.2 can skip a nested EXIT trap when the caller is already in one.
    trap - EXIT
    rm -f -- "$tmp" "$snapshot"
    rmdir -- "$lock"
    # The renderer sources the user config only after the same trust check,
    # which also judges the parent of the file a link resolves to.
    if [ "$status" -eq 0 ] && [ "$scope" != project ] && ! check_trusted_config "$path"; then
        printf 'config: Saved settings are inactive until Cortado can trust %s\n' "$path" >&2
    fi
    return "$status"
)

# snapshot and tmp belong to the locked caller so it can clean up failed saves.
_cfg_stage_conf() {
    local target="$1" scope="$2"
    shift 2
    local dir="${target%/*}" backup="$target.bak" mode=600 ignored
    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
        printf 'config: config destination is not a regular file: %s\n' "$target" >&2
        return 1
    fi
    if [ -f "$target" ]; then
        if [ ! -O "$target" ] || ! mode=$(_cfg_target_mode "$target"); then
            printf 'config: cannot save over a config with unsafe ownership or permissions: %s\n' "$target" >&2
            return 1
        fi
        # Tightening the mode must never make an untrusted user config sourceable.
        # A project file is never sourced, so it is saved owner-only instead.
        if [ "$scope" != project ] && (( (8#$mode & 0022) != 0 )); then
            printf 'config: refusing to save over a group- or world-writable config: %s; review it, then run: chmod go-w %s\n' "$target" "$target" >&2
            return 1
        fi
        printf -v mode '%o' "$((8#$mode & 0700))"
        if [ -L "$backup" ] || { [ -e "$backup" ] && [ ! -f "$backup" ]; }; then
            printf 'config: backup destination is not a regular file: %s\n' "$backup" >&2
            return 1
        fi
        snapshot=$(mktemp "$dir/.cortado-config.XXXXXX") || return 1
        cat -- "$target" >| "$snapshot" || return 1
        if IFS= read -r -d '' ignored < "$snapshot"; then
            printf 'config: cannot preserve a NUL byte in %s\n' "$target" >&2
            return 1
        fi
    fi

    tmp=$(mktemp "$dir/.cortado-config.XXXXXX") || return 1
    if [ "$scope" = project ]; then
        _cfg_render_project_conf "$snapshot" >| "$tmp" || return 1
    else
        _cfg_render_global_conf "$snapshot" "$@" >| "$tmp" || return 1
    fi
    chmod "$mode" "$tmp" || return 1
    if [ -n "$snapshot" ]; then
        mv -f -- "$snapshot" "$backup" || return 1
    fi
    mv -f -- "$tmp" "$target" || return 1
}

_cfg_save_menu() {
    local path="$1" scope="$2" mod_def name var
    local edits=()
    if [ "$scope" = global ]; then
        _cfg_rebuild_module_order
        edits=("COLOR_THEME=$COLOR_THEME" "NETWORK_SHOW_WAN=$NETWORK_SHOW_WAN"
            "NETWORK_WAN_REDACT=$NETWORK_WAN_REDACT" "MODULE_ORDER=$MODULE_ORDER")
        for mod_def in "${_CFG_ALL_MODULES[@]}"; do
            name=$(_cfg_mod_name "$mod_def")
            var=$(_cfg_module_var "$name")
            # The renderer needs true, so legacy yes/on/1 are saved canonically.
            if _cfg_module_enabled "$name"; then
                edits+=("$var=true")
            else
                edits+=("$var=false")
            fi
        done
    fi
    _cfg_write_conf "$path" "$scope" "${edits[@]+"${edits[@]}"}"
}

_cfg_show() {
    local path="$1" scope="$2"
    echo "Config file: $path"
    if [ "$scope" = "global" ] && [ "$_CFG_GLOBAL_CONFIG_REFUSED" = true ]; then
        echo "Saved settings are inactive. The statusline ignores this file."
    elif [[ ! -e "$path" && ! -L "$path" ]]; then
        echo "(file does not exist yet — defaults will be used until saved)"
    fi
    # A refused file is never sourced, opt-in or not.
    if [ "$scope" = "global" ] && [ "${_CORTADO_CONF_ALLOW_BASH:-false}" = true ] &&
        [ "$_CFG_GLOBAL_CONFIG_REFUSED" != true ]; then
        echo "CORTADO_CONF_ALLOW_BASH=1: this file is sourced as Bash."
    fi
    if [ "$scope" = "global" ] && [ "${CONFIG_UNREAD[0]+set}" ]; then
        echo ""
        echo "Not read (config is data; see cortado config --migrate --dry-run):"
        printf '  %s\n' "${CONFIG_UNREAD[@]}"
    fi
    echo ""
    echo "COLOR_THEME=$COLOR_THEME  DISPLAY_MODE=$DISPLAY_MODE  LAYOUT_MODE=$LAYOUT_MODE"
    echo "SEPARATOR=\"$SEPARATOR\"  USE_ICONS=$USE_ICONS  STATUS_STYLE=$STATUS_STYLE"
    if [ "$scope" = "global" ]; then
        echo "NETWORK_SHOW_WAN=$NETWORK_SHOW_WAN  NETWORK_WAN_REDACT=$NETWORK_WAN_REDACT"
    fi
    echo ""
    echo "Modules:"
    local mod_def name state
    for mod_def in "${_CFG_ALL_MODULES[@]}"; do
        name=$(_cfg_mod_name "$mod_def")
        if _cfg_module_enabled "$name" "$scope"; then state="on "; else state="off"; fi
        printf "  [%s] %-14s %s\n" "$state" "$name" "$(_cfg_mod_desc "$mod_def")"
    done
    echo ""
    echo "MODULE_ORDER=$MODULE_ORDER"
}

_cfg_preview_line() {
    # Static sample preview (no network / git) so TUI stays snappy.
    # Icons follow COLOR_THEME the way apply_theme fills unset icon variables.
    local scope="$1" parts="" mod_def name sample label emoji icon theme icons
    theme="${COLOR_THEME:-default}"
    icons="${USE_ICONS:-true}"
    if [ "${USE_EMOJI:-true}" = "false" ]; then
        icons="false"
    fi
    for mod_def in "${_CFG_ALL_MODULES[@]}"; do
        name=$(_cfg_mod_name "$mod_def")
        _cfg_module_enabled "$name" "$scope" || continue
        label=""
        emoji=""
        case "$name" in
            directory) label="project"; emoji="📁" ;;
            context) label="███░░ 42%"; emoji="📊" ;;
            git) label="main"; emoji="🌿" ;;
            project) label="bash"; emoji="⚡" ;;
            model) label="Claude"; emoji="🤖" ;;
            cost) label="\$0.12"; emoji="💰" ;;
            rate-limits) label="5h:20%" ;;
            time) label="12:00"; emoji="🕐" ;;
            battery) label="90%"; emoji="🔋" ;;
            cpu) label="12%"; emoji="CPU" ;;
            memory) label="40%"; emoji="RAM" ;;
            disk) label="55%"; emoji="Disk" ;;
            network) label="lan"; emoji="🌐" ;;
            docker) label="0"; emoji="🐳" ;;
            node) label="22"; emoji="Node" ;;
            weather) label="72°"; emoji="☀️" ;;
            sandbox) label=""; emoji="🔒" ;;
            version) label="v${CORTADO_VERSION:-?}" ;;
            update) label="" ;;
            *) label="$name" ;;
        esac
        icon=""
        if type theme_default_icon >/dev/null 2>&1; then
            icon=$(theme_default_icon "$name")
        fi
        if [ -z "$icon" ] && [ "$theme" = "default" ] && [ "$icons" != "false" ]; then
            icon="$emoji"
        fi
        if [ -n "$icon" ] && [ -n "$label" ]; then
            sample="$icon $label"
        elif [ -n "$icon" ]; then
            sample="$icon"
        else
            sample="$label"
        fi
        [ -z "$sample" ] && continue
        if [ -n "$parts" ]; then
            parts="${parts}${SEPARATOR}${sample}"
        else
            parts="$sample"
        fi
    done
    echo "${parts:-(no modules enabled)}"
}


# ---- Interactive menus -------------------------------------------------------

_cfg_draw_module_menu() {
    local title="$1" current_idx="$2" scope="$3"
    shift 3
    local items=("$@")
    local count=${#items[@]}
    local i=0 name desc state

    if [ "${_CFG_MENU_DRAWN:-false}" = "true" ]; then
        printf "\033[%dA" $((count + 7))
    fi

    printf "\033[K${CFG_BOLD}${CFG_MAGENTA}=== %s ===${CFG_NC}\n" "$title"
    if [ "$scope" = "project" ]; then
        printf "\033[K${CFG_DIM}Space disable · n disable all · Enter next · s save · q quit${CFG_NC}\n"
    else
        printf "\033[K${CFG_DIM}Space toggle · a all · n none · Enter next · s save · q quit${CFG_NC}\n"
    fi
    printf "\033[K${CFG_DIM}Preview: %s${CFG_NC}\n" "$(_cfg_preview_line "$scope")"
    printf "\033[K\n"

    i=0
    for item in "${items[@]}"; do
        name=$(_cfg_mod_name "$item")
        desc=$(_cfg_mod_desc "$item")
        printf "\033[K"
        if [ "$i" -eq "$current_idx" ]; then
            printf "  ${CFG_CYAN}>${CFG_NC} "
        else
            printf "    "
        fi
        if _cfg_module_enabled "$name" "$scope"; then
            printf "${CFG_GREEN}[x]${CFG_NC} "
        else
            printf "${CFG_DIM}[ ]${CFG_NC} "
        fi
        if [ "$i" -eq "$current_idx" ]; then
            printf "${CFG_BOLD}%s${CFG_NC} ${CFG_DIM}%s${CFG_NC}\n" "$name" "$desc"
        else
            printf "%s ${CFG_DIM}%s${CFG_NC}\n" "$name" "$desc"
        fi
        i=$((i + 1))
    done
    printf "\033[K\n"
    _CFG_MENU_DRAWN="true"
}

_cfg_interactive_modules() {
    local title="$1" scope="$2"
    shift 2
    local modules=("$@")
    local count=${#modules[@]}
    [ "$count" -eq 0 ] && return 0

    local current_idx=0
    local name key escape_seq mod_def
    _CFG_MENU_DRAWN="false"
    printf "\033[?25l"
    echo ""
    _cfg_draw_module_menu "$title" "$current_idx" "$scope" "${modules[@]}"

    while true; do
        IFS= read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
            read -rsn2 escape_seq
            case "$escape_seq" in
                '[A'|'OA')
                    if [ "$current_idx" -gt 0 ]; then current_idx=$((current_idx - 1)); else current_idx=$((count - 1)); fi
                    ;;
                '[B'|'OB')
                    if [ "$current_idx" -lt $((count - 1)) ]; then current_idx=$((current_idx + 1)); else current_idx=0; fi
                    ;;
            esac
        elif [[ "$key" == " " ]]; then
            name=$(_cfg_mod_name "${modules[$current_idx]}")
            _cfg_toggle_module "$name" "$scope"
        elif [ "$key" = "a" ] || [ "$key" = "A" ]; then
            for mod_def in "${modules[@]}"; do
                _cfg_set_module "$(_cfg_mod_name "$mod_def")" "true" "$scope"
            done
        elif [ "$key" = "n" ] || [ "$key" = "N" ]; then
            for mod_def in "${modules[@]}"; do
                _cfg_set_module "$(_cfg_mod_name "$mod_def")" "false" "$scope"
            done
        elif [ "$key" = "s" ] || [ "$key" = "S" ]; then
            _CFG_SAVE_REQUESTED=1
            break
        elif [ "$key" = "q" ] || [ "$key" = "Q" ]; then
            _CFG_QUIT_REQUESTED=1
            break
        elif [ "$key" = "" ]; then
            break
        fi
        _cfg_draw_module_menu "$title" "$current_idx" "$scope" "${modules[@]}"
    done
    printf "\033[?25h"
    echo ""
}

_cfg_interactive_choice() {
    local title="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local current_idx=0 drawn="false" key escape_seq label

    printf "\033[?25l"
    echo ""
    while true; do
        if [ "$drawn" = "true" ]; then
            printf "\033[%dA" $((count + 3))
        fi
        printf "\033[K${CFG_BOLD}%s${CFG_NC}\n" "$title"
        printf "\033[K\n"
        local i=0
        for opt in "${options[@]}"; do
            printf "\033[K"
            label="${opt%%|*}"
            if [ "$i" -eq "$current_idx" ]; then
                printf "  ${CFG_CYAN}>${CFG_NC} ${CFG_GREEN}◉${CFG_NC} ${CFG_BOLD}%s${CFG_NC}\n" "$label"
            else
                printf "    ${CFG_DIM}○${CFG_NC} %s\n" "$label"
            fi
            i=$((i + 1))
        done
        printf "\033[K${CFG_DIM}  ↑/↓ Navigate  ⏎ Select${CFG_NC}\n"
        drawn="true"
        IFS= read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
            read -rsn2 escape_seq
            case "$escape_seq" in
                '[A'|'OA') if [ "$current_idx" -gt 0 ]; then current_idx=$((current_idx - 1)); else current_idx=$((count - 1)); fi ;;
                '[B'|'OB') if [ "$current_idx" -lt $((count - 1)) ]; then current_idx=$((current_idx + 1)); else current_idx=0; fi ;;
            esac
        elif [ "$key" = "" ]; then
            break
        fi
    done
    printf "\033[?25h"
    echo ""
    CFG_CHOICE_RESULT=$current_idx
}

_cfg_run_interactive() {
    local path="$1" scope="$2" mod_group theme
    _CFG_SAVE_REQUESTED=0
    _CFG_QUIT_REQUESTED=0

    echo ""
    printf "%sCortado config%s  %s\n" "$CFG_BOLD" "$CFG_NC" "$path"
    echo "Arrow keys · s save · q cancel without write"
    echo ""

    for mod_group in Core System Dev Extra; do
        case "$mod_group" in
            Core) _cfg_interactive_modules "Core modules" "$scope" "${_CFG_CORE_MODULES[@]}" ;;
            System) _cfg_interactive_modules "System modules" "$scope" "${_CFG_SYSTEM_MODULES[@]}" ;;
            Dev) _cfg_interactive_modules "Dev modules" "$scope" "${_CFG_DEV_MODULES[@]}" ;;
            Extra) _cfg_interactive_modules "Extra modules" "$scope" "${_CFG_EXTRA_MODULES[@]}" ;;
        esac
        [ "$_CFG_QUIT_REQUESTED" = "1" ] && { echo "Cancelled — no changes written."; return 1; }
        [ "$_CFG_SAVE_REQUESTED" = "1" ] && { _cfg_save_menu "$path" "$scope" && echo "Saved $path"; return; }
    done

    if [ "$scope" = "project" ] && project_config_inherited COLOR_THEME; then
        echo "Color theme is read-only (set in the startup environment)."
    else
        _cfg_interactive_choice "Color theme" \
            "default|Standard emoji" \
            "monochrome|ASCII labels and indicators"
        case "${CFG_CHOICE_RESULT:-0}" in
            0) theme="default" ;;
            1) theme="monochrome" ;;
        esac
        if [ "$scope" = "project" ]; then
            if ! _cfg_set_project_value COLOR_THEME "$theme"; then
                echo "config: could not set the project color theme" >&2
                return 2
            fi
        else
            COLOR_THEME="$theme"
        fi
    fi

    if [ "$scope" = "global" ]; then
        _cfg_interactive_choice "WAN IP (privacy)" \
            "off|Do not fetch WAN IP (recommended)" \
            "redacted|Fetch but redact" \
            "show|Show full WAN IP"
        case "${CFG_CHOICE_RESULT:-0}" in
            0) NETWORK_SHOW_WAN="false"; NETWORK_WAN_REDACT="true" ;;
            1) NETWORK_SHOW_WAN="true"; NETWORK_WAN_REDACT="true" ;;
            2) NETWORK_SHOW_WAN="true"; NETWORK_WAN_REDACT="false" ;;
        esac
    fi

    echo ""
    printf "Preview: %s\n" "$(_cfg_preview_line "$scope")"
    echo ""
    printf "Save to %s? [Y/n] " "$path"
    local confirm
    read -r confirm
    case "$confirm" in
        n|N|no|NO)
            echo "Cancelled — no changes written."
            return 1
            ;;
    esac
    if _cfg_save_menu "$path" "$scope"; then
        echo "Saved $path"
        echo "Restart Claude Code (or re-render statusline) to apply."
        return 0
    fi
    echo "Failed to write $path" >&2
    return 1
}

# List the lines the data parser cannot read, with their numbers. Read only:
# the file is opened as data and never written, locked or sourced.
_cfg_migrate_dry_run() {
    local path="$1" scope="$2" policy=trusted_config_setting_allowed
    local _CFG_MIGRATE_LINES=()
    [ "$scope" = project ] && policy=project_config_setting_allowed
    case "$path" in
        */barista.conf|*/.barista.conf) echo "Config file: $path (pre-rename Barista config, read in place)" ;;
        *) echo "Config file: $path" ;;
    esac
    if [ ! -f "$path" ]; then
        if [[ -e "$path" || -L "$path" ]]; then
            echo "config: not a regular file; nothing was read: $path" >&2
            return 1
        fi
        echo "(file does not exist; no lines to migrate)"
        return 0
    fi
    read_config_kv "$path" "$policy" _cfg_migrate_ignore _cfg_migrate_record
    if [ "${_CFG_MIGRATE_LINES[0]+set}" ]; then
        echo "Lines Cortado does not read (config is data, never run as Bash):"
        printf '  %s\n' "${_CFG_MIGRATE_LINES[@]}"
        echo "Rewrite each as KEY=\"value\", or remove it. Nothing was changed."
    else
        echo "Every line is data; no lines to migrate."
    fi
    return 0
}

_cfg_migrate_ignore() { :; }

_cfg_migrate_record() {
    local REPLY
    config_printable "$3"
    _CFG_MIGRATE_LINES+=("line $1: $2: $REPLY")
}

_cfg_usage() {
    cat <<'EOF'
Usage: cortado config [options]
       cortado.sh config [options]

Post-install TUI and CLI for cortado.conf (does not re-run the installer).

Options:
  (none)              Interactive TUI (modules + theme + WAN privacy)
  --show              Print current config summary
  --list              Alias for --show
  --set KEY=VALUE     Set a single key (MODULE_*, COLOR_THEME, …) and save
  --toggle NAME       Toggle a module on/off by short name (e.g. git, cpu)
  --path              Print resolved config path and exit
  --migrate --dry-run List each line the data-only parser cannot read; change nothing
  --project           Edit display settings and disable modules in ./.cortado.conf
  --global            Edit $CLAUDE_CONFIG_DIR/cortado.conf (default)
  -h, --help          This help

Examples:
  cortado config
  cortado config --show
  cortado config --toggle weather
  cortado config --set COLOR_THEME=minimal
  cortado config --project --set MODULE_CPU=false
EOF
}

# Entry point
cortado_config_main() {
    _cfg_init_colors
    _cfg_init_catalog
    local _CFG_GLOBAL_CONFIG_REFUSED=false
    local scope="global"
    local action="interactive"
    local set_kv="" toggle_name="" dry_run=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --show|--list) action="show"; shift ;;
            --path) action="path"; shift ;;
            --migrate) action="migrate"; shift ;;
            --dry-run) dry_run=true; shift ;;
            --project) scope="project"; shift ;;
            --global) scope="global"; shift ;;
            --set)
                action="set"
                set_kv="${2:-}"
                if [ -z "$set_kv" ]; then echo "config: --set requires KEY=VALUE" >&2; return 2; fi
                shift 2
                ;;
            --toggle)
                action="toggle"
                toggle_name="${2:-}"
                if [ -z "$toggle_name" ]; then echo "config: --toggle requires module name" >&2; return 2; fi
                shift 2
                ;;
            -h|--help|help) _cfg_usage; return 0 ;;
            *)
                echo "config: unknown option: $1" >&2
                _cfg_usage >&2
                return 2
                ;;
        esac
    done

    local path
    path=$(_cfg_resolve_path "$scope")

    if [ "$action" = "path" ]; then
        echo "$path"
        return 0
    fi
    if [ "$action" = "migrate" ] || [ "$dry_run" = true ]; then
        if [ "$action" != "migrate" ] || [ "$dry_run" != true ]; then
            echo "config: only --migrate --dry-run is available; edit the listed lines by hand" >&2
            return 2
        fi
        if [ "$scope" = "project" ] && [ ! -f "$path" ] && [ -f "${PWD}/.barista.conf" ]; then
            path="${PWD}/.barista.conf"
        fi
        # Until the first render copies it, the statusline reads barista.conf.
        # Inspect it in place rather than copying it.
        local legacy="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/barista.conf"
        if [ "$scope" = "global" ] && [[ ! -e "$path" && ! -L "$path" ]] &&
            [[ -e "$legacy" || -L "$legacy" ]]; then
            path="$legacy"
        fi
        _cfg_migrate_dry_run "$path" "$scope"
        return
    fi

    # Pre-rename fallbacks. cortado.sh copies a trusted global barista.conf at
    # startup when it can; otherwise the renderer keeps reading barista.conf,
    # so show and edit that file. A project's legacy settings are loaded, and
    # an edit writes the new name.
    local load_path="$path"
    if [ "$scope" = "global" ] && [[ ! -e "$path" && ! -L "$path" ]] &&
       [[ -e "${path%/*}/barista.conf" || -L "${path%/*}/barista.conf" ]]; then
        path="${path%/*}/barista.conf"
        load_path="$path"
    elif [ "$scope" = "project" ] && [ ! -f "$path" ] && [ -f "${PWD}/.barista.conf" ]; then
        load_path="${PWD}/.barista.conf"
    fi

    _cfg_load_into_shell "$load_path" "$scope"

    case "$action" in
        show)
            _cfg_show "$load_path" "$scope"
            return 0
            ;;
        set)
            local key="${set_kv%%=*}" val="${set_kv#*=}"
            if [ "$key" = "$set_kv" ] || [ -z "$key" ]; then
                echo "config: --set requires KEY=VALUE" >&2
                return 2
            fi
            if [ "$scope" = "global" ] && ! _cfg_is_global_key "$key"; then
                echo "config: unknown or invalid key: $key" >&2
                return 2
            fi
            if ! _cfg_value_is_safe "$val"; then
                echo "config: invalid value characters" >&2
                return 2
            fi
            local REPLY
            if [ "$scope" = "global" ] && config_key_type "$key" &&
                ! config_value_fits_type "$REPLY" "$val" && [ "${key#MODULE_}" = "$key" ]; then
                echo "config: $key expects a $REPLY value" >&2
                return 2
            fi
            case "$key" in
                MODULE_ORDER) ;;
                MODULE_*)
                    case "$val" in
                        true|TRUE|yes|YES|1|on|ON) val=true ;;
                        false|FALSE|no|NO|0|off|OFF) val=false ;;
                        *)
                            echo "config: $key requires a boolean value" >&2
                            return 2
                            ;;
                    esac
                    ;;
            esac
            if [ "$scope" = project ] && ! _cfg_set_project_value "$key" "$val"; then
                echo "config: project config cannot set $key to that value" >&2
                return 2
            fi
            local edits=("$key=$val") old_order="${MODULE_ORDER:-}"
            # The renderer runs only the modules MODULE_ORDER lists, as --toggle keeps.
            if [ "$scope" = global ] && _cfg_module_name_for_var "$key"; then
                printf -v "$key" '%s' "$val"
                _cfg_sync_module_order "$REPLY"
                if [ "$MODULE_ORDER" != "$old_order" ]; then
                    edits+=("MODULE_ORDER=$MODULE_ORDER")
                fi
            fi
            if _cfg_write_conf "$path" "$scope" "${edits[@]}"; then
                echo "Set $key=$val → $path"
                return 0
            fi
            return 1
            ;;
        toggle)
            local found=0 mod_def name var old_order="${MODULE_ORDER:-}"
            local edits=()
            for mod_def in "${_CFG_ALL_MODULES[@]}"; do
                name=$(_cfg_mod_name "$mod_def")
                if [ "$name" = "$toggle_name" ]; then
                    found=1
                    if ! _cfg_toggle_module "$name" "$scope"; then
                        echo "config: could not toggle $name in $scope config" >&2
                        return 2
                    fi
                    if [ "$scope" = "global" ]; then
                        var=$(_cfg_module_var "$name")
                        _cfg_sync_module_order "$name"
                        edits+=("$var=${!var}")
                        if [ "$MODULE_ORDER" != "$old_order" ]; then
                            edits+=("MODULE_ORDER=$MODULE_ORDER")
                        fi
                    fi
                    break
                fi
            done
            if [ "$found" -eq 0 ]; then
                echo "config: unknown module: $toggle_name" >&2
                return 2
            fi
            if _cfg_write_conf "$path" "$scope" "${edits[@]+"${edits[@]}"}"; then
                if _cfg_module_enabled "$toggle_name" "$scope"; then
                    echo "Enabled $toggle_name → $path"
                else
                    echo "Disabled $toggle_name → $path"
                fi
                return 0
            fi
            return 1
            ;;
        interactive)
            if [ ! -t 0 ] || [ ! -t 1 ]; then
                echo "config: interactive TUI requires a TTY. Use --show / --set / --toggle." >&2
                return 2
            fi
            _cfg_run_interactive "$path" "$scope"
            return $?
            ;;
    esac
}
