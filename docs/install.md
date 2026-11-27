# Installing and updating Cortado

The [README](../README.md#install) has the short version. This page covers the details.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
- macOS or Linux, including WSL. Windows is not supported.
- Bash 3.2 or newer. The default bash on macOS works.
- `jq`, to read the data Claude Code sends. On macOS: `brew install jq`.
- Perl, for background probes and Git and session cache metadata. macOS includes it.
- `bc`, only for the optional temperature module. Most systems include it.

Platform notes:

- The battery and sandbox modules run only on macOS. On Linux they are left out of the line.
- Rate-limit tracking works on macOS and Linux, including WSL.
- On any other platform (Git Bash, Cygwin, BSD) the statusline reads `cortado: unsupported platform`. On Git Bash or Cygwin you can try the Linux modules by setting `CORTADO_OS=linux` in the environment or in `cortado.conf`, but that setup is unsupported. BSD has no such opt-in.

## Install from source

```bash
git clone https://github.com/gcko/Cortado.git
cd Cortado
./install.sh
```

Cortado doesn't have a Homebrew formula yet, so install from source.

The interactive installer:

- lets you pick modules by category (core, system, dev tools and extra). Use ↑ and ↓ to move, Space to toggle and Enter to confirm.
- sets icons, separators, colors and theme.
- shows a live preview of your statusline before it installs.
- backs up your previous statusline.

It installs Cortado in `$CLAUDE_CONFIG_DIR/cortado/` (usually `~/.claude/cortado/`) and points `statusLine` in Claude Code's `settings.json` at `cortado/cortado.sh`. Restart Claude Code to see the new statusline.

## Installer options

```bash
./install.sh                 # Interactive install
./install.sh --defaults      # Install the core modules, no prompts
./install.sh --minimal       # Quick install with a minimal set of modules
./install.sh --force         # Same as --defaults, with no confirmation

./install.sh --no-emoji      # Install without emoji (ASCII mode)
./install.sh --no-color      # Install without colors

./install.sh --check-update       # Check for a newer release
./install.sh --check              # Alias for --check-update
./install.sh --update             # Install the latest release
./install.sh --skip-update-check  # Skip the automatic update check during install
./install.sh --version            # Show the current version

./install.sh --uninstall     # Uninstall and restore your previous statusline
./install.sh --help          # Show all options
```

The update options work for a source install (a git clone). Homebrew does not ship them.

## Updating

`./install.sh --check-update` and `./install.sh --update` use the latest published [release](https://github.com/gcko/Cortado/releases) on GitHub, not the `main` branch. The statusline's `update` module checks the same repository. The installer also checks for a newer release each time you run it, unless you pass `--skip-update-check`.

- If the installer cannot find a release, these commands exit with status 1 and print `Could not determine the latest version`.
- The installer refuses to `--update` a Homebrew Cellar or opt prefix.
- When it updates by downloading an archive, it checks `Cortado-source.zip` against the release's `SHA256SUMS` file before replacing any files. Each download has 5 seconds to connect and 60 seconds to finish. A timeout, a missing checksum or a mismatch stops the update.

### The installed copy

When `settings.json` runs the installed copy at `~/.claude/cortado/cortado.sh`, `--update` refreshes that copy too:

- It builds the new copy beside the old one, carries over your `cortado.conf` and any other files you added, then swaps the two.
- If a step fails, or Ctrl-C, TERM or HUP interrupts the update, the old copy goes back in place. If it can't go back, the installer leaves it unchanged and prints where it is.
- If the update is killed outright (SIGKILL, a crash or a power cut) after it moved the old copy aside, the next `--update` puts that copy back first and names the folder it came from. Then it updates as usual, so your `cortado.conf` comes along.
- An older copy left beside it by an interrupted update is kept, and each update names it until you remove it.
- `--update` will not refresh a `~/.claude/cortado` that is a symbolic link or not a directory. It changes nothing there and exits with status 1. A link to the source clone you are updating from, or to a Homebrew prefix, is skipped without an error. A `~/.claude` that is itself a symbolic link works as usual.

### One update at a time

Only one update or install changes the installed copy at a time. A second `--update` or `./install.sh` started while another is running changes nothing, exits with status 1, and names the other installer's process and the lock file, `~/.claude/.cortado-update.lock`.

The next update clears a lock left by an installer that is no longer running. The lock knows its holder only by process ID, which has some limits:

- If a new process reuses that ID, an old lock looks held. Remove it by hand.
- Installers in different containers that share one `~/.claude` can't see each other's processes.
- Three installers clearing the same old lock in the same instant could end up running together.

## Manual install

1. Copy Cortado into your Claude config directory:

   ```bash
   CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
   cp -r . "$CLAUDE_DIR/cortado"
   chmod +x "$CLAUDE_DIR/cortado/cortado.sh"
   ```

2. Point Claude Code at it. Edit `settings.json` in the same directory:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/cortado/cortado.sh"
     }
   }
   ```

3. Restart Claude Code.

## Uninstall

```bash
./install.sh --uninstall
```

The installer offers to restore the statusline you had before, if it backed one up.
