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

### The `cortado` command

Every install (interactive, `--defaults`, `--minimal` or `--force`) also creates `~/.local/bin/cortado`, a symbolic link to the installed `cortado.sh`, so `cortado config`, `cortado setup`, `cortado update`, `cortado uninstall`, `cortado version` and `cortado help` work from any terminal. The installer creates `~/.local/bin` if it is missing.

- If `~/.local/bin` is not on your `PATH`, the installer says so and prints the line to add: `export PATH="$HOME/.local/bin:$PATH"`, in `~/.zshrc` for zsh, or in `~/.bashrc` for bash (`~/.bash_profile` on macOS). Open a new terminal afterwards.
- The installer never replaces a `cortado` it did not make. A file, a directory, or a link to anything other than this install's `cortado.sh` is left as it is, and the installer says so and carries on. Running the installer again leaves its own link in place.
- `cortado` runs with the same settings as the statusline. If you set `CLAUDE_CONFIG_DIR` for Claude Code, set it in your shell too.
- `cortado update` and `cortado uninstall` act on the config directory the copy is installed in (the folder that holds `cortado/`), even when `CLAUDE_CONFIG_DIR` is not set. If `CLAUDE_CONFIG_DIR` names a different directory, they change nothing and print both, so one install never updates or removes another.

### Pointing Claude Code at Cortado: `cortado setup`

`cortado setup` sets `statusLine` in `$CLAUDE_CONFIG_DIR/settings.json` (usually `~/.claude/settings.json`) to the copy of Cortado it runs from. From a clone, run `./cortado.sh setup`.

- It changes only `statusLine` and keeps every other setting. A missing `settings.json` is created.
- It saves the `statusLine` it replaces where the installer does (readable only by you), so `cortado uninstall` can restore it. If a saved one is already there, it keeps that one: the statusline you had before Cortado. A `statusLine` that runs a `cortado.sh` is never saved as the one to restore.
- If `settings.json` is a symbolic link (to a dotfiles repository, say), the link stays and the file it leads to is updated. A link that leads to no regular file is refused.
- Running it again when Claude Code already runs this copy changes nothing.
- It refuses a `settings.json` that is not one JSON object (or not a regular file), says why, and changes nothing.
- From a Homebrew install it writes the stable `opt` path (for example `/opt/homebrew/opt/cortado/...`), never the versioned `Cellar` path that `brew upgrade` removes. If the `opt` link does not lead to this copy, it changes nothing and says so.

Restart Claude Code to see the change.

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

./install.sh --uninstall     # Uninstall, remove the cortado command, restore your previous statusline
./install.sh --help          # Show all options
```

The update options work for a source install (a git clone) and for the installed copy. Homebrew does not ship them.

## Updating

```bash
cortado update               # from any terminal
./install.sh --update        # from the clone
```

`cortado update` runs the installed copy's own `install.sh --update`, so it needs no clone. It accepts `--no-color` and `--no-emoji`. On a Homebrew install it changes nothing and says to run `brew upgrade cortado`. A copy installed before `cortado update` existed has no `install.sh`; it says so, and one `./install.sh --update` from the clone adds it.

`./install.sh --check-update`, `./install.sh --update` and `cortado update` use the latest published [release](https://github.com/gcko/Cortado/releases) on GitHub, not the `main` branch. The statusline's `update` module checks the same repository. The installer also checks for a newer release each time you run it, unless you pass `--skip-update-check`.

- If the installer cannot find a release, these commands exit with status 1 and print `Could not determine the latest version`.
- The installer refuses to `--update` a Homebrew Cellar or opt prefix.
- When it updates by downloading an archive, it checks `Cortado-source.zip` against the release's `SHA256SUMS` file before replacing any files. Each download has 5 seconds to connect and 60 seconds to finish. A timeout, a missing checksum or a mismatch stops the update.

### The installed copy

`cortado update` always replaces the installed copy this way. From the clone, when `settings.json` runs the installed copy at `~/.claude/cortado/cortado.sh`, `--update` refreshes that copy too:

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

2. Point Claude Code at it. Run `"$CLAUDE_DIR/cortado/cortado.sh" setup`, or edit `settings.json` in the same directory:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/cortado/cortado.sh"
     }
   }
   ```

3. Optionally, add the `cortado` command. Cortado runs correctly through a link:

   ```bash
   mkdir -p ~/.local/bin
   ln -s "$CLAUDE_DIR/cortado/cortado.sh" ~/.local/bin/cortado
   ```

4. Restart Claude Code.

## Uninstall

```bash
cortado uninstall            # from any terminal
./install.sh --uninstall     # from the clone
```

`cortado uninstall` runs the installed copy's `install.sh --uninstall`. On a Homebrew install it deletes no files: it puts back the saved `statusLine` (or removes Cortado's) and says to run `brew uninstall cortado`.

Uninstalling removes `statusLine` only when it runs a `cortado.sh`. A statusline you set since installing Cortado is left as it is, and the uninstaller says so. The installer offers to restore the statusline you had before, if it backed one up. It removes `~/.local/bin/cortado` only when it is a link to this install's `cortado.sh`, and leaves `~/.local/bin` and everything else in it.
