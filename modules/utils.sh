# shellcheck shell=bash
# =============================================================================
# Utils Module - Shared utility functions
# =============================================================================
# This module provides common functions used by all other modules.
# It must be loaded first before any other modules.
# =============================================================================

# The payload and fixed-point helpers also serve the incomplete-install path.
# shellcheck source=modules/payload.sh
. "${BASH_SOURCE[0]%utils.sh}payload.sh"

# =============================================================================
# PORTABLE FILE STAT HELPERS
# =============================================================================
# Call `/usr/bin/stat` with an absolute path on Darwin so GNU coreutils
# (brew `gnubin` in PATH) cannot shadow BSD stat — GNU's `-f` means
# `--file-system`, which returns garbage and silently breaks cache age /
# rate-limit backoff / history-size math.
# Fall back to GNU `stat -c` on Linux and to `0` on any failure.

# _file_stat <bsd_fmt> <gnu_fmt> <file> — shared portable-stat core:
# existence check, Darwin/Linux branch, and `0` fallback on any failure.
_file_stat() {
    local fmt_bsd="$1" fmt_gnu="$2" f="$3"
    [ -e "$f" ] || { echo 0; return; }
    if [[ "${BASH_VERSINFO[5]}" == *-darwin* ]]; then
        /usr/bin/stat -f "$fmt_bsd" "$f" 2>/dev/null || echo 0
    else
        stat -c "$fmt_gnu" "$f" 2>/dev/null || echo 0
    fi
}

_file_mtime() {
    _file_stat %m %Y "$1"
}

# =============================================================================
# CACHE SYSTEM
# =============================================================================
# Simple file-based caching for expensive operations (weather, network, etc.)

CACHE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cortado-cache"

# Initialize cache directory
init_cache() {
    if [ ! -d "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null
    fi
    # Always re-assert owner-only mode. #34 chmod'd only on create, so a
    # pre-existing world-readable ~/.claude/cortado-cache (older install or
    # permissive umask) was never repaired. Cache key names (weather, wan_ip,
    # rate_limits_usage, update_check…) must not leak to other local users.
    if [ -d "$CACHE_DIR" ]; then
        chmod 700 "$CACHE_DIR" 2>/dev/null
    fi
}

# Get cached value if not expired
# Usage: cache_get <key> [max_age_seconds]
# Returns: cached value or empty string if expired/missing
cache_get() {
    local key="$1"
    local max_age="${2:-${CACHE_MAX_AGE:-60}}"

    # Reject keys that attempt path traversal (".."). Flat keys that happen
    # to contain a single "/" (e.g. "rate_limits/1337") are legitimate file
    # names inside the flat CACHE_DIR and are allowed.
    case "$key" in
        *..*) return 1 ;;
    esac

    local cache_file="$CACHE_DIR/${key}"

    if [ ! -f "$cache_file" ]; then
        return 1
    fi

    # Check age
    local file_time
    file_time=$(_file_stat %m %Y "$cache_file")

    if [ "$file_time" -eq 0 ]; then
        return 1
    fi

    local current_time
    current_time=$(date +%s)
    local age=$((current_time - file_time))

    # A non-numeric max_age (from an untrusted .cortado.conf setting
    # CACHE_MAX_AGE, or a direct bad arg) would otherwise make the
    # comparison below silently fail and treat any cache — no matter how
    # old — as fresh. Treat a non-numeric max_age as a miss.
    case "$max_age" in
        ''|*[!0-9]*) return 1 ;;
    esac

    if [ "$age" -gt "$max_age" ] 2>/dev/null; then
        # Cache expired
        return 1
    fi

    # Return cached value
    cat "$cache_file" 2>/dev/null
    return 0
}

# Publish a writer's stdout as an owner-only file, without truncating the
# destination for readers. Stage beside the destination for a same-filesystem
# rename. The subshell keeps the cleanup trap out of the caller's shell.
_atomic_write_file() {
    local target="$1"
    local staging
    shift

    (
        # mv would move the staging file into an existing directory.
        [ ! -d "$target" ] || return 1
        umask 077
        staging=$(mktemp "${target}.XXXXXX" 2>/dev/null) || return 1
        trap 'rm -f -- "$staging" 2>/dev/null' EXIT
        trap 'exit 143' TERM
        "$@" >| "$staging" && mv -f -- "$staging" "$target"
    ) 2>/dev/null
}

