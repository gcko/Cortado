# Cortado - Claude Code Statusline

A modular, shell-based statusline for Claude Code CLI that displays real-time development information including context usage, rate limits, costs, git status, and more.

This file is the canonical repository contract for every agent (Claude Code, Codex, Antigravity). `CLAUDE.md` imports it, so keep Claude-only notes there and everything else here.

## Project Overview

Cortado began as a fork of [Barista](https://github.com/pstuart/Barista) (pstuart/Barista, MIT) and is now an independent project at `gcko/Cortado`, licensed Apache 2.0. The upstream MIT notice is kept in `NOTICE`, so don't remove it. Upstream issue references such as `#21`, `#24`, and `#28` in comments point to pstuart/Barista.

Cortado is a **Bash shell script** project (Bash 3.2+ compatible for macOS). It generates a customizable status line that Claude Code displays at the bottom of the terminal. The architecture is modular - each piece of information (git, battery, CPU, etc.) is handled by a separate module in the `modules/` directory.

## Architecture

```
Cortado/
├── cortado.sh          # Main entry point - loads config, modules, orchestrates output
├── cortado.conf        # Default configuration file (sourced as bash)
├── install.sh          # Interactive installer with arrow key navigation
├── VERSION             # Version tracking (semver), edited only by a release
├── AGENTS.md           # This contract (canonical)
├── CLAUDE.md           # `@AGENTS.md` plus Claude-only notes
├── LICENSE, NOTICE     # Apache 2.0, and the upstream Barista MIT notice
├── lib/
│   ├── config-tui.sh   # Runtime config TUI (`cortado config`)
│   ├── config-permissions.sh # Ownership and mode checks for sourced files
│   ├── module-registry.sh    # Header discovery for renderer and catalogs
│   └── semver.sh            # Version comparison for installer and update module
├── modules/
│   ├── utils.sh        # Shared utility functions (MUST load first)
│   ├── directory.sh    # Current directory module
│   ├── context.sh      # Context window usage with progress bar
│   ├── git.sh          # Git branch and status
│   ├── project.sh      # Project type detection (Node, Rust, Python, etc.)
│   ├── model.sh        # Current Claude model info
│   ├── cost.sh         # Session cost and burn rate
│   ├── rate-limits.sh  # 5-hour and 7-day rate limit tracking
│   ├── time.sh         # Date and time display
│   ├── battery.sh      # Battery percentage (macOS)
│   ├── cpu.sh          # CPU usage
│   ├── memory.sh       # RAM usage
│   ├── disk.sh         # Disk space
│   ├── network.sh      # Network info
│   ├── node.sh         # Node.js version
│   ├── docker.sh       # Docker container status
│   ├── weather.sh      # Weather via wttr.in
│   ├── sandbox.sh      # Lock icon when in a macOS app sandbox
│   ├── version.sh      # Cortado version, shown briefly at the start of each session
│   ├── update.sh       # GitHub release check with a shorter retry interval on failure
│   └── ...             # Additional modules
├── tests/              # Standalone regression tests and shared assertions
├── .claude/skills/     # Repository development skills (canonical; see "Repository skills")
├── .agents/skills/     # Relative symlinks to .claude/skills/* so Codex reads the same skills
├── .shellcheckrc       # ShellCheck policy (see Testing)
└── README.md
```

## How It Works

1. **Claude Code calls `cortado.sh`** with JSON input containing workspace info, model, context window data, etc.
2. **Configuration is loaded** in order of precedence:
   - Module enable defaults from the installed module headers and display fallbacks in `cortado.sh`
   - `cortado.conf` in script directory
   - `$CLAUDE_CONFIG_DIR/cortado.conf` (user overrides, defaults to `~/.claude/`)
   - `.cortado.conf` in current project directory (per-project overrides)

   When there is no `cortado.conf` entry, Cortado and the installer check `$CLAUDE_CONFIG_DIR/barista.conf` before copying it with its permissions intact. The renderer loads a trusted legacy file in place if the destination parent fails the check or copying fails. A project's `.barista.conf` is read only when that project has no `.cortado.conf`. Keep these fallbacks until Barista users have had time to migrate.

   Cortado and the installer use the same permission check before sourcing Bash config. The resolved file must belong to the current user, with root also allowed for packaged config. Its parent must belong to the current user or root. Group or other write access is refused, except on a parent with the sticky bit. Unreadable permission metadata also causes a refusal. When packaged settings are unavailable, the renderer falls back to the module header defaults and its built-in display defaults, and adds one `Config refused` section when it rejects Bash config. Detailed reasons go to stderr and to the statusline's debug log when trusted settings enable it. Per-directory `.cortado.conf` is read as literal KEY=VALUE settings through `load_config_safe`. Config-derived numerics are validated before they reach `bc`/URL sinks. `cortado config --project` uses the same safe parser.
3. **Modules are discovered** from their headers in `modules/` and in `$CLAUDE_CONFIG_DIR/cortado-modules/`. The renderer sources the installed scripts with `utils.sh` first. It sources user modules inside their execution subshell after the same check, except that a sticky parent does not exempt module code. Module refusals are reported only in debug mode.
4. **Modules are executed** in the order specified by `MODULE_ORDER` config
5. **Output is concatenated** with the configured `SEPARATOR` and printed

## Key Files

### `cortado.sh` (Main Entry Point)
- Resolves `CLAUDE_CONFIG_DIR` (env var or defaults to `$HOME/.claude`)
- Applies module enable defaults from the registry
- Loads configuration files in precedence order
- Loads all module files from `modules/`
- Resolves module function names and argument kinds from the registry
- Executes enabled modules and joins output with separator
- Adjusts separator spacing based on `DISPLAY_MODE`

### `modules/utils.sh` (Required Utilities)
- **Theme system**: `apply_theme()` sets icons and indicators based on `COLOR_THEME`
- **Cache system**: File-based caching for expensive operations
- **Safe number handling**: `safe_int()`, `safe_divide()`, `safe_percent()`
- **Status indicators**: `get_status()` (3-level), `get_status_4level()` (4-level for rate limits)
- **Icon handling**: `get_icon()` respects `USE_ICONS` setting
- **Progress bar**: `progress_bar()` generates visual bars
- **Payload parsing**: `main` parses the statusline payload once (`modules/payload.sh`, a single `jq` call) into read-only `CTX_*` variables that input modules read, with missing and null kept distinct from 0. Quota cache, credential and API reads share that one `jq` process. `json_get()` and `json_get_int()` remain for standalone use.
- **REPLY helpers**: `get_status`, `progress_bar` and the `safe_*` helpers set `REPLY` instead of being called through `$(...)`.
- **Display mode checks**: `is_compact()`
- **Logging**: `log_debug()` for debug mode

### `cortado.conf` (Configuration)
All settings are documented with comments. Key settings:
- `SEPARATOR` - Character(s) between modules (default: `" | "`)
- `DISPLAY_MODE` - `"normal"`, `"compact"`, or `"verbose"`
- `COLOR_THEME` - `"default"` or `"monochrome"`
- `USE_ICONS` - Enable/disable emoji icons
- `STATUS_STYLE` - `"emoji"`, `"ascii"`, or `"dots"`
- `MODULE_*` - Enable/disable individual modules
- `MODULE_ORDER` - Comma-separated list defining display order

## Color Themes

`apply_theme()` in `utils.sh` fills unset indicator and icon variables after config loading. The `default` theme uses the shipped display settings. The `monochrome` theme sets `STATUS_STYLE=ascii` and `USE_ICONS=false` to show ASCII labels and status indicators. See README.md for compatibility with older theme values.

## Module Structure

A module defines its header before the first Bash statement. See [Adding a New Module](#adding-a-new-module) for the metadata.

```bash
# =============================================================================
# Module Name - Brief description
# =============================================================================
# Configuration options:
#   OPTION_NAME    - Description (default: value)
# =============================================================================

module_name() {
    local input="$1"  # JSON input (for modules that need it)

    # Get configuration with defaults
    local icon=$(get_icon "${MODULE_ICON:-📊}" "FALLBACK:")
    local some_option="${SOME_OPTION:-default}"

    # Do work...

    # Build and output result
    local result="$icon some_value"
    echo "$result"
}
```

### Module Types

1. **Input-dependent modules** (context, model, cost, rate-limits): Receive JSON input as `$1`
2. **Directory-dependent modules** (git, project): Receive current directory as `$1`
3. **Standalone modules** (time, battery, cpu): Take no arguments

### What a module prints when it does not know

A module that has no reading must say so, never print a value that reads as an all-clear. `rate-limits` prints `5h:-- 7d:--` (or `--` for the one window it lacks) rather than `0%`, and `context` prints `--` until Claude Code reports usage. Missing fields, failed fetches and stale caches must indicate the state of the reading. The optional gateway spend segment appears only when the payload supplies a usable reading. The `visual-review-and-fix` skill walks these cases.

## Display Modes

The `DISPLAY_MODE` setting affects multiple behaviors:

- **`normal`**: Balanced display with icons and key info, padded separators, spaces before status indicators
- **`compact`**: Minimal display, no separator padding, no spaces before status indicators
- **`verbose`**: Full display with all available information

## Status Indicators

Two systems for visual status:

1. **3-level** (`get_status`): green/yellow/red based on warning/critical thresholds
2. **4-level** (`get_status_4level`): green/yellow/orange/red for more granular rate limit display

Both respect `DISPLAY_MODE` for spacing and `STATUS_STYLE` for appearance (emoji/ascii/dots).

## Adding a New Module

Create `modules/mymodule.sh` and put the following metadata in its leading comment block. The renderer, installer, and config catalog read the same headers.

| Header | Meaning |
|---|---|
| `@cortado-module mymodule` | Module ID. Match the filename without `.sh` and use lowercase ASCII letters, digits, and hyphens. Replace hyphens with underscores in `module_mymodule` and `MODULE_MYMODULE`. Cortado reserves `order`, `utils`, and `payload`. |
| `@default false` | Default for the enable flag. The render still requires the ID in `MODULE_ORDER`. |
| `@args none` | Use `dir` for the resolved workspace directory or `payload` for the input JSON. |
| `@ttl 0` | Default probe cache lifetime in seconds. The module manages its cache. |
| `@timeout-ms 0` | Default probe timeout in milliseconds. The module manages its deadlines. |
| `@platforms darwin,linux` | Platforms on which the module runs. Include a platform if the module renders a fallback there. |
| `@config KEY:type` | A project-safe option in an installed module. Add one line per key with `bool`, `int`, `number`, or `string`. The module validates values. |
| `@menu extra` | Optional category. Use `core`, `system`, `dev`, or `extra`. An optional number gives the menu position. |
| `@description My module` | Optional text for the installer and config catalog. |

Project config can turn a registered module off. Project order can reorder or omit trusted user selections. Sourcing a user module requires its ID in the trusted `MODULE_ORDER`. Its file and module directory must be owned by the current user. The file, module directory, and its parent must have no group or world write bits. Use a regular module directory. A file symlink can point to a checked target inside that directory.

## Coding Conventions

- **Bash 3.2+ compatible** - No associative arrays, use `case` statements instead
- **Use utility functions** - `safe_int()`, `json_get()`, etc. for safe operations
- **Local variables** - Always declare with `local` in functions
- **Quoting** - Always quote variables: `"$var"` not `$var`
- **Configuration pattern**: `local value="${CONFIG_VAR:-default}"`
- **Error handling** - Redirect stderr: `command 2>/dev/null`
- **Comments** - Document configuration options at module top
- **Global shell state** - A function that changes `IFS`, `set -f` or the working directory restores it before calling anything else, because modules run inside the caller's state

## Testing

Regression tests live in `tests/` and share the Bash assertions in `tests/lib/assert.sh`. Each suite runs standalone and sandboxes `CLAUDE_CONFIG_DIR` and `CACHE_DIR`. Use `/bin/bash` to exercise Bash 3.2 on macOS.
```bash
/bin/bash tests/test_utils.sh           # utils.sh helpers
/bin/bash tests/test_rate_limits.sh     # rate-limit parsers/backoff
/bin/bash tests/test_config_cli.sh      # cortado config CLI and Barista migration
/bin/bash tests/test_install_update.sh  # installer update flags, runtime copy, migration
/bin/bash tests/run-jq-variants.sh      # all suites with Homebrew and Apple jq on macOS
/bin/bash tests/render_timing.sh        # p50 and p95 for default renders with fresh caches
```

Lint with `shellcheck`. `.shellcheckrc` disables SC2155, SC2034, SC2059, SC2001, SC2012, SC1090, SC2129, SC2086, and SC2002 project-wide. See upstream pstuart/Barista#21 for the original policy.

Test the statusline manually, in a sandbox config dir:
```bash
echo '{"workspace":{"current_dir":"'$PWD'"},"model":{"display_name":"Test"},"output_style":{"name":"default"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":10000}}}' | CLAUDE_CONFIG_DIR="$(mktemp -d)" ./cortado.sh
```

Never run a worktree's `cortado.sh` against the real `~/.claude`: it writes `cortado-cache/`, and the Barista migration copies `barista.conf` to `cortado.conf` on first run.

Enable debug mode:
```bash
DEBUG_MODE="true"  # In config
# Logs to $CLAUDE_CONFIG_DIR/cortado.log: each module's stderr, prefixed with its name
# (otherwise discarded, never printed into the line); rotates at 1 MiB to cortado.log.1
```

## Pre-PR Checks

[Cortado's GitHub Actions workflow](.github/workflows/ci.yml) runs on every pull request and on pushes to `main`. It checks macOS system Bash 3.2 with Homebrew and Apple jq, and Ubuntu. Each suite runs under a 300 s limit. On macOS the default-render timing (60 samples) blocks above p95 250 ms, a regression guard; the 150 ms target holds on a developer Mac, but GitHub's shared runner measures about 188 ms (#25). Ubuntu timing is informational. Windows is not supported (owner decision, 2026-11-25, on #24), so CI does not run it. Releases follow the `cortado-release` skill.

Run the local checks below from the repository root before opening a pull request and again before merging. Paste their output into the pull request's `## Verification` section. This is the canonical local gate.

```bash
# 1. Every regression suite, each standalone
fail=0
for t in tests/test_*.sh; do /bin/bash "$t" >/dev/null 2>&1 || { echo "FAIL: $t"; fail=1; }; done
[ "$fail" -eq 0 ] && echo "tests: all green"

# 2. Bash syntax on every shipped and test script
for f in cortado.sh install.sh lib/*.sh modules/*.sh tests/*.sh tests/lib/*.sh; do /bin/bash -n "$f" || echo "SYNTAX: $f"; done

# 3. ShellCheck: no more findings than the merge base had
/bin/bash <<'BASH'
set -euo pipefail
merge_base=$(git merge-base origin/main HEAD)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/base"
git archive "$merge_base" | tar -x -C "$scratch/base"
sc() (
    cd "$1" || exit 1
    shopt -s nullglob
    local_status=0
    shellcheck -f json cortado.sh install.sh lib/*.sh modules/*.sh tests/*.sh tests/lib/*.sh > "$2" || local_status=$?
    if [ "$local_status" -gt 1 ]; then
        cat "$2" >&2
        exit "$local_status"
    fi
    jq -es 'if length == 1 and (.[0] | type == "array") then .[0] | length else error("Expected one ShellCheck diagnostics array") end' "$2" || {
        local_status=$?
        cat "$2" >&2
        exit "$local_status"
    }
)
base_count=$(sc "$scratch/base" "$scratch/base.json")
head_count=$(sc . "$scratch/head.json")
printf 'shellcheck findings: base %s, head %s\n' "$base_count" "$head_count"
if [ "$head_count" -gt "$base_count" ]; then
    cat "$scratch/head.json"
    exit 1
fi
BASH

# 4. Render smoke in a sandbox config dir (never the real ~/.claude)
sb=$(mktemp -d)
echo '{"workspace":{"current_dir":"'"$PWD"'"},"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":10000}}}' \
  | CLAUDE_CONFIG_DIR="$sb" /bin/bash ./cortado.sh
rm -rf "$sb"
```

A FAIL or SYNTAX line, or a failed ShellCheck comparison, blocks the pull request. A change to what the statusline prints also owes the `visual-review-and-fix` walk, and a change to docs owes `sync-docs`.

## PR Workflow

1. Branch from `origin/main` (never commit to `main`). Use a worktree under `.claude/worktrees/` for parallel work.
2. Write the failing test first, then the change.
3. Run the Pre-PR Checks above, then `sync-docs` for any doc the change made false.
4. Title the pull request with the shipped behaviour in a plain sentence that could go straight into release notes ("Show a stale marker on cached rate limits"). Conventional-commit prefixes are fine; issue numbers belong in the body.
5. The body carries `Closes #N` for each issue it finishes (`Part of #N` for a partial step), a short summary, and a `## Verification` section naming what ran and what it printed.
6. Pull requests are squash-merged. Never edit `VERSION` outside a release.

## Versioning and Releases

`VERSION` is the single source of truth, and only a release changes it. The README version badge, the README footer, the "What's New" section and the version assertion in `tests/test_config_cli.sh` follow it in the same release commit. Releases are `vX.Y.Z` tags on `gcko/Cortado` with a GitHub Release. The installer reads `releases/latest` from `gcko/Cortado`, which is also the `update` module's default `UPDATE_REPO`. The `cortado-release` skill owns the release procedure.

The local clone may carry `v1.x` tags inherited from pstuart/Barista that do not exist on `gcko/Cortado` and are not ancestors of `main`. Read release tags from the remote (`git ls-remote --tags origin`), never from `git tag -l`.

## Calibrating Effort

Review depth follows risk, not size.

| Tier | Applies to | Review |
|---|---|---|
| Self-verify | Docs, comments, tests only, or a display tweak that adds no input, config key or file write | The author's own read of the diff and the Pre-PR Checks |
| Two lenses plus an arbiter | Everything else (the default) | Two independent reviewers, then an arbiter that reproduces each finding |
| Full adversarial | Config loading and sourcing (`load_config`, `load_config_safe`, the config-tui writer and allowlists), credential handling (`.credentials.json`, the OAuth token), any network call (`curl` in rate-limits, weather, network, update, the installer's download), anything `install.sh` writes to `settings.json` or deletes, cache and history file permissions | Reviewers who try to break it, with mutation tests of every new guard |

A layer that nothing calls yet is reviewed together with the layer that makes it reachable, at the higher of their tiers.

## Parallel Work

- Each builder works in its own worktree under `.claude/worktrees/`, never in the main checkout.
- These files are contention surfaces; two in-flight branches must not both edit one: `cortado.sh`, `cortado.conf`, `lib/config-tui.sh`, `install.sh`, `modules/utils.sh`, `README.md`, `AGENTS.md`. Adding or renaming a module touches most of them (see "Adding a New Module"), so module work is one branch at a time.
- Tests are sandboxed and safe to run concurrently. A manual render or a live session must use its own `CLAUDE_CONFIG_DIR`.
- Stop what you start: tmux sessions, `claude` processes started for a live-session walk, delegated `codex`/`agy` runs. A `claude` process can take a few seconds to exit after its tmux session is killed; check by name (`pgrep -fl <pattern>`) before calling it gone or orphaned.

## Repository Skills

Development skills live in `.claude/skills/` (canonical). Each `.agents/skills/<name>` is a relative symlink to `../../.claude/skills/<name>` so Codex and Claude Code read one body, and each skill carries `agents/openai.yaml` for Codex. They are not shipped by the installer.

| Skill | Use it to |
|---|---|
| `burndown` | Plan, build, review and land a GitHub issue, issue list, parent tree or milestone |
| `cortado-release` | Choose the next version from what changed, cut the release and confirm it landed |
| `sync-docs` | Reconcile README, AGENTS.md and `cortado.conf` comments with the code before a pull request |
| `sync-project` | Keep GitHub milestone descriptions and issue bodies lean and current |
| `visual-review-and-fix` | Render the statusline as its reader sees it, with missing and stale data forced, before and after a change |

## Dependencies

- **Required**: `jq` (JSON processor; without it the line reads `cortado: jq missing`). `bc` is used only by the opt-in brightness, load and temperature modules.
- **Optional**: Various CLI tools for specific modules (docker, node, etc.)

## Custom Config Directory

Cortado respects the `CLAUDE_CONFIG_DIR` environment variable for users who have moved their Claude configuration from the default `~/.claude/`. This is resolved once in `cortado.sh` and inherited by all modules:

```bash
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
```

Files stored in this directory:
- `cortado.conf` - User config overrides
- `cortado-modules/` - User module scripts
- `cortado-cache/` - Cache for expensive operations (weather, network, etc.)
- `cortado.log` - Debug log (when `DEBUG_MODE="true"`), rotated at 1 MiB to `cortado.log.1`
- `.usage_history` - Rate limit history for projections

Modules also include their own `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` fallback for robustness if sourced independently.

## Rate Limits Module

The rate limits module (`rate-limits.sh`) is the most complex:
- Reads usage from the statusline payload first: Claude Code sends `rate_limits.five_hour` and `rate_limits.seven_day` (`used_percentage`, `resets_at` in Unix seconds) after a session's first turn (seen in 2.1.330). `_usage_from_payload` reshapes them into the usage API's shape, so one renderer serves both sources. This needs no credential and makes no request, on any platform
- Appends gateway spend from `rate_limits.spend_limit` independently of the 5-hour and 7-day windows. Claude Code receives `used_percentage` with each response and refreshes the optional `used_usd` and `limit_usd` about every five minutes while requests are active. Cortado shows both readings when usable, with the configured usage indicator on the reported percentage, or shows either reading alone. It omits the segment when neither reading is usable or when `limit_usd` is numeric and zero or less
- Until the first turn, or when the payload lacks either window, shows its `5h:-- 7d:--` placeholder or falls back to the Anthropic OAuth usage API with the token in `$CLAUDE_CONFIG_DIR/.credentials.json`, and only when that file is owner-only. It never reads the macOS Keychain
- A payload reading is never written to the shared usage cache, and records a history point at most once per `RATE_CACHE_TTL`. The API path caches responses and serves the last cached reading (up to 24 hours old) when a fetch fails
- Backs off after 429 responses, honoring `Retry-After` headers
- Maintains history file for projection calculations
- Implements file size caps to prevent memory issues
- Shows 4-level color indicators for usage thresholds, plus optional progress bars (`RATE_SHOW_PROGRESS_BAR`)

## Installation

The installer (`install.sh`) provides:
- Interactive module selection with arrow key navigation
- Live preview rendered by Cortado with sample input in a temporary config directory
- Multiple presets (minimal, developer, etc.)
- Auto-update checking from GitHub
- Backup/restore of previous statusline
- Copies `cortado.sh`, `VERSION`, `modules/`, and `lib/` (required for `cortado config`)

`./install.sh --check-update`, `./install.sh --check`, and `./install.sh --update` exit with status 1 and print `Could not determine the latest version` if they cannot find a release.

Archive updates download the tagged Release's `SHA256SUMS` and `Cortado-source.zip` assets. Each download has a 5-second connection deadline and a 60-second total deadline. The installer verifies the published SHA-256 before extracting the archive. An unavailable checksum or a mismatch aborts the update before any files are replaced. The `cortado-release` skill publishes both assets.
