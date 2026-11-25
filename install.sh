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
_version_numeric_component() {
    local value="${1:-}"
    value="${value%%[!0-9]*}"
    printf '%s\n' "${value:-0}"
}

# Compare semantic versions (returns 0 if v1 < v2). Matches modules/update.sh
# _version_gt inverted: numeric major/minor/patch only; suffixes ignored.
version_lt() {
    local v1="$1"
    local v2="$2"
    local v1_major v1_minor v1_patch v2_major v2_minor v2_patch

    IFS=. read -r v1_major v1_minor v1_patch _ <<< "$v1"
    IFS=. read -r v2_major v2_minor v2_patch _ <<< "$v2"

    v1_major=$(_version_numeric_component "$v1_major")
    v1_minor=$(_version_numeric_component "$v1_minor")
    v1_patch=$(_version_numeric_component "$v1_patch")
    v2_major=$(_version_numeric_component "$v2_major")
    v2_minor=$(_version_numeric_component "$v2_minor")
    v2_patch=$(_version_numeric_component "$v2_patch")

    if [ "$v1_major" -lt "$v2_major" ]; then return 0; fi
    if [ "$v1_major" -gt "$v2_major" ]; then return 1; fi
    if [ "$v1_minor" -lt "$v2_minor" ]; then return 0; fi
    if [ "$v1_minor" -gt "$v2_minor" ]; then return 1; fi
    if [ "$v1_patch" -lt "$v2_patch" ]; then return 0; fi
    return 1
}

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

        local tmp_dir
        if ! tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cortado-update.XXXXXX"); then
            print_error "Could not create a temporary directory for the update."
            return 1
        fi
        local extract_dir="$tmp_dir/Cortado-${tag#v}"
        if ! _stage_release_archive "$tag" "$tmp_dir" "$extract_dir"; then
            rm -rf "$tmp_dir"
            return 1
        fi

        cp -r "$SCRIPT_DIR" "$SCRIPT_DIR.backup.$$"
        cp -r "$extract_dir"/* "$SCRIPT_DIR/"
        rm -rf "$SCRIPT_DIR.backup.$$"

        print_success "Updated to version ${tag#v}"
        echo ""
        print_info "Restarting installer with new version..."
        echo ""

        rm -rf "$tmp_dir"
        _reexec_installer "$@"
    fi
}

# =============================================================================
# MODULE DEFINITIONS
# =============================================================================
# Format: "module_name:default_enabled:category"
declare -a CORE_MODULES=(
    "sandbox:true:core"
    "version:true:core"
    "update:true:core"
    "directory:true:core"
    "context:true:core"
    "git:true:core"
    "project:true:core"
    "model:true:core"
    "cost:true:core"
    "rate-limits:true:core"
    "time:true:core"
    "battery:true:core"
)

declare -a SYSTEM_MODULES=(
    "cpu:false:system"
    "memory:false:system"
    "disk:false:system"
    "network:false:system"
    "uptime:false:system"
    "load:false:system"
    "temperature:false:system"
    "brightness:false:system"
    "processes:false:system"
)

declare -a DEV_MODULES=(
    "docker:false:dev"
    "node:false:dev"
)

declare -a EXTRA_MODULES=(
    "weather:false:extra"
    "timezone:false:extra"
)

# All modules combined
declare -a ALL_MODULES=("${CORE_MODULES[@]}" "${SYSTEM_MODULES[@]}" "${DEV_MODULES[@]}" "${EXTRA_MODULES[@]}")

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

# Get module description
get_module_description() {
    local module="$1"
    local icon_mode="$2"  # "icon", "text", or "both"

    local icon=""
    local text=""

    case "$module" in
        # Core modules
        sandbox)      icon="$(emoji '🔒' '[S]')"; text="Lock icon when in macOS app sandbox" ;;
        version)      icon="$(emoji '☕' '[V]')"; text="Cortado version (shown briefly on startup)" ;;
        update)       icon="$(emoji '⬆️ ' '[U]')"; text="Update checker (daily GitHub check)" ;;
        directory)    icon="$(emoji '📁' '[D]')"; text="Current directory name" ;;
        context)      icon="$(emoji '📊' '[C]')"; text="Context window usage with progress bar" ;;
        git)          icon="$(emoji '🌿' '[G]')"; text="Git branch, status, and file count" ;;
        project)      icon="$(emoji '⚡' '[P]')"; text="Project type detection (Nuxt, Rust, etc.)" ;;
        model)        icon="$(emoji '🤖' '[M]')"; text="Claude model and output style" ;;
        cost)         icon="$(emoji '💰' '[$]')"; text="Session cost, burn rate, and TPM" ;;
        rate-limits)  icon="$(emoji '⏱️ ' '[R]')"; text="5-hour and 7-day rate limits" ;;
        time)         icon="$(emoji '🕐' '[T]')"; text="Current date and time" ;;
        battery)      icon="$(emoji '🔋' '[B]')"; text="Battery percentage (macOS)" ;;
        # System modules
        cpu)          icon="$(emoji '💻' '[CPU]')"; text="CPU usage percentage" ;;
        memory)       icon="$(emoji '🧠' '[MEM]')"; text="Memory/RAM usage" ;;
        disk)         icon="$(emoji '💾' '[DSK]')"; text="Disk space usage" ;;
        network)      icon="$(emoji '🌐' '[NET]')"; text="Network info (IP address)" ;;
        uptime)       icon="$(emoji '⏱️ ' '[UP]')"; text="System uptime" ;;
        load)         icon="$(emoji '📊' '[LD]')"; text="System load average" ;;
        temperature)  icon="$(emoji '🌡️ ' '[TMP]')"; text="CPU temperature" ;;
        brightness)   icon="$(emoji '☀️ ' '[BRT]')"; text="Screen brightness (macOS)" ;;
        processes)    icon="$(emoji '🔄' '[PRC]')"; text="Process count" ;;
        # Dev tools
        docker)       icon="$(emoji '🐳' '[DOC]')"; text="Docker container status" ;;
        node)         icon="$(emoji '⬢ ' '[NOD]')"; text="Node.js version" ;;
        # Extra
        weather)      icon="$(emoji '🌤️ ' '[WTH]')"; text="Weather (via wttr.in)" ;;
        timezone)     icon="$(emoji '🌍' '[TZ]')"; text="Multiple timezone clocks" ;;
        *)            icon="?"; text="Unknown module" ;;
    esac

    case "$icon_mode" in
        icon) echo "$icon" ;;
        text) echo "$text" ;;
        *) echo "$icon $text" ;;
    esac
}

# Get sample preview data for a module (icon + sample value)
get_module_sample() {
    local module="$1"
    local status=""

    # Get status indicator based on current style
    case "$STATUS_STYLE" in
        emoji) status="🟢" ;;
        dots)  status="●" ;;
        ascii) status="[OK]" ;;
    esac

    # Build progress bar sample
    local bar="${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_EMPTY}${PROGRESS_EMPTY}${PROGRESS_EMPTY}${PROGRESS_EMPTY}"

    case "$module" in
        sandbox)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🔒"
            else
                echo "SANDBOX"
            fi
            ;;
        directory)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "📁 myproject"
            else
                echo "DIR: myproject"
            fi
            ;;
        context)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "📊 $bar 50%$status"
            else
                echo "CTX: $bar 50%$status"
            fi
            ;;
        git)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🌿 main [●+]"
            else
                echo "GIT: main [●+]"
            fi
            ;;
        project)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "⚡ Nuxt"
            else
                echo "PRJ: Nuxt"
            fi
            ;;
        model)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🤖 Opus 4.5"
            else
                echo "AI: Opus 4.5"
            fi
            ;;
        cost)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "💰 \$1.25"
            else
                echo "\$: \$1.25"
            fi
            ;;
        rate-limits)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "5h:45%$status 7d:23%$status"
            else
                echo "5h:45%$status 7d:23%$status"
            fi
            ;;
        time)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "📅 01/14 🕐 03:30 PM"
            else
                echo "01/14 03:30 PM"
            fi
            ;;
        battery)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🔋 85% ⚡"
            else
                echo "BAT: 85%"
            fi
            ;;
        cpu)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "💻 23%$status"
            else
                echo "CPU: 23%$status"
            fi
            ;;
        memory)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🧠 58%$status"
            else
                echo "MEM: 58%$status"
            fi
            ;;
        disk)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "💾 42%$status"
            else
                echo "DSK: 42%$status"
            fi
            ;;
        network)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🌐 192.168.1.42"
            else
                echo "NET: 192.168.1.42"
            fi
            ;;
        uptime)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "⏱️ 3d 5h"
            else
                echo "UP: 3d 5h"
            fi
            ;;
        load)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "📊 1.24$status"
            else
                echo "LD: 1.24$status"
            fi
            ;;
        temperature)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🌡️ 52°C$status"
            else
                echo "TMP: 52C$status"
            fi
            ;;
        brightness)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "☀️ 75%"
            else
                echo "BRT: 75%"
            fi
            ;;
        processes)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🔄 245"
            else
                echo "PRC: 245"
            fi
            ;;
        docker)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🐳 3$status"
            else
                echo "DOC: 3$status"
            fi
            ;;
        node)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "⬢ 24.x"
            else
                echo "NODE: 24.x"
            fi
            ;;
        weather)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🌤️ 72°F"
            else
                echo "WTH: 72F"
            fi
            ;;
        timezone)
            if [ "$USE_EMOJI" = "true" ]; then
                echo "🌍 UTC:20:30"
            else
                echo "TZ: UTC:20:30"
            fi
            ;;
        *)
            echo "?"
            ;;
    esac
}

# Parse module definition string
get_module_name() { echo "$1" | cut -d: -f1; }
get_module_default() { echo "$1" | cut -d: -f2; }
get_module_category() { echo "$1" | cut -d: -f3; }

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
        local desc=$(get_module_description "$name" "both")
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
show_statusline_preview() {
    local sep="$SEPARATOR_CHAR"
    local preview=""
    if ! type theme_default_icon >/dev/null 2>&1; then
        if [ -f "$SCRIPT_DIR/modules/utils.sh" ]; then
            # shellcheck source=modules/utils.sh
            . "$SCRIPT_DIR/modules/utils.sh"
        fi
    fi

    local module part icon label bar status
    for module in "${SELECTED_MODULES[@]}"; do
        part=""
        icon=""
        label=""
        icon=$(theme_default_icon "$module")
        case "$module" in
            directory) label="myproject" ;;
            context)
                bar="${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_FILLED}${PROGRESS_EMPTY}${PROGRESS_EMPTY}${PROGRESS_EMPTY}${PROGRESS_EMPTY}"
                status=$(theme_status_glyph)
                label="$bar 50%$status"
                ;;
            git) label="main" ;;
            model) label="Opus" ;;
            cost) label="\$1.25" ;;
            time) label="12:30" ;;
            battery) label="85%" ;;
        esac
        if [ -n "$label" ] || [ -n "$icon" ]; then
            if [ -n "$icon" ]; then
                part="$icon $label"
            else
                part="$label"
            fi
        fi

        if [ -n "$part" ]; then
            if [ -n "$preview" ]; then
                preview="${preview}${sep}${part}"
            else
                preview="$part"
            fi
        fi
    done

    if [ ${#preview} -gt 100 ]; then
        preview="${preview:0:97}..."
    fi

    echo ""
    echo -e "  ${DIM}$preview${NC}"
    echo ""
}


# =============================================================================
# CONFIGURATION GENERATION
# =============================================================================
generate_config() {
    local config_file="$1"

    cat > "$config_file" << 'HEADER'
# =============================================================================
# Cortado Configuration
# =============================================================================
# Generated by install.sh
# Enable/disable modules by setting to "true" or "false"
# For full configuration options, see cortado.conf in the repo
# =============================================================================

HEADER

    # Write global settings based on installer selections
    echo "# Global Settings" >> "$config_file"
    if [ "$USE_EMOJI" = "false" ]; then
        echo 'USE_ICONS="false"' >> "$config_file"
    else
        echo 'USE_ICONS="true"' >> "$config_file"
    fi

    # Display mode
    echo "DISPLAY_MODE=\"${DISPLAY_MODE:-normal}\"" >> "$config_file"

    # Status style
    echo "STATUS_STYLE=\"${STATUS_STYLE:-emoji}\"" >> "$config_file"

    # Progress bar characters
    echo "PROGRESS_BAR_FILLED=\"${PROGRESS_FILLED:-█}\"" >> "$config_file"
    echo "PROGRESS_BAR_EMPTY=\"${PROGRESS_EMPTY:-░}\"" >> "$config_file"

    # Separator
    echo "SEPARATOR=\"${SEPARATOR_CHAR:- | }\"" >> "$config_file"

    # Color theme
    echo "COLOR_THEME=\"${COLOR_THEME:-default}\"" >> "$config_file"
    echo "" >> "$config_file"

    # Write module enable/disable settings
    echo "# Module Settings" >> "$config_file"
    for mod_def in "${ALL_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local var_name="MODULE_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')"
        local enabled="false"

        if is_module_selected "$name"; then
            enabled="true"
        fi

        echo "$var_name=\"$enabled\"" >> "$config_file"
    done

    # Write module order
    echo "" >> "$config_file"
    echo "# Module display order (comma-separated)" >> "$config_file"
    local order_str=""
    for module in "${SELECTED_MODULES[@]}"; do
        if [ -z "$order_str" ]; then
            order_str="$module"
        else
            order_str="$order_str,$module"
        fi
    done
    echo "MODULE_ORDER=\"$order_str\"" >> "$config_file"

    # Write footer with basic settings
    cat >> "$config_file" << 'FOOTER'

# =============================================================================
# Display Settings
# =============================================================================

PROGRESS_BAR_WIDTH=8

# =============================================================================
# Advanced Settings
# =============================================================================

# Default cache TTL (seconds) for cache_get when the caller omits max_age.
# Built-in fallback is 60. Git, rate limits, and updates pass their own
# seconds and ignore this. Weather does not call cache_get.
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
}

# =============================================================================
# VALIDATION
# =============================================================================
validate_config() {
    local config_file="$1"
    local errors=0

    if [ ! -f "$config_file" ]; then
        return 0
    fi

    # Source the config to validate
    (
        . "$config_file" 2>/dev/null

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

    return $errors
}

# =============================================================================
# MIGRATION FROM BARISTA
# =============================================================================
# Copy the user's Barista override (barista.conf) to cortado.conf so their settings
# carry over. Never overwrites an existing cortado.conf and leaves the original in
# place. cp -p keeps the 600 mode that cortado.sh's writable-config check expects.
# Prints the path it migrated, or nothing when there was nothing to do.
migrate_legacy_user_config() {
    local legacy="${1:-$LEGACY_USER_CONFIG}"
    local target="${2:-$CLAUDE_DIR/cortado.conf}"
    [ -f "$legacy" ] || return 0
    [ -f "$target" ] && return 0
    cp -p "$legacy" "$target" || return 1
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
# Testable without writing settings.json. Fail if lib/config-tui.sh is absent.
copy_runtime_files() {
    local src="${1:-$SCRIPT_DIR}"
    local dest="$2"

    [ -n "$dest" ] || return 1
    [ -f "$src/cortado.sh" ] || return 1
    [ -d "$src/modules" ] || return 1
    [ -d "$src/lib" ] || return 1

    mkdir -p "$dest/modules" "$dest/lib" || return 1
    cp "$src/cortado.sh" "$dest/" || return 1
    chmod +x "$dest/cortado.sh"
    if [ -f "$src/VERSION" ]; then
        cp "$src/VERSION" "$dest/" || return 1
    fi
    cp "$src/modules/"*.sh "$dest/modules/" || return 1
    cp "$src/lib/"*.sh "$dest/lib/" || return 1
    [ -f "$dest/lib/config-tui.sh" ] || return 1
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

    local preview=""
    local sep="$SEPARATOR_CHAR"
    for module in "${SELECTED_MODULES[@]}"; do
        echo -e "  ${GREEN}+${NC} $module"
    done

    # Build preview with sample data (limit to first 5 modules to fit on screen)
    local count=0
    for module in "${SELECTED_MODULES[@]}"; do
        if [ $count -ge 5 ]; then
            preview="${preview}${sep}..."
            break
        fi
        local sample=$(get_module_sample "$module")
        if [ -n "$preview" ]; then
            preview="${preview}${sep}${sample}"
        else
            preview="$sample"
        fi
        count=$((count + 1))
    done

    echo ""
    echo -e "Preview: ${DIM}$preview${NC}"
    echo ""

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
    mkdir -p "$CLAUDE_DIR" || {
        print_error "Could not create $CLAUDE_DIR"
        exit 1
    }

    local pending_backup=""
    if [ "$first_line" = "detected" ]; then
        if ! mkdir -p "$BACKUP_DIR" || ! pending_backup=$(mktemp -d "$BACKUP_DIR/snapshot.XXXXXX"); then
            print_error "Could not stage a statusline backup in $BACKUP_DIR" >&2
            exit 1
        fi
        trap 'rm -rf -- "$pending_backup"' EXIT
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
            trap - EXIT
            pending_backup=""
        fi
    fi

    # Remove existing installation
    [ -d "$CORTADO_DIR" ] && rm -rf "$CORTADO_DIR"
    [ -f "$CLAUDE_DIR/cortado.sh" ] && rm "$CLAUDE_DIR/cortado.sh"

    # Install files
    print_info "Installing Cortado..."

    mkdir -p "$CORTADO_DIR" || {
        print_error "Could not create $CORTADO_DIR"
        exit 1
    }

    local installed_dir
    if ! installed_dir=$(CDPATH='' cd -- "$CORTADO_DIR" && pwd -P); then
        print_error "Could not resolve the installed directory: $CORTADO_DIR" >&2
        exit 1
    fi

    if ! copy_runtime_files "$SCRIPT_DIR" "$CORTADO_DIR"; then
        print_error "Could not copy Cortado runtime files (need cortado.sh, modules/, lib/config-tui.sh)"
        exit 1
    fi

    # Validate module files
    local module_count=$(ls -1 "$CORTADO_DIR/modules/"*.sh 2>/dev/null | wc -l | tr -d ' ')
    if [ "$module_count" -eq 0 ]; then
        print_warning "No module files found - statusline may not work correctly"
    else
        print_success "Installed $module_count module files"
    fi

    # Carry over the user's Barista settings before the test run below
    local migrated
    if migrated=$(migrate_legacy_user_config); then
        [ -n "$migrated" ] && print_success "Migrated $LEGACY_USER_CONFIG -> $migrated"
    else
        print_warning "Could not copy $LEGACY_USER_CONFIG to $CLAUDE_DIR/cortado.conf (Cortado will read the old file)"
    fi

    # Generate config
    generate_config "$CORTADO_DIR/cortado.conf"

    # Validate generated config
    validate_config "$CORTADO_DIR/cortado.conf"

    print_success "Copied statusline files to $CORTADO_DIR"

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

    if ! test_output=$(render_statusline_sample "$installed_dir/cortado.sh" "$test_json"); then
        print_error "Installation aborted. Settings not modified."
        print_info "Fix the errors above and try again."
        exit 1
    fi

    if ! test_statusline_directory "$installed_dir/cortado.sh" "$test_json" "$HOME"; then
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
        printf '%b %s\n' "${BLUE}i${NC}" "Try running manually: printf '%s\\n' $quoted_payload | $quoted_path"
        exit 1
    fi

    print_success "Statusline test passed!"
    echo ""
    echo "Sample output:"
    echo "  $test_output"
    echo ""

    # Update settings.json only after successful test
    print_info "Applying configuration to settings.json..."

    write_statusline_settings "$quoted_path" || exit 1

    if [ -n "$pending_backup" ]; then
        trap - EXIT
        if ! mv -f "$pending_backup/manifest.json" "$BACKUP_DIR/"; then
            print_warning "Could not replace the backup manifest. The new backup is in $pending_backup."
        fi
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
        local desc=$(get_module_description "$name" "both")
        echo "  $name - $desc"
    done
    echo ""
    echo -e "${CYAN}System Monitoring:${NC}"
    for mod_def in "${SYSTEM_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local desc=$(get_module_description "$name" "both")
        echo "  $name - $desc"
    done
    echo ""
    echo -e "${CYAN}Development Tools:${NC}"
    for mod_def in "${DEV_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local desc=$(get_module_description "$name" "both")
        echo "  $name - $desc"
    done
    echo ""
    echo -e "${CYAN}Extra:${NC}"
    for mod_def in "${EXTRA_MODULES[@]}"; do
        local name=$(get_module_name "$mod_def")
        local desc=$(get_module_description "$name" "both")
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
main() {
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
                print_success "Already up to date ($ver)"
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
