# shellcheck shell=bash
# @cortado-module version
# @default true
# @args payload
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @menu core 2
# @description Cortado version (brief)
# @config VERSION_ICON:string
# @config VERSION_SHOW_DURATION:bool
# =============================================================================
# Version Module - Shows Cortado version briefly on startup
# =============================================================================
# The display window starts when Cortado first sees a session ID. A payload
# without an ID hides the notice.
#
# Configuration options:
#   VERSION_SHOW_DURATION   - Seconds to show version for a new session (default: 120)
#   VERSION_ICON            - Icon to display (default: coffee emoji)
# =============================================================================

_version_session_start() {
    # The lock covers the read, LRU update, and atomic cache_set publication.
    # shellcheck disable=SC2016
    local cache_action='
        . "$1" || exit 1
        CACHE_DIR=$2
        if [ "$#" -eq 2 ]; then init_cache; else cache_set version_sessions "$3"; fi
    '
    perl -MFcntl=:DEFAULT,:flock,:mode -MJSON::PP -e "${_probe_lock_source:-}" -e '
        my ($dir, $id, $now, $action, $utils) = @ARGV;
        utf8::decode($id) or exit 1;
        umask 077;
        unless (private_dir($dir)) {
            exit 1 if -l $dir || (-e $dir && (!-d $dir || !-O $dir));
            system("/bin/bash", "-c", $action, "version-cache", $utils, $dir) == 0
                && private_dir($dir) or exit 1;
        }
        my $lock = cache_lock("$dir/version_sessions-lock") or exit 1;
        alarm 5;
        flock($lock, LOCK_EX) or exit 1;
        alarm 0;

        my $sessions;
        my $path = "$dir/version_sessions";
        my $file;
        if (sysopen($file, $path, O_RDONLY|O_NOFOLLOW|O_NONBLOCK) &&
            S_ISREG((stat($file))[2])) {
            local $/;
            $sessions = eval { JSON::PP::decode_json(<$file>) };
        }
        $sessions = [] unless ref($sessions) eq "ARRAY";
        my @records = grep { ref($_) eq "HASH" } @$sessions;
        my $matches = sub { defined $_[0]->{id} && !ref($_[0]->{id}) && $_[0]->{id} eq $id };
        my ($session) = grep { $matches->($_) } @records;
        $session ||= { id => $id, first_seen => 0 + $now };
        my @updated = ($session, grep { !$matches->($_) } @records);
        splice(@updated, 32) if @updated > 32;
        if (@updated != @$sessions || $updated[0] != $sessions->[0]) {
            fcntl($lock, F_SETFD, 0) or exit 1;
            system("/bin/bash", "-c", $action, "version-cache", $utils, $dir,
                JSON::PP::encode_json(\@updated)) == 0 or exit 1;
        }
        print $session->{first_seen} // "";
    ' -- "$CACHE_DIR" "$1" "$2" "$cache_action" "${BASH_SOURCE[0]%version.sh}utils.sh" 2>/dev/null
}

module_version() {
    local show_duration="${VERSION_SHOW_DURATION:-120}"
    case "$show_duration" in
        *[!0-9]*) show_duration=120 ;;
    esac
    [ "$show_duration" -ge 0 ] 2>/dev/null || show_duration=120
    [ "$show_duration" -gt 0 ] || return 0

    if [ "${CTX_READY:-}" != true ]; then
        with_payload_context module_version <<< "${1:-}"
        return
    fi
    local session_id="${CTX_SESSION_ID:-}"
    [ -n "$session_id" ] || return 0

    local now session_start
    now=$(date +%s)
    [[ "$now" =~ ^[1-9][0-9]*$ ]] || return 0
    session_start=$(_version_session_start "$session_id" "$now") || return 0
    [[ "$session_start" =~ ^[1-9][0-9]*$ ]] || return 0

    local elapsed=$((now - session_start))
    [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$show_duration" ] || return 0

    local version=""
    local version_file="$SCRIPT_DIR/VERSION"
    if [ -f "$version_file" ]; then
        version=$(< "$version_file")
        version=${version//[[:space:]]/}
    fi

    if [ -z "$version" ]; then
        return
    fi

    local icon
    get_icon_reply "${VERSION_ICON:-☕}" "Cortado"; icon=$REPLY
    echo "${icon} v${version}"
}
