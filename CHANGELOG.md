# Changelog

All notable changes to Cortado, newest first.

Cortado is a fork of [Barista](https://github.com/pstuart/Barista) by Patrick D. Stuart. The versions below, up to 1.8.0, are Barista releases. Cortado's own releases will be added above them.

## 1.8.0

- **`cortado config` TUI.** Reconfigure modules, theme and WAN privacy after installing, without re-running the installer (`cortado config`, `--show`, `--set`, `--toggle`).
- **Homebrew install.** `brew tap pstuart/tap && brew install barista` installs the upstream Barista formula. Cortado does not have a formula yet.

## 1.7.0

- **Smart 429 backoff.** Respects `Retry-After` headers for precise backoff timing instead of fixed delays.
- **Unknown module fix.** The installer no longer errors on unrecognized module names in config.
- **Privacy hardening.** WAN IP lookup is now opt-in and redacted by default.
- **Security hardening.** Improvements to config injection, `eval` usage, token exposure and download validation.

## 1.6.1

- **Private credential file.** Reads the Claude Code OAuth token from an owner-only `.credentials.json` file. No system Keychain access or migration. File permissions do not protect against other processes running as the same user.
- **Fail-closed credentials.** Missing, unsafe, malformed or unrelated credential files return no token, without invoking `security`.

## 1.6.0

- **Rate limit 429 backoff.** Automatically backs off API calls after receiving 429 responses.
- **Version display.** Shows the current version in the installer and statusline.
- **Update checker.** Enhanced update checking from GitHub releases.

## 1.5.0

- **Smart terminal layout.** A new `LAYOUT_MODE` setting with line wrapping:
  - `smart` (default): wraps at separator boundaries when the content is wider than the terminal.
  - `newline`: moves Claude's right-side info to the next line.
  - `wrap`: pads output to the line boundary.
  - `truncate`: shortens output to fit on the same line. The marker uses up to three dots, depending on the space available.
  - `none`: no adjustment, natural terminal behaviour.
- Prevents awkward line breaks in the middle of a module on wide statuslines.
- Configurable `RIGHT_SIDE_RESERVE` and `TERMINAL_WIDTH` settings.

## 1.4.0

- **Custom config directory.** Respects the `CLAUDE_CONFIG_DIR` environment variable for users who move their Claude configuration out of `~/.claude/`.
- All paths (cache, logs, usage history, user config) resolve dynamically.
- Nothing changes if you use the default location.

## 1.3.0

- More color theme settings.
- **Improved spacing.** Status indicators have proper spacing in normal and verbose modes.
- **Smart compact mode.** Compact mode removes separator padding and status spacing automatically.
- **Fixed installer preview.** The preview shows sample data instead of just icons.

## 1.2.0

- **Memory optimizations.** Fixed unbounded growth of the history file, and added file size caps.
- **Interactive update check.** The installer offers to check for updates on startup and shows the version.
- **4-level rate limit colors.** Indicators at the 50%, 75% and 95% thresholds (🟢 🟡 🟠 🔴).
- **Monorepo performance.** The git module limits its output to prevent memory spikes in large repositories.

## 1.1.0

- **Auto-update checking.** Checks GitHub for updates and can update itself.
- **Interactive installer.** Arrow keys to move, Space to toggle selections.
- **Customizable separators.** Pipe, arrow, bullet and more.
- **Color themes.** Default (emoji) or monochrome (ASCII).
- **Display modes.** Normal, compact or verbose output.
- **Live preview.** See your statusline before installing.
- **Bash 3.2 compatible.** Works with the default bash on macOS, no Homebrew needed.
