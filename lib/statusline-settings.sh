# shellcheck shell=bash
# =============================================================================
# Claude Code's settings.json - the statusLine Cortado writes and its backup
# =============================================================================
# Shared by install.sh and cortado.sh (`cortado setup`, `update`, `uninstall`).
# The statusLine is {type: "command", command: <the @sh-quoted path>}, and the
# statusLine it replaces is kept in .cortado-backup/manifest.json, which
# `./install.sh --uninstall` (and `cortado uninstall`) restores.
# =============================================================================

# statusline_settings_target <dir>
# Find the file <dir>/settings.json names, following a chain of symbolic
# links, so a linked settings.json (dotfiles) stays a link and its target is
# written in place. 0: REPLY is that regular file. 1: there is none yet, and
# REPLY is the path to create. 2: refuse, with the reason in REPLY.
statusline_settings_target() {
    local path="$1/settings.json" target dir hops=0
    while [ -L "$path" ]; do
        hops=$((hops + 1))
        [ "$hops" -le 40 ] || break
        target=$(readlink "$path") || break
        case "$target" in
            /*) path="$target" ;;
            *)
                dir=$(CDPATH='' cd -P -- "${path%/*}/" 2>/dev/null && pwd) || break
                path="${dir%/}/$target"
                ;;
        esac
    done
    if [ -f "$path" ] && [ ! -L "$path" ]; then
        REPLY="$path"
        return 0
    fi
    if [ "$hops" -gt 0 ]; then
        REPLY="$1/settings.json is a symbolic link that does not lead to a regular file"
        return 2
    fi
    if [ -e "$path" ]; then
        REPLY="$1/settings.json is not a regular file"
        return 2
    fi
    REPLY="$path"
    return 1
}

# statusline_settings_edit <dir> <function> [args...]
# Rewrite <dir>/settings.json (or the file a link there leads to). <function>
# is called as <function> <staged file> <current file, or empty when there is
# none> [args...]; it writes and verifies the staged file, or prints why not
# and fails. The staged file sits beside the
# real one (owner-only) and replaces it with one rename, so a failure changes
# nothing. Prints "Created" or "Updated", or why it failed.
statusline_settings_edit() (
    local dir="$1" edit="$2" target current="" status=0 result="Created" stage_dir staged_settings
    shift 2
    statusline_settings_target "$dir" || status=$?
    case "$status" in
        0) target="$REPLY"; result="Updated" ;;
        1) target="$REPLY" ;;
        *)
            printf 'Could not prepare settings.json: %s\n' "$REPLY"
            return 1
            ;;
    esac
    [ "$status" -ne 0 ] || current="$target"

    stage_dir=$(mktemp -d "${target%/*}/.settings.XXXXXX") || {
        printf 'Could not stage settings.json in %s\n' "${target%/*}"
        return 1
    }
    trap 'rm -rf "$stage_dir"' EXIT
    umask 077
    staged_settings="$stage_dir/${target##*/}"
    "$edit" "$staged_settings" "$current" "$@" || return 1
    # Use the parent as the destination so mv cannot move inside a directory.
    if ! mv -f "$staged_settings" "${target%/*}/"; then
        printf 'Could not replace settings.json in %s\n' "${target%/*}"
        return 1
    fi
    printf '%s\n' "$result"
)

# Editors for statusline_settings_edit. With no settings file, jq reads the
# empty object from stdin.
_statusline_set_command() {
    local input=()
    [ -z "$2" ] || input=("$2")
    # shellcheck disable=SC2016 # $command is a jq variable.
    if ! jq -s --arg command "$3" '
        if length == 1 and (.[0] | type == "object") then
            .[0] | .statusLine = {type: "command", command: $command}
        else
            error("expected one settings object")
        end
    ' "${input[@]}" <<< '{}' > "$1" 2>/dev/null; then
        printf '%s\n' "Could not prepare settings.json: expected one readable JSON object"
        return 1
    fi
    # shellcheck disable=SC2016
    if ! jq -es --arg command "$3" '
        length == 1 and (.[0].statusLine == {type: "command", command: $command})
    ' "$1" >/dev/null 2>&1; then
        printf '%s\n' "Could not verify statusLine in staged settings.json"
        return 1
    fi
}

_statusline_set_saved() {
    local input=()
    [ -z "$2" ] || input=("$2")
    # shellcheck disable=SC2016 # $saved is a jq variable.
    if ! jq -s --argjson saved "$3" '
        if length == 1 and (.[0] | type == "object") then .[0] | .statusLine = $saved
        else error("expected one settings object") end
    ' "${input[@]}" <<< '{}' > "$1" 2>/dev/null ||
        ! jq -es --argjson saved "$3" 'length == 1 and (.[0].statusLine == $saved)' "$1" >/dev/null 2>&1; then
        printf '%s\n' "Could not prepare settings.json: expected one readable JSON object"
        return 1
    fi
}

