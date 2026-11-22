---
name: visual-review-and-fix
description: Use before and after building a Cortado change, to render the statusline the way its reader sees it with missing, stale and odd input forced, hold new work to what that reader expects, and keep the tests behavioural.
---

# visual-review-and-fix

Render the statusline, read it the way the person glancing at the bottom of their terminal reads
it, and find what the suite cannot see.

This skill rests on one measured claim. **Cortado's defect class is the confident wrong answer in
an absence.** On 2026-11-22, with `main` at `7503194`, all 14 test suites green and ShellCheck at
its baseline, one afternoon of rendering found:

- Every status indicator broken in both directions: a healthy reading printed all of its glyphs
  at once (`25% 🟢 🟡 🔴` for context, `42% 🟢 🟡 🟠 🔴` for rate limits), and a warning or critical
  reading printed none (`65%  (30k→⚡)`), so the line went quiet exactly when it should have
  warned. Seen in a live Claude Code session as well as from a fixture. `cortado.sh` ran the
  modules with `IFS=','`, and the status helpers split their glyphs with `read`, so the first
  variable took every glyph and the others were empty. `get_status` is correct when called on its
  own, which is how its tests called it.
- A payload with no `context_window_size` rendering context as `50000000%`, because the missing
  field defaults to `1` rather than to the 200k fallback.
- A quota reading cached six hours earlier, with the fetch failing, rendered exactly as a fresh one:
  `5h:42% [OK]`, no stale marker.
- A quota object with no `utilization` rendered as `5h:0% [OK]`.
- A session with no `current_usage` rendered as `0%` and green, the same line an empty session gets.

None of those was found by a failing test, because a test asserts what the code does with data it
was handed, and this class is about what the line says when the data is not there.

So the review is not a look at the layout. It is a walk through the questions the line answers, with
the awkward inputs forced, and a check that every silence is a stated absence (`5h:-- 7d:--`) rather
than an implied all-clear.

Run it **twice**: once before development, to find what is already wrong and to write down what the
build will be held to, and once after, to catch what the change broke.

## When it is owed, and how much

| The change | Before | After |
|---|---|---|
| Changes what a module prints: text, a threshold, a glyph, a theme, the separator or the wrap layout | Full walk of the stages it touches | Same |
| Changes which payload field a module reads, or a fetch, cache or history path | The stages that render it, from a captured real payload | Same, plus a live session (Mode 2, step 6) |
| Changes `cortado.conf` defaults, `cortado config`, or the installer's generated config | Render under the config it produces | Same |
| Refactors `modules/utils.sh` or `cortado.sh`'s loading or module loop, even with "no output change" | The render matrix below, default and monochrome | Same, against the merge base |
| A doc claim about what the statusline shows | The one surface it describes | Same |
| Tests or prose only, nothing on the rendered path | Skip, and say in the report that you skipped it | Skip, and say so |

The refactor row exists because of the first finding above: it came from a refactor whose whole
point was that output would not change (`62e7ec8`, which extracted the status helpers).

The Skip rows are a real answer, not an escape. Say which mode you skipped and why, so the next
reader knows the walk was considered rather than forgotten.

## Prerequisites

- `bash`, `jq` and the tree under review. Rendering needs no network and no credentials.
- A sandbox config directory for every render. Never point a worktree's `cortado.sh` at the real
  `~/.claude`: it writes `cortado-cache/`, and the Barista migration copies `barista.conf` to
  `cortado.conf` on first run.
- For the live-session check: `tmux` and a logged-in `claude` on PATH.

## The render harness

Paste this into the shell you review from. It renders one payload against one tree with one
config, in a fresh sandbox, and strips only real colour escapes:

```bash
# render <tree> <payload-json> [config lines...]
render() {
    local tree="$1" payload="$2" sb; shift 2
    sb=$(mktemp -d)
    mkdir -p "$sb/cortado-cache" && chmod 700 "$sb/cortado-cache"
    printf '%s\n' "$@" > "$sb/cortado.conf" && chmod 600 "$sb/cortado.conf"
    [ -n "${SEED_CACHE:-}" ] && cp "$SEED_CACHE" "$sb/cortado-cache/rate_limits_usage"
    [ -n "${SEED_AGE:-}" ] && touch -t "$(date -v-"$SEED_AGE" +%Y%m%d%H%M)" "$sb/cortado-cache/rate_limits_usage"
    printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$sb" /bin/bash "$tree/cortado.sh" 2>&1 \
        | sed $'s/\x1b\\[[0-9;]*m//g'
    rm -rf "$sb"
}
```

