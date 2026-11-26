#!/bin/bash

# =============================================================================
# Cortado Installer
# =============================================================================
# Installs Cortado - the modular statusline for Claude Code CLI
#
# Usage:
#   ./install.sh                Install with interactive module selection
#   ./install.sh --uninstall    Uninstall and restore previous statusline
#   ./install.sh --force        Install with all defaults (no prompts)
#   ./install.sh --defaults     Install with core modules enabled
#   ./install.sh --no-emoji     Disable emojis in installer and config
#   ./install.sh --no-color     Disable colors in installer output
#   ./install.sh --minimal      Quick install with minimal modules
# =============================================================================

# Do NOT use set -e - we handle errors explicitly

# =============================================================================
# CONFIGURATION FLAGS (can be set via command line or interactively)
# =============================================================================
USE_EMOJI="true"
USE_COLOR="true"
INSTALL_MODE="interactive"
STATUS_STYLE="emoji"
PROGRESS_FILLED="█"
PROGRESS_EMPTY="░"
SEPARATOR_CHAR=" | "
COLOR_THEME="default"
DISPLAY_MODE="normal"
SKIP_UPDATE_CHECK="false"

# =============================================================================
# COLOR DEFINITIONS
# =============================================================================
setup_colors() {
    if [ "$USE_COLOR" = "true" ] && [ -t 1 ]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        CYAN='\033[0;36m'
        MAGENTA='\033[0;35m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        CYAN=''
        MAGENTA=''
        BOLD=''
        DIM=''
        NC=''
    fi
}

# =============================================================================
# PATHS
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Without its libraries the installer cannot compare versions or list modules,
# so stop rather than report a result it never checked.
_installer_lib_missing() {
    printf 'Cortado installer: cannot load %s. Run install.sh from a complete Cortado checkout or release.\n' \
        "$1" >&2
}
# Exits when run, returns when sourced (return fails outside a sourced file).
# The -r test comes first because POSIX mode aborts on "." of a missing file.
# shellcheck source=lib/semver.sh disable=SC2317
{ [ -r "$SCRIPT_DIR/lib/semver.sh" ] && . "$SCRIPT_DIR/lib/semver.sh"; } || {
    _installer_lib_missing "$SCRIPT_DIR/lib/semver.sh"
    return 1 2>/dev/null || exit 1
}
# Exits when run, returns when sourced (return fails outside a sourced file).
# shellcheck source=lib/config-permissions.sh disable=SC2317
{ [ -r "$SCRIPT_DIR/lib/config-permissions.sh" ] && . "$SCRIPT_DIR/lib/config-permissions.sh"; } || {
    _installer_lib_missing "$SCRIPT_DIR/lib/config-permissions.sh"
    return 1 2>/dev/null || exit 1
}
# Exits when run, returns when sourced (return fails outside a sourced file).
# shellcheck source=lib/config-data.sh disable=SC2317
{ [ -r "$SCRIPT_DIR/lib/config-data.sh" ] && . "$SCRIPT_DIR/lib/config-data.sh"; } || {
    _installer_lib_missing "$SCRIPT_DIR/lib/config-data.sh"
    return 1 2>/dev/null || exit 1
}
# Exits when run, returns when sourced (return fails outside a sourced file).
# shellcheck source=lib/module-registry.sh disable=SC2317
{ [ -r "$SCRIPT_DIR/lib/module-registry.sh" ] && . "$SCRIPT_DIR/lib/module-registry.sh"; } || {
    _installer_lib_missing "$SCRIPT_DIR/lib/module-registry.sh"
    return 1 2>/dev/null || exit 1
}

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$CLAUDE_DIR" in
    /*) ;;
    *) CLAUDE_DIR="$PWD/$CLAUDE_DIR" ;;
esac
CORTADO_DIR="$CLAUDE_DIR/cortado"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
BACKUP_DIR="$CLAUDE_DIR/.cortado-backup"
BACKUP_MANIFEST="$BACKUP_DIR/manifest.json"

# Pre-rename paths. Cortado was forked from Barista (https://github.com/pstuart/Barista);
# these are only read during migration and are never deleted by this installer.
LEGACY_DIR="$CLAUDE_DIR/barista"
LEGACY_USER_CONFIG="$CLAUDE_DIR/barista.conf"

# =============================================================================
# VERSION MANAGEMENT
# =============================================================================
GITHUB_REPO="gcko/Cortado"
LOCAL_VERSION=""
REMOTE_VERSION=""
REMOTE_TAG=""

# Homebrew formula pins tagged tarballs; never overwrite Cellar/opt via --update.
_is_homebrew_prefix() {
    local dir="${1:-$SCRIPT_DIR}"
    case "$dir" in
        */Cellar/cortado/*|*/opt/cortado|*/opt/cortado/*)
            return 0
            ;;
    esac
    return 1
}

# Read local version
get_local_version() {
    if [ -f "$SCRIPT_DIR/VERSION" ]; then
        LOCAL_VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
    elif [ -f "$CORTADO_DIR/VERSION" ]; then
        LOCAL_VERSION=$(cat "$CORTADO_DIR/VERSION" | tr -d '[:space:]')
    else
        LOCAL_VERSION="0.0.0"
    fi
    echo "$LOCAL_VERSION"
}

# Latest published GitHub release (same source as modules/update.sh and brew livecheck).
check_remote_version() {
    REMOTE_TAG=""
    REMOTE_VERSION=""
    if ! command -v curl &> /dev/null; then
        return 1
    fi

    local response http_code body
    response=$(curl -q -s --connect-timeout 5 --max-time 8 --max-redirs 3 --proto =https \
        -w "\n%{http_code}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null) || return 1

    http_code=$(printf '%s\n' "$response" | tail -1)
    body=$(printf '%s\n' "$response" | sed '$d')

    if [ "$http_code" != "200" ] || [ -z "$body" ]; then
        return 1
    fi

    local release_pattern='\Av?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?\z'
    REMOTE_TAG=$(printf '%s\n' "$body" | jq -ers --arg pattern "$release_pattern" \
        'select(length == 1) | .[0] | objects | .tag_name | strings | select(test($pattern))' 2>/dev/null) || return 1

    # Compare and display the numeric version, but fetch the exact published tag.
    REMOTE_VERSION="${REMOTE_TAG#v}"
    REMOTE_VERSION="${REMOTE_VERSION%%[-+]*}"
}

# Leading digits of one semver component (safe for bash arithmetic).
# Check for updates: 0 = newer, 1 = no newer release, 2 = could not check.
check_for_updates() {
    local local_ver=$(get_local_version)

    if ! check_remote_version; then
        return 2
    fi

    version_lt "$local_ver" "$REMOTE_VERSION"
}

# Prompt user to update
prompt_update() {
    local local_ver=$(get_local_version)

    echo ""
    print_header "$(emoji '🆕' '[NEW]') Update Available!"
    echo ""
    echo -e "  Current version: ${YELLOW}$local_ver${NC}"
    echo -e "  Latest version:  ${GREEN}$REMOTE_VERSION${NC}"
    echo ""
    echo "  View changes: https://github.com/$GITHUB_REPO/releases"
    echo ""

    read -rp "Would you like to update now? [Y/n]: " update_choice

    if [ "$update_choice" != "n" ] && [ "$update_choice" != "N" ]; then
        do_update "$@"
        return $?
    fi

    return 0
}

# Interactive startup update check - prompts user before checking
interactive_update_check() {
    local local_ver=$(get_local_version)

    echo ""
    read -rp "Check for updates? [Y/n]: " check_choice

    if [ "$check_choice" = "n" ] || [ "$check_choice" = "N" ]; then
        echo ""
        return 0
    fi

    echo ""
    print_info "Checking for updates..."

    if ! check_remote_version; then
        print_warning "Could not check for updates"
        echo ""
        return 0
    fi

    if version_lt "$local_ver" "$REMOTE_VERSION"; then
        echo ""
        echo -e "  ${YELLOW}Installed:${NC} v${local_ver}"
        echo -e "  ${GREEN}Available:${NC} ${REMOTE_TAG} $(emoji '🆕' '[NEW]')"
        echo ""
        echo "  View changes: https://github.com/$GITHUB_REPO/releases"
        echo ""

        read -rp "Update now before installing? [Y/n]: " update_choice

        if [ "$update_choice" != "n" ] && [ "$update_choice" != "N" ]; then
            do_update "$@"
            return $?
        fi
    else
        echo ""
        echo -e "  ${GREEN}Installed:${NC} v${local_ver}"
        echo -e "  ${DIM}Latest:${NC}    ${REMOTE_TAG}"
        print_success "You have the latest version!"
        echo ""
    fi

    return 0
}

# Test seams: tests redefine these to record argv / skip network.
_reexec_installer() {
    exec "$SCRIPT_DIR/install.sh" "$@"
}

_cortado_git() {
    git "$@"
}

_download_release_asset() {
    local tag="$1" asset="$2" dest="$3" status
    curl -q -fsL --connect-timeout 5 --max-time 60 --max-redirs 3 \
        --proto =https --proto-redir =https \
        "https://github.com/$GITHUB_REPO/releases/download/$tag/$asset" -o "$dest" 2>/dev/null
    status=$?
    case "$status" in
        0) return 0 ;;
        28) print_error "Download timed out for $asset." ;;
        *) print_error "Could not download $asset. A verified update requires both release assets." ;;
    esac
    return 1
}

_release_archive_digest() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 < "$1"
    else
        sha256sum < "$1"
    fi
}

_stage_release_archive() {
    local tag="$1" dir="$2" extract_dir="$3"
    local release_version="${tag#v}" archive_name="Cortado-source.zip" expected actual archive_ver

    _download_release_asset "$tag" SHA256SUMS "$dir/SHA256SUMS" || return 1
    if ! expected=$(awk -v archive="$archive_name" '
        $2 == archive || $2 == "*" archive {
            count++
            if (NF == 2 && length($1) == 64 && $1 !~ /[^0-9A-Fa-f]/)
                digest = tolower($1)
        }
        END {
            if (count != 1 || digest == "") exit 1
            print digest
        }
    ' "$dir/SHA256SUMS" 2>/dev/null); then
        print_error "SHA256SUMS must contain one valid checksum for $archive_name."
        return 1
    fi

    _download_release_asset "$tag" "$archive_name" "$dir/$archive_name" || return 1
    if ! actual=$(_release_archive_digest "$dir/$archive_name" 2>/dev/null); then
        print_error "Could not compute SHA-256 for $archive_name. Check that shasum or sha256sum is available."
        return 1
    fi
    if [ "${actual%% *}" != "$expected" ]; then
        print_error "Checksum mismatch for $archive_name. Aborting update."
        return 1
    fi

    if ! unzip -q "$dir/$archive_name" -d "$dir" >/dev/null 2>&1; then
        print_error "Downloaded file is not a valid ZIP archive or could not be extracted. Aborting update."
        return 1
    fi
    if [ ! -f "$extract_dir/cortado.sh" ] || [ ! -f "$extract_dir/VERSION" ]; then
        print_error "Downloaded archive is missing essential files. Aborting update."
        return 1
    fi

    archive_ver=$(tr -d '[:space:]' < "$extract_dir/VERSION")
    if [ "$archive_ver" != "$release_version" ]; then
        print_error "Archive VERSION ($archive_ver) does not match release $release_version."
        return 1
    fi
}

_copy_staged_release() {
    local extract_dir="$1" entry
    # Publish VERSION last so a failed copy can be retried.
    for entry in "$extract_dir/"*; do
        [ "${entry##*/}" != VERSION ] || continue
        cp -R "$entry" "$SCRIPT_DIR/" || return 1
    done
    cp "$extract_dir/VERSION" "$SCRIPT_DIR/"
}