_statusline_delete() {
    local input=()
    [ -z "$2" ] || input=("$2")
    if ! jq -s '
        if length == 1 and (.[0] | type == "object") then .[0] | del(.statusLine)
        else error("expected one settings object") end
    ' "${input[@]}" <<< '{}' > "$1" 2>/dev/null ||
        ! jq -es 'length == 1 and (.[0] | has("statusLine") | not)' "$1" >/dev/null 2>&1; then
        printf '%s\n' "Could not prepare settings.json: expected one readable JSON object"
        return 1
    fi
}

# statusline_settings_write <dir> <command>: set statusLine to run <command>,
# keeping every other key.
statusline_settings_write() {
    statusline_settings_edit "$1" _statusline_set_command "$2"
}

# statusline_settings_restore <dir> <statusLine JSON>: put a saved statusLine back.
statusline_settings_restore() {
    statusline_settings_edit "$1" _statusline_set_saved "$2"
}

# statusline_settings_remove <dir>: remove statusLine, keeping every other key.
statusline_settings_remove() {
    statusline_settings_edit "$1" _statusline_delete
}

# statusline_runs_cortado <settings_file>
# True when the file's statusLine command runs a cortado.sh: Cortado's own
# line, which is never the one to restore and the only one uninstall removes.
statusline_runs_cortado() {
    local pattern="(^|[/'\"[:space:]])cortado[.]sh(['\"[:space:]]|\$)"
    # shellcheck disable=SC2016 # $pattern is a jq variable.
    jq -e --arg pattern "$pattern" '.statusLine.command | strings | test($pattern)' "$1" >/dev/null 2>&1
}

# statusline_backup_manifest <settings_file> <timestamp>
# Print the backup manifest the installer keeps, with the statusLine now in
# <settings_file> (null when there is none). Returns 0 when a statusLine was
# recorded, 1 when there was none, and 2 when the manifest could not be built.
statusline_backup_manifest() {
    local settings="$1" statusline_config manifest
    # Keep JSON backslashes literal even when Bash enables xpg_echo.
    manifest="{\"timestamp\": \"$2\", \"files\": [], \"settings_statusline\": null}"
    if [ -f "$settings" ]; then
        statusline_config=$(jq '.statusLine // null' "$settings" 2>/dev/null)
        if [ "$statusline_config" != "null" ] && [ -n "$statusline_config" ]; then
            # shellcheck disable=SC2016 # $config is a jq variable.
            manifest=$(printf '%s\n' "$manifest" | jq --argjson config "$statusline_config" \
                '.settings_statusline = $config' 2>/dev/null) || return 2
            printf '%s\n' "$manifest"
            return 0
        fi
    fi
    printf '%s\n' "$manifest"
    return 1
}

# statusline_settings_check <dir> <command>
# 0: statusLine already runs <command>. 1: it can be written. 2: refuse, with
# the reason in REPLY (not a regular file, a link that leads to none, or not
# one JSON object).
statusline_settings_check() {
    local settings status=0
    statusline_settings_target "$1" || status=$?
    case "$status" in
        0) settings="$REPLY" ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
    REPLY=""
    if ! jq -es 'length == 1 and (.[0] | type == "object")' "$settings" >/dev/null 2>&1; then
        REPLY="could not read $1/settings.json: expected one JSON object"
        return 2
    fi
    # shellcheck disable=SC2016 # $command is a jq variable.
    if jq -es --arg command "$2" '
        .[0].statusLine | type == "object" and .type == "command" and .command == $command
    ' "$settings" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# cortado_stable_script_path <physical path of cortado.sh>
# Set REPLY to the path settings.json should run. A copy in Homebrew's
# versioned Cellar is run through its stable opt link, which survives
# `brew upgrade`; fail (REPLY names the opt path) when that link does not lead
# to this same file.
cortado_stable_script_path() {
    local path="$1" prefix rest
    REPLY="$path"
    case "$path" in
        */Cellar/cortado/*/*) ;;
        *) return 0 ;;
    esac
    prefix="${path%%/Cellar/cortado/*}"
    rest="${path#"$prefix"/Cellar/cortado/}"
    REPLY="$prefix/opt/cortado/${rest#*/}"
    [ "$REPLY" -ef "$path" ]
}

