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
  - `truncate` - Cuts output with "..." to fit on same line
  - `none` - No adjustments, natural terminal behavior
- Prevents awkward mid-module line breaks on wide statuslines
- Configurable `RIGHT_SIDE_RESERVE` and `TERMINAL_WIDTH` settings

### v1.4.0

- **Custom Config Directory** - Respects `CLAUDE_CONFIG_DIR` environment variable for users who relocate their Claude configuration from `~/.claude/`
- All paths (cache, logs, usage history, user config) resolve dynamically
- No changes needed if using the default location

### v1.3.0

- **Enhanced Color Themes** - 5 distinct visual themes that actually look different:
  - `default` - Standard emoji (🟢🟡🟠🔴)
  - `minimal` - Subtle geometric shapes (◦ ◐ → ⎇)
  - `vibrant` - Bold heart colors (💚💛🧡❤️)
  - `monochrome` - Pure ASCII ([OK] [~~] [!!] [XX])
  - `nerd` - Nerd Font icons (requires Nerd Font)
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
- **Color Themes** - Default, minimal, vibrant, or monochrome
- **Display Modes** - Normal, compact, or verbose output
- **Live Preview** - See your statusline before installing
- **Bash 3.2 Compatible** - Works with macOS default bash (no brew required)

## What's On The Menu ☕

### Core Modules (The House Blend)

| Module | What It Serves |
|--------|----------------|
| **directory** | Current working directory name |
| **context** | Visual progress bar showing context usage with auto-compact warnings |
| **git** | Branch name, dirty status, staged/modified/untracked indicators |
| **project** | Auto-detects Node.js, Nuxt, Next.js, Vite, Rust, Go, Python, Swift, and more |
| **model** | Current Claude model, output style, and optional thinking/reasoning-effort state (`MODEL_SHOW_THINKING`) |
| **cost** | Session cost with burn rate ($/hour) and tokens per minute (TPM) |
| **rate-limits** | Real-time 5-hour and 7-day rate limit tracking with projections |
| **time** | Current date and time |
| **battery** | Battery percentage (macOS) |
| **sandbox** | Lock icon when running inside a macOS app sandbox |
| **version** | Cortado version, shown briefly after startup |
| **update** | Daily check for new Cortado releases with update notification |

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
| **processes** | Process count |

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
- **bc** - Basic calculator (usually pre-installed)
- **macOS** - For the battery module; rate-limit tracking works on macOS, Linux and Windows (Git Bash)

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
./install.sh --update             # Install that tagged release (not floating main)
./install.sh --skip-update-check  # Skip the automatic update check during install
./install.sh --version            # Show current version

# Other
./install.sh --uninstall     # Uninstall and restore previous statusline
./install.sh --help          # Show all options
```

### Staying Up to Date

**From source (git clone or a copied tree):** `./install.sh --check-update` and `./install.sh --update` use GitHub `releases/latest` on [gcko/Cortado](https://github.com/gcko/Cortado), the same tag source as the statusline `update` module. They do **not** track unpinned `main`. The installer refuses to `--update` a Homebrew Cellar/opt prefix.

Cortado also checks for a newer *release* when you run the from-source installer (skip with `--skip-update-check`).

### Migrating from Barista

Cortado reads your Barista settings, so nothing is lost when you switch:

- **User config.** The first time Cortado runs, it copies `$CLAUDE_CONFIG_DIR/barista.conf` to `cortado.conf`, keeping the file's permissions. It does this only if `cortado.conf` doesn't exist yet, and it leaves the original in place. `./install.sh` does the same copy and tells you about it.
- **Project config.** A project's `.barista.conf` is still read when there's no `.cortado.conf` next to it. `cortado config --project` copies it to `.cortado.conf` the first time you edit it.
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
| **Color Themes** | Default, Minimal, Vibrant, Monochrome, Nerd Font |
| **Display Mode** | Normal, Compact, Verbose |

### Runtime config (`cortado config`)

After install, reconfigure without re-running the installer:

```bash
cortado config                 # interactive TUI (modules, theme, WAN privacy)
cortado config --show          # print current settings
cortado config --toggle weather
cortado config --set COLOR_THEME=minimal
cortado config --project       # edit ./.cortado.conf in the current directory
```

Saves to `$CLAUDE_CONFIG_DIR/cortado.conf` (default `~/.claude/cortado.conf`). Cancel leaves the file untouched.

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
- Debug logs (`cortado.log`)
- Rate limit history (`.usage_history`)

No other configuration changes are needed.

#### Per-Directory Overrides

Create `.cortado.conf` in any project directory to customize the statusline for that project. That file is **never sourced** — only allowlisted `KEY=VALUE` lines are applied (`load_config_safe`).

```bash
# ~/myproject/.cortado.conf
# Minimal statusline for this large monorepo
DISPLAY_MODE="compact"
MODULE_WEATHER="false"
MODULE_ORDER="directory,context,git,model"
```

Configuration is loaded in order of precedence:
1. Built-in defaults
2. `cortado.conf` (in script directory — sourced as bash after a writable check)
3. `$CLAUDE_CONFIG_DIR/cortado.conf` (user overrides, defaults to `~/.claude/` — also sourced)
4. `.cortado.conf` (per-directory KEY=VALUE allowlist; never sourced)

### Full Configuration Options

```bash
# =============================================================================
# GLOBAL SETTINGS
# =============================================================================