# Set cache value
# Usage: cache_set <key> <value>
cache_set() {
    local key="$1"
    local value="$2"

    # Reject keys that attempt path traversal (".."). Flat keys that happen
    # to contain a single "/" (e.g. "rate_limits/1337") are legitimate file
    # names inside the flat CACHE_DIR and are allowed.
    case "$key" in
        *..*) return 1 ;;
    esac

    init_cache

    local cache_file="$CACHE_DIR/${key}"
    local cache_dirname
    cache_dirname=$(dirname "$cache_file")
    mkdir -p "$cache_dirname" 2>/dev/null
    _atomic_write_file "$cache_file" printf '%s\n' "$value"
}

# Render from a fresh reading, or return with an empty REPLY and start a
# refresh. A failed probe has its own short TTL and leaves no reading behind.
# cached_probe <key> <ttl> <failure-ttl> <module-file> <probe> [args...]
_probe_entry_exists() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ -s "$1" ]
}

# Modules run in separate subshells. Take one timestamp snapshot before they
# fork so a warm set does not need a date and a stat for each reading.
_snapshot_probe_cache() {
    local file before found=false restore_failglob=false restore_noglob=false
    local entries=()
    if shopt -q failglob; then restore_failglob=true; shopt -u failglob; fi
    case "$-" in *f*) restore_noglob=true; set +f ;; esac
    entries=("$CACHE_DIR"/*)
    if [ "$restore_failglob" = true ]; then shopt -s failglob; fi
    if [ "$restore_noglob" = true ]; then set -f; fi
    for file in "${entries[@]+"${entries[@]}"}"; do
        case "${file##*/}" in
            brightness|brightness-failed|cpu|cpu-failed|docker-*|load|load-failed|network-local-*|network_wan|network_wan-failed|node-*|npm-*|processes-*|weather|weather-*)
                if _probe_entry_exists "$file"; then found=true; break; fi ;;
        esac
    done
    [ "$found" = true ] || return 0

    before=$SECONDS
    _probe_clock=$(date +%s) || _probe_clock=
    _probe_clock_seconds=$SECONDS
    # Fall back to exact reads if the sample straddled a seconds boundary.
    if [ "$before" -ne "$_probe_clock_seconds" ] || ! [[ "$_probe_clock" =~ ^[1-9][0-9]{0,10}$ ]]; then
        _probe_clock=
        return 0
    fi
    _probe_mtimes=$'\n'$(perl -MFcntl=:mode -e '
        my ($path) = @ARGV;
        opendir(my $dir, $path) or exit 1;
        for (my $i=0; $i < 128 && defined(my $name = readdir($dir)); $i++) {
            next unless $name =~ /\A[a-zA-Z0-9_-]+\z/;
            my @entry = lstat("$path/$name");
            print "$name $entry[9]\n" if @entry && S_ISREG($entry[2]) && $entry[7];
        }
    ' "$CACHE_DIR" 2>/dev/null)$'\n' || _probe_mtimes=
}

