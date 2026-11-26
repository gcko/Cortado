#!/bin/bash
# ABOUTME: Exercise the command saved by the installer through sh, with a
# ABOUTME: sandboxed config, and verify backup and restore preserve it.

umask 077
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh" indented-unquoted
# shellcheck source=tests/lib/sections.sh
. "$REPO_ROOT/tests/lib/sections.sh"

# Each section installs into its own config directories and spends its time
# running the installer, so a full run starts each one as its own copy of this
# suite in INSTALL_TEST_JOBS lanes (default 4), slowest first.
section="${INSTALL_TEST_SECTION:-all}"
if [ "$section" = all ]; then
    run_sections INSTALL_TEST_SECTION "${INSTALL_TEST_JOBS:-4}" "${BASH_SOURCE[0]}" \
        faults-settings invalid reinstall faults-probe sample fresh generation restore backup publish
fi

TEST_BASE=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_BASE"' EXIT
export HOME="$TEST_BASE/home"
export CORTADO_PATH_TEST="expanded"
mkdir -p "$HOME"
run_installer() {
    local config_dir="$1"
    shift
    local bash_options=()
    if [ "${INSTALLER_XPG_ECHO:-}" = "true" ]; then
        bash_options=(-O xpg_echo)
    fi
    CLAUDE_CONFIG_DIR="$config_dir" CACHE_DIR="$config_dir/cortado-cache" \
        /bin/bash "${bash_options[@]}" "${INSTALLER_TREE:-$REPO_ROOT}/install.sh" --skip-update-check --no-color --no-emoji "$@"
}

install_minimal() {
    local config_dir="$1"
    if ! run_installer "$config_dir" --minimal > "$TEST_BASE/install.log" 2>&1; then
        fail "install completes in ${config_dir##*/}"
        cat "$TEST_BASE/install.log"
        return 1
    fi
}

assert_statusline_runs() {
    local desc="$1" settings="$2" cmd output render_dir
    local payload='{"workspace":{"current_dir":"/"},"model":{"display_name":"Opus[1m]"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'
    if ! cmd=$(jq -er '.statusLine.command' "$settings"); then
        fail "$desc (no saved command)"
        return
    fi
    render_dir=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
    if output=$(cd / && printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$render_dir" \
        CACHE_DIR="$render_dir/cortado-cache" TERMINAL_WIDTH=200 /bin/sh -c "$cmd" 2>"$render_dir/stderr"); then
        case "$output" in
            *"25%"*"MODEL: Opus[1m]"*)
                pass "$desc"
                return
                ;;
        esac
    fi
    fail "$desc"
    printf '    stdout: %s\n' "$output"
    if [ -s "$render_dir/stderr" ]; then
        printf '    stderr:\n'
        cat "$render_dir/stderr"
    fi
}

fresh_install() {
    local name="$1" config_dir="$TEST_BASE/$1"
    install_minimal "$config_dir"
    assert_eq "fresh install sets the statusLine type [$name]" "command" \
        "$(jq -r '.statusLine.type' "$config_dir/settings.json")"
    assert_statusline_runs "fresh install renders through sh [$name]" "$config_dir/settings.json"
}

quoted_home="$TEST_BASE/quote\"home"
mkdir -p "$quoted_home" || exit 1
old_settings='{"statusLine":{"type":"command","command":"old-command","padding":4},"other":true}'

if section_is fresh; then
    # The restore section installs 'with space' itself, then reinstalls over it.
    for name in "apostrophe's" 'double"quote' "literal\$CORTADO_PATH_TEST" 'literal`tick'; do
        fresh_install "$name"
    done

    relative_dir='rel space'
    if (cd "$TEST_BASE" && install_minimal "$relative_dir"); then
        assert_statusline_runs 'relative config saves a statusline command runnable from /' \
            "$TEST_BASE/$relative_dir/settings.json"
    else
        fail 'relative config installs successfully'
    fi

    launch_dir="$TEST_BASE/removable launch"
    mkdir "$launch_dir" || exit 1
    if (cd "$launch_dir" && install_minimal ../sibling-config); then
        rmdir "$launch_dir" || exit 1
        assert_statusline_runs 'sibling config command survives removal of the launch directory' \
            "$TEST_BASE/sibling-config/settings.json"
    else
        fail 'sibling config installs successfully'
    fi

    linked_config="$TEST_BASE/linked-config"
    physical_config="$TEST_BASE/physical-config"
    mkdir "$physical_config" || exit 1
    ln -s "$physical_config" "$linked_config" || exit 1
    if install_minimal "$linked_config"; then
        rm "$linked_config" || exit 1
        assert_statusline_runs 'saved command follows the physical directory after the config symlink is removed' \
            "$physical_config/settings.json"
    fi
fi