`/bin/bash` is deliberate: on macOS it is Bash 3.2, the floor Cortado supports, and the test suite
runs under whatever `bash` is first on PATH. `SEED_CACHE` (a JSON file) and `SEED_AGE` (a BSD `date
-v` offset such as `6H`) plant a rate-limit reading. `date -v` is macOS-only; on Linux use
`touch -d '6 hours ago'`.

Pin the modules you are reviewing, so the line holds only what you are reading:

```bash
P='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'
render . "$P" 'MODULE_ORDER="context,model"' 'MODULE_CONTEXT="true"' 'MODULE_MODEL="true"' 'COLOR_THEME="monochrome"'
```

The render matrix, for any change on the rendered path: the payload above and one captured real
payload, each under `COLOR_THEME` `default` and `monochrome`, `DISPLAY_MODE` `normal` and `compact`,
and `TERMINAL_WIDTH` `60` and `200`.

## Mode 1: before development

### 1. Name the question you are about to touch

The statusline answers six questions, set out in [the walk](references/the-walk.md). Write down
which one the issue changes, what the line says today, and what it should say when it does not know.
If no question is touched, the "Tests or prose only" row applies.

### 2. Get real data

Render from a captured real payload, not only from a payload you wrote. A hand-written fixture
agrees with the code that was written by the same hand; a captured one shows what Claude Code
actually sends. Capture one with the live-session recipe (Mode 2, step 6). On 2026-11-22 the
startup payload from Claude Code 2.1.330 carried `context_window.context_window_size: 1000000`, no
`current_usage`, and an `effort` and `thinking` block, none of which the hand-written fixtures in
this repository had.

Redact before a capture goes anywhere near a commit: it holds `session_id`, `transcript_path`,
`cwd`, `workspace.added_dirs` and other private paths.

### 3. Walk the stages the change touches

Render each stage the issue touches and read the rendered text. Quote it in your report. Read the
line, not the source: `get_status` read correctly and printed correctly in isolation while every
statusline printed three glyphs.

### 4. Attack the absences

This is the highest-yield step and the reason the skill exists: four of the five findings above
needed an absent, stale or odd input to reach at all. For every module the issue touches, force the
input where there is nothing to say and check the line says that rather than implying the opposite:

- The field missing, the field `null`, and the field present as `0`. Three inputs, and the line must
  not render the first two as the third.
- No credentials file, and one that is not owner-only.
- A fetch that fails with a cached reading on disk, fresh and hours old.
- A 429 backoff file in place.
- The tool a module shells out to missing or failing: not a git repository, Docker not running.
- Each theme, `USE_ICONS="false"`, and `STATUS_STYLE` `ascii` and `dots`.

The standard to hold new work to is the code's own best case: `rate-limits` prints `5h:-- 7d:--`
when it has no reading, and `⏸ API cooldown 5m` during a backoff with nothing cached. Anything new
that prints a number, a zero or a green where those print a placeholder is a finding.

### 5. Write the criteria the build will be held to

Turn the walk into acceptance criteria the `burndown` skill can carry, each one rendered text a
reader can see, each with its own `Verified by:` clause naming the render that settles it. "With no
`context_window_size`, the context segment shows a placeholder, not a percentage. Verified by:
render of the payload with the field removed" is reviewable. "`json_get_int` gets a better default"
is not.

### 6. Dispose of what you found

Everything Mode 1 finds predates the change you are about to make, so it is filed as a GitHub issue
with the payload, the config lines and the rendered text, never folded into the branch you are about
to open. The exception is a finding that makes the issue's own plan wrong: that is a correction to
the issue, and it belongs there before any code is written.

## Mode 2: after development, before the pull request opens

Run this in the worktree with the change applied and before `gh pr create`.

### 1. Re-walk what you walked before

Same stages, same absences, same render matrix. You are looking for two things: the property the
issue promised, and anything that used to read correctly and now does not.

### 2. Compare against the merge base, not against your memory

For anything that looks wrong, render the same payload and config against the base before calling
it a regression:

