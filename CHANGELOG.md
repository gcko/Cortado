# Changelog

All notable changes to Cortado, newest first.

Cortado is a fork of [Barista](https://github.com/pstuart/Barista) by Patrick D. Stuart. 2.0.0 is Cortado's first release of its own. The versions from 1.8.0 down are Barista releases.

## 2.2.0

Install Cortado with Homebrew, or without git at all.

- `brew install gcko/tap/cortado`, then `cortado setup`, installs Cortado from the new [gcko/homebrew-tap](https://github.com/gcko/homebrew-tap). The tap tests every formula on macOS and Linux, and opens a pull request for each new Cortado release (gcko/homebrew-tap#1, gcko/homebrew-tap#2).
- On a Homebrew install, the statusline's update notice says `brew upgrade cortado` (#141).
- `get-cortado.sh`, attached to each release, installs Cortado without git or Homebrew. It checks the release's checksum before it unpacks or runs anything (#144).
- `./install.sh --update` and `cortado update` now create the `cortado` command when it is missing, so a 2.0.0 install gets it from its next update (#142).
- The docs lead with Homebrew, and cover all three ways to install (#143, #144).

## 2.1.0

A real `cortado` command, with everything you need to set up, update, check and remove Cortado without the git clone.

- The installer puts `cortado` in `~/.local/bin` and tells you how to add it to your PATH if needed. It never replaces a `cortado` it did not create (#133).
- Cortado runs correctly through a symlink. A link no longer loads the `lib/` and module files next to it (#133).
- `cortado setup` points Claude Code at the copy you run it from. It keeps your other settings, keeps a symlinked `settings.json` a link, and on Homebrew writes the stable path (#136).
- `cortado update` and `cortado uninstall` work from the installed copy, which now includes its installer. They act only on the copy they run from, and refuse, changing nothing, if `CLAUDE_CONFIG_DIR` names another one (#136).
- Uninstall removes the statusLine only when it runs Cortado (#136).
- `cortado doctor` checks an install end to end and prints the command that fixes each problem. It makes no network request and changes no file (#137).
- The statusline notices now say what to run: `Config refused: run cortado doctor` and `Config partly read: run cortado config --show` (#138).

## 2.0.0

Barista becomes Cortado: a new name, a new home at gcko/Cortado, and the Apache 2.0 license. This release also changes how config files are read, so check the breaking changes before you upgrade.

### Breaking changes

- Barista is renamed Cortado (#1). It installs to `~/.claude/cortado/` and reads `cortado.conf`. Your Barista settings carry over the first time it runs: see [Migrating from Barista](docs/migrating-from-barista.md).
- Config files are read as data and never run (#96). Cortado skips a line that runs a command or expands a variable, and the statusline shows `Config partly read`. `cortado config --migrate --dry-run` lists those lines. Setting `CORTADO_CONF_ALLOW_BASH=1` in Claude Code's environment keeps the old behaviour for your user config for now: see [Upgrading from a config that runs Bash](docs/configuration.md#upgrading-from-a-config-that-runs-bash).
- Cortado refuses a config file it can't prove is yours (#68, #103). A file that others can write, or that sits in a directory others can write, is skipped, and the statusline starts with `Config refused`. `cortado config --show` says which file and why.
- A project's `.cortado.conf` can only change display settings and turn modules off (#39).
- Cortado supports macOS and Linux, including WSL. On other platforms the statusline reads `cortado: unsupported platform` (#84).
- Cortado now needs Perl, for background probes and cache metadata. macOS and most Linux distributions include it. `bc` is now needed only by the optional temperature module.

### New

- Rate limits come from the data Claude Code sends, so they need no credential (#10).
- Shows how much of your spend limit is used, when Claude Code sends one (#67).
- A reading Cortado doesn't have shows `--`, never a stale, dropped or made-up value. A cached rate-limit reading that is out of date shows its age (#45, #52, #60, #66, #100).
- A custom module is one file in `cortado-modules/`: see [Writing a custom module](docs/custom-modules.md) (#71).
- `cortado config --set` and the menu change only the settings you changed, and keep everything else in the file (#72, #103).

### Fixes and speed

- Each render parses the payload once and runs slow network and system probes in the background, so a slow probe never freezes the line (#50, #61, #69, #102).
- `./install.sh --update` checks the release archive against its checksum, can't hang, and keeps your config if it is interrupted or runs twice at once (#62, #101).
- Two sessions at once never garble each other's cache or temp files (#40), and an install path with a space works (#41).
- An update check that fails says so, instead of reporting that you have the latest version (#43).

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
