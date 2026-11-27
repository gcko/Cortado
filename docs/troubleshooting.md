# Troubleshooting

## Rate limits show `--`

- Send a message. Claude Code includes your 5-hour and 7-day usage in the statusline data only after a session's first reply (seen in Claude Code 2.1.330), so a new session shows `5h:-- 7d:--` until then. No credential setup is needed.
- Make sure you use Claude Code with a Pro or Team subscription, and that you are logged in (`claude login`).
- If it still shows `--` after a reply, your Claude Code version may not send usage. Cortado then asks the usage API itself, which needs an owner-only `.credentials.json` in `CLAUDE_CONFIG_DIR` (default `~/.claude`). It does not read a login kept only in the macOS Keychain.

## A module doesn't show up

- Check that the module is turned on (`MODULE_NAME="true"`) and listed in `MODULE_ORDER`. `cortado config --show` prints both.
- Check that `cortado.sh` is executable: `chmod +x cortado.sh`.
- Check that the module file exists in `modules/`. For your own modules, see [Writing a custom module](custom-modules.md#permissions).
- Turn on debug mode with `DEBUG_MODE="true"`. Module errors, such as a missing tool or a bad setting, never print into the statusline. In debug mode they go to `cortado.log` in your Claude config directory, prefixed with the module name. The log rotates at 1 MiB and keeps one previous file, `cortado.log.1`.
- If the statusline reads `cortado: jq missing`, install `jq`. Cortado needs it to read the data Claude Code sends.

## `Config refused` or `Config partly read`

`Config partly read` means Cortado skipped lines it couldn't read as data, or values of the wrong type. Run `cortado config --show` to see each one, or `cortado config --migrate --dry-run` for a list with line numbers. [The file format](configuration.md#file-format) explains what Cortado accepts.

`Config refused` means Cortado skipped a whole config file because it couldn't prove the file is yours. Run `cortado config --show` in a terminal to see the file and the reason on stderr. When a trusted config turns on debug mode, the same details go to `cortado.log`.

Cortado trusts a config file when:

- The file belongs to you, and has no group or world write bits. The packaged config may also belong to root.
- Its directory belongs to you or root, and is group- or world-writable only if it has the sticky bit.
- On macOS, no ACL entry lets anyone but you change the file or its directory. `ls -le` lists ACL entries and `chmod -N` removes them. Entries that only read, deny, or name your own user are fine.
- Cortado can read its permissions. Missing or unreadable permission metadata causes a refusal.

For a symlink, Cortado checks the file it points to and that file's directory.

To fix a refusal:

- For a file you own, `chmod 600 /path/to/resolved/cortado.conf` removes extra write access.
- A private file can still be replaced through a writable directory. If you own that directory and can remove its shared write access, run `chmod go-w /path/to/resolved/parent`. Leave a deliberately shared directory's permissions to its owner.
- A Claude config directory you can't search also shows `Config refused` (after `chmod 600` on the directory, say, or for a symlinked config directory whose target sits under one), because Cortado can't tell whether a config is there. Run `chmod 700` on the directory. Since `cortado.log` lives in that directory, the reason appears only on stderr. A config directory that doesn't exist is not an error.

A project's `.cortado.conf` uses the same parser, with a narrower list of allowed settings.

## Arrow keys don't work in the installer

- Run the installer in an interactive terminal, not from a script.
- If it still doesn't work, try a different terminal emulator.

## Test the statusline by hand

Pipe a sample of the data Claude Code sends into Cortado:

```bash
echo '{"workspace":{"current_dir":"'$PWD'"},"model":{"display_name":"Test"},"output_style":{"name":"default"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":10000}}}' | ~/.claude/cortado/cortado.sh
```

To test a source checkout, pipe the same sample into its `./cortado.sh` and add `CLAUDE_CONFIG_DIR="$(mktemp -d)"` before the command, so the test never writes to your own config directory.
