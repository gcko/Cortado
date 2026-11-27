# Migrating from Barista

Cortado began as a fork of [Barista](https://github.com/pstuart/Barista) by Patrick D. Stuart and is now developed as its own project at [gcko/Cortado](https://github.com/gcko/Cortado). Install it the usual way (see [Installing](install.md)) and it picks up your Barista settings.

## What carries over

### Your config

When there is no `$CLAUDE_CONFIG_DIR/cortado.conf`, Cortado and the installer copy a trusted `barista.conf` to it, keeping its permissions and leaving the original in place. If the copy fails, or the destination directory fails the permission check, Cortado reads the legacy file where it is, and `cortado config` shows and edits `barista.conf`. A dangling `cortado.conf` symlink counts as an existing file, so nothing is copied over it.

### Project configs

Cortado reads a project's `.barista.conf` when there is no `.cortado.conf` next to it. The first successful save with `cortado config --project` writes the allowed settings to `.cortado.conf` and leaves `.barista.conf` in place.

### Your statusline setting

The installer puts Cortado in `$CLAUDE_CONFIG_DIR/cortado/` and points `statusLine` in `settings.json` at `cortado/cortado.sh`. It backs up your previous `statusLine` command, so `./install.sh --uninstall` can switch back to Barista.

### Cache and logs

These move to `cortado-cache/` and `cortado.log` and are rebuilt automatically. `.usage_history` keeps its name.

### Config files are data

Config files are now read as data and never run as Bash. If your `barista.conf` runs commands or expands variables, see [Upgrading from a config that runs Bash](configuration.md#upgrading-from-a-config-that-runs-bash).

## Cleaning up

Once Cortado works, you can remove the old files from your Claude config directory: `barista/`, `barista.conf`, `barista-cache/` and `.barista-backup/`.

If you installed Barista with Homebrew, also run:

```bash
brew uninstall barista
brew untap pstuart/tap
```
