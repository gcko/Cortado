# shellcheck shell=bash
# =============================================================================
# Platform - the one place that decides where Cortado is running
# =============================================================================
# CORTADO_OS is darwin or linux (WSL reports linux). Anything else is
# unsupported and leaves CORTADO_OS empty, which the renderer states instead of
# running Linux code. cortado.sh resolves it once per render, after the trusted
# configs and before modules load; the untrusted project config cannot set it.
#
# The stat helpers below follow the host's real userland, not a forced
# CORTADO_OS, so forcing a platform never breaks file metadata reads.
# =============================================================================

# cortado_os_from_triple <host triple> - REPLY is darwin, linux or empty.
cortado_os_from_triple() {
    case "$1" in
        *-darwin*) REPLY=darwin ;;
        *-linux*) REPLY=linux ;;
        *) REPLY= ;;
    esac
}

# The triple bash was built for is read-only, so neither the environment nor a
# loaded config can fake it the way they can change OSTYPE.
cortado_host_os() {
    cortado_os_from_triple "${BASH_VERSINFO[5]}"
}

# Keep a forced darwin or linux (environment or trusted config). Any other
# forced value is recorded in CORTADO_OS_REFUSED and the detected host is used.
cortado_resolve_os() {
    local REPLY
    CORTADO_OS_REFUSED=
    case "${CORTADO_OS:-}" in
        darwin|linux) return 0 ;;
        '') ;;
        *) CORTADO_OS_REFUSED="$CORTADO_OS" ;;
    esac
    cortado_host_os
    CORTADO_OS="$REPLY"
}

# =============================================================================
# BSD / GNU HELPERS
# =============================================================================
# Call `/usr/bin/stat` with an absolute path on macOS so GNU coreutils
# (brew `gnubin` in PATH) cannot shadow BSD stat. GNU's `-f` means
# `--file-system`, which returns garbage and silently breaks cache age,
# rate-limit backoff and history-size math.

# _file_stat <bsd_fmt> <gnu_fmt> <file> - prints the field, or 0 on any failure.
_file_stat() {
    local fmt_bsd="$1" fmt_gnu="$2" f="$3" REPLY
    [ -e "$f" ] || { echo 0; return; }
    cortado_host_os
    if [ "$REPLY" = darwin ]; then
        /usr/bin/stat -f "$fmt_bsd" "$f" 2>/dev/null || echo 0
    else
        stat -c "$fmt_gnu" "$f" 2>/dev/null || echo 0
    fi
}

_file_mtime() {
    _file_stat %m %Y "$1"
}

# cortado_file_mode <file> - prints the octal permission bits (e.g. 600).
# Fails, printing nothing, when the mode cannot be read or is not octal.
cortado_file_mode() {
    local mode REPLY
    cortado_host_os
    if [ "$REPLY" = darwin ]; then
        mode=$(/usr/bin/stat -f %Lp "$1" 2>/dev/null) || return 1
    else
        mode=$(stat -c %a "$1" 2>/dev/null) || return 1
    fi
    case "$mode" in ''|*[!0-7]*) return 1 ;; esac
    printf '%s\n' "$mode"
}

# cortado_utc_epoch <YYYY-MM-DDTHH:MM:SS> - UTC timestamp to epoch seconds, or 0.
# BSD date needs -j -f and GNU date needs -d; try both so a GNU date earlier in
# PATH on macOS still converts.
cortado_utc_epoch() {
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$1" +%s 2>/dev/null ||
        date -u -d "$1" +%s 2>/dev/null ||
        echo 0
}
