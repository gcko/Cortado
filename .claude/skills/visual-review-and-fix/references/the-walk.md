# The walk

The statusline answers six questions for the person glancing at it. Each stage below names the
modules that answer it, what a reading looks like, the absences to force, and the limit that has to
stay true. Walk the stages the issue touches, not all six, unless the change reaches the module loop,
`utils.sh` or the layout.

"A reading" shows what a correct line looks like. The behaviour described under each absence is
what the harness in [the skill](../SKILL.md#the-render-harness) rendered on 2026-11-22 with `main`
at `7503194`; on that date every status indicator also printed all of its glyphs at once, which the
readings below leave out. Re-render rather than trusting these copies: the line is the authority,
and a fix will change some of them.

## S1. Where am I?

**Modules:** `directory`, `git`, `project`, `sandbox`.

**A reading:** `📁 Barista | 🌿 main [●+] 📝 2`.

**Force these absences:**

- No `workspace.current_dir` in the payload. The code falls back to `.cwd`, then to `.`; check
  which directory the segments then describe.
- A directory that is not a git repository, a detached HEAD, and a repository large enough to hit
  the git module's output cap.
- `git` missing from PATH.

**The limit:** the git segment is cached (TTL), so it can lag a commit by the cache age.

## S2. How much room is left in this conversation?

**Module:** `context`.

**A reading:** `📊 ██░░░░░░ 25% 🟢 (110k→⚡)`, with the tokens left before auto-compact in brackets.

**Force these absences:**

- `current_usage` missing or `null`. Today the line reads `0%` and green, exactly as an empty
  session does, so the reader cannot tell "nothing used" from "nothing reported".
- `context_window_size` missing. Today the line reads `50000000%`, because the missing field
  defaults to `1`.
- A 1M window (`context_window_size: 1000000`), which current Claude Code sends for 1M models.
- Usage past the compact threshold, where the bracket reads `(0→⚡)`.

**The limit:** the percentage is computed from the four `current_usage` token counts against the
window size. Claude Code's own context display may count differently.

## S3. Will I hit my plan's limit?

**Module:** `rate-limits`. This is the stage where Cortado has failed most often.

**A reading:** `5h:42% 🟢 (2h 0m) 7d:10% 🟢 (2h 0m)`, the reset countdown in brackets.

**Sources:** the payload's `rate_limits` first (sent after a session's first turn), then the usage
API with an owner-only credential file. Walk both.

**Force these absences:**

- A payload with no `rate_limits`, as at session start, and no credential file. The line reads
  `5h:-- 7d:--`, which is honest, and says nothing about why.
- A payload with `rate_limits` beside a cached API reading or a 429 backoff file: the payload's
  figures, with no cooldown marker.
- A payload with one window, or a non-numeric `used_percentage`: the placeholder, not a guess.
- A payload reading followed by a payload without one: the placeholder, not the earlier reading
  replayed as current.
- A credentials file that is not owner-only (mode 644), on the API path. Same placeholder; the
  refusal is only in the debug log.
- A fetch that fails with a cached reading on disk. Plant one with `SEED_CACHE` and `SEED_AGE=6H`:
  today the six-hour-old reading renders exactly as a fresh one.
- A 429 backoff with nothing cached: `⏸ API cooldown 5m` (`WAIT: API cooldown 5m` in monochrome).
- A 429 backoff with a cached reading: the reading plus a `⏸` cooldown marker.
- A window object with no `utilization`. Today it renders `0%` and green.
- One window present and the other `null`: the whole segment falls back to the placeholder.
- A `resets_at` already in the past.

**The limit:** the figures are what Claude Code last sent, or what the Anthropic usage endpoint
returns for the logged-in account, no more often than the cache TTL (`RATE_CACHE_TTL`, 120 seconds
by default).

## S4. What is this costing, and on which model?

**Modules:** `cost`, `model`.

**A reading:** `💰 $1.25 @$7.50/h | 🤖 Opus`.

**Force these absences:**

- No `cost` object. The cost segment disappears rather than printing `$0.00`.
- `total_duration_ms` of `0` or negative, which the burn-rate arithmetic must not divide by or turn
  into a negative rate.
- No `model.display_name` (the code falls back to `Unknown`), and a display name carrying brackets
  such as `Opus[1m]`.
- A payload with and without the `effort` and `thinking` blocks, for the thinking and effort
  segment.

**The limit:** cost is the session figure Claude Code reports. Cortado does not price tokens itself.

## S5. Is my machine all right?

**Modules:** `battery`, `cpu`, `memory`, `disk`, `load`, `temperature`, `brightness`, `network`,
`uptime`, `processes`, `docker`, `node`, `weather`, `time`, `timezone`.

**Force these absences:**

- The command a module shells out to missing or failing: Docker not running, no battery (a desktop
  or a Linux VM), no temperature sensor.
- The first CPU sample, which has no previous sample to diff against.
- `weather` with no network, and `network` with `NETWORK_SHOW_WAN` at its default (off) and
  redacted.

**The limit:** every one of these is a point sample taken when Claude Code last called the
statusline, cached per module.

## S6. Is Cortado itself current?

**Modules:** `version`, `update`.

**Force these absences:**

- No releases on `UPDATE_REPO`. On 2026-11-22 `gcko/Cortado` had none, so the releases API answered
  404 for every install.
- No network, and GitHub's unauthenticated API rate limit.
- A `VERSION` file missing from the install.

**The limit:** the update check runs at most once per check interval (24 hours by default) and
compares against the latest release, not against `main`.

## If the walk says a doc is wrong

The README module tables, the `cortado.conf` comments and `AGENTS.md` describe what these stages
print. When the line and a doc disagree, the line is the authority for what ships today; hand the
doc fix to `sync-docs` in the same branch if your change caused it, or file it if it predates you.