# -----------------------------------------------------------------------------
# Update transaction: every path an update creates is recorded here before any
# file lands in it, so an error or a catchable signal removes it. Globals, so
# the trap handlers can read them from any call depth.
# -----------------------------------------------------------------------------
_UPD_DEPTH=0
_UPD_DEFER=false
_UPD_SIGNAL=""
_UPD_PREV_TRAPS=""
_UPD_PREV_EXIT_CMD=""
_UPD_TMP=""
_UPD_RUNTIME_TMP=""
_UPD_BACKUP=""
_UPD_BACKUP_DONE=false
_UPD_RT_DEST=""
_UPD_RT_STAGE=""
_UPD_RT_PREV=""
_UPD_RT_PUBLISHED=false
_UPD_REFRESHED=false
_UPD_LOCK=""

# Remove a directory tree this update created, including read-only parts.
_update_remove_tree() {
    [ -n "$1" ] || return 0
    [ ! -L "$1" ] || return 1
    chmod -R u+rwX -- "$1" 2>/dev/null
    rm -rf -- "$1"
}

_update_cleanup() {
    if [ -n "$_UPD_RT_PREV" ]; then
        # The old runtime is deleted only once the new one is published or the
        # old one is back in place. Otherwise keep it and say where it is.
        if [ ! -e "$_UPD_RT_PREV/runtime" ] && [ ! -L "$_UPD_RT_PREV/runtime" ]; then
            _update_remove_tree "$_UPD_RT_PREV"
        elif [ "$_UPD_RT_PUBLISHED" = true ]; then
            _update_remove_tree "$_UPD_RT_PREV"
        elif [ ! -e "$_UPD_RT_DEST" ] && [ ! -L "$_UPD_RT_DEST" ] &&
            mv -- "$_UPD_RT_PREV/runtime" "$_UPD_RT_DEST"; then
            _update_remove_tree "$_UPD_RT_PREV"
        else
            print_error "Could not put the previous Cortado runtime back at $_UPD_RT_DEST. It is kept, unchanged, at $_UPD_RT_PREV/runtime; move it back to recover it and its cortado.conf."
        fi
    fi
    _update_remove_tree "$_UPD_RT_STAGE"
    _update_remove_tree "$_UPD_TMP"
    _update_remove_tree "$_UPD_RUNTIME_TMP"
    if [ "$_UPD_BACKUP_DONE" != true ]; then
        _update_remove_tree "$_UPD_BACKUP"
    fi
    _UPD_TMP=""
    _UPD_RUNTIME_TMP=""
    _UPD_BACKUP=""
    _UPD_BACKUP_DONE=false
    _UPD_RT_DEST=""
    _UPD_RT_STAGE=""
    _UPD_RT_PREV=""
    _UPD_RT_PUBLISHED=false
    # Release the lock last, and only while it still names this installer.
    if [ -n "$_UPD_LOCK" ]; then
        if [ "$(readlink "$_UPD_LOCK" 2>/dev/null)" = "$$" ]; then
            rm -f -- "$_UPD_LOCK"
        fi
        _UPD_LOCK=""
    fi
}

# Restore the caller's traps after cleanup.
_update_restore_traps() {
    trap - EXIT HUP INT TERM
    eval "$_UPD_PREV_TRAPS"
    _UPD_DEPTH=0
}

# A second signal during cleanup is held, so cleanup never re-enters itself
# and the first signal sets the exit status.
_update_on_signal() {
    if [ "$_UPD_DEFER" = true ]; then
        _UPD_SIGNAL="$1"
        return
    fi
    _UPD_DEFER=true
    _update_cleanup
    _update_restore_traps
    exit "$1"
}

_update_on_exit() {
    _update_cleanup
    eval "$_UPD_PREV_EXIT_CMD"
}

# Set REPLY to the command in one line of `trap -p` output:
#   trap -- 'command' EXIT
_trap_command() {
    REPLY=""
    [ -n "$1" ] || return 0
    eval "set -- $1"
    REPLY="$3"
}

# Start (or join) an update transaction.
_update_begin() {
    _UPD_DEPTH=$((_UPD_DEPTH + 1))
    [ "$_UPD_DEPTH" -eq 1 ] || return 0
    _UPD_PREV_TRAPS=$(trap -p EXIT HUP INT TERM)
    _trap_command "$(trap -p EXIT)"
    _UPD_PREV_EXIT_CMD="$REPLY"
    _UPD_SIGNAL=""
    _UPD_DEFER=false
    trap '_update_on_exit' EXIT
    trap '_update_on_signal 129' HUP
    trap '_update_on_signal 130' INT
    trap '_update_on_signal 143' TERM
}

# Clean up and hand the traps back once the outermost caller finishes.
_update_end() {
    [ "$_UPD_DEPTH" -gt 0 ] || return 0
    _UPD_DEPTH=$((_UPD_DEPTH - 1))
    [ "$_UPD_DEPTH" -eq 0 ] || return 0
    # Deliver a signal held during the last step, such as the publish rename.
    _update_take_signal
    _update_cleanup
    _update_restore_traps
}

# mktemp -d with signals deferred until the caller has recorded the path.
# Usage: _update_mktemp_dir VAR template
_update_mktemp_dir() {
    local made status=0
    _UPD_DEFER=true
    made=$(mktemp -d "$2") || status=$?
    [ "$status" -ne 0 ] || eval "$1=\$made"
    _UPD_DEFER=false
    return "$status"
}

# Deliver a signal that arrived while an allocation was deferred.
_update_take_signal() {
    local status="$_UPD_SIGNAL"
    [ -n "$status" ] || return 0
    _UPD_SIGNAL=""
    _update_on_signal "$status"
}

# -----------------------------------------------------------------------------
# One runtime update at a time. The lock is a symlink beside the runtime whose
# target is the PID of the installer that holds it, so the lock and its owner
# appear in one step and a SIGKILL never leaves a lock without an owner.
# -----------------------------------------------------------------------------

# Take the update lock in directory $1, or say why not and fail.
_update_lock() {
    local lock="$1/.cortado-update.lock" holder made attempt
    for attempt in 1 2 3; do
        if [ -e "$lock" ] && [ ! -L "$lock" ]; then
            print_error "$lock is not a Cortado update lock. If no update is running, remove it and run the update again."
            return 1
        fi
        made=false
        _UPD_DEFER=true
        if ln -sn -- "$$" "$lock" 2>/dev/null; then
            _UPD_LOCK="$lock"
            made=true
        fi
        _UPD_DEFER=false
        _update_take_signal
        [ "$made" = false ] || return 0
        # Gone already: its holder finished, so try again.
        [ -L "$lock" ] || continue
        # Released since the check above: try again.
        holder=$(readlink "$lock" 2>/dev/null) || continue
        case "$holder" in
            ''|0*|*[!0-9]*)
                print_error "The update lock at $lock does not name an installer process. If no update is running, remove it and run the update again."
                return 1
                ;;
        esac
        if kill -0 "$holder" 2>/dev/null; then
            print_error "Another Cortado update (process $holder) is changing the runtime. Wait for it to finish. If no update is running, remove $lock and run the update again."
            return 1
        fi
        _update_break_stale_lock "$lock" "$holder"
    done
    print_error "Could not take the update lock at $lock."
    return 1
}

# Remove the lock at $1 only while it names the exited installer $2. It is
# renamed aside first, so of two installers breaking it only one removes it,
# and a lock that a running update has taken since is handed back. Signals
# wait until the lock is back, so one never strands it aside.
_update_break_stale_lock() {
    local lock="$1" stale="$2" aside="$1.$$" taken
    _UPD_DEFER=true
    if mv -- "$lock" "$aside" 2>/dev/null; then
        taken=$(readlink "$aside" 2>/dev/null)
        if [ "$taken" != "$stale" ]; then
            ln -sn -- "$taken" "$lock" 2>/dev/null
        fi
        rm -f -- "$aside"
    fi
    _UPD_DEFER=false
    _update_take_signal
}

# With the lock held: when no runtime is at $1, put back the newest runtime an
# interrupted update moved aside, so its cortado.conf and other files carry
# over as usual. Staging and empty leftovers only hold copies and are removed;
# any other moved-aside runtime is kept and named, never deleted.
_update_recover_runtime() {
    local dest="$1" parent="${1%/*}" dir newest=""
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
        for dir in "$parent"/.cortado-previous.*; do
            [ ! -L "$dir" ] && [ -d "$dir/runtime" ] && [ ! -L "$dir/runtime" ] || continue
            if [ -z "$newest" ] || [ "$dir" -nt "$newest" ]; then
                newest="$dir"
            fi
        done
        if [ -n "$newest" ]; then
            if ! mv -- "$newest/runtime" "$dest"; then
                print_error "Could not restore the Cortado runtime that an interrupted update left at $newest/runtime. Move it back to $dest to recover it and its cortado.conf."
                return 1
            fi
            print_warning "Recovered the Cortado runtime and its cortado.conf that an interrupted update left at $newest/runtime."
        fi
    fi
    for dir in "$parent"/.cortado-runtime.*; do
        # _update_remove_tree refuses a symlink.
        [ -d "$dir" ] || continue
        _update_remove_tree "$dir"
    done
    # A SIGKILL while a stale lock was set aside leaves it as
    # .cortado-update.lock.<pid>; remove it once that installer has exited.
    for dir in "$parent"/.cortado-update.lock.*; do
        [ -L "$dir" ] || continue
        case "${dir##*.}" in
            ''|0*|*[!0-9]*) continue ;;
        esac
        kill -0 "${dir##*.}" 2>/dev/null || rm -f -- "$dir"
    done
    for dir in "$parent"/.cortado-previous.*; do
        [ ! -L "$dir" ] && [ -d "$dir" ] || continue
        rmdir -- "$dir" 2>/dev/null && continue
        [ -L "$dir/runtime" ] || [ ! -d "$dir/runtime" ] || dir="$dir/runtime"
        print_warning "An interrupted update left an earlier Cortado runtime at $dir. Cortado does not use it. Copy what you need from it, such as cortado.conf, then remove it."
    done
}

_publish_release_archive() {
    local tag="$1" refresh="${2:-false}" extract_dir rc=1
    _update_begin
    if ! _update_mktemp_dir _UPD_TMP "${TMPDIR:-/tmp}/cortado-update.XXXXXX"; then
        _update_take_signal
        print_error "Could not create a temporary directory for the update."
        _update_end
        return 1
    fi
    _update_take_signal

    extract_dir="$_UPD_TMP/Cortado-${tag#v}"
    if _stage_release_archive "$tag" "$_UPD_TMP" "$extract_dir"; then
        if ! _update_mktemp_dir _UPD_BACKUP "$SCRIPT_DIR.backup.XXXXXX"; then
            _update_take_signal
            print_error "Could not create a source backup in the parent of $SCRIPT_DIR."
        elif _update_take_signal && ! cp -R "$SCRIPT_DIR/." "$_UPD_BACKUP/"; then
            print_error "Could not back up the source to $_UPD_BACKUP."
        else
            _UPD_BACKUP_DONE=true
            if ! _copy_staged_release "$extract_dir"; then
                print_error "Could not copy the release to $SCRIPT_DIR. The source backup is at $_UPD_BACKUP."
                # Keep the completed backup for recovery.
                _UPD_BACKUP=""
            else
                # Mark the backup removable before deleting it, so a signal
                # part-way through removes the rest.
                _UPD_BACKUP_DONE=false
                _update_remove_tree "$_UPD_BACKUP"
                _UPD_BACKUP=""
                rc=0
                # Build the runtime from the verified tree, not the overlaid source.
                if [ "$refresh" = true ] && ! _refresh_managed_runtime "$tag" "$extract_dir"; then
                    rc=1
                fi
            fi
        fi
    fi

    _update_end
    return "$rc"
}

