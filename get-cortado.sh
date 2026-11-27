#!/bin/bash
# =============================================================================
# get-cortado.sh - Install a Cortado release without git or Homebrew
# =============================================================================
# Downloads a published gcko/Cortado release, checks Cortado-source.zip against
# the release's SHA256SUMS, and only then runs the install.sh inside it.
#
# Usage:
#   bash get-cortado.sh [VERSION] [INSTALLER OPTIONS]
#
#   VERSION            A release such as 2.1.0 (default: the latest release)
#   --defaults         Install the core modules without questions
#   --minimal          Install a minimal set of modules
#   --force            Same as --defaults, no confirmation prompts
#   --no-emoji         No emoji in the installer or the generated config
#   --no-color         No colours in the installer output
#   -h, --help         Show this help
#
# Read it before you run it. It never pipes anything into a shell, and runs
# nothing from outside the verified release (its install.sh, and the files that
# installer loads from the same verified zip).
# Needs: curl, unzip, jq, and shasum or sha256sum. Bash 3.2 or newer.
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "get-cortado: run this with bash: bash get-cortado.sh" >&2
    exit 1
fi

REPO="gcko/Cortado"
API="https://api.github.com/repos/$REPO/releases"
DOWNLOAD="https://github.com/$REPO/releases/download"
ARCHIVE="Cortado-source.zip"
# Size caps in bytes: release metadata, the checksum list, the source zip.
API_CAP=1048576
SUMS_CAP=65536
ZIP_CAP=20971520

say() { printf '%s\n' "$*"; }
die() { printf 'get-cortado: %s\n' "$*" >&2; exit 1; }

usage() {
    say "Usage: bash get-cortado.sh [VERSION] [--defaults|--minimal|--force] [--no-emoji] [--no-color]"
    say "Installs the latest Cortado release (or VERSION, such as 2.1.0) after checking"
    say "$ARCHIVE against the release's SHA256SUMS."
}

# --- arguments: everything is checked before anything is downloaded -----------
VERSION=""
INSTALL_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --defaults|--minimal|--force|--no-emoji|--no-color)
            INSTALL_ARGS[${#INSTALL_ARGS[@]}]="$1"
            ;;
        -*)
            die "$1 is not an installer option get-cortado.sh passes on. Run: bash get-cortado.sh --help"
            ;;
        *)
            [ -z "$VERSION" ] || die "Only one version can be given."
            version_re='^v?[0-9]+\.[0-9]+\.[0-9]+$'
            [[ "$1" =~ $version_re ]] || die "Not a release version: '$1'. Give one like 2.1.0."
            VERSION="${1#v}"
            ;;
    esac
    shift
done

# --- tools -----------------------------------------------------------------------
for tool in curl unzip jq; do
    command -v "$tool" >/dev/null 2>&1 || die "Cortado's installer needs $tool. Install it and run this again."
done
if command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 < "$1"; }
elif command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum < "$1"; }
else
    die "Checking the download needs shasum or sha256sum. Install one and run this again."
fi