_probe_clock='' _probe_clock_seconds='' _probe_mtimes=''
# Standalone helpers and detached workers use direct cache reads.
if [ "${FUNCNAME[1]:-}" = load_modules ] && [ -d "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ]; then
    _snapshot_probe_cache
fi

_probe_entry_fresh() {
    local file="$1" now="$2" ttl="$3" stamp marker=$'\n'"${1##*/} "
    _probe_entry_exists "$file" || return 1
    # Entries published since the snapshot and standalone callers can read
    # the mtime directly.
    if [[ "$_probe_mtimes" == *"$marker"* ]]; then
        stamp=${_probe_mtimes#*"$marker"}
        stamp=${stamp%%$'\n'*}
    elif [[ "${BASH_VERSINFO[5]}" == *-darwin* ]]; then
        stamp=$(/usr/bin/stat -f %m "$file" 2>/dev/null) || return 1
    else
        stamp=$(stat -c %Y "$file" 2>/dev/null) || return 1
    fi
    [[ "$stamp" =~ ^[1-9][0-9]{0,10}$ && "$now" =~ ^[1-9][0-9]{0,10}$ ]] &&
        [ "$now" -ge "$stamp" ] && [ "$((now - stamp))" -lt "$ttl" ]
}

cached_probe() {
    local key="$1" ttl="$2" failure_ttl="$3" module_file="$4"
    shift 4
    REPLY=
    case "$key" in ''|*[!a-zA-Z0-9_-]*) return ;; esac
    [ ! -L "$CACHE_DIR" ] || return 0

    local file="$CACHE_DIR/$key" now
    if _probe_entry_exists "$file" || _probe_entry_exists "$file-failed"; then
        if [ -n "$_probe_clock" ]; then
            now=$((_probe_clock + SECONDS - _probe_clock_seconds))
        else
            now=$(date +%s) || now=
        fi
        if _probe_entry_fresh "$file" "$now" "$ttl"; then
            # Older caches may have no trailing newline.
            IFS= read -r REPLY < "$file" || :
            [ -z "$REPLY" ] || return 0
        fi
        _probe_entry_fresh "$file-failed" "$now" "$failure_ttl" && return 0
    fi

    # Only probe arguments cross the exec boundary. Rendering config stays
    # in the caller, and the worker uses the shared atomic cache writer.
    # shellcheck disable=SC2016
    local write='
        . "$1" && . "$2" || exit 1
        CACHE_DIR=$3 key=$4
        shift 4
        value=$("$@") && [ -n "$value" ] || exit 1
        cache_set "$key" "$value"
    '
    # Perl is already used for portable descriptor locks. If detachment or
    # locking is unavailable, leave the reading absent.
    (
        umask 077
        [ ! -L "$CACHE_DIR" ] && init_cache && [ -d "$CACHE_DIR" ] || exit 1
        exec perl -MFcntl=:DEFAULT,:flock,:mode -MPOSIX=setsid,setpgid,_exit -e '
            use strict;
            use warnings;
            my ($dir, $key, $ttl, $failure_ttl, $write, $utils, $module, @probe) = @ARGV;
            defined(setsid()) or exit 1;
            sysopen(my $lock, "$dir/$key-lock", O_WRONLY|O_CREAT|O_NOFOLLOW|O_NONBLOCK, 0600)
                or exit 1;
            my @lock_stat = stat($lock);
            @lock_stat && S_ISREG($lock_stat[2]) && $lock_stat[3] == 1 &&
                -O $lock && chmod(0600, $lock) or exit 1;
            flock($lock, LOCK_EX|LOCK_NB) or exit 0;

            # Another render may have finished between our read and the lock.
            sub fresh {
                my ($path, $ttl) = @_;
                my @stat = lstat($path);
                return 0 unless @stat && S_ISREG($stat[2]) && $stat[7];
                my $age = time - $stat[9];
                return $age >= 0 && $age < $ttl;
            }
            exit 0 if fresh("$dir/$key", $ttl) || fresh("$dir/$key-failed", $failure_ttl);

            # Keep the descriptor through exec. If this supervisor is killed,
            # the probe and its watchdog still own the lock.
            fcntl($lock, F_SETFD, 0) or exit 1;
            sub bounded {
                my ($seconds, @command) = @_;
                pipe(my $stop, my $notify) or return 1;
                my $worker = fork();
                defined($worker) or return 1;
                if (!$worker) {
                    close $notify;
                    defined(setpgid(0, 0)) or _exit(1);
                    my $group = $$;
                    my $watchdog = fork();
                    defined($watchdog) or _exit(1);
                    if (!$watchdog) {
                        my $terminate = sub { kill "KILL", -$group; _exit(1) };
                        $SIG{ALRM} = $terminate;
                        alarm $seconds;
                        # A completion byte stops leftover children immediately.
                        # EOF means the supervisor died. The alarm still applies.
                        sleep($seconds + 1) unless sysread($stop, my $byte, 1);
                        $terminate->();
                    }
                    close $stop;
                    exec @command;
                    _exit(1);
                }
                close $stop;
                my $status = waitpid($worker, 0) == $worker ? $? : 1;
                # Only the watchdog signals its own group, even after the
                # worker is reaped, so a reused PID never targets another job.
                local $SIG{PIPE} = "IGNORE";
                syswrite($notify, ".");
                return $status;
            }
            my @write = ("/bin/bash", "-c", $write, "probe", $utils, $module, $dir);
            if (bounded(5, @write, $key, @probe)) {
                bounded(1, @write, "$key-failed", printf => "%s", "--");
            }
        ' "$CACHE_DIR" "$key" "$ttl" "$failure_ttl" "$write" "${BASH_SOURCE[0]}" "$module_file" "$@"
    ) </dev/null >/dev/null 2>&1 &
    return 0
}

# Clear specific cache key or all cache
# Usage: cache_clear [key]
cache_clear() {
    local key="$1"

    # Guard against empty or root paths
    if [ -z "$CACHE_DIR" ] || [ "$CACHE_DIR" = "/" ]; then
        return 1
    fi

    if [ -n "$key" ]; then
        # Reject keys that attempt path traversal ("..")
        case "$key" in
            *..*) return 1 ;;
        esac
        rm -f "$CACHE_DIR/${key}" 2>/dev/null
    else
        rm -rf "$CACHE_DIR" 2>/dev/null
    fi
}