# Stage the exact bytes of release $1 below $2 and set REPLY to the tree.
# A Git checkout reads the tag itself, never its working tree; any other
# source downloads and verifies the published archive.
_stage_release_tree() {
    local tag="$1" dir="$2" tree release_ver
    tree="$dir/Cortado-${tag#v}"
    if [ -d "$SCRIPT_DIR/.git" ]; then
        if ! _cortado_git -C "$SCRIPT_DIR" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null 2>&1; then
            _cortado_git -C "$SCRIPT_DIR" fetch -q origin --tags --force >/dev/null 2>&1
        fi
        if ! { mkdir "$tree" &&
            _cortado_git -C "$SCRIPT_DIR" archive --format=tar -o "$dir/release.tar" "refs/tags/$tag" 2>/dev/null &&
            tar -xf "$dir/release.tar" -C "$tree"; }; then
            print_error "Could not read release $tag from the Git checkout at $SCRIPT_DIR."
            return 1
        fi
        if [ ! -f "$tree/cortado.sh" ] || [ ! -f "$tree/VERSION" ]; then
            print_error "Release $tag is missing essential files."
            return 1
        fi
        release_ver=$(tr -d '[:space:]' < "$tree/VERSION")
        if [ "$release_ver" != "${tag#v}" ]; then
            print_error "Release VERSION ($release_ver) does not match release ${tag#v}."
            return 1
        fi
    else
        _stage_release_archive "$tag" "$dir" "$tree" || return 1
    fi
    REPLY="$tree"
}

# Set REPLY to the runtime directory when settings.json runs exactly this
# installer's managed command; fail for a custom command or no settings.
# Only the config directory is resolved, never the runtime path itself:
# return 2 when that path is a symlink or something other than a directory.
_managed_runtime_dest() {
    local dest parent
    [ -f "$SETTINGS_FILE" ] || return 1
    parent=$(CDPATH='' cd -- "$CLAUDE_DIR" 2>/dev/null && pwd -P) || return 1
    dest="$parent/cortado"
    # shellcheck disable=SC2016 # $path is a jq variable.
    jq -e --arg path "$dest/cortado.sh" --arg configured "$CORTADO_DIR/cortado.sh" '
        .statusLine | select(.type == "command") | .command as $command
        | [$path, $configured, ($path | @sh), ($configured | @sh)] | index($command) != null
    ' "$SETTINGS_FILE" >/dev/null 2>&1 || return 1
    REPLY="$dest"
    if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -d "$dest" ]; }; then
        return 2
    fi
}

# Set REPLY to the mode for the runtime published at $1: its current mode
# without group or other write when it is a directory, else the umask default.
_runtime_mode() {
    local current=""
    if [ -d "$1" ]; then
        current=$(stat -c '%a' "$1" 2>/dev/null) || current=$(stat -f '%Lp' "$1" 2>/dev/null)
    fi
    case "$current" in
        ''|*[!0-7]*) REPLY=$(printf '%o' $(( 8#777 & ~8#$(umask) ))) ;;
        *) REPLY=$(printf '%o' $(( (8#$current & 8#777 & ~8#022) | 8#700 ))) ;;
    esac
}

# Publish release tree $1 (version $3) as the runtime at $2. The new runtime
# is assembled and validated beside $2, then swapped in with two renames; the
# working runtime is moved back if the swap fails or a signal arrives.
_publish_managed_runtime() {
    local tree="$1" dest="$2" version="$3" parent entry staged_version mode status
    parent="${dest%/*}"
    if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -d "$dest" ]; }; then
        print_error "Will not replace $dest: it is not a runtime directory."
        return 1
    fi
    _update_begin
    _UPD_RT_DEST="$dest"
    # Hold the lock before reading or moving anything beside the runtime.
    if ! _update_lock "$parent" || ! _update_recover_runtime "$dest"; then
        _update_end
        return 1
    fi
    if ! _update_mktemp_dir _UPD_RT_STAGE "$parent/.cortado-runtime.XXXXXX" ||
        ! _update_take_signal ||
        ! _update_mktemp_dir _UPD_RT_PREV "$parent/.cortado-previous.XXXXXX" ||
        ! _update_take_signal; then
        _update_take_signal
        print_error "Could not stage a runtime beside $dest."
        _update_end
        return 1
    fi
    if ! copy_runtime_files "$tree" "$_UPD_RT_STAGE"; then
        print_error "Could not copy release ${version} into the staged runtime."
        _update_end
        return 1
    fi
    # Carry over everything the release does not own, such as cortado.conf.
    if [ -d "$dest" ] && { [ ! -r "$dest" ] || [ ! -x "$dest" ]; }; then
        print_error "Could not read the current runtime at $dest, so its files cannot be carried over."
        _update_end
        return 1
    fi
    if [ -d "$dest" ]; then
        for entry in "$dest"/* "$dest"/.[!.]* "$dest"/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            case "${entry##*/}" in
                cortado.sh|VERSION|modules|lib) continue ;;
            esac
            if ! cp -pR "$entry" "$_UPD_RT_STAGE/"; then
                print_error "Could not carry ${entry##*/} over to the staged runtime."
                _update_end
                return 1
            fi
        done
    fi
    staged_version=""
    if [ -f "$_UPD_RT_STAGE/VERSION" ]; then
        staged_version=$(tr -d '[:space:]' < "$_UPD_RT_STAGE/VERSION")
    fi
    _runtime_mode "$dest"
    mode="$REPLY"
    if [ ! -x "$_UPD_RT_STAGE/cortado.sh" ] || [ ! -f "$_UPD_RT_STAGE/lib/config-tui.sh" ] ||
        [ "$staged_version" != "$version" ] ||
        ! chmod "$mode" "$_UPD_RT_STAGE" || ! chmod -R go-w "$_UPD_RT_STAGE"; then
        print_error "The staged runtime for release ${version} is incomplete."
        _update_end
        return 1
    fi
    if [ -e "$dest" ] && ! mv -- "$dest" "$_UPD_RT_PREV/runtime"; then
        print_error "Could not move the current runtime at $dest aside."
        _update_end
        return 1
    fi
    # Record the publish together with the rename, so cleanup never restores
    # over (or deletes the old runtime before) a half-recorded publish.
    _UPD_DEFER=true
    status=0
    mv -- "$_UPD_RT_STAGE" "$dest" || status=$?
    if [ "$status" -eq 0 ]; then
        _UPD_RT_PUBLISHED=true
        _UPD_RT_STAGE=""
    fi
    _UPD_DEFER=false
    if [ "$status" -ne 0 ]; then
        print_error "Could not publish the staged runtime at $dest."
        _update_end
        return 1
    fi
    _update_end
}

# Refresh only the runtime managed by this installer to release $1, from the
# staged release tree $2 when the caller has one. Preserves its config and
# the statusLine command that Claude Code already uses.
_refresh_managed_runtime() {
    local tag="$1" tree="${2:-}" dest source_dir target installed_version="" rc=1 status=0
    _UPD_REFRESHED=false
    _managed_runtime_dest || status=$?
    case "$status" in
        0|2) dest="$REPLY" ;;
        *) return 0 ;;
    esac
    source_dir=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P) || return 1
    if [ "$status" -eq 2 ]; then
        # A link to this source clone or to Homebrew is used in place, as before.
        if [ -L "$dest" ] && target=$(CDPATH='' cd -- "$dest" 2>/dev/null && pwd -P) &&
            { [ "$target" = "$source_dir" ] || _is_homebrew_prefix "$target"; }; then
            return 0
        fi
        if [ -L "$dest" ]; then
            print_error "$CORTADO_DIR is a symbolic link. Cortado will not replace it or what it points to; update that runtime yourself, or remove the link and run ./install.sh."
        else
            print_error "$CORTADO_DIR is not a directory. Cortado will not replace it; move it aside and run ./install.sh."
        fi
        return 1
    fi
    if [ "$source_dir" = "$dest" ] || _is_homebrew_prefix "$dest"; then
        return 0
    fi
    if [ -f "$dest/VERSION" ]; then
        installed_version=$(tr -d '[:space:]' < "$dest/VERSION")
    fi
    # A current runtime is kept only when it holds every library this release
    # ships; the list comes from the release, so new libraries are covered too.
    if [ "$installed_version" = "${tag#v}" ] && [ -f "$dest/cortado.sh" ]; then
        local lib_file runtime_complete=true
        for lib_file in "${tree:-$source_dir}"/lib/*.sh; do
            [ -f "$dest/lib/${lib_file##*/}" ] || { runtime_complete=false; break; }
        done
        [ "$runtime_complete" = true ] && return 0
    fi

    _update_begin
    if [ -z "$tree" ]; then
        if ! _update_mktemp_dir _UPD_RUNTIME_TMP "${TMPDIR:-/tmp}/cortado-update.XXXXXX"; then
            _update_take_signal
            print_error "Could not create a temporary directory for the update."
            _update_end
            return 1
        fi
        _update_take_signal
        if _stage_release_tree "$tag" "$_UPD_RUNTIME_TMP"; then
            tree="$REPLY"
        fi
    fi
    if [ -n "$tree" ]; then
        if _publish_managed_runtime "$tree" "$dest" "${tag#v}"; then
            print_success "Refreshed the installed Cortado runtime at $dest"
            _UPD_REFRESHED=true
            rc=0
        else
            print_error "Could not refresh the installed Cortado runtime at $dest."
        fi
    fi
    _update_end
    return "$rc"
}

# --update and an update accepted from --check-update end with the managed
# runtime on the release. An update accepted before an install does not: the
# restarted installer replaces the runtime itself.
_update_refreshes_runtime() {
    case "$INSTALL_MODE" in
        update|check-update) return 0 ;;
    esac
    return 1
}

# Perform the update from the latest GitHub *release* tag (not unpinned main).
do_update() {
    print_info "Updating Cortado..."

    if _is_homebrew_prefix "$SCRIPT_DIR"; then
        print_error "This install is Homebrew-managed. Use: brew upgrade cortado"
        return 1
    fi

    if [ -z "$REMOTE_TAG" ]; then
        if ! check_remote_version; then
            print_error "Could not resolve the latest GitHub release."
            return 1
        fi
    fi

    local tag="$REMOTE_TAG"

    # Check if we're in a git repo
    if [ -d "$SCRIPT_DIR/.git" ]; then
        print_info "Checking out release $tag..."
        cd "$SCRIPT_DIR" || { print_error "Could not cd to $SCRIPT_DIR"; return 1; }

        _cortado_git stash -q 2>/dev/null
        if _cortado_git fetch origin --tags --force 2>/dev/null \
            && _cortado_git checkout -q "$tag" 2>/dev/null; then
            if _update_refreshes_runtime; then
                _refresh_managed_runtime "$tag" || return 1
            fi
            print_success "Updated to version $REMOTE_VERSION"
            echo ""
            print_info "Restarting installer with new version..."
            echo ""
            _reexec_installer "$@"
        else
            print_error "Could not check out $tag. Try: cd $SCRIPT_DIR && git fetch --tags && git checkout $tag"
            return 1
        fi
    else
        print_info "Downloading release $tag..."
        local refresh=false
        if _update_refreshes_runtime; then
            refresh=true
        fi
        _publish_release_archive "$tag" "$refresh" || return 1

        print_success "Updated to version ${tag#v}"
        echo ""
        print_info "Restarting installer with new version..."
        echo ""

        _reexec_installer "$@"
    fi
}

# =============================================================================
# MODULE DEFINITIONS
# =============================================================================
# The installer lists shipped modules. User modules stay in the config directory
# and can be managed with cortado config after installation.
init_installer_catalog() {
    local record
    discover_module_registry "$SCRIPT_DIR/modules" || return 1
    CORE_MODULES=()
    SYSTEM_MODULES=()
    DEV_MODULES=()
    EXTRA_MODULES=()
    ALL_MODULES=("${_CORTADO_MODULE_CATALOG[@]}")
    for record in "${ALL_MODULES[@]}"; do
        case "${record#*:*:}" in
            core:*) CORE_MODULES+=("$record") ;;
            system:*) SYSTEM_MODULES+=("$record") ;;
            dev:*) DEV_MODULES+=("$record") ;;
            extra:*) EXTRA_MODULES+=("$record") ;;
        esac
    done
}

