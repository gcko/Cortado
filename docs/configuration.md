# Configuring Cortado

You can change settings in two ways: with `cortado config`, or by editing `cortado.conf` yourself. Both write the same file.

## `cortado config`

```bash
cortado config                      # Interactive menu: modules, theme, WAN privacy
cortado config --show               # Print settings, and name any line that was skipped
cortado config --list               # Same as --show
cortado config --migrate --dry-run  # List lines the parser skips, with line numbers; changes nothing
cortado config --toggle weather     # Turn a module on or off
cortado config --set COLOR_THEME=monochrome
cortado config --project            # Edit ./.cortado.conf in the current directory
cortado config --global             # Edit the user config (the default)
cortado config --path               # Print the config file path
cortado config --help               # Show usage
```

### What a save changes

- The default target is `$CLAUDE_CONFIG_DIR/cortado.conf`, usually `~/.claude/cortado.conf`. Use `--project` to save allowed settings in the current directory instead.
- Cancel leaves the file untouched.
- A menu save writes only the settings you changed, and moves only the modules you switched on or off in `MODULE_ORDER`. With no changes, it writes nothing.
- The theme and WAN choices start on the current setting, so pressing Enter through them keeps it.
- A module runs only when its flag is exactly `true`. The menu and `--show` report a flag spelled `yes`, `1` or `on` as off, the way the statusline treats it. Switching it on saves `true`.

### `--set` on the user config

- It replaces the last standalone assignment for the key, or appends one.
- If a later line could assign the key again (inside an `if`, say), it appends the new value so it takes effect, and says which line.
- It refuses a value that doesn't fit the setting's type.
- For module flags it saves `yes`, `1` and `on` as `true`, and `no`, `0` and `off` as `false`. Like `--toggle`, it adds or removes the module in `MODULE_ORDER`.

### Project files

For a project `.cortado.conf`, `--set`, `--toggle` and a menu save change only the lines they set. The last line the project parser reads as that key is replaced in place, a missing key is appended, and every other line stays as it was, comments and blank lines included. A new project file starts with a header and any settings Cortado accepted from a legacy `.barista.conf`.

### File safety

- For the user config, the editor follows symlinks and writes to the target. It refuses a group- or world-writable user config, and prints the `chmod go-w` command to run once you've reviewed the file.
- It refuses a project `.cortado.conf` that is a symlink, because a repository can commit one that points at your own files.
- A user config save keeps the previous contents in an owner-only `.bak` beside the file. A project save changes only its own lines, so it writes no `.bak`, and it saves the file owner-only.
- Cortado creates a missing global config directory with private permissions, and leaves an existing directory's mode alone.
- If a save succeeds but the statusline still can't trust the file (its directory is group- or world-writable, say), the editor says the saved settings are inactive. See [Config refused](troubleshooting.md#config-refused-or-config-partly-read).

## Config files

Cortado reads these in order. A later file overrides an earlier one.

1. Built-in defaults.
2. `cortado.conf` next to `cortado.sh`, the packaged defaults.
3. `$CLAUDE_CONFIG_DIR/cortado.conf`, your settings. This is usually `~/.claude/cortado.conf`.
4. `.cortado.conf` in the current project directory, for that project's display settings.