SEPARATOR=" | "           # Section separator (or " › ", " • ", etc.)
DISPLAY_MODE="normal"     # "normal", "compact", "verbose"
COLOR_THEME="default"     # "default", "minimal", "vibrant", "monochrome", "nerd"
USE_ICONS="true"          # Enable emoji icons
USE_STATUS_INDICATORS="true"  # Enable colored status dots/emoji
STATUS_STYLE="emoji"      # "emoji", "ascii", "dots"

# Custom status indicators (STATUS_STYLE="emoji"; COLOR_THEME fills indicator and icon variables only when they are still unset, and shipped cortado.conf already sets the default emoji, so minimal, vibrant, and nerd do not replace them. monochrome still forces STATUS_STYLE=ascii and USE_ICONS=false).
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
MODULE_VERSION="true"       # Version notice after startup
MODULE_UPDATE="true"        # Daily update check

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
DEBUG_MODE="false"           # Debug logging to $CLAUDE_CONFIG_DIR/cortado.log
```

Per-module settings (icons, thresholds, formats, and TTLs such as `GIT_CACHE_TTL`, `RATE_CACHE_TTL`, `WEATHER_CACHE_TTL`, `VERSION_SHOW_DURATION`, and `UPDATE_CHECK_INTERVAL`) are documented inline in the shipped `cortado.conf`.

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
│   └── config-tui.sh   # Runtime config TUI (`cortado config`)
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

Create a new file in `modules/` following this recipe:

```bash
# =============================================================================
# My Custom Module - Description
# =============================================================================

module_mycustom() {
    local input="$1"  # JSON input from Claude Code
    # Your logic here
    echo "🎯 My Output"
}
```

Then add to `cortado.conf`:
```bash
MODULE_MYCUSTOM="true"
MODULE_ORDER="...,mycustom,..."
```

## Troubleshooting

### Rate limits show "--"
- Send a message. Claude Code includes your 5-hour and 7-day usage in the statusline data only after a session's first reply (seen in Claude Code 2.1.330), so a new session shows `5h:-- 7d:--` until then. No credential setup is needed for this.
- Ensure you're using Claude Code with a Pro/Team subscription.
- If it still shows `--` after a reply, your Claude Code version may not send usage. Cortado then falls back to asking the usage API itself, which needs an owner-only `.credentials.json` in `CLAUDE_CONFIG_DIR` (default `~/.claude`). A login kept only in the macOS Keychain is not read.
- Verify you're logged in (`claude login`)

### Modules not loading
- Check file permissions: `chmod +x cortado.sh`
- Verify module files exist in `modules/` directory
- Enable debug mode: `DEBUG_MODE="true"`

### Arrow keys not working in installer
- Make sure you're running in a proper terminal (not a script)
- Try a different terminal emulator if issues persist

### Config file not loading
- Packaged `cortado.conf` and `$CLAUDE_CONFIG_DIR/cortado.conf` are sourced as bash. Cortado refuses to source either if they are group- or world-writable.
- Fix the **user** file with `chmod 600 "$CLAUDE_CONFIG_DIR/cortado.conf"` (or `644` if you want it world-readable but not writable).
- Per-directory `.cortado.conf` is never sourced. `chmod` on that file does not make it executable.

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