# Selected modules (array of module names)
declare -a SELECTED_MODULES=()

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Get emoji or text fallback
emoji() {
    if [ "$USE_EMOJI" = "true" ]; then
        echo "$1"
    else
        echo "$2"
    fi
}

# Print functions
print_info() {
    local icon=$(emoji "i" "i")
    echo -e "${BLUE}${icon}${NC} $1"
}

print_success() {
    local icon=$(emoji "$(printf '\xE2\x9C\x93')" "+")
    echo -e "${GREEN}${icon}${NC} $1"
}

print_warning() {
    local icon=$(emoji "!" "!")
    echo -e "${YELLOW}${icon}${NC} $1"
}

print_error() {
    local icon=$(emoji "x" "x")
    echo -e "${RED}${icon}${NC} $1"
}

print_header() {
    echo -e "${BOLD}${CYAN}$1${NC}"
}

get_module_description() { printf '%s\n' "${1#*:*:*:}"; }

# Parse module definition string
get_module_name() { printf '%s\n' "${1%%:*}"; }
get_module_default() {
    local rest="${1#*:}"
    printf '%s\n' "${rest%%:*}"
}
get_module_category() {
    local rest="${1#*:*:}"
    printf '%s\n' "${rest%%:*}"
}

# Check if module is in selected array
is_module_selected() {
    local module="$1"
    for sel in "${SELECTED_MODULES[@]}"; do
        if [ "$sel" = "$module" ]; then
            return 0
        fi
    done
    return 1
}

# Add module to selection
select_module() {
    local module="$1"
    if ! is_module_selected "$module"; then
        SELECTED_MODULES+=("$module")
    fi
}

# Remove module from selection
deselect_module() {
    local module="$1"
    local new_array=()
    for sel in "${SELECTED_MODULES[@]}"; do
        if [ "$sel" != "$module" ]; then
            new_array+=("$sel")
        fi
    done
    SELECTED_MODULES=("${new_array[@]}")
}

# Toggle module selection
toggle_module() {
    local module="$1"
    if is_module_selected "$module"; then
        deselect_module "$module"
        return 1
    else
        select_module "$module"
        return 0
    fi
}

# =============================================================================
# BANNER
# =============================================================================
show_banner() {
    echo ""
    echo -e "${CYAN}"
    cat << 'EOF'
 CCCC  OOO  RRRR  TTTTT   A   DDDD   OOO
C     O   O R   R   T    A A  D   D O   O
C     O   O RRRR    T   AAAAA D   D O   O
C     O   O R  R    T   A   A D   D O   O
 CCCC  OOO  R   R   T   A   A DDDD   OOO
EOF
    echo -e "${NC}"
    local coffee=$(emoji "☕" "")
    local ver=$(get_local_version)
    echo -e "  ${DIM}Serving up fresh stats for Claude Code${NC} $coffee"
    echo -e "  ${DIM}Version: ${NC}${BOLD}v${ver}${NC}"
    echo ""
}

# =============================================================================
# INTERACTIVE CHECKBOX SELECTOR
# =============================================================================
# Uses arrow keys to navigate, space to toggle, enter to confirm

# Draw the checkbox menu
draw_checkbox_menu() {
    local title="$1"
    local description="$2"
    local current_idx="$3"
    shift 3
    local items=("$@")

    local count=${#items[@]}

    # Move cursor up to redraw (count + header lines)
    # Only do this if not first draw
    if [ "$MENU_DRAWN" = "true" ]; then
        printf "\033[%dA" $((count + 5))
    fi

    # Clear lines and draw header
    printf "\033[K"
    printf "${BOLD}${MAGENTA}=== %s ===${NC}\n" "$title"
    if [ -n "$description" ]; then
        printf "\033[K"
        printf "${DIM}%s${NC}\n" "$description"
    fi
    printf "\033[K\n"

    # Draw each item
    local i=0
    for item in "${items[@]}"; do
        printf "\033[K"  # Clear line

        local name=$(echo "$item" | cut -d'|' -f1)
        local desc=$(echo "$item" | cut -d'|' -f2)

        # Cursor indicator
        if [ "$i" -eq "$current_idx" ]; then
            printf "  ${CYAN}>${NC} "
        else
            printf "    "
        fi

        # Checkbox
        if is_module_selected "$name"; then
            printf "${GREEN}[x]${NC} "
        else
            printf "${DIM}[ ]${NC} "
        fi

        # Description (highlighted if current)
        if [ "$i" -eq "$current_idx" ]; then
            printf "${BOLD}%s${NC}\n" "$desc"
        else
            printf "%s\n" "$desc"
        fi

        i=$((i + 1))
    done

    # Instructions
    printf "\033[K\n"
    printf "\033[K"
    printf "${DIM}  ↑/↓ Navigate  ␣ Toggle  a All  n None  ⏎ Done${NC}\n"

    MENU_DRAWN="true"
}

# Interactive checkbox menu
# Returns selected items via SELECTED_MODULES array
interactive_checkbox() {
    local title="$1"
    local description="$2"
    shift 2
    local modules=("$@")

    local count=${#modules[@]}
    if [ "$count" -eq 0 ]; then
        return
    fi

    # Build items array with name|description format
    local items=()
    local module_names=()
    for mod_def in "${modules[@]}"; do
        local name=$(get_module_name "$mod_def")
        local desc=$(get_module_description "$mod_def")
        items+=("${name}|${desc}")
        module_names+=("$name")
    done

    local current_idx=0
    MENU_DRAWN="false"

    # Hide cursor
    printf "\033[?25l"

    # Initial draw
    echo ""
    draw_checkbox_menu "$title" "$description" "$current_idx" "${items[@]}"

    # Read input
    while true; do
        # Read single character
        IFS= read -rsn1 key

        # Handle escape sequences (arrow keys)
        if [[ "$key" == $'\e' ]]; then
            read -rsn2 escape_seq
            case "$escape_seq" in
                '[A'|'OA') # Up arrow
                    if [ "$current_idx" -gt 0 ]; then
                        current_idx=$((current_idx - 1))
                    else
                        current_idx=$((count - 1))  # Wrap to bottom
                    fi
                    ;;
                '[B'|'OB') # Down arrow
                    if [ "$current_idx" -lt $((count - 1)) ]; then
                        current_idx=$((current_idx + 1))
                    else
                        current_idx=0  # Wrap to top
                    fi
                    ;;
            esac
        elif [[ "$key" == " " ]]; then
            # Space - toggle current item
            local name="${module_names[$current_idx]}"
            toggle_module "$name"
        elif [ "$key" = "a" ] || [ "$key" = "A" ]; then
            # Select all
            for name in "${module_names[@]}"; do
                select_module "$name"
            done
        elif [ "$key" = "n" ] || [ "$key" = "N" ]; then
            # Deselect all
            for name in "${module_names[@]}"; do
                deselect_module "$name"
            done
        elif [ "$key" = "" ]; then
            # Enter - done with this category
            break
        elif [ "$key" = "q" ] || [ "$key" = "Q" ]; then
            # Quit selection
            break
        fi

        # Redraw
        draw_checkbox_menu "$title" "$description" "$current_idx" "${items[@]}"
    done

    # Show cursor
    printf "\033[?25h"
    echo ""
}

# Main interactive module selection
interactive_module_selection() {
    local pkg_icon=$(emoji "📦" "[PKG]")
    print_header "$pkg_icon Module Selection"
    echo ""
    echo "Select which modules to include in your statusline."
    echo "Use arrow keys to navigate, space to toggle, Enter when done."
    echo ""

    # Initialize with default selections
    for mod_def in "${ALL_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local default=$(get_module_default "$mod_def")
        if [ "$default" = "true" ]; then
            select_module "$name"
        fi
    done

    # Show current selection summary
    printf "${DIM}Default selection: %d modules${NC}\n" "${#SELECTED_MODULES[@]}"

    # Core modules
    interactive_checkbox "Core Modules" "Claude Code specific modules" "${CORE_MODULES[@]}"

    # System modules
    interactive_checkbox "System Monitoring" "CPU, memory, disk, etc." "${SYSTEM_MODULES[@]}"

    # Dev tools
    interactive_checkbox "Development Tools" "Docker, Node.js, etc." "${DEV_MODULES[@]}"

    # Extra modules
    interactive_checkbox "Extra Modules" "Weather, timezones, etc." "${EXTRA_MODULES[@]}"

    # Final summary
    echo ""
    print_header "Selected Modules (${#SELECTED_MODULES[@]} total)"
    echo ""

    if [ ${#SELECTED_MODULES[@]} -eq 0 ]; then
        print_warning "No modules selected. Using core defaults."
        for mod_def in "${CORE_MODULES[@]}"; do
            select_module "$(get_module_name "$mod_def")"
        done
    fi

    # Display selection grouped by category
    for category in "core" "system" "dev" "extra"; do
        local cat_modules=()
        for mod_def in "${ALL_MODULES[@]}"; do
            local name=$(get_module_name "$mod_def")
            local cat=$(get_module_category "$mod_def")
            if [ "$cat" = "$category" ] && is_module_selected "$name"; then
                cat_modules+=("$name")
            fi
        done

        if [ ${#cat_modules[@]} -gt 0 ]; then
            local cat_label=""
            case "$category" in
                core) cat_label="Core" ;;
                system) cat_label="System" ;;
                dev) cat_label="Dev Tools" ;;
                extra) cat_label="Extra" ;;
            esac
            printf "  ${CYAN}%s:${NC} %s\n" "$cat_label" "${cat_modules[*]}"
        fi
    done
    echo ""
}