# =============================================================================
# COLOR THEME SYSTEM
# =============================================================================
# Themes define the visual style of status indicators and icons
# Call apply_theme() after loading config to set up theme-specific values

apply_theme() {
    local theme="${COLOR_THEME:-default}"

    case "$theme" in
        minimal)
            # Subtle, understated - simple geometric shapes
            STATUS_GREEN="${STATUS_GREEN:-◦}"
            STATUS_YELLOW="${STATUS_YELLOW:-◦}"
            STATUS_ORANGE="${STATUS_ORANGE:-◦}"
            STATUS_RED="${STATUS_RED:-●}"
            # Minimal icons - simple arrows and symbols
            DIRECTORY_ICON="${DIRECTORY_ICON:-→}"
            CONTEXT_ICON="${CONTEXT_ICON:-◐}"
            GIT_ICON="${GIT_ICON:-⎇}"
            MODEL_ICON="${MODEL_ICON:-◈}"
            COST_ICON="${COST_ICON:-$}"
            TIME_DATE_ICON="${TIME_DATE_ICON:-}"
            TIME_CLOCK_ICON="${TIME_CLOCK_ICON:-}"
            BATTERY_ICON="${BATTERY_ICON:-⚡}"
            CPU_ICON="${CPU_ICON:-▪}"
            MEMORY_ICON="${MEMORY_ICON:-▫}"
            NODE_ICON="${NODE_ICON:-⬡}"
            # Minimal progress bar
            PROGRESS_BAR_FILLED="${PROGRESS_BAR_FILLED:-▪}"
            PROGRESS_BAR_EMPTY="${PROGRESS_BAR_EMPTY:-·}"
            ;;

        vibrant)
            # Bold, expressive - colorful emoji with more impact
            STATUS_GREEN="${STATUS_GREEN:-💚}"
            STATUS_YELLOW="${STATUS_YELLOW:-💛}"
            STATUS_ORANGE="${STATUS_ORANGE:-🧡}"
            STATUS_RED="${STATUS_RED:-❤️}"
            # Vibrant icons - more expressive emoji
            DIRECTORY_ICON="${DIRECTORY_ICON:-📂}"
            CONTEXT_ICON="${CONTEXT_ICON:-🎯}"
            GIT_ICON="${GIT_ICON:-🔀}"
            MODEL_ICON="${MODEL_ICON:-🧠}"
            COST_ICON="${COST_ICON:-💸}"
            TIME_DATE_ICON="${TIME_DATE_ICON:-🗓️}"
            TIME_CLOCK_ICON="${TIME_CLOCK_ICON:-⏰}"
            BATTERY_ICON="${BATTERY_ICON:-🔌}"
            CPU_ICON="${CPU_ICON:-⚙️}"
            MEMORY_ICON="${MEMORY_ICON:-💾}"
            NODE_ICON="${NODE_ICON:-💎}"
            # Vibrant progress bar
            PROGRESS_BAR_FILLED="${PROGRESS_BAR_FILLED:-▓}"
            PROGRESS_BAR_EMPTY="${PROGRESS_BAR_EMPTY:-░}"
            ;;

        monochrome)
            # No color, pure ASCII - terminal friendly
            STATUS_GREEN="${STATUS_GREEN:-[OK]}"
            STATUS_YELLOW="${STATUS_YELLOW:-[~~]}"
            STATUS_ORANGE="${STATUS_ORANGE:-[!!]}"
            STATUS_RED="${STATUS_RED:-[XX]}"
            # ASCII text labels
            DIRECTORY_ICON="${DIRECTORY_ICON:-DIR:}"
            CONTEXT_ICON="${CONTEXT_ICON:-CTX:}"
            GIT_ICON="${GIT_ICON:-GIT:}"
            MODEL_ICON="${MODEL_ICON:-AI:}"
            COST_ICON="${COST_ICON:-\$:}"
            TIME_DATE_ICON="${TIME_DATE_ICON:-}"
            TIME_CLOCK_ICON="${TIME_CLOCK_ICON:-}"
            BATTERY_ICON="${BATTERY_ICON:-BAT:}"
            CPU_ICON="${CPU_ICON:-CPU:}"
            MEMORY_ICON="${MEMORY_ICON:-MEM:}"
            NODE_ICON="${NODE_ICON:-NODE:}"
            # ASCII progress bar
            PROGRESS_BAR_FILLED="${PROGRESS_BAR_FILLED:-#}"
            PROGRESS_BAR_EMPTY="${PROGRESS_BAR_EMPTY:--}"
            # Force ASCII status style
            STATUS_STYLE="ascii"
            USE_ICONS="false"
            ;;

        nerd)
            # Nerd Font icons - requires Nerd Font installed
            STATUS_GREEN="${STATUS_GREEN:-}"
            STATUS_YELLOW="${STATUS_YELLOW:-}"
            STATUS_ORANGE="${STATUS_ORANGE:-}"
            STATUS_RED="${STATUS_RED:-}"
            # Nerd Font icons
            DIRECTORY_ICON="${DIRECTORY_ICON:-}"
            CONTEXT_ICON="${CONTEXT_ICON:-}"
            GIT_ICON="${GIT_ICON:-}"
            MODEL_ICON="${MODEL_ICON:-}"
            COST_ICON="${COST_ICON:-}"
            TIME_DATE_ICON="${TIME_DATE_ICON:-}"
            TIME_CLOCK_ICON="${TIME_CLOCK_ICON:-}"
            BATTERY_ICON="${BATTERY_ICON:-}"
            CPU_ICON="${CPU_ICON:-}"
            MEMORY_ICON="${MEMORY_ICON:-}"
            NODE_ICON="${NODE_ICON:-}"
            # Nerd Font progress bar
            PROGRESS_BAR_FILLED="${PROGRESS_BAR_FILLED:-█}"
            PROGRESS_BAR_EMPTY="${PROGRESS_BAR_EMPTY:-░}"
            ;;

        *)
            # default - Standard emoji (no changes needed, uses config defaults)
            # Status indicators use standard colored circles
            STATUS_GREEN="${STATUS_GREEN:-🟢}"
            STATUS_YELLOW="${STATUS_YELLOW:-🟡}"
            STATUS_ORANGE="${STATUS_ORANGE:-🟠}"
            STATUS_RED="${STATUS_RED:-🔴}"
            ;;
    esac
}


