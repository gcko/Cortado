# Cortado ☕

**Serving up fresh stats for your Claude Code sessions.**

A feature-rich, modular statusline for [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) that brews real-time development information including context usage, rate limits, costs, and more.

> Cortado started as a fork of [Barista](https://github.com/pstuart/Barista) by Patrick D. Stuart, which is where the coffee name comes from. Coming from Barista? See [Migrating from Barista](#migrating-from-barista).

![Cortado](https://img.shields.io/badge/Cortado-Claude_Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white)
![Version](https://img.shields.io/badge/Version-1.8.0-green?style=for-the-badge)
![Shell Script](https://img.shields.io/badge/Shell_Script-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=for-the-badge)

<p align="center">
  <img src="demo.gif" alt="Cortado Demo" width="800">
</p>

## What's New in v1.8.0 🆕

- **`cortado config` TUI** - Reconfigure modules, theme, and WAN privacy post-install without re-running the installer (`cortado config`, `--show`, `--set`, `--toggle`)
- **Homebrew install** - `brew tap pstuart/tap && brew install barista` (upstream Barista formula; Cortado does not have one yet)

### v1.7.0



- **Smart 429 Backoff** - Respects `Retry-After` headers for precise backoff timing instead of fixed delays
- **Unknown Module Fix** - Installer no longer errors on unrecognized module names in config
- **Privacy Hardening** - WAN IP lookup is now opt-in and redacted by default
- **Security Hardening** - Config injection, eval usage, token exposure, and download validation improvements

### v1.6.1

- **Private credential file** - Reads Claude Code OAuth from an owner-only `.credentials.json` file. No system Keychain access or migration. File permissions do not protect against other processes running as the same user.
- **Fail-closed credentials** - Missing, unsafe, malformed, or unrelated credential files return no token without invoking `security`.

### v1.6.0

- **Rate Limit 429 Backoff** - Automatically backs off API calls after receiving 429 responses
- **Version Display** - Shows current Cortado version in installer and statusline
- **Update Checker** - Enhanced update checking from GitHub releases

### v1.5.0

- **Smart Terminal Layout** - New `LAYOUT_MODE` setting with intelligent line wrapping
  - `smart` (default) - Wraps at separator boundaries when content exceeds terminal width
  - `newline` - Forces Claude's right-side info to next line
  - `wrap` - Pads output to line boundary
  - `truncate` - Shortens output to fit on the same line. The marker uses up to three dots, depending on available space.
  - `none` - No adjustments, natural terminal behavior
- Prevents awkward mid-module line breaks on wide statuslines
- Configurable `RIGHT_SIDE_RESERVE` and `TERMINAL_WIDTH` settings

### v1.4.0

- **Custom Config Directory** - Respects `CLAUDE_CONFIG_DIR` environment variable for users who relocate their Claude configuration from `~/.claude/`
- All paths (cache, logs, usage history, user config) resolve dynamically
- No changes needed if using the default location

### v1.3.0

- Added more color theme settings.
- **Improved Spacing** - Status indicators now have proper spacing in normal/verbose modes
- **Smart Compact Mode** - Separator padding and status spacing automatically removed in compact mode
- **Fixed Installer Preview** - Preview now shows actual sample data instead of just icons

### v1.2.0
- **Memory Optimizations** - Fixed unbounded history file growth, added file size caps
- **Interactive Update Check** - Installer now prompts to check for updates on startup with version display
- **4-Level Rate Limit Colors** - Visual indicators at 50%/75%/95% thresholds (🟢→🟡→🟠→🔴)
- **Monorepo Performance** - Git module now limits output to prevent memory spikes in large repos

### v1.1.0
- **Auto-Update Checking** - Cortado checks GitHub for updates and can self-update
- **Interactive Installer** - Arrow key navigation with space to toggle selections
- **Customizable Separators** - Choose from pipe, arrow, bullet, and more
- **Color Themes** - Default (emoji) or monochrome (ASCII)
- **Display Modes** - Normal, compact, or verbose output
- **Live Preview** - See your statusline before installing
- **Bash 3.2 Compatible** - Works with macOS default bash (no brew required)

## What's On The Menu ☕

### Core Modules (The House Blend)

| Module | What It Serves |
|--------|----------------|
| **directory** | Current working directory name |
| **context** | Visual progress bar showing context usage with auto-compact warnings; shows `--` until Claude Code reports usage (every new session starts that way) |
| **git** | Branch name, dirty status, staged/modified/untracked indicators |
| **project** | Auto-detects Node.js, Nuxt, Next.js, Vite, Rust, Go, Python, Swift, and more |
| **model** | Current Claude model, output style, and optional thinking/reasoning-effort state (`MODEL_SHOW_THINKING`) |
| **cost** | Session cost with burn rate ($/hour) and tokens per minute (TPM) |
| **rate-limits** | Real-time 5-hour and 7-day rate limit tracking with projections. A window with no reading shows `--` (for example `5h:42% 7d:--`). When a fetch fails and Cortado serves a cached reading older than `RATE_CACHE_TTL`, it shows the reading's age after the percentage (for example `5h:42%~6h0m`). For gateway spend, Cortado shows each available reading (for example `spend:$12.40/$50.00 (25% 🟢)`). Claude Code receives the percentage with each response and refreshes the dollar estimate about every five minutes while requests are active. Cortado omits the spend segment when it has no usable reading or the payload gives a numeric dollar limit of zero or less. |
| **time** | Current date and time |
| **battery** | Battery percentage (macOS) |
| **sandbox** | Lock icon when running inside a macOS app sandbox |
| **version** | Cortado version, shown briefly at the start of each Claude Code session |
| **update** | Checks GitHub for new Cortado releases. Successful checks are cached for a day by default. `⬆ --` or `UPD: --` means the check was unavailable. The next render after the failure cache expires (at most one hour) retries. |

### System Modules (The Espresso Shots)

| Module | What It Serves |
|--------|----------------|
| **cpu** | CPU usage percentage |
| **memory** | RAM usage |
| **disk** | Disk space usage |
| **network** | IP address and network info |
| **uptime** | System uptime |
| **load** | System load average |
| **temperature** | CPU temperature (requires osx-cpu-temp) |
| **brightness** | Screen brightness |
| **processes** | Total and running process counts |

### Dev Tools (The Specialty Drinks)

| Module | What It Serves |
|--------|----------------|
| **docker** | Docker container status |
| **node** | Node.js version |
| **weather** | Current weather via wttr.in |
| **timezone** | Multiple timezone clocks |

## Fresh Brew Sample

```
📁 myproject | 📊 ██████░░ 75%🔴 (10k→⚡) | 🌿 main [●+] 📝 3 | ⚡ Nuxt 🚀 | 🤖 Claude Opus 4.5 | 💰 $2.50 @$5.00/h | 5h:45%🟢 7d:78%🟠 | 📅 01/12 🕐 04:30 PM | 🔋 85%
```

**With different separators:**
```
📁 myproject › 📊 ████░░░░ 50%🟢 › 🌿 main › 🤖 Opus    # Arrow style
📁 myproject • 📊 ████░░░░ 50%🟢 • 🌿 main • 🤖 Opus    # Bullet style
DIR: myproject | CTX: ####---- 50%[OK] | GIT: main      # ASCII mode
```

### Temperature Gauge

**Context Usage (3-level):**
| Indicator | Usage | Status |
|-----------|-------|--------|
| 🟢 | Below 60% | Smooth sipping |
| 🟡 | 60-75% | Getting warm |
| 🔴 | Above 75% | Boiling over |

**Rate Limits (4-level):**
| Indicator | Usage | Status |
|-----------|-------|--------|
| 🟢 | Below 50% | Plenty of headroom |
| 🟡 | 50-75% | Moderate usage |
| 🟠 | 75-95% | High usage |
| 🔴 | Above 95% | Critical, near limit |

## Requirements

- **Claude Code CLI** - [Installation Guide](https://docs.anthropic.com/en/docs/claude-code)
- **Bash 3.2+** - Works with macOS default bash
- **jq** - JSON processor (required)
- **bc** - Basic calculator used by the opt-in temperature module (usually pre-installed)
- **Perl** - Runs background probes and handles Git and session cache metadata (pre-installed on macOS)
- The battery and sandbox modules run only on macOS; on Linux they are left out of the line. Rate-limit tracking works on macOS and Linux, including WSL.
- Windows: not supported. On a platform other than macOS or Linux (Git Bash, Cygwin, BSD) the statusline reads `cortado: unsupported platform`. To try the Linux modules there anyway, set `CORTADO_OS=linux` in the environment or in `cortado.conf`.

```bash
# Install dependencies on macOS
brew install jq
```

## Installation

### From source

```bash
# Clone the repo
git clone https://github.com/gcko/Cortado.git
cd Cortado

# Run the installer
./install.sh
```

Cortado doesn't have a Homebrew formula yet, so install from source for now.

The interactive installer features:
- **Arrow key navigation** - Use ↑/↓ to move, Space to toggle, Enter to confirm
- **Module categories** - Core, System, Dev Tools, and Extra modules
- **Display customization** - Icons, separators, colors, and themes
- **Live preview** - See your statusline before installing
- **Automatic backup** - Your previous statusline is saved

### Installer Options

```bash
# Installation
./install.sh                 # Interactive installation with keyboard navigation
./install.sh --defaults      # Install with core modules, no prompts
./install.sh --minimal       # Quick install with minimal modules
./install.sh --force         # Same as --defaults, no confirmation

# Display options
./install.sh --no-emoji      # Install without emojis (ASCII mode)
./install.sh --no-color      # Install without colors

# Updates (from-source / git clone only — not shipped by Homebrew)
./install.sh --check-update       # Check the latest GitHub *release* tag
./install.sh --check              # Alias for --check-update
./install.sh --update             # Install that tagged release (not floating main)
./install.sh --skip-update-check  # Skip the automatic update check during install
./install.sh --version            # Show current version

# Other
./install.sh --uninstall     # Uninstall and restore previous statusline
./install.sh --help          # Show all options
```

### Staying Up to Date

For a source install, `./install.sh --check-update`, its alias `./install.sh --check`, and `./install.sh --update` use the latest published release tag on GitHub. The statusline `update` module uses the same repository by default. When the installer cannot find a release, these commands exit with status 1 and print `Could not determine the latest version`. The installer refuses to `--update` a Homebrew Cellar/opt prefix. [Cortado releases](https://github.com/gcko/Cortado/releases)

Cortado also checks for a newer *release* when you run the from-source installer (skip with `--skip-update-check`).

If the installer updates by downloading an archive, it verifies `Cortado-source.zip` against the Release's `SHA256SUMS` file before replacing any files. Each asset download has up to 5 seconds to connect and 60 seconds to finish. A timed-out download, a missing checksum, or a checksum mismatch stops the update.

When `settings.json` runs the installed copy at `~/.claude/cortado/cortado.sh`, `--update` also refreshes that copy to the release. It builds the new copy beside the old one, carries over your `cortado.conf` and any other files you added, and then swaps the two. If any step fails, or Ctrl-C or a TERM or HUP signal interrupts the update, the old copy goes back in place. If it cannot go back, the installer keeps it unchanged and prints where it is. `--update` will not refresh a `~/.claude/cortado` that is a symbolic link or not a directory: it changes nothing there and exits with status 1. A link to the source clone you are updating from, or to a Homebrew prefix, is skipped without an error. A `~/.claude` that is itself a symbolic link works as usual.

### Migrating from Barista

Cortado can read your existing Barista settings.

- **User config.** When there is no `$CLAUDE_CONFIG_DIR/cortado.conf`, Cortado and the installer copy a trusted `barista.conf`, keeping its permissions and leaving the original in place. Cortado uses the trusted legacy file in place if the destination directory fails the permission check or the copy fails, and `cortado config` then shows and edits `barista.conf`. A dangling `cortado.conf` symlink counts as an existing destination.
- **Project config.** Cortado reads a project's `.barista.conf` when there's no `.cortado.conf` next to it. The first successful save with `cortado config --project` writes the allowed settings to `.cortado.conf` and leaves `.barista.conf` in place.
- **Install location.** The installer puts Cortado in `$CLAUDE_CONFIG_DIR/cortado/` and points `statusLine` in `settings.json` at `cortado/cortado.sh`. Your previous `statusLine` command is backed up, so `./install.sh --uninstall` can switch back to Barista.
- **Cache and logs.** These move to `cortado-cache/` and `cortado.log` and are rebuilt automatically. `.usage_history` keeps its name.

After you've confirmed Cortado works, you can remove the old files: `$CLAUDE_CONFIG_DIR/barista/`, `barista.conf`, `barista-cache/`, and `.barista-backup/`. If you installed Barista with Homebrew, run `brew uninstall barista` and `brew untap pstuart/tap`.

### Manual Brew

1. **Copy cortado to your Claude directory:**
   ```bash
   CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
   cp -r . "$CLAUDE_DIR/cortado"
   chmod +x "$CLAUDE_DIR/cortado/cortado.sh"
   ```

2. **Configure Claude Code settings:**

   Edit your `settings.json` (in `$CLAUDE_CONFIG_DIR` or `~/.claude/`):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/cortado/cortado.sh"
     }
   }
   ```

3. **Restart Claude Code** to taste your fresh statusline.

## Customization

### Interactive Display Preferences

The installer lets you customize:

| Setting | Options |
|---------|---------|
| **Icon Style** | Emoji icons or ASCII text |
| **Status Indicators** | 🟢🟡🔴 Emoji, ●●● Dots, or [OK][WARN] ASCII |
| **Progress Bars** | ████░░ Blocks, ▓▓▓░░ Shaded, ●●●○○ Circles, #### Hash |
| **Separators** | \| Pipe, ║ Double, › Arrow, • Bullet, : Colon |
| **Color Themes** | `default` (emoji), `monochrome` (ASCII labels and status indicators) |
| **Display Mode** | Normal, Compact, Verbose |

Existing configs can still use `minimal`, `vibrant`, or `nerd`. With the shipped display settings they look like `default`.

### Runtime config (`cortado config`)

After install, reconfigure without re-running the installer:

```bash
cortado config                 # interactive TUI (modules, theme, WAN privacy)
cortado config --show          # print settings and flag an inactive saved file
cortado config --list          # alias for --show
cortado config --toggle weather
cortado config --set COLOR_THEME=monochrome
cortado config --project       # edit ./.cortado.conf in the current directory
cortado config --global        # edit the user config (default scope)
cortado config --path          # print the resolved config path
cortado config --help          # show usage
```

The default save path is `$CLAUDE_CONFIG_DIR/cortado.conf` (usually `~/.claude/cortado.conf`). Use `--project` to save allowed preferences in the current directory. Cancel leaves the file untouched.

For the user config, `--set` replaces the last standalone assignment for the key or appends one if needed. When a later line could assign the key again (inside an `if`, say), it appends the new value so it takes effect, and says which line. It saves module flag values of `yes`, `1`, and `on` as `true`, and `no`, `0`, and `off` as `false`, and adds or removes the module in `MODULE_ORDER` the way `--toggle` does.

For the user config, the editor follows symlinks and writes to the target. It refuses a group- or world-writable user config and prints the `chmod go-w` command to run after you review it. A project `.cortado.conf` that is a symlink is refused, because a repository can commit one that points at your own files. Either save keeps the previous contents of an existing file in an owner-only `.bak` beside the file it writes.

Cortado creates a missing global config directory with private permissions and leaves an existing directory's mode alone. When a save succeeds but the statusline still cannot trust the file it wrote (its directory is group- or world-writable, say), the editor says the saved settings are inactive; see [Config file not loading](#config-file-not-loading).

### Configuration Files

Edit `cortado.conf` or create a user override config in your Claude config directory:

```bash
# Default location
~/.claude/cortado.conf

# Or if using a custom config directory
$CLAUDE_CONFIG_DIR/cortado.conf
```

#### Custom Config Directory

If you've moved your Claude configuration from the default `~/.claude/`, set the `CLAUDE_CONFIG_DIR` environment variable:

```bash
export CLAUDE_CONFIG_DIR="/path/to/my/claude-config"
```

Cortado will automatically use that directory for:
- User config overrides (`cortado.conf`)
- Cache files (`cortado-cache/`)
- Debug logs (`cortado.log`, rotated to `cortado.log.1` at 1 MiB)
- Rate limit history (`.usage_history`)

No other configuration changes are needed.

#### Per-Directory Overrides

Create `.cortado.conf` in a project directory to customize its statusline. Cortado reads literal `KEY=VALUE` lines from a shared list of display settings, such as layout, separators, themes, icons, and thresholds. A project can also turn a known module off with `MODULE_*=false`. Only enabled modules in `MODULE_ORDER` run.

Use the user config for enabling modules or setting URLs, repositories, locations, paths, and debug mode. Settings exported before Cortado starts keep their trusted effective values. The renderer and `cortado config --project` use the same project permissions.

```bash
# ~/myproject/.cortado.conf
# Minimal statusline for this large monorepo
DISPLAY_MODE="compact"
MODULE_WEATHER="false"
MODULE_ORDER="directory,context,git,model"
```

Configuration is loaded in order of precedence:
1. Built-in defaults
2. `cortado.conf` in the script directory, sourced as Bash after the permission check below
3. `$CLAUDE_CONFIG_DIR/cortado.conf`, sourced as Bash after the same check with user-file ownership rules
4. `.cortado.conf` (per-directory display preferences and module disables)

### Full Configuration Options

```bash
# =============================================================================
# GLOBAL SETTINGS
# =============================================================================

SEPARATOR=" | "           # Section separator (or " › ", " • ", etc.)
DISPLAY_MODE="normal"     # "normal", "compact", "verbose"
COLOR_THEME="default"     # "default" or "monochrome"
USE_ICONS="true"          # Enable emoji icons
USE_STATUS_INDICATORS="true"  # Enable colored status dots/emoji
STATUS_STYLE="emoji"      # "emoji", "ascii", "dots"

# Custom status indicators apply when STATUS_STYLE="emoji".
# The monochrome theme sets STATUS_STYLE="ascii" and USE_ICONS="false".
STATUS_GREEN="🟢"
STATUS_YELLOW="🟡"
STATUS_ORANGE="🟠"        # 4-level indicators (rate limits) use the orange band
STATUS_RED="🔴"

# Progress bar customization
PROGRESS_BAR_WIDTH=8
PROGRESS_BAR_FILLED="█"   # Or "▓", "●", "#"
PROGRESS_BAR_EMPTY="░"    # Or "░", "○", "-"

# =============================================================================
# MODULE ENABLE/DISABLE
# =============================================================================

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
MODULE_SANDBOX="true"       # Lock icon when in a macOS app sandbox
MODULE_VERSION="true"       # Version notice at the start of each session
MODULE_UPDATE="true"        # Check for releases when update is in MODULE_ORDER

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

# Module display order
MODULE_ORDER="sandbox,directory,context,git,project,model,cost,rate-limits,time,battery"

# =============================================================================
# RATE LIMIT SETTINGS (v1.2.0+)
# =============================================================================

RATE_SHOW_USAGE_STATUS="true"   # Show 4-level color indicators
RATE_LOW_THRESHOLD=50           # Green/yellow boundary
RATE_MEDIUM_THRESHOLD=75        # Yellow/orange boundary
RATE_HIGH_THRESHOLD=95          # Orange/red boundary
RATE_SHOW_PROGRESS_BAR="false"  # Optional progress bars for 5h/7d usage
RATE_PROGRESS_BAR_WIDTH=""      # Empty = use global PROGRESS_BAR_WIDTH

# =============================================================================
# TERMINAL LAYOUT (v1.5.0+)
# =============================================================================

LAYOUT_MODE="smart"          # "smart", "newline", "wrap", "truncate", "none"
TERMINAL_WIDTH=""            # Manual override (empty = auto-detect)
RIGHT_SIDE_RESERVE=20        # Space reserved for Claude's right-side display

# =============================================================================
# ADVANCED SETTINGS
# =============================================================================

CACHE_MAX_AGE=60             # Default cache TTL (seconds) for cache_get() when no max_age is passed
DEBUG_MODE="false"           # Debug logging to $CLAUDE_CONFIG_DIR/cortado.log (module errors included)
```

Per-module settings (icons, thresholds, formats, and TTLs such as `GIT_CACHE_TTL`, `RATE_CACHE_TTL`, `WEATHER_CACHE_TTL`, `VERSION_SHOW_DURATION`, and `UPDATE_CHECK_INTERVAL`) are documented inline in the shipped `cortado.conf`.

Weather, network, CPU, load, brightness, processes, Docker, and Node.js use background refreshes. A cold or expired reading shows `--` until a refresh succeeds. Weather uses `WEATHER_CACHE_TTL` with a minimum of one second. Public IP uses five minutes. CPU uses five seconds. Local network, load, brightness, and processes use ten seconds. Docker uses fifteen seconds, and Node.js and npm versions use thirty seconds. After a failed request, weather and public IP retry on the next render after fifteen seconds. Other probes retry after five seconds. Refreshes keep one lock per reading. Clearing the cache discards readings and invalidates pending refresh results while retaining the locks. The watchdog allows up to five seconds for directory setup, the probe and publication, plus one second for recording a failure.

`UPDATE_CHECK_INTERVAL` sets how long a successful release check is cached (86,400 seconds by default). After an unavailable check, Cortado shows `⬆ --` or `UPD: --` and retries on the next render after half the configured interval, capped at one hour.

### Preset Recipes

**Espresso (Minimal):**
```bash
DISPLAY_MODE="compact"
SEPARATOR=" › "
MODULE_ORDER="directory,context,git,model"
```

**Americano (Developer):**
```bash
MODULE_CPU="true"
MODULE_MEMORY="true"
MODULE_DOCKER="true"
MODULE_ORDER="directory,git,docker,cpu,memory,model,cost,rate-limits,battery"
```

**Decaf (ASCII-only):**
```bash
USE_ICONS="false"
STATUS_STYLE="ascii"
SEPARATOR=" | "
PROGRESS_BAR_FILLED="#"
PROGRESS_BAR_EMPTY="-"
```

**Monochrome (Minimal colors):**
```bash
COLOR_THEME="monochrome"
STATUS_STYLE="dots"
SEPARATOR=" • "
```

## The Menu (Architecture)

```
~/.claude/cortado/
├── cortado.sh          # Main entry point (+ config/version CLI)
├── lib/
│   ├── config-tui.sh   # Runtime config TUI (`cortado config`)
│   ├── config-permissions.sh # Ownership and mode checks for sourced files
│   ├── module-registry.sh    # Module discovery from file headers
│   └── semver.sh       # Version comparison for the installer and update module
├── cortado.conf        # Configuration file
├── VERSION             # Version tracking
└── modules/
    ├── utils.sh        # Shared utility functions
    ├── directory.sh    # Directory module
    ├── context.sh      # Context window module
    ├── git.sh          # Git module
    ├── project.sh      # Project detection module
    ├── model.sh        # Model info module
    ├── cost.sh         # Cost & TPM module
    ├── rate-limits.sh  # Rate limits module
    ├── time.sh         # Date/time module
    ├── battery.sh      # Battery module
    └── ...             # Additional modules
```

### Crafting Custom Modules

Create `cortado-modules/` in your Claude config directory (`$CLAUDE_CONFIG_DIR`, which defaults to `~/.claude`). Save the following as `cortado-modules/mycustom.sh`. You must own the file, its directory and the Claude config directory, and only you may write to any of them. The commands after the next step set those modes.

```bash
# @cortado-module mycustom
# @default false
# @args none
# @ttl 0
# @timeout-ms 0
# @platforms darwin,linux
# @description My custom segment
module_mycustom() {
    printf '%s\n' '🎯 My Output'
}
```

Add these settings to `cortado.conf` in the same Claude config directory. This order keeps the model and adds the custom segment. Append `mycustom` to your existing order to keep all your current segments.

```bash
MODULE_MYCUSTOM="true"
MODULE_ORDER="model,mycustom"
```

Then make the files private. A shell with umask `002`, the default on Ubuntu, creates them group-writable. Cortado skips a group- or world-writable module or module directory and leaves it off the statusline with no notice; with `DEBUG_MODE="true"`, `cortado.log` names what it refused. A refused `cortado.conf`, including one in a group- or world-writable Claude config directory, shows `Config refused` at the start of the statusline instead; see [Config file not loading](#config-file-not-loading).

```bash
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
chmod go-w "$dir"
chmod 700 "$dir/cortado-modules"
chmod 600 "$dir/cortado-modules/mycustom.sh" "$dir/cortado.conf"
```

`cortado config --list` shows the module. Module IDs use lowercase ASCII letters, digits, and hyphens and match the filename without `.sh`. Replace hyphens with underscores in the Bash function and uppercase flag.

To contribute a module to Cortado, place the same file in the checkout's `modules/` directory. The installer and config catalog discover it automatically. See [Adding a New Module](AGENTS.md#adding-a-new-module) for the header fields.

## Troubleshooting

### Rate limits show "--"
- Send a message. Claude Code includes your 5-hour and 7-day usage in the statusline data only after a session's first reply (seen in Claude Code 2.1.330), so a new session shows `5h:-- 7d:--` until then. No credential setup is needed for this.
- Ensure you're using Claude Code with a Pro/Team subscription.
- If it still shows `--` after a reply, your Claude Code version may not send usage. Cortado then falls back to asking the usage API itself, which needs an owner-only `.credentials.json` in `CLAUDE_CONFIG_DIR` (default `~/.claude`). A login kept only in the macOS Keychain is not read.
- Verify you're logged in (`claude login`)

### Modules not loading
- Check file permissions: `chmod +x cortado.sh`
- Verify module files exist in `modules/` directory
- Enable debug mode: `DEBUG_MODE="true"`. Module errors (a missing tool, a bad setting) never print into the statusline; with debug mode on they go to `cortado.log`, prefixed with the module name. The log rotates at 1 MiB and keeps one previous file, `cortado.log.1`.
- If the statusline reads `cortado: jq missing`, install `jq`: Cortado needs it to read the data Claude Code sends.

### Arrow keys not working in installer
- Make sure you're running in a proper terminal (not a script)
- Try a different terminal emulator if issues persist

### Config file not loading

- `Config refused` in the statusline means Cortado skipped a Bash config. Run `cortado config --show` in a terminal for the file and reason on stderr. The same details go to `cortado.log` when a trusted config enables debug logging.
- For a symlink, check the resolved file and its immediate parent. The file must belong to your user and have no group or world write bits. Root ownership is also allowed for the packaged config. The parent must belong to your user or root and may be group- or world-writable only with the sticky bit. Missing or unreadable permission metadata causes a refusal.
- For a user-owned file, `chmod 600 /path/to/resolved/cortado.conf` removes extra write access. A private file can still be replaced through a writable parent. If you own that directory and can remove its shared write access, run `chmod go-w /path/to/resolved/parent`. Leave a deliberately shared directory's permissions to its owner.
- Per-directory `.cortado.conf` uses the literal settings parser.

### Testing manually
```bash
echo '{"workspace":{"current_dir":"'$PWD'"},"model":{"display_name":"Test"},"output_style":{"name":"default"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":10000}}}' | ~/.claude/cortado/cortado.sh
```

### Running the test suite
Regression tests live in `tests/` and run standalone:
```bash
bash tests/test_utils.sh    # or any other tests/test_*.sh
```

## Uninstall

```bash
./install.sh --uninstall
```

This will offer to restore your previous statusline if one was backed up.

## Credits

- Forked from [Barista](https://github.com/pstuart/Barista) by [Patrick D. Stuart](https://github.com/pstuart), who built the original modular statusline
- Inspired by [cc-statusline](https://github.com/chongdashu/cc-statusline) by [@chongdashu](https://github.com/chongdashu)
- Built for use with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by Anthropic

## License

Apache License 2.0. See [LICENSE](LICENSE) for the full text.

Cortado includes code from Barista, which is MIT-licensed. The upstream copyright and permission notice is kept in [NOTICE](NOTICE).

## Maintainer

**Jared Scott**
- GitHub: [@gcko](https://github.com/gcko)

---

<div align="center">

**Enjoy your fresh brew!** ☕

*Cortado v1.8.0 - Because your Claude Code deserves a great statusline.*

</div>