if section_is sample; then
    HOME="$quoted_home" install_minimal "$TEST_BASE/quoted home"
    assert_file_contains 'self-test renders the quoted HOME directory' 'DIR: quote"home' "$TEST_BASE/install.log"
    assert_file_contains 'self-test renders the sample model with a quoted HOME' 'MODEL: Test' "$TEST_BASE/install.log"
    assert_not_contains 'fresh install with no restore point has no backup publication warning' \
        'Could not replace the backup manifest' "$(cat "$TEST_BASE/install.log")"

    for display in full-path short-directory wrap narrow-truncation; do
        config_dir=$(mktemp -d "$TEST_BASE/$display.XXXXXX") || exit 1
        case "$display" in
            full-path) HOME="$quoted_home" DIRECTORY_SHOW_FULL_PATH=true install_minimal "$config_dir" ;;
            short-directory) HOME="$quoted_home" DIRECTORY_MAX_LENGTH=5 install_minimal "$config_dir" ;;
            wrap) LAYOUT_MODE=wrap install_minimal "$config_dir" ;;
            narrow-truncation) LAYOUT_MODE=truncate TERMINAL_WIDTH=25 install_minimal "$config_dir" ;;
        esac
        assert_file_contains "sample passes under $display display settings" 'Statusline test passed!' "$TEST_BASE/install.log"
    done

    error_name_home="$TEST_BASE/syntax error"
    mkdir "$error_name_home" || exit 1
    HOME="$error_name_home" install_minimal "$TEST_BASE/error name"
    assert_file_contains 'shell diagnostic words are allowed in the sample directory name' \
        'DIR: syntax error' "$TEST_BASE/install.log"

    config_dir="$TEST_BASE/directory-disabled"
    mkdir "$config_dir" || exit 1
    printf '%s\n' 'MODULE_DIRECTORY="false"' > "$config_dir/cortado.conf" || exit 1
    chmod 600 "$config_dir/cortado.conf" || exit 1
    install_minimal "$config_dir"
    assert_file_contains 'user config can hide the directory in the sample' 'MODEL: Test' "$TEST_BASE/install.log"
    assert_not_contains 'sample honors the disabled directory' 'DIR: home' "$(cat "$TEST_BASE/install.log")"

    project_home="$TEST_BASE/project-disabled"
    mkdir "$project_home" || exit 1
    printf '%s\n' 'MODULE_DIRECTORY="false"' > "$project_home/.cortado.conf" || exit 1
    chmod 600 "$project_home/.cortado.conf" || exit 1
    HOME="$project_home" install_minimal "$TEST_BASE/project-disabled-config"
    assert_file_contains 'directory verification tolerates a project-level disable' 'MODEL: Test' "$TEST_BASE/install.log"
    assert_not_contains 'sample honors the project-level disable' 'DIR: project-disabled' "$(cat "$TEST_BASE/install.log")"
fi

assert_install_failure() {
    local desc="$1" config_dir="$2" diagnostic="$3" output
    if output=$(run_installer "$config_dir" --minimal 2>&1); then
        fail "$desc exits non-zero"
    else
        pass "$desc exits non-zero"
    fi
    assert_contains "$desc explains the failure" "$diagnostic" "$output"
    assert_not_contains "$desc does not report a settings update" 'Updated settings.json' "$output"
    assert_not_contains "$desc does not report settings creation" 'Created settings.json' "$output"
    assert_not_contains "$desc does not report installation complete" 'Installation Complete!' "$output"
    case "$diagnostic" in
        *'Statusline test'*|*'statusline test'*)
            assert_not_contains "$desc does not approve the sample" 'Statusline test passed!' "$output"
            ;;
    esac
    assert_empty "$desc cleans up staged settings" "$(find "$config_dir" -name '.settings.*')"
}

# Inject failures at the tool boundary so the real installer handles the
# exit status, empty output or bad candidate file.
fault_bin="$TEST_BASE/fault-bin"
mkdir "$fault_bin" || exit 1
FAULT_REAL_JQ=$(type -P jq) || exit 1
FAULT_STAGE_DIR=$(mktemp -d "$TEST_BASE/stage-fault.XXXXXX") || exit 1
FAULT_ERRORS_FILE=$(mktemp "$TEST_BASE/errors-fault.XXXXXX") || exit 1
FAULT_BACKUP_DIR=$(mktemp -d "$TEST_BASE/backup-fault.XXXXXX") || exit 1
export FAULT_REAL_JQ FAULT_STAGE_DIR FAULT_ERRORS_FILE FAULT_BACKUP_DIR
cat > "$fault_bin/jq" <<'SH'
#!/bin/bash
case "$1 ${2:-} ${3:-}" in
    '-nc --arg dir')
        if [ "$INSTALLER_TEST_FAULT" = payload ]; then
            "$FAULT_REAL_JQ" "$@"
            exit 1
        fi
        ;;
    '-nr --arg path')
        if [ "$INSTALLER_TEST_FAULT" = quote ]; then
            "$FAULT_REAL_JQ" "$@"
            exit 1
        fi
        ;;
    '-s --arg command')
        case "$INSTALLER_TEST_FAULT" in
            incomplete) printf '%s\n' '{"other":true}'; exit 0 ;;
            wrong-command) printf '%s\n' '{"statusLine":{"type":"command","command":"other"}}'; exit 0 ;;
            wrong-type)
                exec "$FAULT_REAL_JQ" -n --arg command "$4" '{statusLine:{type:"other",command:$command}}'
                ;;
            multiple-candidates) "$FAULT_REAL_JQ" "$@"; exec "$FAULT_REAL_JQ" "$@" ;;
            writer) "$FAULT_REAL_JQ" "$@"; exit 1 ;;
        esac
        ;;
    '--argjson config '*)
        if [ "$INSTALLER_TEST_FAULT" = backup-statusline ]; then
            "$FAULT_REAL_JQ" "$@"
            exit 1
        fi
        ;;
    '--arg path '*)
        case "$INSTALLER_TEST_FAULT:$3" in
            backup-modular-json:*/snapshot.*/cortado|backup-single-json:*/snapshot.*/cortado.sh)
                "$FAULT_REAL_JQ" "$@"
                exit 1
                ;;
        esac
        ;;