Cortado checks the ownership and permissions of the packaged and user files before reading them. See [Config refused](troubleshooting.md#config-refused-or-config-partly-read) for the rules.

### File format

Every config file is data. Cortado never runs it.

- Write one `KEY=VALUE` per line. The value can be a bare word, `"double quoted"` or `'single quoted'`.
- `#` starts a comment, on its own line or after the value.
- A later line for the same key wins. An `export` prefix is ignored.
- To put a color code in a separator or icon, type the escape byte itself inside the quotes.

Cortado skips any other kind of line, such as `$(...)`, backticks, `$HOME`, `$'...'`, a leading `~`, a function or an `if`. It also skips a value that doesn't fit its setting, such as `CONTEXT_WARNING_THRESHOLD=high`. When it skips something, the statusline shows `Config partly read` and renders everything else. A name Cortado doesn't know is only listed, since no module reads it.

`cortado config --show` names each skipped line, and `cortado config --migrate --dry-run` lists them with line numbers.

### Upgrading from a config that runs Bash

Earlier versions sourced `cortado.conf` as Bash. A config that runs commands or expands variables now has those lines skipped. Run `cortado config --migrate --dry-run` to list them, then rewrite each as a plain `KEY="value"`.

If you still need the old behaviour, start Claude Code with `CORTADO_CONF_ALLOW_BASH=1` in its environment. Cortado then sources your user config as Bash, after the same permission check. Only the environment can turn this on, never a config file, and it never applies to the packaged or project configs. This opt-in lasts through the next major release and is removed in the one after.

### A custom config directory

If you moved your Claude configuration out of `~/.claude/`, set `CLAUDE_CONFIG_DIR`:

```bash
export CLAUDE_CONFIG_DIR="/path/to/my/claude-config"
```

Cortado then keeps all of its files there:

- `cortado.conf`, your settings.
- `cortado-cache/`, cached readings.
- `cortado.log`, the debug log. It rotates to `cortado.log.1` at 1 MiB.
- `.usage_history`, rate-limit history.

Nothing else needs to change.

### Per-project settings

Create `.cortado.conf` in a project directory to change how the statusline looks there:

```bash
# ~/myproject/.cortado.conf
# Minimal statusline for this large monorepo
DISPLAY_MODE="compact"
MODULE_WEATHER="false"
MODULE_ORDER="directory,context,git,model"
```

A project file is untrusted, so Cortado reads only a shared list of display settings from it, such as layout, separators, themes, icons and thresholds. It can also turn a known module off with `MODULE_*=false`. Only enabled modules in `MODULE_ORDER` run.

Turning modules on, and setting URLs, repositories, locations, paths and debug mode, belong in your user config. Settings exported in the environment before Cortado starts keep their trusted values. The statusline and `cortado config --project` read project files with the same rules.

## Display options

The installer and `cortado config` set these for you:

| Setting | Options |
|---|---|
| Icon style | Emoji icons or ASCII text |
| Status indicators | 🟢🟡🔴 emoji, ●●● dots, or [OK][WARN] ASCII |
| Progress bars | ████░░ blocks, ▓▓▓░░ shaded, ●●●○○ circles, #### hash |
| Separators | \| pipe, ║ double, › arrow, • bullet, : colon |
| Color theme | `default` (emoji) or `monochrome` (ASCII labels and status indicators) |
| Display mode | Normal, compact or verbose |

Existing configs can still use the `minimal`, `vibrant` or `nerd` themes. With the shipped display settings they look like `default`.

## All settings

The common settings, with their defaults:

```bash
# Global
SEPARATOR=" | "                # Between segments (or " › ", " • ", and so on)
DISPLAY_MODE="normal"          # "normal", "compact" or "verbose"
COLOR_THEME="default"          # "default" or "monochrome"
USE_ICONS="true"               # Emoji icons
USE_STATUS_INDICATORS="true"   # Colored status dots or emoji
STATUS_STYLE="emoji"           # "emoji", "ascii" or "dots"

# Custom status indicators, used when STATUS_STYLE="emoji".
# The monochrome theme sets STATUS_STYLE="ascii" and USE_ICONS="false".
STATUS_GREEN="🟢"
STATUS_YELLOW="🟡"
STATUS_ORANGE="🟠"             # Rate limits use the fourth, orange level
STATUS_RED="🔴"

# Progress bars
PROGRESS_BAR_WIDTH=8
PROGRESS_BAR_FILLED="█"        # Or "▓", "●", "#"
PROGRESS_BAR_EMPTY="░"         # Or "○", "-"

# Core modules (on by default)
MODULE_DIRECTORY="true"
MODULE_CONTEXT="true"
MODULE_GIT="true"
MODULE_PROJECT="true"
MODULE_MODEL="true"
MODULE_COST="true"
MODULE_RATE_LIMITS="true"
MODULE_TIME="true"
MODULE_BATTERY="true"
MODULE_SANDBOX="true"          # Lock icon inside a macOS app sandbox
MODULE_VERSION="true"          # Version notice at the start of each session
MODULE_UPDATE="true"           # Checks for releases when update is in MODULE_ORDER

# System modules (off by default)
MODULE_CPU="false"
MODULE_MEMORY="false"
MODULE_DISK="false"
MODULE_NETWORK="false"
MODULE_UPTIME="false"
MODULE_LOAD="false"
MODULE_TEMPERATURE="false"
MODULE_BRIGHTNESS="false"
MODULE_PROCESSES="false"

# Development and extra modules (off by default)
MODULE_DOCKER="false"
MODULE_NODE="false"
MODULE_WEATHER="false"
MODULE_TIMEZONE="false"

# Display order
MODULE_ORDER="sandbox,directory,context,git,project,model,cost,rate-limits,time,battery"

# Rate limits
RATE_SHOW_USAGE_STATUS="true"  # 4-level color indicators
RATE_LOW_THRESHOLD=50          # Green/yellow boundary
RATE_MEDIUM_THRESHOLD=75       # Yellow/orange boundary
RATE_HIGH_THRESHOLD=95         # Orange/red boundary
RATE_SHOW_PROGRESS_BAR="false" # Progress bars for 5h and 7d usage
RATE_PROGRESS_BAR_WIDTH=""     # Empty uses PROGRESS_BAR_WIDTH

# Terminal layout
LAYOUT_MODE="smart"            # "smart", "newline", "wrap", "truncate" or "none"
TERMINAL_WIDTH=""              # Override the detected width (empty detects it)
RIGHT_SIDE_RESERVE=20          # Space kept for Claude Code's right-side display

# Advanced
CACHE_MAX_AGE=60               # Default cache lifetime in seconds for cache_get()
DEBUG_MODE="false"             # Log module errors to $CLAUDE_CONFIG_DIR/cortado.log
```

Each module's own settings (icons, thresholds, formats, and cache lifetimes such as `GIT_CACHE_TTL`, `RATE_CACHE_TTL`, `WEATHER_CACHE_TTL`, `VERSION_SHOW_DURATION` and `UPDATE_CHECK_INTERVAL`) are documented in the shipped `cortado.conf`.

### Layout modes

| `LAYOUT_MODE` | What it does |
|---|---|
| `smart` (default) | Wraps at a separator when the line is wider than the terminal |
| `newline` | Moves Claude Code's right-side info to the next line |
| `wrap` | Pads the output to the end of the line |
| `truncate` | Shortens the output to fit on one line, ending it with up to three dots |
| `none` | No adjustment |

### Background refreshes

Weather, network, CPU, load, brightness, processes, Docker and Node.js read their values in the background, so a slow command never holds up the statusline. A reading that is missing or expired shows `--` until a refresh succeeds.

| Reading | Refreshed after |
|---|---|
| Weather | `WEATHER_CACHE_TTL` (at least 1 second) |
| Public IP | 5 minutes |
| CPU | 5 seconds |
| Local network, load, brightness, processes | 10 seconds |
| Docker | 15 seconds |
| Node.js and npm versions | 30 seconds |

After a failed request, weather and public IP retry on the next render after 15 seconds, and the other readings after 5 seconds. Each reading has one refresh lock. Clearing the cache discards readings and invalidates pending refresh results, but keeps the locks. A refresh gets up to 5 seconds for directory setup, the probe and publishing the result, plus 1 second to record a failure.

`UPDATE_CHECK_INTERVAL` sets how long a successful release check is cached (86,400 seconds by default). After a failed check, the statusline shows `⬆ --` or `UPD: --`, and the next render after half the interval (at most one hour) tries again.

## Presets

Minimal:

```bash
DISPLAY_MODE="compact"
SEPARATOR=" › "
MODULE_ORDER="directory,context,git,model"
```

Developer:

```bash
MODULE_CPU="true"
MODULE_MEMORY="true"
MODULE_DOCKER="true"
MODULE_ORDER="directory,git,docker,cpu,memory,model,cost,rate-limits,battery"
```

ASCII only:

```bash
USE_ICONS="false"
STATUS_STYLE="ascii"
SEPARATOR=" | "
PROGRESS_BAR_FILLED="#"
PROGRESS_BAR_EMPTY="-"
```

Monochrome:

```bash
COLOR_THEME="monochrome"
STATUS_STYLE="dots"
SEPARATOR=" • "
```