# =============================================================================
# MODULE ORDERING
# =============================================================================
interactive_module_ordering() {
    local count=${#SELECTED_MODULES[@]}
    if [ "$count" -le 1 ]; then
        return
    fi

    echo ""
    local ruler_icon=$(emoji "📐" "[ORD]")
    print_header "$ruler_icon Module Order"
    echo ""
    echo "Current order:"

    local i=1
    for module in "${SELECTED_MODULES[@]}"; do
        echo -e "  ${CYAN}$i)${NC} $module"
        i=$((i + 1))
    done
    echo ""

    read -rp "Would you like to reorder the modules? [y/N]: " reorder
    if [ "$reorder" != "y" ] && [ "$reorder" != "Y" ]; then
        return
    fi

    echo ""
    echo "Enter the new order as comma-separated numbers."
    echo "Example: 2,1,3,4 would put module 2 first, then 1, then 3, then 4"
    echo "Or enter 'reverse' to reverse the order"
    echo ""

    read -rp "New order: " order_input

    if [ -z "$order_input" ]; then
        print_info "Keeping current order"
        return
    fi

    # Handle reverse keyword
    if [ "$order_input" = "reverse" ]; then
        local reversed=()
        for ((i=${#SELECTED_MODULES[@]}-1; i>=0; i--)); do
            reversed+=("${SELECTED_MODULES[$i]}")
        done
        SELECTED_MODULES=("${reversed[@]}")
        print_success "Reversed module order"
        return
    fi

    # Parse order
    local order_nums=$(echo "$order_input" | tr ',' ' ')
    local new_order=()
    local valid=true
    local seen=()

    for num in $order_nums; do
        num=$(echo "$num" | tr -d ' ')
        if [ "$num" -ge 1 ] 2>/dev/null && [ "$num" -le "$count" ] 2>/dev/null; then
            # Check for duplicates
            for s in "${seen[@]}"; do
                if [ "$s" = "$num" ]; then
                    print_warning "Duplicate number: $num"
                    valid=false
                    break
                fi
            done
            if [ "$valid" = "true" ]; then
                seen+=("$num")
                local idx=$((num - 1))
                new_order+=("${SELECTED_MODULES[$idx]}")
            fi
        else
            print_warning "Invalid number: $num"
            valid=false
            break
        fi
    done

    if [ "$valid" = "true" ] && [ ${#new_order[@]} -eq $count ]; then
        SELECTED_MODULES=("${new_order[@]}")
        echo ""
        print_success "New order:"
        local j=1
        for module in "${SELECTED_MODULES[@]}"; do
            echo -e "  ${CYAN}$j)${NC} $module"
            j=$((j + 1))
        done
    else
        print_warning "Invalid order input. Keeping current order."
        print_info "Make sure to include all $count module numbers exactly once."
    fi
}

# =============================================================================
# DISPLAY PREFERENCES
# =============================================================================

# Interactive single-choice selector
# Usage: interactive_choice "title" "option1|desc1" "option2|desc2" ...
# Returns: selected index (0-based) in CHOICE_RESULT
interactive_choice() {
    local title="$1"
    shift
    local options=("$@")

    local count=${#options[@]}
    local current_idx=0
    local drawn="false"

    # Hide cursor
    printf "\033[?25l"

    echo ""

    while true; do
        # Move cursor up to redraw
        if [ "$drawn" = "true" ]; then
            printf "\033[%dA" $((count + 3))
        fi

        # Draw title
        printf "\033[K"
        printf "${BOLD}%s${NC}\n" "$title"
        printf "\033[K\n"

        # Draw options
        local i=0
        for opt in "${options[@]}"; do
            printf "\033[K"
            local label=$(echo "$opt" | cut -d'|' -f1)
            local desc=$(echo "$opt" | cut -d'|' -f2)

            if [ "$i" -eq "$current_idx" ]; then
                printf "  ${CYAN}>${NC} ${GREEN}◉${NC} ${BOLD}%s${NC}" "$label"
            else
                printf "    ${DIM}○${NC} %s" "$label"
            fi

            if [ -n "$desc" ]; then
                printf " ${DIM}- %s${NC}" "$desc"
            fi
            printf "\n"

            i=$((i + 1))
        done

        printf "\033[K"
        printf "${DIM}  ↑/↓ Navigate  ⏎ Select${NC}\n"

        drawn="true"

        # Read input
        IFS= read -rsn1 key

        if [[ "$key" == $'\e' ]]; then
            read -rsn2 escape_seq
            case "$escape_seq" in
                '[A'|'OA') # Up
                    if [ "$current_idx" -gt 0 ]; then
                        current_idx=$((current_idx - 1))
                    else
                        current_idx=$((count - 1))
                    fi
                    ;;
                '[B'|'OB') # Down
                    if [ "$current_idx" -lt $((count - 1)) ]; then
                        current_idx=$((current_idx + 1))
                    else
                        current_idx=0
                    fi
                    ;;
            esac
        elif [[ "$key" == "" ]]; then
            # Enter - select
            break
        fi
    done

    # Show cursor
    printf "\033[?25h"
    echo ""

    CHOICE_RESULT=$current_idx
}

interactive_display_preferences() {
    echo ""
    local style_icon=$(emoji "🎨" "[STY]")
    print_header "$style_icon Display Preferences"

    # Icon style
    interactive_choice "Icon Style:" \
        "Emoji icons|📁 myproject | 📊 ████░░ 75% | 🌿 main" \
        "ASCII/Text|DIR: myproject | CTX: #### 75% | GIT: main"

    case "$CHOICE_RESULT" in
        1)
            USE_EMOJI="false"
            print_success "Using ASCII/Text mode"
            ;;
        *)
            USE_EMOJI="true"
            print_success "Using Emoji icons"
            ;;
    esac

    # Status indicator style
    if [ "$USE_EMOJI" = "true" ]; then
        interactive_choice "Status Indicators:" \
            "🟢🟡🔴 Emoji circles" \
            "●●● Colored dots" \
            "[OK][WARN][CRIT] ASCII text"

        case "$CHOICE_RESULT" in
            1) STATUS_STYLE="dots" ;;
            2) STATUS_STYLE="ascii" ;;
            *) STATUS_STYLE="emoji" ;;
        esac
    else
        interactive_choice "Status Indicators:" \
            "[OK][WARN][CRIT] ASCII text" \
            "●●● Dots"

        case "$CHOICE_RESULT" in
            1) STATUS_STYLE="dots" ;;
            *) STATUS_STYLE="ascii" ;;
        esac
    fi
    print_success "Status style: $STATUS_STYLE"

    # Progress bar style
    if [ "$USE_EMOJI" = "true" ]; then
        interactive_choice "Progress Bar Style:" \
            "████░░░░ Blocks" \
            "▓▓▓▓░░░░ Shaded" \
            "●●●●○○○○ Circles" \
            "####---- ASCII"

        case "$CHOICE_RESULT" in
            1) PROGRESS_FILLED="▓"; PROGRESS_EMPTY="░" ;;
            2) PROGRESS_FILLED="●"; PROGRESS_EMPTY="○" ;;
            3) PROGRESS_FILLED="#"; PROGRESS_EMPTY="-" ;;
            *) PROGRESS_FILLED="█"; PROGRESS_EMPTY="░" ;;
        esac
    else
        interactive_choice "Progress Bar Style:" \
            "####---- Hash" \
            "====---- Equals" \
            "****.... Stars"

        case "$CHOICE_RESULT" in
            1) PROGRESS_FILLED="="; PROGRESS_EMPTY="-" ;;
            2) PROGRESS_FILLED="*"; PROGRESS_EMPTY="." ;;
            *) PROGRESS_FILLED="#"; PROGRESS_EMPTY="-" ;;
        esac
    fi
    print_success "Progress bar: ${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_EMPTY}${PROGRESS_EMPTY}"

    # Separator style
    if [ "$USE_EMOJI" = "true" ]; then
        interactive_choice "Separator Style:" \
            " | Pipe (default)" \
            " ║ Double pipe" \
            " › Arrow" \
            " • Bullet"

        case "$CHOICE_RESULT" in
            1) SEPARATOR_CHAR=" ║ " ;;
            2) SEPARATOR_CHAR=" › " ;;
            3) SEPARATOR_CHAR=" • " ;;
            *) SEPARATOR_CHAR=" | " ;;
        esac
    else
        interactive_choice "Separator Style:" \
            " | Pipe (default)" \
            " : Colon" \
            " - Dash" \
            " / Slash"

        case "$CHOICE_RESULT" in
            1) SEPARATOR_CHAR=" : " ;;
            2) SEPARATOR_CHAR=" - " ;;
            3) SEPARATOR_CHAR=" / " ;;
            *) SEPARATOR_CHAR=" | " ;;
        esac
    fi
    print_success "Separator: '$SEPARATOR_CHAR'"

    # Color theme
    interactive_choice "Color Theme:" \
        "Default|Standard emoji (🟢🟡🔴)" \
        "Monochrome|ASCII labels and indicators ([OK] [WARN])"

    case "$CHOICE_RESULT" in
        1) COLOR_THEME="monochrome" ;;
        *) COLOR_THEME="default" ;;
    esac
    print_success "Color theme: $COLOR_THEME"

    # Display mode
    interactive_choice "Display Density:" \
        "Normal|Full information" \
        "Compact|Abbreviated output" \
        "Verbose|Extra details"

    case "$CHOICE_RESULT" in
        1) DISPLAY_MODE="compact" ;;
        2) DISPLAY_MODE="verbose" ;;
        *) DISPLAY_MODE="normal" ;;
    esac
    print_success "Display mode: $DISPLAY_MODE"

    # Show preview
    echo ""
    print_header "$(emoji '👁️ ' '[PRV]') Preview"
    show_statusline_preview
}

# Generate a live preview of the statusline
render_install_preview() (
    local sandbox payload
    sandbox=$(mktemp -d) || return 1
    trap 'rm -rf "$sandbox"' EXIT
    umask 077
    mkdir "$sandbox/myproject" "$sandbox/cortado-cache" || return 1
    generate_config "$sandbox/cortado.conf" || return 1
    payload=$(statusline_test_payload "$sandbox/myproject") || return 1
    # Previews have no credentials. Keep opt-in network probes offline as well.
    # shellcheck disable=SC2329 # The renderer calls the exported function.
    curl() { return 7; }
    export -f curl
    CLAUDE_CONFIG_DIR="$sandbox" CACHE_DIR="$sandbox/cortado-cache" \
        /bin/bash "$SCRIPT_DIR/cortado.sh" <<< "$payload"
)

show_statusline_preview() {
    local preview
    if ! preview=$(render_install_preview); then
        preview="Preview unavailable"
    fi
    printf '\n  %b%s%b\n\n' "$DIM" "$preview" "$NC"
}

# =============================================================================
# CONFIGURATION GENERATION
# =============================================================================
generate_config() (
    local config_file="$1"
    umask 077
    # umask covers a new file; chmod covers one that already existed.
    : >> "$config_file" || return 1
    chmod 600 "$config_file" || return 1

    cat > "$config_file" << 'HEADER' || return 1
# =============================================================================
# Cortado Configuration
# =============================================================================
# Generated by install.sh
# Enable/disable modules by setting to "true" or "false"
# For full configuration options, see cortado.conf in the repo
# =============================================================================

HEADER

    # Write global settings based on installer selections
    echo "# Global Settings" >> "$config_file" || return 1
    if [ "$USE_EMOJI" = "false" ]; then
        echo 'USE_ICONS="false"' >> "$config_file" || return 1
    else
        echo 'USE_ICONS="true"' >> "$config_file" || return 1
    fi

    # Display mode
    echo "DISPLAY_MODE=\"${DISPLAY_MODE:-normal}\"" >> "$config_file" || return 1

    # Status style
    echo "STATUS_STYLE=\"${STATUS_STYLE:-emoji}\"" >> "$config_file" || return 1

    # Progress bar characters
    echo "PROGRESS_BAR_FILLED=\"${PROGRESS_FILLED:-█}\"" >> "$config_file" || return 1
    echo "PROGRESS_BAR_EMPTY=\"${PROGRESS_EMPTY:-░}\"" >> "$config_file" || return 1

    # Separator
    echo "SEPARATOR=\"${SEPARATOR_CHAR:- | }\"" >> "$config_file" || return 1

    # Color theme
    echo "COLOR_THEME=\"${COLOR_THEME:-default}\"" >> "$config_file" || return 1
    echo "" >> "$config_file" || return 1

    # Write module enable/disable settings
    echo "# Module Settings" >> "$config_file" || return 1
    for mod_def in "${ALL_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local var_name="MODULE_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')"
        local enabled="false"

        if is_module_selected "$name"; then
            enabled="true"
        fi

        echo "$var_name=\"$enabled\"" >> "$config_file" || return 1
    done

    # Write module order
    echo "" >> "$config_file" || return 1
    echo "# Module display order (comma-separated)" >> "$config_file" || return 1
    local order_str=""
    for module in "${SELECTED_MODULES[@]}"; do
        if [ -z "$order_str" ]; then
            order_str="$module"
        else
            order_str="$order_str,$module"
        fi
    done
    echo "MODULE_ORDER=\"$order_str\"" >> "$config_file" || return 1

    # Write footer with basic settings
    cat >> "$config_file" << 'FOOTER' || return 1

# =============================================================================
# Display Settings
# =============================================================================

PROGRESS_BAR_WIDTH=8

# =============================================================================
# Advanced Settings
# =============================================================================

# Default cache TTL (seconds) for cache_get() when the caller omits max_age.
# Built-in fallback is also 60 (modules/utils.sh). Only rate-limits and update
# call cache_get, and both pass their own seconds (RATE_CACHE_TTL,
# UPDATE_CHECK_INTERVAL), so no shipped module reads this today. Git uses
# GIT_CACHE_TTL. Weather (WEATHER_CACHE_TTL), network, CPU, load, brightness,
# processes, Docker and Node.js refresh in the background on their own TTLs.
# Digits only; when cache_get uses this value, anything else is a miss.
CACHE_MAX_AGE=60

# Cache files live under CLAUDE_CONFIG_DIR (default: ~/.claude/cortado-cache).
# Set CLAUDE_CONFIG_DIR before running Cortado to move them.

# Enable debug logging
DEBUG_MODE="false"

# =============================================================================
# Per-Directory Overrides
# =============================================================================
# Cortado supports per-directory configuration overrides.
# Create a .cortado.conf file in any project directory to override settings
# for that project only. This is useful for:
#   - Minimal statusline in large monorepos
#   - Different modules for different project types
#   - Disabling slow modules in certain directories
FOOTER
)