esac
exec "$FAULT_REAL_JQ" "$@"
SH
cat > "$fault_bin/mv" <<'SH'
#!/bin/bash
case "${2:-}" in
    */.cortado-install.*/previous/cortado) ;;
    */.cortado-install.*/cortado)
        if [ "$INSTALLER_TEST_FAULT" = promote ]; then exit 1; fi
        ;;
    */.settings.*/settings.json)
        case "$INSTALLER_TEST_FAULT" in
            rename) exit 1 ;;
            rename-directory) mkdir "$CLAUDE_CONFIG_DIR/settings.json" || exit 1 ;;
        esac
        ;;
    */snapshot.*/manifest.json)
        case "$INSTALLER_TEST_FAULT" in
            backup-publish) exit 1 ;;
            backup-publish-directory) mkdir "$CLAUDE_CONFIG_DIR/.cortado-backup/manifest.json" || exit 1 ;;
        esac
        ;;
esac
exec /bin/mv "$@"
SH
cat > "$fault_bin/mkdir" <<'SH'
#!/bin/bash
case "$INSTALLER_TEST_FAULT:${2:-}" in
    backup-mkdir:*/.cortado-backup) /bin/mkdir "$@"; exit 1 ;;
esac
exec /bin/mkdir "$@"
SH
cat > "$fault_bin/cp" <<'SH'
#!/bin/bash
case "$INSTALLER_TEST_FAULT:${!#}" in
    backup-modular:*/snapshot.*/cortado|backup-single:*/snapshot.*/cortado.sh)
        /bin/cp "$@"
        exit 1
        ;;
esac
exec /bin/cp "$@"
SH
cat > "$fault_bin/stat" <<'SH'
#!/bin/bash
case "$INSTALLER_TEST_FAULT:${3:-}" in
    config-metadata:*/cortado/cortado.conf) exit 1 ;;
esac
exec /usr/bin/stat "$@"
SH
cat > "$fault_bin/basename" <<'SH'
#!/bin/bash
case "$INSTALLER_TEST_FAULT" in
    directory) [ "$1" != "$HOME" ] || exit 1 ;;
    empty-directory)
        if [ "$1" = "$HOME" ] || [ "${2:-}" = "$HOME" ]; then
            exit 0
        fi
        ;;
    expected-basename)
        if [ "$1" = -- ] && [ "${2:-}" = "$HOME" ]; then
            /usr/bin/basename "$@"
            exit 1
        fi
        ;;
esac
exec /usr/bin/basename "$@"
SH
cat > "$fault_bin/mktemp" <<'SH'
#!/bin/bash
if [ "$#" -eq 1 ] && [ "$1" = -d ]; then
    case "$INSTALLER_TEST_FAULT" in
        probe-temp) printf '%s\n' "$FAULT_PROBE_DIR"; exit 1 ;;
        probe-renderer|probe-mode) printf '%s\n' "$FAULT_PROBE_DIR"; exit 0 ;;
    esac
fi
case "${2:-}" in
    */.settings.*)
        if [ "$INSTALLER_TEST_FAULT" = stage ]; then
            printf '%s\n' "$FAULT_STAGE_DIR"
            exit 1
        fi
        ;;
    */.cortado-backup/snapshot.*)
        if [ "$INSTALLER_TEST_FAULT" = backup-temp ]; then
            printf '%s\n' "$FAULT_BACKUP_DIR"
            exit 1
        fi
        ;;
esac
case "$INSTALLER_TEST_FAULT:$1" in
    diagnostic-temp:*/cortado-test.*) printf '%s\n' "$FAULT_ERRORS_FILE"; exit 1 ;;
    diagnostic-cleanup:*/cortado-test.*) printf '%s\n' "$FAULT_ERRORS_FILE"; exit 0 ;;
esac
exec /usr/bin/mktemp "$@"
SH
chmod +x "$fault_bin/"* || exit 1

# Bash reads this hook only in the fault cases below. Preserve valid output
# while failing the operation so each exit-status check has its own regression.
cat > "$TEST_BASE/fault-env" <<'SH'
case "$INSTALLER_TEST_FAULT" in
    generate|generate-header|missing-generated|symlink-generated)
        cat() {
            command cat "$@" || return
            if [ "$#" -eq 0 ] && [ -n "${config_file:-}" ]; then
                generator_calls=$(( ${generator_calls:-0} + 1 ))
                case "$INSTALLER_TEST_FAULT:$generator_calls" in
                    generate:2|generate-header:1) return 7 ;;
                    missing-generated:2) rm -f -- "$config_file" || return ;;
                    symlink-generated:2)
                        mv -- "$config_file" "$config_file.body" &&
                            ln -s cortado.conf.body "$config_file" || return
                        ;;
                esac
            fi
        }
        ;;
    generate-write)
        echo() {
            builtin echo "$@" || return
            if [ -n "${config_file:-}" ] && [ "$1" = '# Global Settings' ]; then return 7; fi
        }
        ;;
    physical-path)
        pwd() {
            builtin pwd "$@" || return
            case "${1:-}:$PWD" in -P:*/fault-physical-path) return 1 ;; esac
        }
        ;;
    backup-manifest)
        printf() {
            builtin printf "$@" || return
            case "${2:-}" in *'"type": "file"'*) return 1 ;; esac
        }
        ;;
    probe-config)
        printf() {
            builtin printf "$@" || return
            [ "${2:-}" != 'MODULE_ORDER=directory' ]
        }
        ;;
    probe-renderer)
        if [ "$CLAUDE_CONFIG_DIR" = "$FAULT_PROBE_DIR" ]; then
            printf 'Dir: %s\n' "${HOME##*/}"
            exit 7
        fi
        ;;
    probe-mode)
        if [ "$CLAUDE_CONFIG_DIR" = "$FAULT_PROBE_DIR" ]; then
            LC_ALL=C ls -ld "$CLAUDE_CONFIG_DIR/cortado.conf" > "$FAULT_MODE_LOG"
        fi
        ;;