# Name of the icon variable apply_theme assigns for a module.
# Usage: _theme_icon_var <module>  (returns non-zero for an unknown module)
_theme_icon_var() {
    case "$1" in
        directory) printf '%s\n' DIRECTORY_ICON ;;
        context) printf '%s\n' CONTEXT_ICON ;;
        git) printf '%s\n' GIT_ICON ;;
        model) printf '%s\n' MODEL_ICON ;;
        cost) printf '%s\n' COST_ICON ;;
        time) printf '%s\n' TIME_CLOCK_ICON ;;
        battery) printf '%s\n' BATTERY_ICON ;;
        cpu) printf '%s\n' CPU_ICON ;;
        memory) printf '%s\n' MEMORY_ICON ;;
        node) printf '%s\n' NODE_ICON ;;
        *) return 1 ;;
    esac
}

# Glyph apply_theme would assign for one module when that icon variable is still unset.
# The nerd theme's defaults are empty, so this prints nothing for it.
# Usage: theme_default_icon <module> [theme]
theme_default_icon() {
    local module="$1"
    local theme="${2:-${COLOR_THEME:-default}}"
    case "$theme" in
        minimal|vibrant|monochrome)
            # Derive the glyph from apply_theme itself so the preview cannot drift
            # from the real theme table. Only the theme's unset-variable fallback
            # is wanted here, so blank the variable in a subshell first.
            local var
            var=$(_theme_icon_var "$module") || return
            (
                COLOR_THEME="$theme"
                eval "unset $var"
                apply_theme
                eval "printf '%s\\n' \"\${$var-}\""
            )
            ;;
        nerd)
            # Every nerd icon default is empty; only the status style is set.
            ;;
        *)
            local icons="${USE_ICONS:-true}"
            if [ "${USE_EMOJI:-true}" = "false" ]; then
                icons="false"
            fi
            if [ "$icons" = "false" ]; then
                case "$module" in
                    directory) printf '%s\n' "DIR:" ;;
                    context) printf '%s\n' "CTX:" ;;
                    git) printf '%s\n' "GIT:" ;;
                    model) printf '%s\n' "MODEL:" ;;
                    cost) printf '%s\n' "COST:" ;;
                    time) printf '%s\n' "TIME:" ;;
                    battery) printf '%s\n' "BAT:" ;;
                esac
            else
                case "$module" in
                    directory) printf '%s\n' "📁" ;;
                    context) printf '%s\n' "📊" ;;
                    git) printf '%s\n' "🌿" ;;
                    model) printf '%s\n' "🤖" ;;
                    cost) printf '%s\n' "💰" ;;
                    time) printf '%s\n' "🕐" ;;
                    battery) printf '%s\n' "🔋" ;;
                esac
            fi
            ;;
    esac
}

