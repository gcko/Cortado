# shellcheck shell=bash
# =============================================================================
# Claude Code's settings.json - the statusLine Cortado writes and its backup
# =============================================================================
# Shared by install.sh and cortado.sh (`cortado setup`, `update`, `uninstall`).
# The statusLine is {type: "command", command: <the @sh-quoted path>}, and the
# statusLine it replaces is kept in .cortado-backup/manifest.json, which
# `./install.sh --uninstall` (and `cortado uninstall`) restores.
# =============================================================================

# statusline_settings_write <dir> <command>
# Set statusLine in <dir>/settings.json, keeping every other key. The new file
# is staged beside it (owner-only), verified, then moved into place, so a
# failure changes nothing. Prints "Created" or "Updated", or why it failed.
statusline_settings_write() (
    local dir="$1" command="$2" settings result="Created" stage_dir staged_settings
    local input=()
    settings="$dir/settings.json"
    if [ -f "$settings" ]; then
        input=("$settings")
        result="Updated"
    elif [ -e "$settings" ] || [ -L "$settings" ]; then
        printf '%s\n' "Could not prepare settings.json: expected a regular file"
        return 1
    fi

    stage_dir=$(mktemp -d "$dir/.settings.XXXXXX") || {
        printf 'Could not stage settings.json in %s\n' "$dir"
        return 1
    }
    trap 'rm -rf "$stage_dir"' EXIT
    umask 077
    staged_settings="$stage_dir/settings.json"

    # With no settings file, jq reads the empty object from stdin.
    if ! jq -s --arg command "$command" '
        if length == 1 and (.[0] | type == "object") then
            .[0] | .statusLine = {type: "command", command: $command}
        else
            error("expected one settings object")
        end
    ' "${input[@]}" <<< '{}' > "$staged_settings" 2>/dev/null; then
        printf '%s\n' "Could not prepare settings.json: expected one readable JSON object"
        return 1
    fi
    if ! jq -es --arg command "$command" '
        length == 1 and (.[0].statusLine == {type: "command", command: $command})
    ' "$staged_settings" >/dev/null 2>&1; then
        printf '%s\n' "Could not verify statusLine in staged settings.json"
        return 1
    fi
    # Use the parent as the destination so mv cannot move inside a settings.json directory.
    if ! mv -f "$staged_settings" "$dir/"; then
        printf 'Could not replace settings.json in %s\n' "$dir"
        return 1
    fi
    printf '%s\n' "$result"
)

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

# statusline_settings_check <settings_file> <command>
# 0: statusLine already runs <command>. 1: it can be written. 2: refuse, with
# the reason in REPLY (not a regular file, or not one JSON object).
statusline_settings_check() {
    local settings="$1"
    REPLY=""
    if [ ! -e "$settings" ] && [ ! -L "$settings" ]; then
        return 1
    fi
    if [ ! -f "$settings" ]; then
        REPLY="$settings is not a regular file"
        return 2
    fi
    if ! jq -es 'length == 1 and (.[0] | type == "object")' "$settings" >/dev/null 2>&1; then
        REPLY="could not read $settings: expected one JSON object"
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

# True when cortado.sh at physical path $1 belongs to a Homebrew install.
cortado_is_homebrew_copy() {
    case "$1" in
        */Cellar/cortado/*|*/opt/cortado/*) return 0 ;;
    esac
    return 1
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

    statusline_settings_check "$settings" "$command" || status=$?
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
    # restore point already exists: the first one is the line from before Cortado.
    backup_dir="$dir/.cortado-backup"
    if [ ! -e "$backup_dir/manifest.json" ] && [ ! -L "$backup_dir/manifest.json" ]; then
        status=0
        manifest=$(statusline_backup_manifest "$settings" "$(date +%Y%m%d_%H%M%S)") || status=$?
        if [ "$status" -eq 0 ]; then
            if ! (umask 077; mkdir -p -- "$backup_dir") 2>/dev/null ||
                ! snapshot=$(umask 077; mktemp -d "$backup_dir/snapshot.XXXXXX" 2>/dev/null) ||
                ! printf '%s\n' "$manifest" > "$snapshot/manifest.json" ||
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

# `cortado update` and `cortado uninstall` run this copy's install.sh, which
# carries the verified release update and the uninstaller.
cortado_installer_main() {
    local action="$1" self arg
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
    if [ "$action" = update ] && { cortado_is_homebrew_copy "$self" || cortado_is_homebrew_copy "$SCRIPT_DIR/"; }; then
        printf 'This copy of Cortado is managed by Homebrew. Update it with: brew upgrade cortado\n' >&2
        return 1
    fi
    if [ ! -f "$SCRIPT_DIR/install.sh" ]; then
        if [ "$action" = update ]; then
            printf 'cortado update: this copy has no install.sh. Run ./install.sh --update from your Cortado clone once; the copy it installs includes install.sh, and cortado update works from then on.\n' >&2
        else
            printf 'cortado uninstall: this copy has no install.sh. Run ./install.sh --uninstall from your Cortado clone instead.\n' >&2
        fi
        return 1
    fi
    exec "${BASH:-bash}" "$SCRIPT_DIR/install.sh" "${args[@]}"
}