esac
SH

fault_case() {
    local fault="$1" config_dir="$TEST_BASE/fault-$1" diagnostic
    mkdir "$config_dir" || exit 1
    printf '%s\n' "$old_settings" > "$config_dir/settings.json" || exit 1
    cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
    case "$fault" in
        stage) diagnostic='Could not stage settings.json' ;;
        writer) diagnostic='Could not prepare settings.json' ;;
        incomplete|wrong-command|wrong-type|multiple-candidates) diagnostic='Could not verify statusLine' ;;
        rename) diagnostic='Could not replace settings.json' ;;
        payload|quote) diagnostic='Could not prepare statusline test' ;;
        *directory|expected-basename|probe-*) diagnostic='Statusline test FAILED - sample directory missing' ;;
        physical-path) diagnostic='Could not resolve the installed directory' ;;
        diagnostic-temp) diagnostic='Could not capture statusline test diagnostics' ;;
    esac
    FAULT_PROBE_DIR=$(mktemp -d "$TEST_BASE/probe-fault.XXXXXX") || exit 1
    export FAULT_PROBE_DIR
    PATH="$fault_bin:$PATH" HOME="$quoted_home" INSTALLER_TEST_FAULT="$fault" \
        BASH_ENV="$TEST_BASE/fault-env" assert_install_failure "$fault failure" "$config_dir" "$diagnostic"
    assert_rc "$fault failure keeps original settings bytes" 0 cmp -s \
        "$TEST_BASE/previous-settings" "$config_dir/settings.json"
    assert_eq "$fault failure keeps the complete statusLine backup" \
        '{"type":"command","command":"old-command","padding":4}' \
        "$(jq -c '.settings_statusline' "$config_dir/.cortado-backup/manifest.json")"
    if [ "$fault" = probe-renderer ]; then
        assert_rc 'failed directory probe cleans up its sandbox' 1 test -e "$FAULT_PROBE_DIR"
    fi
}

if section_is faults-settings; then
    for fault in stage writer incomplete wrong-command wrong-type multiple-candidates rename payload quote; do
        fault_case "$fault"
    done
fi

if section_is faults-probe; then
    for fault in directory empty-directory expected-basename probe-temp probe-config probe-renderer physical-path \
        diagnostic-temp; do
        fault_case "$fault"
    done
fi

if section_is invalid; then
    for invalid in empty whitespace null zero multiple; do
        case "$invalid" in
            empty) content='' ;;
            whitespace) content=$' \n\t' ;;
            null) content='null' ;;
            zero) content='0' ;;
            multiple) content=$'{}\n{}' ;;
        esac
        config_dir=$(mktemp -d "$TEST_BASE/invalid.XXXXXX") || exit 1
        printf '%s' "$content" > "$config_dir/settings.json" || exit 1
        cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
        assert_install_failure "$invalid settings" "$config_dir" 'Could not prepare settings.json'
        assert_rc "$invalid settings stay byte-identical" 0 cmp -s \
            "$TEST_BASE/previous-settings" "$config_dir/settings.json"
    done

    config_dir="$TEST_BASE/dangling-settings"
    mkdir "$config_dir" || exit 1
    ln -s "$TEST_BASE/missing-settings.json" "$config_dir/settings.json" || exit 1
    assert_install_failure 'settings path with a missing symlink target' "$config_dir" 'Could not prepare settings.json'
    assert_eq 'failed install keeps the original settings symlink' "$TEST_BASE/missing-settings.json" \
        "$(readlink "$config_dir/settings.json")"

    config_dir="$TEST_BASE/fifo-settings"
    mkdir "$config_dir" || exit 1
    mkfifo "$config_dir/settings.json" || exit 1
    assert_install_failure 'settings path is a FIFO' "$config_dir" 'Could not prepare settings.json'
    assert_rc 'failed install keeps the original settings FIFO' 0 test -p "$config_dir/settings.json"

    config_dir="$TEST_BASE/read-only"
    mkdir -p "$config_dir/cortado" "$config_dir/.cortado-backup" || exit 1
    printf '%s\n' "$old_settings" > "$config_dir/settings.json" || exit 1
    cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
    chmod 500 "$config_dir" || exit 1
    if [ ! -w "$config_dir" ]; then
        assert_install_failure 'read-only config directory' "$config_dir" 'Could not stage Cortado runtime'
        assert_rc 'read-only config keeps the original settings bytes' 0 cmp -s \
            "$TEST_BASE/previous-settings" "$config_dir/settings.json"
        assert_eq 'read-only config keeps the complete statusLine backup' \
            '{"type":"command","command":"old-command","padding":4}' \
            "$(jq -c '.settings_statusline' "$config_dir/.cortado-backup/manifest.json")"
    else
        printf '  SKIP: current user can write to a chmod 500 directory\n'
    fi
    chmod 700 "$config_dir" || exit 1

    config_dir=$(mktemp -d "$TEST_BASE/rename-target.XXXXXX") || exit 1
    PATH="$fault_bin:$PATH" INSTALLER_TEST_FAULT=rename-directory \
        assert_install_failure 'directory appearing at the settings destination' "$config_dir" 'Could not replace settings.json'
    assert_rc 'rename fixture presents a directory at settings.json' 0 test -d "$config_dir/settings.json"
    assert_rc 'failed publication leaves no nested settings file' 1 test -e "$config_dir/settings.json/settings.json"

    config_dir=$(mktemp -d "$TEST_BASE/settings-mode.XXXXXX") || exit 1
    (umask 022; install_minimal "$config_dir")
    assert_match 'settings mode is 0600 under umask 022' '^-rw-------' \
        "$(LC_ALL=C ls -ld "$config_dir/settings.json")"

    FAULT_PROBE_DIR=$(mktemp -d "$TEST_BASE/probe-mode.XXXXXX") || exit 1
    FAULT_MODE_LOG="$TEST_BASE/probe-mode.log"
    export FAULT_PROBE_DIR FAULT_MODE_LOG
    config_dir=$(mktemp -d "$TEST_BASE/probe-driver.XXXXXX") || exit 1
    if (
        umask 002
        export CLAUDE_CONFIG_DIR="$config_dir" CACHE_DIR="$config_dir/cortado-cache"
        # shellcheck source=install.sh
        . "$REPO_ROOT/install.sh"
        payload=$(statusline_test_payload "$HOME") || exit 1
        PATH="$fault_bin:$PATH" INSTALLER_TEST_FAULT=probe-mode BASH_ENV="$TEST_BASE/fault-env" \
            test_statusline_directory "$REPO_ROOT/cortado.sh" "$payload" "$HOME"
    ); then
        pass 'directory probe works in isolation under umask 002'
    else
        fail 'directory probe works in isolation under umask 002'
    fi
    assert_match 'directory probe config mode is 0600 under umask 002' '^-rw-------' "$(cat "$FAULT_MODE_LOG")"