# Status glyph the preview should show for the active theme and STATUS_STYLE.
# Monochrome forces the ASCII mark even when STATUS_STYLE is still emoji.
theme_status_glyph() {
    local theme="${1:-${COLOR_THEME:-default}}"
    local style="${STATUS_STYLE:-emoji}"
    if [ "$theme" = "monochrome" ]; then
        style="ascii"
    fi
    case "$style" in
        ascii) printf '%s\n' "[OK]" ;;
        dots) printf '%s\n' "●" ;;
        *)
            case "$theme" in
                minimal) printf '%s\n' "◦" ;;
                vibrant) printf '%s\n' "💚" ;;
                *) printf '%s\n' "🟢" ;;
            esac
            ;;
    esac
}

# =============================================================================
# STATUS INDICATORS
# =============================================================================

# Resolve status-indicator glyphs according to STATUS_STYLE.
# Usage: _status_style <levels>
#   levels 3 or 4 (4 includes the orange band); the ascii yellow label follows
#   the band count: 3-level → "[WARN]", 4-level → "[MED]"
_status_style_reply() {
    local levels="${1:-3}"
    local green="${STATUS_GREEN:-🟢}"
    local yellow="${STATUS_YELLOW:-🟡}"
    local orange="${STATUS_ORANGE:-🟠}"
    local red="${STATUS_RED:-🔴}"

    case "${STATUS_STYLE:-emoji}" in
        ascii)
            green="[OK]"
            if [ "$levels" -ge 4 ] 2>/dev/null; then
                yellow="[MED]"
            else
                yellow="[WARN]"
            fi
            orange="[HIGH]"
            red="[CRIT]"
            ;;
        dots)
            green="●"
            yellow="●"
            orange="●"
            red="●"
            ;;
    esac

    if [ "$levels" -ge 4 ] 2>/dev/null; then
        REPLY="$green $yellow $orange $red"
    else
        REPLY="$green $yellow $red"
    fi
}

# Return the status indicator including its normal-mode separator.
get_status_reply() {
    local value warning critical
    safe_int_reply "$1" 0; value=$REPLY
    safe_int_reply "$2" 60; warning=$REPLY
    safe_int_reply "$3" 80; critical=$REPLY

    REPLY=
    [ "${USE_STATUS_INDICATORS:-true}" = "true" ] || return 0

    local green yellow red
    _status_style_reply 3
    IFS=$' \t\n' read -r green yellow red <<< "$REPLY"

    if [ "$value" -ge "$critical" ] 2>/dev/null; then
        REPLY=$red
    elif [ "$value" -ge "$warning" ] 2>/dev/null; then
        REPLY=$yellow
    else
        REPLY=$green
    fi
    [ "${DISPLAY_MODE:-normal}" = "compact" ] || REPLY=" $REPLY"
}

