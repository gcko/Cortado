# shellcheck shell=bash
# Discover modules from their comment headers without sourcing code for the catalog.
# Bash 3.2 uses named scalar variables for dispatch and indexed arrays for menus.

module_id_valid() {
    local LC_ALL=C
    case "$1" in
        # A leading hyphen reads as an option to echo, tr and the config CLI.
        ''|-*|*[!a-z0-9-]*|order|utils|payload) return 1 ;;
        *) return 0 ;;
    esac
}

# REPLY holds the internal lookup key for a validated module ID.
module_lookup_key() {
    module_id_valid "$1" || return 1
    REPLY="_CORTADO_MODULE_${1//-/_}"
}

read_module_headers() {
    # One process reads only the leading comment block of each candidate.
    # The arguments are ID/path pairs. Paths are opened as data, never evaluated.
    # The caller uses a command substitution, so exec avoids an extra fork.
    LC_ALL=C exec awk -v builtin_end="$1" '
        BEGIN {
            for (i = 1; i < ARGC; i += 2) {
                id = substr(ARGV[i], 4); path = ARGV[i+1]
                name = ""; enabled = "false"; args = "none"; platforms = "darwin,linux"
                category = "extra"; position = 10000; description = id; keys = ""; valid = 1
                while ((getline < path) > 0) {
                    if ($0 !~ /^[[:space:]]*(#|$)/) break
                    if ($1 != "#") continue
                    if ($2 == "@cortado-module") name = $3
                    if ($2 == "@default") {
                        if ($3 !~ /^(true|false)$/) valid = 0
                        enabled = $3
                    }
                    if ($2 == "@args") {
                        if ($3 !~ /^(none|dir|payload)$/) valid = 0
                        args = $3
                    }
                    if ($2 == "@platforms") {
                        if ($3 !~ /^(darwin|linux|darwin,linux|linux,darwin)$/) valid = 0
                        platforms = $3
                    }
                    if ($2 == "@ttl" || $2 == "@timeout-ms") {
                        if ($3 !~ /^[0-9]+$/) valid = 0
                    }
                    if ($2 == "@menu") {
                        if ($3 ~ /^(core|system|dev|extra)$/) category = $3
                        if ($4 ~ /^[0-9]+$/) position = $4 + 0
                    }
                    # An empty description keeps the ID as its label.
                    if ($2 == "@description" &&
                        sub(/^[[:space:]]*#[[:space:]]+@description[[:space:]]+/, "") && $0 != "") {
                        if ($0 !~ /[|[:cntrl:]]/) description = $0
                    }
                    if ($2 == "@config" && i <= builtin_end &&
                        $3 ~ /^[A-Z][A-Z0-9_]*:(bool|int|number|string)$/ && $3 !~ /^MODULE_/) {
                        split($3, option, ":")
                        keys = keys " " option[1]
                    }
                }
                close(path)
                if (!valid || id != name) continue
                flag = toupper(id)
                gsub(/-/, "_", flag)
                line = id "|" enabled "|" args "|" platforms "|MODULE_" flag "|" category "|" description "|" keys
                # Keep menu positions stable. Equal positions retain discovery order.
                j = count++
                while (j > 0 && positions[j-1] > position) {
                    records[j] = records[j-1]
                    positions[j] = positions[j-1]
                    j--
                }
                records[j] = line
                positions[j] = position
            }
            for (i = 0; i < count; i++) print records[i]
        }
    ' "${@:2}"
}

# Record a refused user module file for the debug log.
module_refused() {
    _CORTADO_MODULE_REFUSED_IDS="$_CORTADO_MODULE_REFUSED_IDS$1 "
    _CORTADO_MODULE_REFUSALS+=("$2:$3")
}

discover_module_registry() {
    local shipped_dir="$1" user_dir="${2:-}" apply_defaults="${3:-false}"
    local path id key target builtin_end path_var
    local records enabled args platforms flag category description keys
    local candidates=()

    # Only this discovery may bind a source path. Drop inherited or earlier ones.
    unset "${!_CORTADO_SOURCE_@}"
    _CORTADO_MODULE_CATALOG=()
    # Refusals are reported after config loads, and only in debug mode.
    _CORTADO_MODULE_REFUSALS=()
    _CORTADO_MODULE_REFUSED_IDS=' '
    _CORTADO_PROJECT_KEYS=' '
    _CORTADO_MODULE_FLAGS=' '
    _CORTADO_MODULE_IDS=' '
    for path in "$shipped_dir"/*.sh; do
        [ -f "$path" ] || continue
        id=${path##*/}
        id=${id%.sh}
        module_id_valid "$id" || continue
        candidates+=("id:$id" "$path")
    done
    builtin_end=${#candidates[@]}

    if [[ -n "$user_dir" && -d "$user_dir" ]] && type check_trusted_config >/dev/null 2>&1; then
        if [[ ! -L "$user_dir" ]] && check_trusted_config "$user_dir" module-directory 2>/dev/null; then
            user_dir="$REPLY"
            for path in "$user_dir"/*.sh; do
                [ -f "$path" ] || continue
                id=${path##*/}
                id=${id%.sh}
                module_lookup_key "$id" || continue
                local id_key="${REPLY#_CORTADO_MODULE_}"
                # Reserve installed filenames before examining user code.
                [ ! -e "$shipped_dir/$id.sh" ] || continue
                if ! check_trusted_config "$path" module 2>/dev/null; then
                    module_refused "$id" module "$path"
                    continue
                fi
                target="$REPLY"
                # Source the checked target. A link must stay inside the checked
                # directory so an external path cannot replace an ancestor.
                if [ "${target%/*}" != "$user_dir" ]; then
                    module_refused "$id" module "$path"
                    continue
                fi
                printf -v "_CORTADO_SOURCE_$id_key" '%s' "$target"
                candidates+=("id:$id" "$target")
            done
        else
            _CORTADO_MODULE_REFUSALS+=("module directory:$user_dir")
            # Read only the names, so a listed module is reported as refused.
            for path in "$user_dir"/*.sh; do
                id=${path##*/}
                id=${id%.sh}
                if module_id_valid "$id"; then
                    _CORTADO_MODULE_REFUSED_IDS="$_CORTADO_MODULE_REFUSED_IDS$id "
                fi
            done
        fi
    fi

    [ "${#candidates[@]}" -gt 0 ] || return 0
    records=$(read_module_headers "$builtin_end" "${candidates[@]}") || return 1
    [ -n "$records" ] || return 0
    while IFS='|' read -r id enabled args platforms flag category description keys; do
        module_lookup_key "$id" || continue
        key="$REPLY"
        _CORTADO_MODULE_IDS="$_CORTADO_MODULE_IDS$id "
        _CORTADO_PROJECT_KEYS="$_CORTADO_PROJECT_KEYS$keys "
        _CORTADO_MODULE_FLAGS="$_CORTADO_MODULE_FLAGS$flag "
        _CORTADO_MODULE_CATALOG+=("$id:$enabled:$category:$description")
        printf -v "$key" '%s' "$flag|$args|$platforms"
        path_var="_CORTADO_SOURCE_${key#_CORTADO_MODULE_}"
        # Install defaults before trusted config so a config can also unset a
        # flag. Honor an inherited flag for a user-installed module.
        if [ "$apply_defaults" = true ] && [[ -z "${!path_var-}" || -z "${!flag+x}" ]]; then
            printf -v "$flag" '%s' "$enabled"
        fi
    done <<< "$records"
}

registered_module_key() {
    case "$_CORTADO_MODULE_IDS" in
        *" $1 "*) module_lookup_key "$1" ;;
        *) return 1 ;;
    esac
}