fi

if section_is backup; then
    for backup_fault in backup-mkdir backup-temp backup-statusline backup-modular backup-modular-json \
        backup-single backup-single-json backup-manifest backup-publish backup-publish-directory; do
        config_dir="$TEST_BASE/$backup_fault"
        mkdir -p "$config_dir/cortado" || exit 1
        printf '%s\n' 'original modular payload' > "$config_dir/cortado/original" || exit 1
        printf '%s\n' 'original single-file payload' > "$config_dir/cortado.sh" || exit 1
        printf '%s\n' "$old_settings" > "$config_dir/settings.json" || exit 1
        cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
        case "$backup_fault" in
            backup-mkdir|backup-temp) diagnostic='Could not stage a statusline backup' ;;
            backup-publish*) diagnostic='Could not save backup manifest' ;;
            *) diagnostic='Could not prepare a statusline backup' ;;
        esac
        PATH="$fault_bin:$PATH" INSTALLER_TEST_FAULT="$backup_fault" BASH_ENV="$TEST_BASE/fault-env" \
            assert_install_failure "$backup_fault failure before replacing runtime" "$config_dir" "$diagnostic"
        assert_rc "$backup_fault preserves settings bytes" 0 cmp -s \
            "$TEST_BASE/previous-settings" "$config_dir/settings.json"
        assert_file_contains "$backup_fault preserves the original modular payload" \
            'original modular payload' "$config_dir/cortado/original"
        assert_file_contains "$backup_fault preserves the original single payload" \
            'original single-file payload' "$config_dir/cortado.sh"
        if [ "$backup_fault" = backup-publish-directory ]; then
            assert_rc 'failed first backup publication leaves no nested manifest' 1 test -e \
                "$config_dir/.cortado-backup/manifest.json/manifest.json"
        fi
    done
fi