# =============================================================================
# VALIDATION
# =============================================================================
validate_config() {
    local config_file="$1" REPLY

    if [[ ! -e "$config_file" && ! -L "$config_file" ]]; then
        return 0
    fi
    check_trusted_config "$config_file" packaged || return 1

    # Read the config as data, as the statusline does; nothing in it runs.
    (
        # shellcheck disable=SC2329 # read_config_kv calls it by name.
        _validate_unread() {
            local REPLY
            config_printable "$3"
            echo "Warning: config line $1 is not read ($2): $REPLY"
        }
        read_config_kv "$REPLY" trusted_config_setting_allowed trusted_config_assign _validate_unread

        # Validate MODULE_ORDER contains valid modules
        if [ -n "$MODULE_ORDER" ]; then
            local order=$(echo "$MODULE_ORDER" | tr ',' ' ')
            for module in $order; do
                module=$(echo "$module" | tr -d ' ')
                local valid=false
                for mod_def in "${ALL_MODULES[@]}"; do
                    if [ "$(get_module_name "$mod_def")" = "$module" ]; then
                        valid=true
                        break
                    fi
                done
                if [ "$valid" = "false" ]; then
                    echo "Warning: Unknown module in MODULE_ORDER: $module"
                fi
            done
        fi

        # Validate threshold values are numeric (no eval — explicit lookups)
        local _thresh_name _thresh_val
        for _thresh_name in CONTEXT_WARNING_THRESHOLD CONTEXT_CRITICAL_THRESHOLD \
                   RATE_WARNING_THRESHOLD RATE_CRITICAL_THRESHOLD \
                   BATTERY_LOW_THRESHOLD BATTERY_CRITICAL_THRESHOLD; do
            case "$_thresh_name" in
                CONTEXT_WARNING_THRESHOLD)  _thresh_val="${CONTEXT_WARNING_THRESHOLD:-}" ;;
                CONTEXT_CRITICAL_THRESHOLD) _thresh_val="${CONTEXT_CRITICAL_THRESHOLD:-}" ;;
                RATE_WARNING_THRESHOLD)     _thresh_val="${RATE_WARNING_THRESHOLD:-}" ;;
                RATE_CRITICAL_THRESHOLD)    _thresh_val="${RATE_CRITICAL_THRESHOLD:-}" ;;
                BATTERY_LOW_THRESHOLD)      _thresh_val="${BATTERY_LOW_THRESHOLD:-}" ;;
                BATTERY_CRITICAL_THRESHOLD) _thresh_val="${BATTERY_CRITICAL_THRESHOLD:-}" ;;
            esac
            if [ -n "$_thresh_val" ] && ! echo "$_thresh_val" | grep -qE '^[0-9]+$'; then
                echo "Warning: $_thresh_name should be a number, got: $_thresh_val"
            fi
        done
    )

    return 0
}

# =============================================================================
# MIGRATION FROM BARISTA
# =============================================================================
# Copy the user's Barista override (barista.conf) to cortado.conf so their settings
# carry over. Never overwrites an existing cortado.conf and leaves the original in
# place. Verify the original before copying it with permissions intact.
# Prints the path it migrated, or nothing when there was nothing to do.
migrate_legacy_user_config() {
    local legacy="${1:-$LEGACY_USER_CONFIG}"
    local target="${2:-$CLAUDE_DIR/cortado.conf}"
    local REPLY
    [[ -e "$legacy" || -L "$legacy" ]] || return 0
    [[ -e "$target" || -L "$target" ]] && return 0
    check_trusted_config "$legacy" || return 1
    if ! copy_checked_legacy_config "$REPLY" "$target"; then
        print_warning "Using legacy config in place at $legacy" >&2
        return 0
    fi
    echo "$target"
}

# =============================================================================
# BACKUP/RESTORE
# =============================================================================
detect_existing_statusline() {
    local existing_command=""
    local existing_files=""

    if [ -f "$SETTINGS_FILE" ]; then
        existing_command=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null)
    fi

    if [ -d "$CORTADO_DIR" ]; then
        existing_files="$CORTADO_DIR (modular)"
    fi
    if [ -f "$CLAUDE_DIR/cortado.sh" ]; then
        if [ -n "$existing_files" ]; then
            existing_files="$existing_files, $CLAUDE_DIR/cortado.sh (single file)"
        else
            existing_files="$CLAUDE_DIR/cortado.sh (single file)"
        fi
    fi

    if [ -n "$existing_command" ] || [ -n "$existing_files" ]; then
        echo "detected"
        echo "$existing_command"
        echo "$existing_files"
    else
        echo "none"
    fi
}

backup_existing_statusline() {
    local snapshot="$1"
    print_info "Backing up existing statusline configuration..."

    local timestamp=$(date +%Y%m%d_%H%M%S)
    # Keep JSON backslashes literal even when Bash enables xpg_echo.
    local manifest="{\"timestamp\": \"$timestamp\", \"files\": [], \"settings_statusline\": null}"

    if [ -f "$SETTINGS_FILE" ]; then
        local statusline_config=$(jq '.statusLine // null' "$SETTINGS_FILE" 2>/dev/null)
        if [ "$statusline_config" != "null" ] && [ -n "$statusline_config" ]; then
            manifest=$(printf '%s\n' "$manifest" | jq --argjson config "$statusline_config" '.settings_statusline = $config' 2>/dev/null) || return 1
            print_success "Backed up statusLine config from settings.json"
        fi
    fi

    if [ -d "$CORTADO_DIR" ]; then
        local backup_modular="$snapshot/cortado"
        cp -r "$CORTADO_DIR" "$backup_modular" || return 1
        manifest=$(printf '%s\n' "$manifest" | jq --arg path "$backup_modular" --arg orig "$CORTADO_DIR" \
            '.files += [{"original": $orig, "backup": $path, "type": "directory"}]' 2>/dev/null) || return 1
        print_success "Backed up Cortado directory"
    fi

    if [ -f "$CLAUDE_DIR/cortado.sh" ]; then
        local backup_single="$snapshot/cortado.sh"
        cp "$CLAUDE_DIR/cortado.sh" "$backup_single" || return 1
        manifest=$(printf '%s\n' "$manifest" | jq --arg path "$backup_single" --arg orig "$CLAUDE_DIR/cortado.sh" \
            '.files += [{"original": $orig, "backup": $path, "type": "file"}]' 2>/dev/null) || return 1
        print_success "Backed up single-file cortado.sh"
    fi

    printf '%s\n' "$manifest" > "$snapshot/manifest.json"
}

restore_from_backup() {
    if [ ! -f "$BACKUP_MANIFEST" ]; then
        print_error "No backup manifest found at $BACKUP_MANIFEST"
        print_info "Cannot restore - no previous statusline was backed up"
        return 1
    fi

    print_info "Restoring previous statusline from backup..."
    echo ""

    local manifest
    manifest=$(cat "$BACKUP_MANIFEST") || {
        print_error "Could not read backup manifest"
        return 1
    }

    local timestamp=$(printf '%s\n' "$manifest" | jq -r '.timestamp // "unknown"')
    print_info "Restoring from backup created at: $timestamp"

    # Restore files
    printf '%s\n' "$manifest" | jq -c '.files[]' 2>/dev/null | while read -r file_info; do
        local original=$(printf '%s\n' "$file_info" | jq -r '.original')
        local backup=$(printf '%s\n' "$file_info" | jq -r '.backup')
        local type=$(printf '%s\n' "$file_info" | jq -r '.type')

        if [ -e "$backup" ]; then
            if [ "$type" = "directory" ]; then
                rm -rf "$original" 2>/dev/null
                cp -r "$backup" "$original" && print_success "Restored: $original"
            else
                rm -f "$original" 2>/dev/null
                cp "$backup" "$original" && print_success "Restored: $original"
            fi
        else
            print_warning "Backup not found: $backup"
        fi
    done

    # Restore settings.json statusLine
    local settings_statusline=$(printf '%s\n' "$manifest" | jq '.settings_statusline')
    if [ "$settings_statusline" != "null" ] && [ -f "$SETTINGS_FILE" ]; then
        local tmp_file=$(mktemp)
        if jq --argjson statusline "$settings_statusline" '.statusLine = $statusline' "$SETTINGS_FILE" > "$tmp_file" 2>/dev/null; then
            mv "$tmp_file" "$SETTINGS_FILE"
            print_success "Restored statusLine config in settings.json"
        else
            rm -f "$tmp_file"
            print_warning "Could not restore statusLine config"
        fi
    elif [ "$settings_statusline" = "null" ] && [ -f "$SETTINGS_FILE" ]; then
        local tmp_file=$(mktemp)
        if jq 'del(.statusLine)' "$SETTINGS_FILE" > "$tmp_file" 2>/dev/null; then
            mv "$tmp_file" "$SETTINGS_FILE"
            print_success "Removed statusLine from settings.json (none existed before)"
        else
            rm -f "$tmp_file"
        fi
    fi

    echo ""
    print_success "Restore complete!"
    print_info "Restart Claude Code to apply changes"
}

# =============================================================================
# UNINSTALL
# =============================================================================
do_uninstall() {
    show_banner
    print_header "Uninstalling Cortado..."
    echo ""

    if [ -f "$BACKUP_MANIFEST" ]; then
        echo -e "${YELLOW}A backup of your previous statusline was found.${NC}"
        echo ""
        echo "Options:"
        echo "  1) Restore previous statusline from backup"
        echo "  2) Just remove current statusline (no restore)"
        echo "  3) Cancel"
        echo ""
        read -rp "Choose an option [1-3]: " choice

        case $choice in
            1)
                [ -d "$CORTADO_DIR" ] && rm -rf "$CORTADO_DIR" && print_success "Removed Cortado directory"
                [ -f "$CLAUDE_DIR/cortado.sh" ] && rm "$CLAUDE_DIR/cortado.sh" && print_success "Removed cortado.sh"

                restore_from_backup

                echo ""
                read -rp "Remove backup files? [y/N]: " remove_backup
                if [ "$remove_backup" = "y" ] || [ "$remove_backup" = "Y" ]; then
                    rm -rf "$BACKUP_DIR" && print_success "Removed backup directory"
                fi
                ;;
            2)
                [ -d "$CORTADO_DIR" ] && rm -rf "$CORTADO_DIR" && print_success "Removed Cortado directory"
                [ -f "$CLAUDE_DIR/cortado.sh" ] && rm "$CLAUDE_DIR/cortado.sh" && print_success "Removed cortado.sh"

                if [ -f "$SETTINGS_FILE" ]; then
                    local tmp_file=$(mktemp)
                    if jq 'del(.statusLine)' "$SETTINGS_FILE" > "$tmp_file" 2>/dev/null; then
                        mv "$tmp_file" "$SETTINGS_FILE"
                        print_success "Removed statusLine from settings.json"
                    else
                        rm -f "$tmp_file"
                    fi
                fi
                ;;
            *)
                print_info "Uninstall cancelled"
                exit 0
                ;;
        esac
    else
        [ -d "$CORTADO_DIR" ] && rm -rf "$CORTADO_DIR" && print_success "Removed Cortado directory"
        [ -f "$CLAUDE_DIR/cortado.sh" ] && rm "$CLAUDE_DIR/cortado.sh" && print_success "Removed cortado.sh"

        if [ -f "$SETTINGS_FILE" ]; then
            local tmp_file=$(mktemp)
            if jq 'del(.statusLine)' "$SETTINGS_FILE" > "$tmp_file" 2>/dev/null; then
                mv "$tmp_file" "$SETTINGS_FILE"
                print_success "Removed statusLine from settings.json"
            else
                rm -f "$tmp_file"
            fi
        fi
    fi

    echo ""
    print_success "Uninstall complete!"
    print_info "Restart Claude Code to apply changes"
}

