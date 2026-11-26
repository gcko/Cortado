# shellcheck shell=bash
# Shared by the statusline and installer before sourcing Bash configuration or user modules.

_trusted_config_path() (
    local path="$1" scope="$2" target links=0 metadata
    local file_mode file_owner dir_mode dir_owner
    local mode entry pattern

    local LC_ALL=C

    [[ "$path" = /* ]] || path="$PWD/$path"
    while :; do
        # Resolve directory symlinks with Bash, then follow any file symlink.
        CDPATH='' builtin cd -P -- "${path%/*}/" || return 1
        path="${PWD%/}/${path##*/}"
        [[ -L "$path" ]] || break
        (( links < 40 )) || return 1
        links=$((links + 1))
        # Preserve any trailing newline in the target name.
        target=$(command readlink -n "$path" && printf '.') || return 1
        target="${target%.}"
        if [[ "$target" = /* ]]; then path="$target"
        else path="${PWD%/}/$target"
        fi
    done
    if [[ "$scope" = module-directory ]]; then
        [[ -d "$path" ]] || return 1
    else
        [[ -f "$path" ]] || return 1
    fi

    # OSTYPE can be overridden by the environment or by loaded config.
    case "${BASH_VERSINFO[5]}" in
        *-darwin*)
            # BSD %Lp omits the sticky bit. %p includes it and the file type.
            mode='[0-7]{5,6}'
            metadata=$(command stat -f '%p:%u' "$path" "$PWD") || return 1
            ;;
        *)
            mode='[0-7]{1,4}'
            metadata=$(command stat -c '%a:%u' "$path" "$PWD") || return 1
            ;;
    esac
    entry="($mode):([0-9]+)"
    pattern="^${entry}"$'\n'"${entry}$"
    [[ "$metadata" =~ $pattern ]] || return 1
    file_mode="${BASH_REMATCH[1]}" file_owner="${BASH_REMATCH[2]}"
    dir_mode="${BASH_REMATCH[3]}" dir_owner="${BASH_REMATCH[4]}"

    # A system installation may ship a root-owned packaged config.
    [[ "$file_owner" = "$EUID" || ( "$scope" = packaged && "$file_owner" = 0 ) ]] || return 1
    [[ "$dir_owner" = "$EUID" || "$dir_owner" = 0 ]] || return 1
    (( (8#$file_mode & 022) == 0 )) || return 1
    if [[ "$scope" = module* ]]; then
        (( (8#$dir_mode & 022) == 0 )) || return 1
    else
        (( (8#$dir_mode & 022) == 0 || (8#$dir_mode & 01000) != 0 )) || return 1
    fi
    printf '%s.' "$path"
)

config_refusal_message() {
    printf 'cortado: refusing to source config with unsafe or unknown permissions: %q\n' "$1"
}

# Set REPLY to the checked path so callers source the same target they checked.
check_trusted_config() {
    local checked
    if ! checked=$(_trusted_config_path "$1" "${2:-user}" 2>/dev/null); then
        config_refusal_message "$1" >&2
        return 1
    fi
    REPLY="${checked%.}"
}