get_status() {
    get_status_reply "$@"
    echo "$REPLY"
}

# Return the green, yellow, orange or red band for rate-limit usage.
get_status_4level_reply() {
    local value low medium high
    safe_int_reply "$1" 0; value=$REPLY
    safe_int_reply "$2" 50; low=$REPLY
    safe_int_reply "$3" 75; medium=$REPLY
    safe_int_reply "$4" 95; high=$REPLY

    REPLY=
    [ "${USE_STATUS_INDICATORS:-true}" = "true" ] || return 0

    local green yellow orange red
    _status_style_reply 4
    IFS=$' \t\n' read -r green yellow orange red <<< "$REPLY"

    if [ "$value" -ge "$high" ] 2>/dev/null; then
        REPLY=$red
    elif [ "$value" -ge "$medium" ] 2>/dev/null; then
        REPLY=$orange
    elif [ "$value" -ge "$low" ] 2>/dev/null; then
        REPLY=$yellow
    else
        REPLY=$green
    fi
    [ "${DISPLAY_MODE:-normal}" = "compact" ] || REPLY=" $REPLY"
}

get_status_4level() {
    get_status_4level_reply "$@"
    echo "$REPLY"
}

# =============================================================================
# ICON HANDLING
# =============================================================================

# Get icon based on USE_ICONS setting
# Usage: get_icon <icon> <fallback_text>
get_icon_reply() {
    if [ "${USE_ICONS:-true}" = "true" ]; then
        REPLY="$1"
    else
        REPLY="${2:-}"
    fi
}

get_icon() {
    get_icon_reply "$@"
    echo "$REPLY"
}

# =============================================================================
# STRING UTILITIES
# =============================================================================