# Copy runtime files (script, VERSION, modules, lib) into an install prefix.
# Testable without writing settings.json.
copy_runtime_files() {
    local src="${1:-$SCRIPT_DIR}"
    local dest="$2"

    [ -n "$dest" ] || return 1
    [ -f "$src/cortado.sh" ] || return 1
    [ -d "$src/modules" ] || return 1
    [ -f "$src/lib/config-permissions.sh" ] && [ -f "$src/lib/config-tui.sh" ] || return 1

    mkdir -p "$dest/modules" "$dest/lib" || return 1
    cp "$src/cortado.sh" "$dest/" || return 1
    chmod +x "$dest/cortado.sh" || return 1
    cp "$src/modules/"*.sh "$dest/modules/" || return 1
    cp "$src/lib/"*.sh "$dest/lib/" || return 1
    # VERSION goes last, so a partial copy never looks current.
    if [ -f "$src/VERSION" ]; then
        cp "$src/VERSION" "$dest/" || return 1
    fi
    return 0
}

statusline_test_payload() {
    # shellcheck disable=SC2016 # $dir is a jq variable.
    jq -nc --arg dir "$1" '{
        workspace: {current_dir: $dir},
        model: {display_name: "Test"},
        output_style: {name: "default"},
        context_window: {context_window_size: 200000, current_usage: {input_tokens: 1000}}
    }'
}

render_statusline_sample() (
    local script="$1" payload="$2" output errors
    errors=$(mktemp "${TMPDIR:-/tmp}/cortado-test.XXXXXX") || {
        print_error "Could not capture statusline test diagnostics" >&2
        return 1
    }
    trap 'rm -f "$errors"' EXIT

    if ! output=$(CLAUDE_CONFIG_DIR="$CLAUDE_DIR" "$script" <<< "$payload" 2>"$errors") ||
       grep -Eq 'declare: -A: invalid option|syntax error|command not found' "$errors"; then
        print_error "Statusline test FAILED - script errors detected:" >&2
        printf '  %s\n' "$output" >&2
        cat "$errors" >&2
        return 1
    fi
    printf '%s' "$output"
)

test_statusline_directory() (
    local script="$1" payload="$2" sample_dir="$3" probe_dir output directory
    local probe_settings=(
        MODULE_ORDER=directory MODULE_DIRECTORY=true DIRECTORY_STYLE=text
        DIRECTORY_SHOW_FULL_PATH=false DIRECTORY_MAX_LENGTH=0 LAYOUT_MODE=none
    )
    probe_dir=$(mktemp -d) || return 1
    trap 'rm -rf "$probe_dir"' EXIT
    umask 077

    # Check the sample before display preferences can hide or clip its directory.
    printf '%s\n' "${probe_settings[@]}" > "$probe_dir/cortado.conf" || return 1
    # Inherited settings take precedence over any project config in the sample directory.
    output=$(env "${probe_settings[@]}" CLAUDE_CONFIG_DIR="$probe_dir" CACHE_DIR="$probe_dir/cortado-cache" \
        "$script" <<< "$payload" 2>/dev/null) || return 1
    directory=$(basename -- "$sample_dir") || return 1
    [ -n "$directory" ] && [ "$output" = "Dir: $directory" ]
)