if section_is reinstall; then
    config_dir="$TEST_BASE/failed-reinstall"
    settings="$config_dir/settings.json"
    manifest="$config_dir/.cortado-backup/manifest.json"
    mkdir -p "$config_dir/cortado" || exit 1
    printf '%s\n' 'original modular payload' > "$config_dir/cortado/original" || exit 1
    printf '%s\n' 'original single-file payload' > "$config_dir/cortado.sh" || exit 1
    printf '%s\n' '{"statusLine":{"type":"command","command":"original"}}' > "$settings" || exit 1
    install_minimal "$config_dir" || exit 1
    cp "$manifest" "$TEST_BASE/saved-manifest" || exit 1
    printf '\n# Later local edit\n' >> "$config_dir/cortado/cortado.conf" || exit 1
    cp "$config_dir/cortado/cortado.conf" "$TEST_BASE/previous-config" || exit 1
    cp "$settings" "$TEST_BASE/previous-settings" || exit 1
    fault_tree="$TEST_BASE/metadata-tree"
    mkdir -p "$fault_tree/lib" || exit 1
    cp "$REPO_ROOT/"{install.sh,cortado.sh,VERSION} "$fault_tree/" || exit 1
    ln -s "$REPO_ROOT/modules" "$fault_tree/modules" || exit 1
    # Link every other shipped library, so the copy installs like a checkout.
    for lib_file in "$REPO_ROOT"/lib/*.sh; do
        [ "${lib_file##*/}" = config-permissions.sh ] || ln -s "$lib_file" "$fault_tree/lib/" || exit 1
    done
    sed 's@/usr/bin/stat @command stat @g' "$REPO_ROOT/lib/config-permissions.sh" \
        > "$fault_tree/lib/config-permissions.sh" || exit 1
    PATH="$fault_bin:$PATH" INSTALLER_TEST_FAULT=config-metadata INSTALLER_TREE="$fault_tree" \
        assert_install_failure 'unreadable replacement config metadata' "$config_dir" 'refusing to source config'
    assert_rc 'validation failure keeps the active config bytes' 0 cmp -s \
        "$TEST_BASE/previous-config" "$config_dir/cortado/cortado.conf"
    assert_rc 'validation failure keeps the settings bytes' 0 cmp -s "$TEST_BASE/previous-settings" "$settings"
    assert_rc 'validation failure keeps the published restore manifest' 0 cmp -s "$TEST_BASE/saved-manifest" "$manifest"
    assert_statusline_runs 'the old command still renders after validation failure' "$settings"

    printf '%s\n' 'later single-file payload' > "$config_dir/cortado.sh" || exit 1
    for fault in empty rename promote; do
        if [ "$fault" = empty ]; then
            : > "$settings"
            diagnostic='Could not prepare settings.json'
        else
            printf '%s\n' '{"statusLine":{"type":"command","command":"second"}}' > "$settings"
            if [ "$fault" = rename ]; then
                diagnostic='Could not replace settings.json'
            else
                diagnostic='Could not install the staged runtime'
            fi
        fi
        cp "$settings" "$TEST_BASE/previous-settings" || exit 1
        PATH="$fault_bin:$PATH" INSTALLER_TEST_FAULT="$fault" \
            assert_install_failure "$fault reinstall" "$config_dir" "$diagnostic"
        assert_rc "$fault reinstall keeps settings bytes" 0 cmp -s "$TEST_BASE/previous-settings" "$settings"
        assert_rc "$fault reinstall keeps the original restore manifest bytes" 0 cmp -s \
            "$TEST_BASE/saved-manifest" "$manifest"
        assert_rc "$fault reinstall restores the active config bytes" 0 cmp -s \
            "$TEST_BASE/previous-config" "$config_dir/cortado/cortado.conf"
        assert_file_contains "$fault reinstall preserves the later single-file payload" \
            'later single-file payload' "$config_dir/cortado.sh"
        assert_eq "$fault reinstall keeps only the published backup generation" 1 \
            "$(find "$config_dir/.cortado-backup" -type d -name 'snapshot.*' | wc -l | tr -d ' ')"
    done
    printf '1\nn\n' | run_installer "$config_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1
    assert_eq 'restore after failed reinstalls recovers the original command' original \
        "$(jq -r '.statusLine.command' "$settings")"
    assert_file_contains 'restore after failed reinstalls recovers the original modular file' \
        'original modular payload' "$config_dir/cortado/original"
    assert_file_contains 'restore after failed reinstalls recovers the original single file' \
        'original single-file payload' "$config_dir/cortado.sh"

    config_dir="$TEST_BASE/failed-backup-publication"
    mkdir "$config_dir" || exit 1
    printf '%s\n' "$old_settings" > "$config_dir/settings.json" || exit 1
    install_minimal "$config_dir" || exit 1
    manifest="$config_dir/.cortado-backup/manifest.json"
    cp "$manifest" "$TEST_BASE/saved-manifest" || exit 1
    PATH="$fault_bin:$PATH" INSTALLER_TEST_FAULT=backup-publish install_minimal "$config_dir"
    assert_file_contains 'failed backup publication reports the pending manifest after settings succeeded' \
        'Could not replace the backup manifest. The new backup is in' "$TEST_BASE/install.log"
    assert_rc 'failed backup publication leaves the original restore manifest' 0 cmp -s "$TEST_BASE/saved-manifest" "$manifest"
    assert_eq 'failed backup publication retains the new snapshot for recovery' 1 \
        "$(find "$config_dir/.cortado-backup" -name manifest.json ! -path "$manifest" | wc -l | tr -d ' ')"

fi