# Truncate string to max length
# Usage: truncate_string <string> <max_length>
truncate_string() {
    local str="$1"
    local max_len
    safe_int_reply "$2" 0; max_len=$REPLY

    if [ "$max_len" -gt 0 ] && [ ${#str} -gt "$max_len" ]; then
        local truncated="${str:0:$((max_len-3))}"
        echo "${truncated}..."
    else
        echo "$str"
    fi
}

# =============================================================================
# DISPLAY MODE CHECKS
# =============================================================================

# Check if in compact mode (global or module-specific)
# Usage: is_compact <module_compact_var>
is_compact() {
    local module_compact="${1:-false}"

    if [ "${DISPLAY_MODE:-normal}" = "compact" ] || [ "$module_compact" = "true" ]; then
        return 0  # true
    fi
    return 1  # false
}

# =============================================================================
# PROGRESS BAR
# =============================================================================

# Generate a progress bar
# Usage: progress_bar <percentage> [width] [filled_char] [empty_char]
progress_bar_reply() {
    local percent width
    decimal_int_reply "$1" 0; percent=$REPLY
    safe_int_reply "${2:-}" "${PROGRESS_BAR_WIDTH:-8}"; width=$REPLY
    local filled_char="${3:-${PROGRESS_BAR_FILLED:-█}}"
    local empty_char="${4:-${PROGRESS_BAR_EMPTY:-░}}"

    # Clamp percentage to 0-100
    if [ "$percent" -lt 0 ]; then percent=0; fi
    if [ "$percent" -gt 100 ]; then percent=100; fi

    # Preserve the shell diagnostic for a malformed configured width, then
    # omit the bar so the module can still show the measured percentage.
    if [ "$width" -gt 0 ]; then
        decimal_int_reply "$width" 8; width=$REPLY
    elif [ "$width" -le 0 ] 2>/dev/null; then
        width=8
    else
        REPLY=
        return 0
    fi

    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    local bar=""
    local i=0
    while [ $i -lt $filled ]; do
        bar="${bar}${filled_char}"
        i=$((i + 1))
    done
    i=0
    while [ $i -lt $empty ]; do
        bar="${bar}${empty_char}"
        i=$((i + 1))
    done

    REPLY=$bar
}

progress_bar() {
    progress_bar_reply "$@"
    echo "$REPLY"
}

# =============================================================================
# TIME FORMATTING
# =============================================================================

# Format seconds into a compact cooldown/countdown string: "1h 5m", "45m", or
# "30s" (sub-minute). Distinct from format_time_remaining, which reports
# relative units ("1d 0h", "now") and omits the seconds tier.
format_cooldown() {
    local secs
    safe_int_reply "$1" 0; secs=$REPLY

    if [ "$secs" -ge 3600 ]; then
        echo "$((secs / 3600))h$((secs % 3600 / 60))m"
    elif [ "$secs" -ge 60 ]; then
        echo "$((secs / 60))m"
    else
        echo "${secs}s"
    fi
}

# Format seconds into human-readable time (e.g., "2h 15m" or "3d 5h")
format_time_remaining() {
    local seconds
    safe_int_reply "$1" 0; seconds=$REPLY

    if [ "$seconds" -le 0 ]; then
        echo "now"
        return
    fi

    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local minutes=$(((seconds % 3600) / 60))

    if [ "$days" -gt 0 ]; then
        echo "${days}d ${hours}h"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# =============================================================================
# NUMBER FORMATTING
# =============================================================================

# Format large numbers with k/M suffix
format_number_reply() {
    local num
    safe_int_reply "$1" 0; num=$REPLY

    if [ "$num" -ge 1000000 ]; then
        REPLY="$((num / 1000000))M"
    elif [ "$num" -ge 1000 ]; then
        REPLY="$((num / 1000))k"
    else
        REPLY=$num
    fi
}

format_number() {
    format_number_reply "$@"
    echo "$REPLY"
}

# =============================================================================
# LOGGING
# =============================================================================

# Best-effort debug logging. The lock covers both the size check and append so
# concurrent refreshes cannot each rotate the same log.
log_debug() {
    [ "${DEBUG_MODE:-false}" = "true" ] || return 0
    local log_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cortado.log"
    local lock="$log_file-lock" limit=1048576
    local LC_ALL=C  # Count bytes, including for messages that contain Unicode.
    local entry size

    (
        umask 077
        # A single unusually large diagnostic still fits in one generation.
        entry="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
        entry="${entry:0:$((limit - 1))}"$'\n'

        # Keep the lock inode independent of the rotating log. The kernel
        # releases the lock when the inherited descriptor closes.
        [ ! -L "$lock" ] && { [ ! -e "$lock" ] || [ -f "$lock" ]; } || return 1
        exec 9>>"$lock" || return 1
        if command -v flock >/dev/null 2>&1; then
            flock -w 5 9
        else
            perl -MFcntl=:flock -e 'open(my $lock, ">&=9") or exit 1; alarm 5; exit(!flock($lock, LOCK_EX))'
        fi || return 1

        # Only append to a regular log. Protect logs left by older versions
        # before we append or move them into the previous generation.
        [ ! -L "$log_file" ] || return 1
        if [ -e "$log_file" ]; then
            [ -f "$log_file" ] && chmod 600 "$log_file" || return 1
            size=$(wc -c < "$log_file") || return 1
            if [ "$((size + ${#entry}))" -gt "$limit" ]; then
                [ ! -d "$log_file.1" ] && mv -f -- "$log_file" "$log_file.1" || return 1
            fi
        fi
        printf '%s' "$entry" >> "$log_file"
    ) 2>/dev/null || :
}

# =============================================================================
# JSON PARSING HELPERS
# =============================================================================

# Safely extract JSON value with default
# Usage: json_get <json> <path> [default]
# Note: Requires jq
json_get() {
    local json="$1"
    local path="$2"
    local default="${3:-}"

    if [ -z "$json" ] || [ "$json" = "null" ]; then
        echo "$default"
        return
    fi

    local value
    value=$(echo "$json" | jq -r "$path // empty" 2>/dev/null)

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Safely extract numeric JSON value
# Usage: json_get_int <json> <path> [default]
json_get_int() {
    local json="$1"
    local path="$2"
    local default="${3:-0}"

    local value
    value=$(json_get "$json" "$path" "$default")
    safe_int "$value" "$default"
}