write_statusline_settings() (
    local command="$1" result="Created" stage_dir staged_settings
    local input=()
    if [ -f "$SETTINGS_FILE" ]; then
        input=("$SETTINGS_FILE")
        result="Updated"
    elif [ -e "$SETTINGS_FILE" ] || [ -L "$SETTINGS_FILE" ]; then
        print_error "Could not prepare settings.json: expected a regular file" >&2
        return 1
    fi

    stage_dir=$(mktemp -d "$CLAUDE_DIR/.settings.XXXXXX") || {
        print_error "Could not stage settings.json in $CLAUDE_DIR" >&2
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
        print_error "Could not prepare settings.json: expected one readable JSON object" >&2
        return 1
    fi
    if ! jq -es --arg command "$command" '
        length == 1 and (.[0].statusLine == {type: "command", command: $command})
    ' "$staged_settings" >/dev/null 2>&1; then
        print_error "Could not verify statusLine in staged settings.json" >&2
        return 1
    fi
    # Use the parent as the destination so mv cannot move inside a settings.json directory.
    if ! mv -f "$staged_settings" "$CLAUDE_DIR/"; then
        print_error "Could not replace settings.json in $CLAUDE_DIR" >&2
        return 1
    fi
    print_success "$result settings.json"
)

# =============================================================================
# MAIN INSTALLATION
# =============================================================================
do_install() (
    local mode="$1"
    # Banner already shown in interactive mode during update check
    if [ "$mode" != "interactive" ]; then
        show_banner
    fi

    # Check requirements
    print_info "Checking requirements..."

    if ! command -v jq &> /dev/null; then
        print_error "jq is required but not installed."
        echo ""
        echo "Install jq:"
        echo "  macOS:  brew install jq"
        echo "  Ubuntu: sudo apt-get install jq"
        echo "  Fedora: sudo dnf install jq"
        echo ""
        exit 1
    fi
    print_success "jq is installed"

    if ! command -v bc &> /dev/null; then
        print_warning "bc is not installed (burn rate/TPM calculations may not work)"
    else
        print_success "bc is installed"
    fi

    if [ ! -f "$SCRIPT_DIR/cortado.sh" ]; then
        print_error "Source file not found: $SCRIPT_DIR/cortado.sh"
        exit 1
    fi
    print_success "Source files found"

    echo ""

    # Detect existing statusline
    local detection=$(detect_existing_statusline)
    local first_line=$(echo "$detection" | head -1)

    if [ "$first_line" = "detected" ]; then
        local warn_icon=$(emoji "⚠️ " "[!]")
        print_header "$warn_icon Existing Statusline Detected"
        echo ""

        local existing_command=$(echo "$detection" | sed -n '2p')
        local existing_files=$(echo "$detection" | tail -n +3)

        [ -n "$existing_command" ] && echo -e "  Current command: ${CYAN}$existing_command${NC}"
        [ -n "$existing_files" ] && echo -e "  Existing files: ${YELLOW}$existing_files${NC}"

        echo ""
        echo -e "${YELLOW}${BOLD}WARNING:${NC} Installing will overwrite your existing statusline."
        echo -e "Your current statusline will be ${GREEN}backed up${NC} and can be ${GREEN}restored${NC}."
        echo ""

        if [ "$mode" = "interactive" ]; then
            read -rp "Continue with installation? [y/N]: " confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                print_info "Installation cancelled"
                exit 0
            fi
        fi
    fi

    # Module selection based on mode
    case "$mode" in
        interactive)
            interactive_module_selection
            interactive_module_ordering
            interactive_display_preferences
            ;;
        minimal)
            # Just directory, context, git, model
            SELECTED_MODULES=("directory" "context" "git" "model")
            ;;
        *)
            # Use defaults (core modules)
            for mod_def in "${CORE_MODULES[@]}"; do
                local name=$(get_module_name "$mod_def")
                local default=$(get_module_default "$mod_def")
                if [ "$default" = "true" ]; then
                    select_module "$name"
                fi
            done
            ;;
    esac

    # Show summary
    echo ""
    local summary_icon=$(emoji "📋" "[SUM]")
    print_header "$summary_icon Installation Summary"
    echo ""
    echo "Modules to install (${#SELECTED_MODULES[@]} total):"

    for module in "${SELECTED_MODULES[@]}"; do
        echo -e "  ${GREEN}+${NC} $module"
    done
    printf '\nPreview'
    show_statusline_preview

    # Show display settings
    echo -e "${DIM}Display settings:${NC}"
    if [ "$USE_EMOJI" = "true" ]; then
        echo -e "  ${DIM}Icons: Emoji${NC}"
    else
        echo -e "  ${DIM}Icons: ASCII/Text${NC}"
    fi
    echo -e "  ${DIM}Status: ${STATUS_STYLE}${NC}"
    echo -e "  ${DIM}Progress: ${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_EMPTY}${PROGRESS_EMPTY}${NC}"
    echo ""

    if [ "$mode" = "interactive" ]; then
        read -rp "Proceed with installation? [Y/n]: " final_confirm
        if [ "$final_confirm" = "n" ] || [ "$final_confirm" = "N" ]; then
            print_info "Installation cancelled"
            exit 0
        fi
    fi

    echo ""

    # Create directories
    (umask 077; mkdir -p "$CLAUDE_DIR") || {
        print_error "Could not create $CLAUDE_DIR"
        exit 1
    }

    if [[ -e "$CORTADO_DIR" || -L "$CORTADO_DIR" ]] && [ ! -d "$CORTADO_DIR" ]; then
        print_error "Expected a directory at $CORTADO_DIR" >&2
        exit 1
    fi

    local pending_backup="" runtime_stage="" runtime_promoted=false runtime_committed=false
    # Older ShellCheck (CI's Ubuntu) reports the trap-only body as unreachable (SC2317).
    # shellcheck disable=SC2317,SC2329 # Called by the EXIT trap in this subshell.
    cleanup_install() {
        if [ -n "$runtime_stage" ]; then
            if [ "$runtime_committed" = false ]; then
                if [ "$runtime_promoted" = true ]; then
                    if ! mv -- "$CORTADO_DIR" "$runtime_stage/"; then
                        print_error "Could not roll back the new runtime. The previous runtime is in $runtime_stage/previous." >&2
                        return 1
                    fi
                fi
                local saved="$runtime_stage/previous/cortado"
                if [[ -e "$saved" || -L "$saved" ]] && ! mv -- "$saved" "$CLAUDE_DIR/"; then
                    print_error "Could not restore $saved to $CLAUDE_DIR" >&2
                    return 1
                fi
            fi
            rm -rf -- "$runtime_stage"
        fi
        [ -z "$pending_backup" ] || rm -rf -- "$pending_backup"
    }
    trap cleanup_install EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [ "$first_line" = "detected" ]; then
        local snapshot
        if ! mkdir -p "$BACKUP_DIR" || ! snapshot=$(mktemp -d "$BACKUP_DIR/snapshot.XXXXXX"); then
            print_error "Could not stage a statusline backup in $BACKUP_DIR" >&2
            exit 1
        fi
        pending_backup="$snapshot"
        if ! backup_existing_statusline "$pending_backup"; then
            print_error "Could not prepare a statusline backup in $BACKUP_DIR" >&2
            exit 1
        fi
        # Publish the first restore point before replacing any runtime files.
        # During a reinstall, keep the existing restore point until settings commit.
        if [ ! -f "$BACKUP_MANIFEST" ]; then
            if ! mv -f "$pending_backup/manifest.json" "$BACKUP_DIR/"; then
                print_error "Could not save backup manifest in $BACKUP_DIR" >&2
                exit 1
            fi
            pending_backup=""
        fi
    fi

    # Stage and test a complete replacement before moving any live files.
    print_info "Installing Cortado..."

    local stage staged_runtime
    if ! stage=$(mktemp -d "$CLAUDE_DIR/.cortado-install.XXXXXX"); then
        print_error "Could not stage Cortado runtime in $CLAUDE_DIR" >&2
        exit 1
    fi
    runtime_stage="$stage"
    staged_runtime="$runtime_stage/cortado"
    (umask 077; mkdir "$staged_runtime" "$runtime_stage/previous") || exit 1

    local installed_dir
    if ! installed_dir=$(CDPATH='' cd -- "$CLAUDE_DIR" && pwd -P); then
        print_error "Could not resolve the installed directory: $CORTADO_DIR" >&2
        exit 1
    fi
    installed_dir="${installed_dir%/}/cortado"

    if ! copy_runtime_files "$SCRIPT_DIR" "$staged_runtime"; then
        print_error "Could not copy Cortado runtime files (need cortado.sh, modules/, and lib/)"
        exit 1
    fi

    # Validate module files
    local module_count=$(ls -1 "$staged_runtime/modules/"*.sh 2>/dev/null | wc -l | tr -d ' ')
    if [ "$module_count" -eq 0 ]; then
        print_warning "No module files found - statusline may not work correctly"
    else
        print_success "Installed $module_count module files"
    fi

    local generated="$staged_runtime/cortado.conf"
    if ! generate_config "$generated" || [ ! -f "$generated" ] || [ -L "$generated" ]; then
        print_error "Could not generate Cortado config" >&2
        exit 1
    fi
    validate_config "$generated" || exit 1

    # Carry over the user's Barista settings before the test run below.
    local migrated
    if migrated=$(migrate_legacy_user_config) && [ -n "$migrated" ]; then
        print_success "Migrated $LEGACY_USER_CONFIG -> $migrated"
    fi

    # Test installation BEFORE applying to settings.json
    echo ""
    print_info "Testing statusline before applying..."

    local test_json quoted_path test_output
    if [ -z "$HOME" ]; then
        print_error "Could not prepare statusline test: HOME is empty. Settings not modified." >&2
        exit 1
    fi
    # Claude Code runs the command through a shell. Quote its absolute path.
    # shellcheck disable=SC2016 # $path is a jq variable.
    if ! test_json=$(statusline_test_payload "$HOME") ||
       ! quoted_path=$(jq -nr --arg path "$installed_dir/cortado.sh" '$path | @sh'); then
        print_error "Could not prepare statusline test. Settings not modified." >&2
        exit 1
    fi

    if ! test_output=$(render_statusline_sample "$staged_runtime/cortado.sh" "$test_json"); then
        print_error "Installation aborted. Settings not modified."
        print_info "Fix the errors above and try again."
        exit 1
    fi

    if ! test_statusline_directory "$staged_runtime/cortado.sh" "$test_json" "$HOME"; then
        print_error "Statusline test FAILED - sample directory missing or could not be checked" >&2
        print_error "Installation aborted. Settings not modified." >&2
        exit 1
    fi

    # Check for valid output
    if [ -z "$test_output" ] || [ ${#test_output} -lt 5 ]; then
        print_error "Statusline test FAILED - no output produced"
        echo ""
        print_error "Installation aborted. Settings not modified."
        # shellcheck disable=SC2016 # $payload is a jq variable.
        local quoted_payload=$(jq -nr --arg payload "$test_json" '$payload | @sh')
        # shellcheck disable=SC2016 # $path is a jq variable.
        local quoted_source=$(jq -nr --arg path "$SCRIPT_DIR/cortado.sh" '$path | @sh')
        printf '%b %s\n' "${BLUE}i${NC}" "Try running manually: printf '%s\\n' $quoted_payload | $quoted_source"
        exit 1
    fi

    print_success "Statusline test passed!"
    echo ""
    echo "Sample output:"
    echo "  $test_output"
    echo ""

    if [ -d "$CORTADO_DIR" ] && ! mv -- "$CORTADO_DIR" "$runtime_stage/previous/"; then
        print_error "Could not move the previous runtime at $CORTADO_DIR" >&2
        exit 1
    fi
    if ! mv -- "$staged_runtime" "$CLAUDE_DIR/"; then
        print_error "Could not install the staged runtime in $CLAUDE_DIR" >&2
        exit 1
    fi
    runtime_promoted=true
    print_success "Copied statusline files to $CORTADO_DIR"

    # Update settings.json only after successful test and promotion.
    print_info "Applying configuration to settings.json..."

    write_statusline_settings "$quoted_path" || exit 1
    runtime_committed=true
    if [ -f "$CLAUDE_DIR/cortado.sh" ]; then
        rm -- "$CLAUDE_DIR/cortado.sh" || print_warning "Could not remove the older $CLAUDE_DIR/cortado.sh"
    fi

    if [ -n "$pending_backup" ]; then
        if ! mv -f "$pending_backup/manifest.json" "$BACKUP_DIR/"; then
            print_warning "Could not replace the backup manifest. The new backup is in $pending_backup."
        fi
        pending_backup=""
    fi

    # Final message
    echo ""
    echo "================================================================"
    echo "                   Installation Complete!                       "
    echo "================================================================"
    echo ""
    print_success "Restart Claude Code to see your new statusline"
    echo ""
    echo "Configuration:"
    echo "  Edit:     $CORTADO_DIR/cortado.conf"
    printf '  Or run:   %s config\n' "$quoted_path"
    echo "  Modules:  $CORTADO_DIR/modules/"
    echo ""
    echo "Per-directory overrides:"
    echo "  Create .cortado.conf in any project directory (.barista.conf is still read)"
    echo ""

    if [ -d "$LEGACY_DIR" ] || [ -f "$LEGACY_USER_CONFIG" ] || [ -d "$CLAUDE_DIR/barista-cache" ]; then
        echo "Old Barista files were left in place so --uninstall can restore them:"
        [ -d "$LEGACY_DIR" ] && echo "  $LEGACY_DIR"
        [ -f "$LEGACY_USER_CONFIG" ] && echo "  $LEGACY_USER_CONFIG"
        [ -d "$CLAUDE_DIR/barista-cache" ] && echo "  $CLAUDE_DIR/barista-cache"
        echo "  Remove them once you're happy with Cortado. A Homebrew install: brew uninstall barista"
        echo ""
    fi

    if [ -f "$BACKUP_MANIFEST" ]; then
        echo -e "${GREEN}Your previous statusline was backed up.${NC}"
        echo -e "To restore it, run: ${CYAN}$0 --uninstall${NC}"
        echo ""
    fi
    exit 0
)

# =============================================================================
# HELP
# =============================================================================
show_help() {
    show_banner
    local ver=$(get_local_version)
    echo "Cortado v$ver"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo -e "${BOLD}Installation Options:${NC}"
    echo "  (none)             Interactive install with multiselect module picker"
    echo "  --defaults         Install with core modules enabled (default order)"
    echo "  --minimal          Quick install with minimal modules"
    echo "  --force            Same as --defaults, no confirmation prompts"
    echo ""
    echo -e "${BOLD}Display Options:${NC}"
    echo "  --no-emoji         Disable emojis in installer and generated config"
    echo "  --no-color         Disable colors in installer output"
    echo ""
    echo -e "${BOLD}Update Options:${NC}"
    echo "  --check-update, --check  Check if a newer version is available"
    echo "  --update           Download and install the latest version"
    echo "  --skip-update-check  Skip automatic update check during install"
    echo "  --version, -v      Show current version"
    echo ""
    echo -e "${BOLD}Other Options:${NC}"
    echo "  --uninstall        Uninstall and optionally restore previous statusline"
    echo "  --help, -h         Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                      # Interactive installation"
    echo "  $0 --check-update       # Check for updates"
    echo "  $0 --no-emoji           # Install without emojis"
    echo "  $0 --minimal --no-emoji # Minimal install, no emojis"
    echo ""
    echo -e "${BOLD}Available Modules:${NC}"
    echo ""
    echo -e "${CYAN}Core (enabled by default):${NC}"
    for mod_def in "${CORE_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local desc=$(get_module_description "$mod_def")
        echo "  $name - $desc"
    done
    echo ""
    echo -e "${CYAN}System Monitoring:${NC}"
    for mod_def in "${SYSTEM_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local desc=$(get_module_description "$mod_def")
        echo "  $name - $desc"
    done
    echo ""
    echo -e "${CYAN}Development Tools:${NC}"
    for mod_def in "${DEV_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local desc=$(get_module_description "$mod_def")
        echo "  $name - $desc"
    done
    echo ""
    echo -e "${CYAN}Extra:${NC}"
    for mod_def in "${EXTRA_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local desc=$(get_module_description "$mod_def")
        echo "  $name - $desc"
    done
    echo ""
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-emoji)
                USE_EMOJI="false"
                shift
                ;;
            --no-color)
                USE_COLOR="false"
                shift
                ;;
            --uninstall)
                INSTALL_MODE="uninstall"
                shift
                ;;
            --force)
                INSTALL_MODE="force"
                shift
                ;;
            --defaults)
                INSTALL_MODE="defaults"
                shift
                ;;
            --minimal)
                INSTALL_MODE="minimal"
                shift
                ;;
            --update)
                INSTALL_MODE="update"
                shift
                ;;
            --check-update|--check)
                INSTALL_MODE="check-update"
                shift
                ;;
            --skip-update-check)
                SKIP_UPDATE_CHECK="true"
                shift
                ;;
            --version|-v)
                INSTALL_MODE="version"
                shift
                ;;
            --help|-h)
                INSTALL_MODE="help"
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Run '$0 --help' for usage information"
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================
# Installer-owned files are executable code. Add group and other write
# protection to the caller's umask, keeping any stricter bits it already has.
_restrict_umask() {
    local current
    current=$(umask) || return 1
    umask "$(printf '%04o' $(( 8#$current | 8#022 )))"
}

main() {
    _restrict_umask
    parse_args "$@"
    setup_colors

    # Handle version display
    if [ "$INSTALL_MODE" = "version" ]; then
        local ver=$(get_local_version)
        echo "Cortado v$ver"
        exit 0
    fi

    # Handle explicit release checks and updates
    if [[ "$INSTALL_MODE" = "check-update" || "$INSTALL_MODE" = "update" ]]; then
        if ! command -v jq >/dev/null 2>&1; then
            print_error "jq is required to check for Cortado updates" >&2
            exit 1
        fi
        show_banner
        print_info "Checking for updates..."
        if check_for_updates; then
            if [ "$INSTALL_MODE" = "update" ]; then
                do_update "$@"
            else
                prompt_update "$@"
            fi
            exit $?
        elif [ "$?" -eq 2 ]; then
            print_warning "Could not determine the latest version"
            exit 1
        else
            local ver=$(get_local_version)
            if [ "$INSTALL_MODE" = "update" ]; then
                if [ "$ver" = "${REMOTE_TAG#v}" ] && [ -f "$SCRIPT_DIR/VERSION" ] &&
                    ! _is_homebrew_prefix "$SCRIPT_DIR"; then
                    _refresh_managed_runtime "$REMOTE_TAG" || exit 1
                fi
                if [ "$_UPD_REFRESHED" != true ]; then
                    print_success "Already up to date ($ver)"
                fi
            else
                print_success "You have the latest version ($ver)"
            fi
        fi
        exit 0
    fi

    # Check for updates before install (unless skipped)
    if [ "$SKIP_UPDATE_CHECK" != "true" ] && [ "$INSTALL_MODE" != "uninstall" ] && [ "$INSTALL_MODE" != "help" ]; then
        # In interactive mode, show banner first and ask user if they want to check
        if [ "$INSTALL_MODE" = "interactive" ]; then
            show_banner
            interactive_update_check "$@" || exit $?
        else
            # Non-interactive modes: silent check, only prompt if update available
            if check_for_updates; then
                setup_colors  # Ensure colors are set before prompt
                prompt_update "$@" || exit $?
            fi
        fi
    fi

    if [ "$INSTALL_MODE" != uninstall ] && ! init_installer_catalog; then
        print_error "Could not read module catalog" >&2
        return 1
    fi

    case "$INSTALL_MODE" in
        uninstall)
            do_uninstall
            ;;
        help)
            show_help
            ;;
        force|defaults)
            do_install "defaults"
            ;;
        minimal)
            do_install "minimal"
            ;;
        *)
            do_install "interactive"
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