if section_is generation; then
    for generation_fault in generate generate-header generate-write missing-generated symlink-generated; do
        fresh_config="$TEST_BASE/$generation_fault"
        mkdir "$fresh_config" || exit 1
        printf '%s\n' 'MODEL_ICON=Test' > "$fresh_config/cortado.conf" || exit 1
        chmod 600 "$fresh_config/cortado.conf" || exit 1
        INSTALLER_TEST_FAULT="$generation_fault" BASH_ENV="$TEST_BASE/fault-env" \
            assert_install_failure "$generation_fault failure" "$fresh_config" 'Could not generate Cortado config'
        assert_rc "$generation_fault failure leaves settings absent" 1 test -e "$fresh_config/settings.json"
    done

    blocked_config="$TEST_BASE/runtime-path-is-file"
    mkdir "$blocked_config" || exit 1
    printf '%s\n' 'Existing file at the runtime path' > "$blocked_config/cortado" || exit 1
    assert_install_failure 'a non-directory at the runtime path' "$blocked_config" 'Expected a directory'
    assert_file_contains 'the installer preserves a file at the runtime path' \
        'Existing file at the runtime path' "$blocked_config/cortado"

    dash_home="$TEST_BASE/quote\"parent/-n"
    mkdir -p "$dash_home" || exit 1
    for missing_dir in empty-home option-name; do
        config_dir=$(mktemp -d "$TEST_BASE/$missing_dir.XXXXXX") || exit 1
        printf '%s\n' "$old_settings" > "$config_dir/settings.json" || exit 1
        cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
        case "$missing_dir" in
            empty-home) HOME="" assert_install_failure 'empty HOME' "$config_dir" 'Could not prepare statusline test: HOME is empty' ;;
            option-name) HOME="$dash_home" assert_install_failure 'quoted HOME with basename -n' \
                "$config_dir" 'Statusline test FAILED - sample directory missing' ;;
        esac
        assert_rc "$missing_dir settings stay byte-identical" 0 cmp -s \
            "$TEST_BASE/previous-settings" "$config_dir/settings.json"
    done

    config_dir="$TEST_BASE/renderer-error"
    mkdir "$config_dir" || exit 1
    printf '%s\n' 'printf "%s\n" "DIR: home | MODEL: Test"' 'exit 7' > "$config_dir/cortado.conf" || exit 1
    chmod 600 "$config_dir/cortado.conf" || exit 1
    assert_install_failure 'nonzero renderer with output' "$config_dir" 'Statusline test FAILED'

    config_dir="$TEST_BASE/diagnostic-renderer"
    mkdir "$config_dir" || exit 1
    printf '%s\n' 'printf "%s\n" "syntax error" >&2' > "$config_dir/cortado.conf" || exit 1
    chmod 600 "$config_dir/cortado.conf" || exit 1
    printf '%s\n' "$old_settings" > "$config_dir/settings.json" || exit 1
    cp "$config_dir/settings.json" "$TEST_BASE/previous-settings" || exit 1
    PATH="$fault_bin:$PATH" INSTALLER_TEST_FAULT=diagnostic-cleanup \
        assert_install_failure 'zero-exit renderer with a syntax diagnostic on stderr' \
            "$config_dir" 'Statusline test FAILED - script errors detected'
    assert_rc 'zero-exit renderer with a diagnostic preserves settings bytes' 0 cmp -s \
        "$TEST_BASE/previous-settings" "$config_dir/settings.json"
    assert_rc 'failed sample removes temporary stderr capture' 1 test -e "$FAULT_ERRORS_FILE"
fi

if section_is restore; then
    space_dir="$TEST_BASE/with space"
    fresh_install 'with space'

    # Simulate a settings edit made between installs. Reinstall should detect the
    # saved command, back it up and update the settings while preserving other keys.
    settings="$space_dir/settings.json"
    manifest="$space_dir/.cortado-backup/manifest.json"
    jq '.includeCoAuthoredBy = true | .statusLine.padding = 4' "$settings" > "$TEST_BASE/settings.json" || exit 1
    mv "$TEST_BASE/settings.json" "$settings" || exit 1
    original_statusline=$(jq -c '.statusLine' "$settings")

    install_minimal "$space_dir"
    assert_eq "reinstall backs up the complete statusLine" "$original_statusline" \
        "$(jq -c '.settings_statusline' "$manifest")"
    assert_eq "reinstall preserves unrelated settings" "true" \
        "$(jq -r '.includeCoAuthoredBy' "$settings")"
    assert_eq "reinstall replaces the statusLine object" "false" \
        "$(jq -r '.statusLine | has("padding")' "$settings")"
    assert_statusline_runs "reinstall renders through sh [with space]" "$settings"
    hint=$(sed -n 's/^  Or run: *//p' "$TEST_BASE/install.log")
    # Parse the hint as a shell command without launching the interactive config TUI.
    hint_args=$(/bin/sh -c "set -- $hint; printf '%s\n' \"\$#\" \"\$@\"")
    assert_eq "config hint names the installed executable and config argument" \
        "$(printf '2\n%s/cortado.sh\nconfig' "$(cd "$space_dir/cortado" && pwd -P)")" "$hint_args"

    printf '1\nn\n' | run_installer "$space_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1
    assert_eq "uninstall restores the saved statusLine verbatim" "$original_statusline" \
        "$(jq -c '.statusLine' "$settings")"
    assert_statusline_runs "restored statusline renders through sh [with space]" "$settings"

    printf '2\n' | run_installer "$space_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1
    assert_eq "uninstall without restore removes the statusLine key" "false" \
        "$(jq -r 'has("statusLine")' "$settings")"
    assert_eq "uninstall preserves unrelated settings" "true" \
        "$(jq -r '.includeCoAuthoredBy' "$settings")"

    # xpg_echo interprets backslashes in JSON escapes for the quoted command.
    config_dir="$TEST_BASE/restore apostrophe's"
    settings="$config_dir/settings.json"
    manifest="$config_dir/.cortado-backup/manifest.json"
    INSTALLER_XPG_ECHO=true install_minimal "$config_dir"
    jq '.statusLine.padding = 7' "$settings" > "$TEST_BASE/settings.json" || exit 1
    mv "$TEST_BASE/settings.json" "$settings" || exit 1
    original_statusline=$(jq -ce '.statusLine' "$settings") || exit 1

    INSTALLER_XPG_ECHO=true install_minimal "$config_dir"
    if jq -es --argjson original "$original_statusline" --arg dir "$config_dir/cortado" '
        length == 1 and (.[0] | type == "object" and .settings_statusline == $original
            and any(.files[]; .type == "directory" and .original == $dir))
    ' "$manifest" >/dev/null; then
        pass "xpg_echo reinstall backs up the apostrophe path and complete statusLine"
    else
        fail "xpg_echo reinstall backs up the apostrophe path and complete statusLine"
    fi

    if ! printf '1\nn\n' | INSTALLER_XPG_ECHO=true run_installer "$config_dir" --uninstall > "$TEST_BASE/uninstall.log" 2>&1; then
        fail "xpg_echo uninstall completes with restore"
        cat "$TEST_BASE/uninstall.log"
    fi
    if [ -x "$config_dir/cortado/cortado.sh" ]; then
        pass "xpg_echo uninstall restores the executable"
    else
        fail "xpg_echo uninstall restores the executable"
    fi
    assert_eq "xpg_echo uninstall restores the complete statusLine" "$original_statusline" \
        "$(jq -c '.statusLine' "$settings")"
    assert_statusline_runs "xpg_echo restored statusline renders through sh" "$settings"