```bash
base=$(mktemp -d); git archive "$(git merge-base origin/main HEAD)" | tar -x -C "$base"
render "$base" "$P" 'MODULE_ORDER="context"' 'MODULE_CONTEXT="true"'
render .       "$P" 'MODULE_ORDER="context"' 'MODULE_CONTEXT="true"'
rm -rf "$base"
```

That separates "the change made it worse", which is fixed in this branch, from "this was always
so", which is filed.

### 3. Check the regression classes this repository has actually shipped

Each of these was measured on `main` on 2026-11-22:

- **Global shell state leaking into modules.** A module runs inside the caller's `IFS`, `set -f` and
  working directory. A loop that sets `IFS=','` and calls modules before restoring it broke every
  `read`-based split below it.
- **A fallback that is a valid value.** `json_get_int ... 1` made a missing window size a window of
  one token. A default must be distinguishable from a reading.
- **A stale reading presented as current.** The rate-limit cache is served for up to 24 hours when a
  fetch fails, and only a backoff adds a marker.
- **Missing presented as zero.** `jq '... // 0'` turns an absent value into a confident `0%` with a
  green indicator.

And two that have not been seen here yet but are cheap to check: the wrap layout at
`TERMINAL_WIDTH` `60`, and output under `/bin/bash` 3.2 when the change uses any Bash 4 syntax.

### 4. Hold the tests to behaviour

Apply "Behavioural testing first" below to the tests the change added. A change that shipped without
a test of the rendered text for the property the reader sees has a Mode 2 finding against it.

### 5. Dispose

- **Your change introduced it**: fix it here, before the PR opens.
- **It predates your change**: file it, with the base render that proves it predates.
- **You cannot tell**: say so, and file it as unsettled rather than guessing.

### 6. Walk a real session when the change reaches one

A fixture shows what Cortado does with a payload. Only a live session shows the payload Claude Code
actually sends and the line as the terminal draws it. Walk one when the change reads a new payload
field, changes how the line wraps, or touches the module loop. This recipe was run on 2026-11-22:

```bash
WALK=$(mktemp -d)
mkdir -p "$WALK/project" "$WALK/captures" "$WALK/claude-cfg"
(cd "$WALK/project" && git init -q && echo "# scratch" > README.md)
cat > "$WALK/statusline.sh" <<EOF
#!/bin/bash
payload=\$(cat)
printf '%s\n' "\$payload" > "$WALK/captures/\$(date +%s).json"
printf '%s' "\$payload" | CLAUDE_CONFIG_DIR="$WALK/claude-cfg" "$PWD/cortado.sh"
EOF
chmod +x "$WALK/statusline.sh"
cd "$WALK/project" && tmux new-session -d -s cortado-walk -x 160 -y 40 \
  "claude --settings '{\"statusLine\":{\"type\":\"command\",\"command\":\"$WALK/statusline.sh\"}}'"
cd - >/dev/null
```

Run it from the worktree root, because the wrapper renders `$PWD/cortado.sh`. `--settings` adds
the statusline for this session only and leaves your own settings alone. Claude Code asks whether to
trust the new scratch folder. Answer it only for a scratch folder you created, and only once the
menu is live: keys sent as soon as the word "trust" appears are dropped, and a lone Enter then
selects "No, exit" and ends the session.

```bash
until tmux capture-pane -p -t cortado-walk 2>/dev/null | grep -q 'Enter to confirm'; do sleep 0.5; done
sleep 1.5
for i in 1 2 3 4 5; do
  tmux capture-pane -p -t cortado-walk | grep -q '❯ Yes, I trust' && break
  tmux send-keys -t cortado-walk Down; sleep 0.7
done
tmux capture-pane -p -t cortado-walk | grep -q '❯ Yes, I trust' && tmux send-keys -t cortado-walk Enter
```

Then read the line and the payload:

```bash
tmux capture-pane -p -t cortado-walk | grep -v '^\s*$' | tail -4
jq . "$WALK/captures/$(ls "$WALK/captures" | tail -1)"
```

The startup payload has no `current_usage` and no usage figures. Seeing them populated needs a
turn, and a turn is a model call: ask the owner before sending a prompt. Stop what you started:

```bash
tmux kill-session -t cortado-walk
pgrep -fl "$WALK/statusline.sh" || echo "no leftovers"
rm -rf "$WALK"
```

