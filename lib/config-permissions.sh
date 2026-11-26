# shellcheck shell=bash
# Shared by the statusline and installer before sourcing Bash configuration or user modules.

_config_permission_error() {
    printf '%s\n' "$1"
    return 1
}

# Check the immediate physical parent and, when supplied, the resolved file.
# Print a reason on failure so stderr and the renderer's debug log can agree.
_check_config_metadata() {
    local scope="$1"; shift
    local metadata mode entry pattern file_mode file_owner dir_mode dir_owner
    local LC_ALL=C

    # OSTYPE can be overridden by the environment or by loaded config.
    case "${BASH_VERSINFO[5]}" in
        *-darwin*)
            # BSD %Lp omits the sticky bit. %p includes it and the file type.
            mode='[0-7]{5,6}'
            metadata=$(/usr/bin/stat -f '%p:%u' "$@") ||
                { _config_permission_error 'could not read permission metadata'; return; }
            ;;
        *)
            mode='[0-7]{1,4}'
            metadata=$(command stat -c '%a:%u' "$@") ||
                { _config_permission_error 'could not read permission metadata'; return; }
            ;;
    esac
    entry="($mode):([0-9]+)"
    if [ "$#" -eq 2 ]; then
        pattern="^${entry}"$'\n'"${entry}$"
    else
        pattern="^${entry}$"
    fi
    [[ "$metadata" =~ $pattern ]] ||
        { _config_permission_error 'invalid permission metadata'; return; }

    if [ "$#" -eq 2 ]; then
        file_mode="${BASH_REMATCH[1]}" file_owner="${BASH_REMATCH[2]}"
        dir_mode="${BASH_REMATCH[3]}" dir_owner="${BASH_REMATCH[4]}"
        # A system installation may ship a root-owned packaged config.
        if [[ "$file_owner" != "$EUID" && ! ( "$scope" = packaged && "$file_owner" = 0 ) ]]; then
            _config_permission_error 'file has an unexpected owner'
            return
        fi
        (( (8#$file_mode & 022) == 0 )) ||
            { _config_permission_error 'file is group- or world-writable'; return; }
    else
        dir_mode="${BASH_REMATCH[1]}" dir_owner="${BASH_REMATCH[2]}"
    fi
    [[ "$dir_owner" = "$EUID" || "$dir_owner" = 0 ]] ||
        { _config_permission_error 'parent must belong to the current user or root'; return; }
    # The sticky bit protects a shared config's name, but not module code.
    if [[ "$scope" = module* ]]; then
        (( (8#$dir_mode & 022) == 0 )) ||
            { _config_permission_error 'parent is group- or world-writable'; return; }
    else
        (( (8#$dir_mode & 022) == 0 || (8#$dir_mode & 01000) != 0 )) ||
            { _config_permission_error 'parent is group- or world-writable without the sticky bit'; return; }
    fi
}

_trusted_config_path() (
    local path="$1" scope="$2" target links=0
    local LC_ALL=C

    [[ "$path" = /* ]] || path="$PWD/$path"
    while :; do
        if [[ "$path" = */ && "$path" != / ]]; then
            # A trailing slash names a directory, so a file read fails with ENOTDIR.
            [[ "$scope" = module-directory ]] ||
                { _config_permission_error 'target ends in a slash, so it is not a regular file'; return; }
            # Strip it so the path is not its own parent below. Keep "/".
            while [[ "$path" = */ && "$path" != / ]]; do path="${path%/}"; done
        fi
        # Resolve directory symlinks with Bash, then follow any file symlink.
        CDPATH='' builtin cd -P -- "${path%/*}/" ||
            { _config_permission_error 'could not resolve the parent directory'; return; }
        path="${PWD%/}/${path##*/}"
        [[ -L "$path" ]] || break
        (( links < 40 )) ||
            { _config_permission_error 'too many symbolic links'; return; }
        links=$((links + 1))
        # Preserve any trailing newline in the target name.
        target=$(command readlink -n "$path" && printf '.') ||
            { _config_permission_error 'could not read the symbolic link'; return; }
        target="${target%.}"
        if [[ "$target" = /* ]]; then path="$target"
        else path="${PWD%/}/$target"
        fi
    done
    if [[ "$scope" = module-directory ]]; then
        [[ -d "$path" ]] ||
            { _config_permission_error 'target is missing or is not a directory'; return; }
    else
        [[ -f "$path" ]] ||
            { _config_permission_error 'target is missing or is not a regular file'; return; }
    fi
    _check_config_metadata "$scope" "$path" "$PWD" || return 1
    printf '%s.' "$path"
)

# The optional noun names what was refused (default: config).
config_refusal_message() {
    printf 'cortado: refusing to source %s with unsafe or unknown permissions: %q\n' "${2:-config}" "$1"
}

# Set REPLY to the checked path on success, or the diagnostic on failure.
check_trusted_config() {
    local checked
    # Module callers discard this diagnostic, so it always names a config.
    if ! checked=$(_trusted_config_path "$1" "${2:-user}" 2>/dev/null); then
        printf -v REPLY 'cortado: refusing to source config %q: %s' "$1" "$checked"
        printf '%s\n' "$REPLY" >&2
        return 1
    fi
    REPLY="${checked%.}"
}

# A config path that does not stat may lie under a directory Cortado cannot
# search, which hides whether the config exists. Set REPLY to a refusal when the
# nearest ancestor that exists is such a directory. A path whose existing
# ancestors are all searchable simply does not exist.
check_config_searchable() {
    local dir="$1"
    [[ "$dir" = /* ]] || dir="$PWD/$dir"
    while :; do
        dir="${dir%/*}"
        [ -n "$dir" ] || return 0
        [[ -e "$dir" || -L "$dir" ]] || continue
        [[ -d "$dir" && ! -x "$dir" ]] || return 0
        printf -v REPLY 'cortado: refusing to source config %q: %s' "$1" \
            'cannot search the directory that holds it'
        printf '%s\n' "$REPLY" >&2
        return 1
    done
}

# Publish a checked legacy file only into a parent where it will be accepted.
copy_checked_legacy_config() (
    local source="$1" destination="$2" stage filename="${2##*/}"
    CDPATH='' builtin cd -P -- "${destination%/*}/" || return 1
    _check_config_metadata user "$PWD" >/dev/null || return 1

    stage=$(mktemp -d "$PWD/.cortado-migrate.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    cp -p "$source" "$stage/$filename" || return 1
    # Publish without replacing any entry that appeared during the copy.
    # A hard link also preserves a dangling symlink at the destination.
    ln -- "$stage/$filename" "$PWD/"
)