fi

if section_is publish; then

    # The saved command must trigger a backup even without old runtime files.
    config_dir="$TEST_BASE/settings only \$CORTADO_PATH_TEST"
    settings="$config_dir/settings.json"
    manifest="$config_dir/.cortado-backup/manifest.json"
    mkdir -p "$config_dir" || exit 1
    # shellcheck disable=SC2016 # $path is a jq variable.
    jq -n --arg path "$config_dir/cortado/cortado.sh" '
        {statusLine: {type: "command", command: ($path | @sh), padding: 11},
         includeCoAuthoredBy: false}
    ' > "$settings" || exit 1
    original_statusline=$(jq -ce '.statusLine' "$settings") || exit 1

    install_minimal "$config_dir"
    if jq -es --argjson original "$original_statusline" '
        length == 1 and (.[0] | type == "object" and .settings_statusline == $original)
    ' "$manifest" >/dev/null; then
        pass "settings-only install backs up the complete quoted statusLine"
    else
        fail "settings-only install backs up the complete quoted statusLine"
    fi
    assert_eq "settings-only install preserves unrelated settings" "false" \
        "$(jq -r '.includeCoAuthoredBy' "$settings")"
    assert_statusline_runs 'updated settings render through sh with a literal $ in the path' "$settings"

    # GNU syntax first: GNU stat -f succeeds (it reports the filesystem), so a BSD-first
    # fallback would never run there. BSD stat rejects -c and falls through.
    file_mode() {
        stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
    }

    config_dir="$TEST_BASE/group-write-umask"
    mkdir -p "$config_dir" && chmod 755 "$config_dir" || exit 1
    if (umask 002; LC_ALL=en_US.UTF-8 install_minimal "$config_dir"); then
        pass 'minimal install passes the UTF-8 sample under umask 002'
    else
        fail 'minimal install passes the UTF-8 sample under umask 002'
    fi
    assert_eq 'the generated config is owner-only under umask 002' '600' "$(file_mode "$config_dir/cortado/cortado.conf")"
    # shellcheck disable=SC2016 # $path is a jq variable.
    assert_eq 'umask 002 publishes the managed command' \
        "$(jq -nr --arg path "$(cd "$config_dir/cortado" 2>/dev/null && pwd -P)/cortado.sh" '$path | @sh')" \
        "$(jq -r '.statusLine.command' "$config_dir/settings.json" 2>/dev/null)"
    assert_statusline_runs 'the generated config renders through the command saved under umask 002' \
        "$config_dir/settings.json"
    assert_eq 'umask 002 keeps the existing config parent mode' 755 "$(file_mode "$config_dir")"
    for path in "$config_dir/cortado" "$config_dir/cortado/modules" "$config_dir/cortado/lib" \
        "$config_dir/cortado/cortado.sh" "$config_dir/cortado/VERSION" \
        "$config_dir/cortado/modules/"*.sh "$config_dir/cortado/lib/"*.sh; do
        mode=$(file_mode "$path")
        if [ -n "$mode" ] && (( (8#$mode & 8#022) == 0 )); then
            pass "umask 002 publishes ${path#"$config_dir"/} without group or other write ($mode)"
        else
            fail "umask 002 publishes ${path#"$config_dir"/} without group or other write ($mode)"
        fi
    done

    # Disable the only listed module to trigger the installer's manual test hint.
    config_dir="$TEST_BASE/manual hint's"
    mkdir -p "$config_dir" || exit 1
    printf '%s\n' 'MODULE_ORDER="model"' 'MODULE_MODEL="false"' > "$config_dir/cortado.conf" || exit 1
    chmod 600 "$config_dir/cortado.conf" || exit 1
    if run_installer "$config_dir" --minimal > "$TEST_BASE/install.log" 2>&1; then
        fail "empty statusline triggers the manual test hint"
    else
        hint=$(sed -n 's/^i Try running manually: //p' "$TEST_BASE/install.log")
        render_dir=$(mktemp -d "$TEST_BASE/render.XXXXXX") || exit 1
        if output=$(CLAUDE_CONFIG_DIR="$render_dir" CACHE_DIR="$render_dir/cortado-cache" \
            TERMINAL_WIDTH=200 /bin/sh -c "$hint" 2>"$render_dir/stderr") &&
            [[ "$output" == *"🤖 Test"* || "$output" == *"MODEL: Test"* ]]; then
            pass "manual test hint renders the sample through sh"
        else
            fail "manual test hint renders the sample through sh"
            printf '    hint: %s\n    stdout: %s\n' "$hint" "$output"
            cat "$render_dir/stderr"
        fi
    fi
fi

section_results