`claude` can take a few seconds to exit after its tmux session is killed (about three, measured
twice on 2026-11-22), so a `pgrep` straight after the kill can name a process that is already on its
way out. Check again before treating it as an orphan.

## Behavioural testing first

`AGENTS.md` requires a failing test before the fix. This skill is about what that test is allowed
to assert.

A behavioural test here:

- **Drives the statusline as Claude Code does**: a JSON payload piped to `cortado.sh` with a
  sandboxed `CLAUDE_CONFIG_DIR`, as `tests/test_config_cli.sh` does, rather than a helper called in
  isolation. The IFS defect is invisible to any test that calls `get_status` directly.
- **Is named as a sentence about what the reader sees.** "a missing window size shows a placeholder,
  not a percentage" is a claim someone can check; "json_get_int default" is not.
- **Asserts the rendered text**, not the shape of the data behind it.
- **Covers the absence**, because that is where this product fails.

Then prove it. **Break the source the test defends and watch it go red.** A mutation that comes back
green does not mean the code is safe; it means the test is wrong.

Restore by file copy, never by `git checkout --`, which also discards any uncommitted work in that
file.

## Delegating to Codex and Antigravity

The render harness is plain shell, so a delegate can reproduce a finding, unlike a browser walk.
Hand each one a self-contained, read-only job with the harness pasted in:

```bash
command -v codex && codex --version
command -v agy   && agy --version
codex exec --sandbox read-only "$(cat prompt-a.txt)" < /dev/null > out-a.txt 2>err-a.txt &
agy --sandbox -p="$(cat prompt-b.txt)" > out-b.txt 2>err-b.txt &
```

- `codex exec` waits for EOF on an open stdin, so always close it with `< /dev/null`.
- `agy`'s `-p` consumes the very next token, whatever it is. Attach the prompt as `-p="..."` or put
  it straight after `-p`; `agy -p --sandbox "prompt"` makes `--sandbox` the prompt.
- Keep them read-only. An edit landing mid-review turns correct findings into false refutations.

**What to delegate:** falsifying a claim against the code, enumerating every module's fallback
values, and recomputing a figure. **What never to delegate:** the live session. Only the
orchestrator has the logged-in `claude`. Treat every delegated verdict as a candidate: ask for
`file:line` and the exact render command, and run it yourself before acting on it.

## Terminal harness traps

Each of these produced a wrong reading during the 2026-11-22 walk:

- **Stripping colour with `sed 's/\[[0-9;]*m//g'` eats real text.** It removed `[1m` from the model
  name `Opus[1m]` and printed `Opus]`. Match the escape character too, as the harness does, or read
  raw output with `cat -v`.
- **A sandbox reused across scenarios carries its cache forward.** A "fresh" render reads the last
  scenario's `cortado-cache/`. The harness makes a new sandbox per render for that reason.
- **A pipe has no terminal width.** Wrapping follows `TERMINAL_WIDTH`; set it to compare layouts.
- **A theme can hide a defect.** The three-glyph indicator is obvious in `monochrome`
  (`[OK] [WARN] [CRIT]`) and easy to read past in emoji. Render both.

## What this review cannot see

- **Security boundaries.** Whether a token reaches a log, a cache file's mode, what a project's
  `.cortado.conf` can execute. The rendered line looks identical either way; these need the
  full-adversarial review tier in `AGENTS.md` and a mutation test of the guard.
- **Whether a network call happened.** The line saying `5h:--` does not tell you whether a fetch was
  tried. `DEBUG_MODE="true"` and `cortado.log` in the sandbox do.
- **Latency.** Claude Code runs the statusline often. Time a render (`time render ...`) when a change
  adds a subprocess or a fetch.
- **Linux and Git Bash.** The harness above is macOS-flavoured (`date -v`, `/bin/bash` 3.2). A
  change to a platform branch needs that platform.

When a finding falls in one of these, say which, and name the instrument that would settle it.

## Hard rules

Never render a worktree against the real `~/.claude`. Use a sandbox `CLAUDE_CONFIG_DIR`.

Never edit the tree while a review is running, yours or a delegate's.

Never promote a Mode 1 finding into the branch. File it.

Never assert a defect from source alone when the claim is about what the reader sees. Quote the
rendered line, with the payload and config that produced it.

Stop every tmux session and `claude` process you start, and say what you did not check: a stage you
skipped, an absence you could not force, a platform you had no machine for. An unstated gap reads as
a clean result.
