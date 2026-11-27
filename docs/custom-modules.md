# Writing a custom module

A module is one Bash file. It holds a comment header that describes it and a function that prints one segment of the statusline. Your own modules live in your Claude config directory, so they survive Cortado updates.

## Quick start

This adds a segment that prints `🎯 My Output` after the model name.

1. Create `cortado-modules/` in your Claude config directory (`$CLAUDE_CONFIG_DIR`, which defaults to `~/.claude`), and save this as `cortado-modules/mycustom.sh`:

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

2. Turn it on in `cortado.conf`, in the same Claude config directory. This order shows the model, then your segment. To keep your current segments, add `mycustom` to your existing `MODULE_ORDER` instead.

   ```bash
   MODULE_MYCUSTOM="true"
   MODULE_ORDER="model,mycustom"
   ```

3. Make the files private. Cortado skips a module file or module directory that others can write to, and it does so silently. A shell with umask `002` (the default on Ubuntu) creates files group-writable, so run this even if you didn't change any permissions:

   ```bash
   dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
   chmod go-w "$dir"
   chmod 700 "$dir/cortado-modules"
   chmod 600 "$dir/cortado-modules/mycustom.sh" "$dir/cortado.conf"
   ```

4. Check it. `cortado config --list` shows `mycustom` in the module list. The segment appears the next time Claude Code redraws the statusline.

## Naming

- The module ID is the filename without `.sh`. Use lowercase ASCII letters, digits and hyphens.
- The function is `module_` plus the ID, and the enable flag is `MODULE_` plus the ID in uppercase. Hyphens become underscores in both: `my-thing.sh` defines `module_my_thing` and is turned on with `MODULE_MY_THING`.
- `order`, `utils` and `payload` are reserved.

## The header

Cortado reads the leading comment block of each module without running it. Only `@cortado-module` is required.

| Header | Meaning | Default |
|---|---|---|
| `@cortado-module mycustom` | The module ID. It must match the filename. | Required |
| `@default false` | Whether the module is on when the config does not say. It still runs only when its ID is in `MODULE_ORDER`. | `false` |
| `@args none` | What the function receives: `none`, `dir` (the workspace directory) or `payload` (the JSON Claude Code sent). See [Input](#input). | `none` |
| `@ttl 0` | Default probe cache lifetime in seconds. The module manages its own cache. | `0` |
| `@timeout-ms 0` | Default probe timeout in milliseconds. The module manages its own deadlines. | `0` |
| `@platforms darwin,linux` | Where the module works: `darwin`, `linux`, or both. On other platforms Cortado skips it. | `darwin,linux` |
| `@config KEY:type` | A setting the module reads, typed `bool`, `int`, `number` or `string`. See [Settings](#settings). | None |
| `@menu extra` | The category in the installer and `cortado config`: `core`, `system`, `dev` or `extra`, with an optional position number. | `extra` |
| `@description My custom segment` | The label in the installer and `cortado config`. | The ID |

## Input

With `@args dir`, the function gets the current workspace directory as `$1`:

```bash
# @cortado-module folder
# @args dir
module_folder() {
    printf '📂 %s\n' "${1##*/}"
}
```

With `@args payload`, `$1` is the JSON that Claude Code sent for this render. Read it with `jq`:

```bash
# @cortado-module output-style
# @args payload
module_output_style() {
    local style
    style=$(jq -r '.output_style.name // empty' <<< "$1" 2>/dev/null)
    printf '🎨 %s\n' "${style:---}"
}
```

Claude Code documents the fields it sends in its [statusline guide](https://code.claude.com/docs/en/statusline).

## Settings

Declare each setting your module reads with `@config`, and give it a default in the code. A custom module's settings must start with its own prefix (`FOLDER_` for `folder`), and Cortado ignores any other key it declares.

```bash
# @cortado-module folder
# @args dir
# @config FOLDER_LABEL:string
module_folder() {
    local label="${FOLDER_LABEL:-📂}"
    printf '%s %s\n' "$label" "${1##*/}"
}
```

Then set it in `cortado.conf` like any other setting: `FOLDER_LABEL="in"`. Your module still has to check the values it reads.

## What to print

- Print one line. It becomes the segment.
- Print nothing to leave the segment out.
- When the module has no reading, print `--` rather than a value that looks real. A missing reading should never show as `0` or a green indicator.
- Anything written to stderr stays off the statusline. With `DEBUG_MODE="true"`, it goes to `cortado.log` in your Claude config directory, prefixed with the module ID.
- If the function exits with an error, Cortado leaves the segment out and, in debug mode, logs the exit code.
- The function runs on every redraw, so keep it fast. To branch by platform, test `$CORTADO_OS` (`darwin` or `linux`) rather than calling `uname`.

## Permissions

Cortado loads a custom module only when all of these hold:

- Its ID is in `MODULE_ORDER` in a trusted config (your user config or the packaged one, not a project's `.cortado.conf`).
- You own the module file and `cortado-modules/`.
- The module file, `cortado-modules/` and your Claude config directory have no group or world write bits. On macOS, an ACL entry that lets others write the module file or `cortado-modules/` counts too.
- `cortado-modules/` is a regular directory. A module file may be a symlink to a file inside that directory.

A module that fails these checks is left off the statusline with no notice. With `DEBUG_MODE="true"`, `cortado.log` names what was refused. If your `cortado.conf` itself is refused, the statusline starts with `Config refused`; see [Troubleshooting](troubleshooting.md#config-refused-or-config-partly-read).

## Contributing a module to Cortado

To ship a module with Cortado, put the same file in the repository's `modules/` directory. The installer and `cortado config` find it from its header. [AGENTS.md](../AGENTS.md#adding-a-new-module) covers the rest of the contribution rules, and the files in `modules/` are worked examples.