# True when path $1 lies in a Homebrew keg: <prefix>/Cellar/cortado/<version>/,
# or <prefix>/opt/cortado/ where opt/cortado is Homebrew's link into the Cellar.
# A plain /opt/cortado (a manual install) is not Homebrew.
cortado_is_homebrew_copy() {
    local prefix
    case "$1" in
        ?*/Cellar/cortado/?*/*) return 0 ;;
        ?*/opt/cortado/*)
            prefix="${1%%/opt/cortado/*}"
            # readlink prints nothing for a real directory.
            case "$(readlink "$prefix/opt/cortado" 2>/dev/null)" in
                *Cellar/cortado/?*) return 0 ;;
            esac
            ;;
    esac
    return 1
}

# cortado_runtime_config_dir <dir>
# When <dir> is a copy the installer made, <X>/cortado (no .git, no README.md,
# as a clone or release has), set REPLY to <X>, its config directory.
cortado_runtime_config_dir() {
    local dir
    dir=$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd) || return 1
    [ "${dir##*/}" = cortado ] || return 1
    if [ -e "$dir/.git" ] || [ -e "$dir/README.md" ]; then
        return 1
    fi
    REPLY="${dir%/*}"
    REPLY="${REPLY:-/}"
}

# Set REPLY to the physical path of this copy's cortado.sh ($SCRIPT_DIR).
_cortado_self_path() {
    local dir
    dir=$(CDPATH='' cd -P -- "$SCRIPT_DIR" 2>/dev/null && pwd) || return 1
    REPLY="${dir%/}/cortado.sh"
}