# --- a private temp dir, removed on exit and on INT, TERM and HUP ----------------
WORK=""
# shellcheck disable=SC2329 # Run by the EXIT trap.
cleanup() {
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        chmod -R u+rwX "$WORK" 2>/dev/null
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
tmp_parent="${TMPDIR:-/tmp}"
# mktemp -d creates the directory readable only by you.
WORK=$(mktemp -d "${tmp_parent%/}/get-cortado.XXXXXX") || die "Could not create a temporary directory."

# fetch <url> <dest> <cap> <label>: one HTTPS request with install.sh's timeouts.
fetch() {
    local url="$1" dest="$2" cap="$3" label="$4" status size
    local opts=(--max-time 60)
    case "$url" in "$API"/*) opts=(--max-time 8 -H "Accept: application/vnd.github+json") ;; esac
    curl -q -fsL --connect-timeout 5 "${opts[@]}" --max-redirs 3 \
        --proto =https --proto-redir =https --max-filesize "$cap" \
        -o "$dest" "$url" 2>/dev/null
    status=$?
    case "$status" in
        0) ;;
        28) die "Download timed out for $label." ;;
        63) die "$label is too large (over $cap bytes). Nothing was installed." ;;
        *) die "Could not download $label (curl exit $status). Nothing was installed." ;;
    esac
    # curl cannot hold the cap when the server announces no length.
    size=$(wc -c < "$dest" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) die "Could not read the size of $label." ;; esac
    [ "$size" -le "$cap" ] || die "$label is too large (over $cap bytes). Nothing was installed."
}

# --- which release ------------------------------------------------------------------
if [ -n "$VERSION" ]; then
    want_tag="v$VERSION"
    release_url="$API/tags/$want_tag"
    say "Looking up Cortado $want_tag..."
else
    want_tag=""
    release_url="$API/latest"
    say "Looking up the latest Cortado release..."
fi
fetch "$release_url" "$WORK/release.json" "$API_CAP" "the release information"

# The response is untrusted: one JSON object, published (not a draft, not a
# prerelease), with a vX.Y.Z tag. Only that validated tag is used afterwards.
tag=$(jq -ers '
    select(length == 1) | .[0] | objects
    | select(.draft == false and .prerelease == false)
    | .tag_name | strings
' "$WORK/release.json" 2>/dev/null)
published=$?
if [ "$published" -ne 0 ]; then
    if jq -es 'length == 1 and (.[0] | type == "object" and .draft == false and .prerelease == false)' \
        "$WORK/release.json" >/dev/null 2>&1; then
        die "Unexpected release tag from GitHub. Nothing was installed."
    fi
    die "GitHub did not return a published release (not a draft or prerelease). Nothing was installed."
fi
tag_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
if ! [[ "$tag" =~ $tag_re ]] || { [ -n "$want_tag" ] && [ "$tag" != "$want_tag" ]; }; then
    die "Unexpected release tag from GitHub. Nothing was installed."
fi
release_version="${tag#v}"
say "Found Cortado $tag on github.com/$REPO."

# --- download and verify --------------------------------------------------------------
say "Downloading SHA256SUMS and $ARCHIVE..."
fetch "$DOWNLOAD/$tag/SHA256SUMS" "$WORK/SHA256SUMS" "$SUMS_CAP" "SHA256SUMS"
# The same parser install.sh --update uses: exactly one well-formed line for the zip.
if ! expected=$(awk -v archive="$ARCHIVE" '
    $2 == archive || $2 == "*" archive {
        count++
        if (NF == 2 && length($1) == 64 && $1 !~ /[^0-9A-Fa-f]/)
            digest = tolower($1)
    }
    END {
        if (count != 1 || digest == "") exit 1
        print digest
    }
' "$WORK/SHA256SUMS" 2>/dev/null); then
    die "SHA256SUMS must contain one valid checksum for $ARCHIVE. Nothing was installed."
fi

fetch "$DOWNLOAD/$tag/$ARCHIVE" "$WORK/$ARCHIVE" "$ZIP_CAP" "$ARCHIVE"
actual=$(sha256 "$WORK/$ARCHIVE" 2>/dev/null) || die "Could not compute the SHA-256 of $ARCHIVE."
actual=$(printf '%s' "${actual%% *}" | tr '[:upper:]' '[:lower:]')
if [ "${#actual}" -ne 64 ] || [ "$actual" != "$expected" ]; then
    die "Checksum mismatch for $ARCHIVE. It was not unpacked and nothing was installed."
fi
say "Checksum OK ($ARCHIVE matches SHA256SUMS)."

# --- unpack the verified zip and run its installer -----------------------------------------
mkdir "$WORK/src" || die "Could not create $WORK/src."
if ! unzip -q "$WORK/$ARCHIVE" -d "$WORK/src" < /dev/null > /dev/null 2>&1; then
    die "The download is not a valid ZIP archive or could not be extracted. Nothing was installed."
fi
src="$WORK/src/Cortado-$release_version"
if [ ! -f "$src/install.sh" ] || [ ! -f "$src/cortado.sh" ] || [ ! -f "$src/VERSION" ]; then
    die "The archive is missing essential files. Nothing was installed."
fi
archive_version=$(tr -d '[:space:]' < "$src/VERSION")
if [ "$archive_version" != "$release_version" ]; then
    die "Archive VERSION ($archive_version) does not match release $release_version. Nothing was installed."
fi

say "Running the installer from Cortado $tag..."
say ""
# A child, not exec, so the temp dir is removed afterwards. The release is
# already chosen, so the installer's own update check is skipped.
"${BASH:-bash}" "$src/install.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"} --skip-update-check
exit $?