# `cortado setup`: point Claude Code's statusLine at this copy.
cortado_setup_main() {
    local self stable command dir settings backup_dir snapshot manifest status=0 message
    if [ "$#" -gt 0 ]; then
        printf 'Usage: cortado setup\n' >&2
        return 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        printf 'cortado setup: jq is required. Nothing was changed.\n' >&2
        return 1
    fi
    if ! _cortado_self_path; then
        printf 'cortado setup: could not find this copy of cortado.sh. Nothing was changed.\n' >&2
        return 1
    fi
    self="$REPLY"
    if ! cortado_stable_script_path "$self"; then
        printf 'cortado setup: this Homebrew copy is not reachable at its stable path %s, so Claude Code would lose it on the next brew upgrade. Run brew reinstall cortado, then run cortado setup again. Nothing was changed.\n' "$REPLY" >&2
        return 1
    fi
    stable="$REPLY"
    # Claude Code runs the command through a shell. Quote its absolute path.
    # shellcheck disable=SC2016 # $path is a jq variable.
    command=$(jq -nr --arg path "$stable" '$path | @sh') || return 1

    dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    case "$dir" in
        /*) ;;
        *) dir="$PWD/$dir" ;;
    esac
    settings="$dir/settings.json"
    if ! (umask 077; mkdir -p -- "$dir") 2>/dev/null; then
        printf 'cortado setup: could not create %s. Nothing was changed.\n' "$dir" >&2
        return 1
    fi

    statusline_settings_check "$dir" "$command" || status=$?
    case "$status" in
        0)
            printf 'Claude Code already runs %s. Nothing changed.\n' "$stable"
            return 0
            ;;
        1) ;;
        *)
            printf 'cortado setup: %s. Nothing was changed.\n' "$REPLY" >&2
            return 1
            ;;
    esac

    # Keep the statusLine this replaces, as the installer does, unless a
    # restore point already exists (the first one is the line from before
    # Cortado) or the line runs a cortado.sh, which is never the one to restore.
    backup_dir="$dir/.cortado-backup"
    if [ ! -e "$backup_dir/manifest.json" ] && [ ! -L "$backup_dir/manifest.json" ] &&
        ! statusline_runs_cortado "$settings"; then
        status=0
        manifest=$(statusline_backup_manifest "$settings" "$(date +%Y%m%d_%H%M%S)") || status=$?
        if [ "$status" -eq 0 ]; then
            if ! (umask 077; mkdir -p -- "$backup_dir") 2>/dev/null ||
                ! snapshot=$(umask 077; mktemp -d "$backup_dir/snapshot.XXXXXX" 2>/dev/null) ||
                ! (umask 077; printf '%s\n' "$manifest" > "$snapshot/manifest.json") ||
                ! mv -f -- "$snapshot/manifest.json" "$backup_dir/"; then
                [ -z "${snapshot:-}" ] || rm -rf -- "$snapshot"
                printf 'cortado setup: could not back up the current statusLine in %s. Nothing was changed.\n' "$backup_dir" >&2
                return 1
            fi
            rmdir -- "$snapshot" 2>/dev/null
            printf 'Backed up the previous statusLine. cortado uninstall restores it.\n'
        elif [ "$status" -ne 1 ]; then
            printf 'cortado setup: could not back up the current statusLine. Nothing was changed.\n' >&2
            return 1
        fi
    fi

    if ! message=$(statusline_settings_write "$dir" "$command"); then
        printf 'cortado setup: %s\n' "$message" >&2
        return 1
    fi
    printf '%s %s\n' "$message" "$settings"
    printf 'Claude Code now runs %s. Restart Claude Code to see it.\n' "$stable"
}

# Set REPLY to the config directory `cortado` acts on outside an installed
# copy: CLAUDE_CONFIG_DIR as the environment gave it, else ~/.claude.
_cortado_env_config_dir() {
    REPLY="${CORTADO_ENV_CONFIG_DIR:-$HOME/.claude}"
    case "$REPLY" in
        /*) ;;
        *) REPLY="$PWD/$REPLY" ;;
    esac
}

# `cortado uninstall` from Homebrew: Homebrew owns the files, so delete none.
# Put back the statusLine saved before Cortado, or remove Cortado's own, and
# leave a statusLine that does not run Cortado as it is.
_cortado_homebrew_uninstall() {
    local dir settings saved="null" message
    if ! command -v jq >/dev/null 2>&1; then
        printf 'cortado uninstall: jq is required. Nothing was changed.\n' >&2
        return 1
    fi
    _cortado_env_config_dir
    dir="$REPLY"
    settings="$dir/settings.json"
    if ! jq -e 'has("statusLine")' "$settings" >/dev/null 2>&1; then
        printf 'Claude Code has no statusLine in %s. Nothing to restore.\n' "$settings"
    elif ! statusline_runs_cortado "$settings"; then
        printf 'Left statusLine in %s as it is: it does not run Cortado.\n' "$settings"
    else
        if [ -f "$dir/.cortado-backup/manifest.json" ]; then
            saved=$(jq -c '.settings_statusline | objects' "$dir/.cortado-backup/manifest.json" 2>/dev/null)
            [ -n "$saved" ] || saved="null"
        fi
        if [ "$saved" != null ]; then
            if ! message=$(statusline_settings_restore "$dir" "$saved"); then
                printf 'cortado uninstall: %s\n' "$message" >&2
                return 1
            fi
            printf 'Restored the previous statusLine in %s.\n' "$settings"
        else
            if ! message=$(statusline_settings_remove "$dir"); then
                printf 'cortado uninstall: %s\n' "$message" >&2
                return 1
            fi
            printf 'Removed Cortado'"'"'s statusLine from %s.\n' "$settings"
        fi
    fi
    printf 'This copy of Cortado is managed by Homebrew. To remove it: brew uninstall cortado\n'
}

# `cortado update` and `cortado uninstall` run this copy's install.sh, which
# carries the verified release update and the uninstaller. An installed copy
# (<X>/cortado) acts on its own config directory <X>, never on another one.
cortado_installer_main() {
    local action="$1" self arg owner env_dir
    local args=("--$1")
    shift
    for arg in "$@"; do
        case "$arg" in
            --no-color|--no-emoji) args+=("$arg") ;;
            *)
                printf 'Usage: cortado %s [--no-color] [--no-emoji]\n' "$action" >&2
                return 2
                ;;
        esac
    done
    self="$SCRIPT_DIR/cortado.sh"
    if _cortado_self_path; then
        self="$REPLY"
    fi
    if cortado_is_homebrew_copy "$self" || cortado_is_homebrew_copy "$SCRIPT_DIR/"; then
        if [ "$action" = update ]; then
            printf 'This copy of Cortado is managed by Homebrew. Update it with: brew upgrade cortado\n' >&2
            return 1
        fi
        _cortado_homebrew_uninstall
        return
    fi
    if [ ! -f "$SCRIPT_DIR/install.sh" ]; then
        if [ "$action" = update ]; then
            printf 'cortado update: this copy has no install.sh. Run ./install.sh --update from your Cortado clone once; the copy it installs includes install.sh, and cortado update works from then on.\n' >&2
        else
            printf 'cortado uninstall: this copy has no install.sh. Run ./install.sh --uninstall from your Cortado clone instead.\n' >&2
        fi
        return 1
    fi
    if cortado_runtime_config_dir "$SCRIPT_DIR"; then
        owner="$REPLY"
        if [ -n "${CORTADO_ENV_CONFIG_DIR:-}" ]; then
            env_dir=$(CDPATH='' cd -P -- "$CORTADO_ENV_CONFIG_DIR" 2>/dev/null && pwd)
            if [ "$env_dir" != "$owner" ]; then
                printf 'cortado %s: this copy is installed in %s, but CLAUDE_CONFIG_DIR is %s. Nothing was changed. Run it with CLAUDE_CONFIG_DIR=%s, or run the cortado installed in %s.\n' \
                    "$action" "$owner" "$CORTADO_ENV_CONFIG_DIR" "$owner" "$CORTADO_ENV_CONFIG_DIR" >&2
                return 1
            fi
        fi
        CLAUDE_CONFIG_DIR="$owner"
        export CLAUDE_CONFIG_DIR
    fi
    exec "${BASH:-bash}" "$SCRIPT_DIR/install.sh" "${args[@]}"
}
