# Delegation mode

Read this when the caller passes `--delegate`, or asks in their own words for the session to
coordinate and hand the work to Codex and Antigravity (AGY). The shared stages stay in force:
delegation changes **who** runs the plan, build and review stages, not what those stages require.

The point is cost: the orchestrating session spends its own tokens on coordination while Codex and
AGY carry the deep dives, builds, lenses and arbiter.

## Who does what

| Work | Delegated mode | Why |
|---|---|---|
| Steps 1, 2, 5, 6, 7: load, plan, land, reconcile, close | Orchestrator | Issue writes, merges and the owner's approvals need the session's tools. |
| The live-session walk | Orchestrator | Only the orchestrator has the logged-in `claude`. |
| Fixture renders for Mode 1 and Mode 2 | Orchestrator, or a delegate whose render the orchestrator re-runs | The render harness is plain shell, so a delegate can reproduce a finding; the orchestrator still quotes a render it ran itself. |
| Step 3 deep dive | Codex, at the plan stage's setting, inside the build run | The builder writes the analysis file first. |
| Step 4.1, 4.2, 4.5: tests, code, `sync-docs`, fix rounds | Codex | Long agentic edits with a test loop. |
| Step 4.4 lenses | Mixed: Codex and AGY | Two model families find different defects. |
| Step 4.4 arbiter | Codex | It reproduces findings, so it needs a working shell. |
| Small inline fixes (a few lines and a test) | Orchestrator | Faster than a fresh delegated run. |

The orchestrator reads every hand-back, every lens report and the arbiter's verdict before acting on
any of them, and re-runs the Pre-PR Checks itself on the head it merges. A delegate's "done" is a
claim to check, not a fact.

## Choose the models at run time

Model names change between runs, and a name the caller remembers may not exist. Read the live
catalogs before recommending anything:

```bash
# Codex: slug, supported efforts and visibility; recommend only visibility "list"
codex debug models | python3 -c 'import json,sys
for m in json.load(sys.stdin)["models"]:
    print(m["slug"], [l["effort"] for l in m["supported_reasoning_levels"]], m.get("visibility"))'
grep -E '^model' ~/.codex/config.toml   # the owner's configured default and effort
# AGY: one row per model-effort variant
perl -e 'alarm shift; exec @ARGV' 20 agy models
```

If a requested name is missing, say so and offer the closest listed slug: a run launched with a
remembered name that the catalog does not hold can sit idle for a long time before anyone notices.

Codex takes effort separately (`-c model_reasoning_effort=<level>`); AGY encodes it in the model
variant name. Recommend from the newest listed generation, and map the planning reference's stage
table onto it:

| Stage | Default | Full-adversarial group |
|---|---|---|
| Plan (inside the build run) | Codex newest general model · medium | Codex · high |
| Build and fix rounds | Codex · medium; high for a group touching `cortado.sh`, `modules/utils.sh` or `install.sh` | Codex · high |
| Review lenses | one Codex · high and one AGY · high | add a second AGY lens of a different model, all at high |
| Arbiter | Codex · high, a different model from the builder when one is listed | Codex · high |

Never recommend `xhigh`, `max` or `ultra` unless the caller asks. Ask the stage questions as the
planning reference says, naming the exact slugs and efforts, with the recommendation first.

## Dispatch mechanics

- **Close stdin.** `codex exec` prints `Reading additional input from stdin...` and waits for EOF
  when stdin is an open pipe. Always end the command with `< /dev/null`.
- **Bound every run.** macOS has no `timeout`: wrap each call in
  `perl -e 'alarm shift; exec @ARGV' <seconds> ...`, about twice the stage's usual time, and run it
  in the background so its exit wakes the orchestrator.
- **Sandbox.** Cortado's suites need no network and no loopback port; they write only to `mktemp`
  directories. Start builders with `--sandbox workspace-write` and `-C <worktree>`. Fall back to
  `--sandbox danger-full-access` only if a suite fails on a sandbox denial, and then only inside the
  builder's own worktree, never the main checkout.
- **Codex command shape.**
  `codex exec -m <slug> -c model_reasoning_effort=<level> --sandbox workspace-write -C <worktree> -o <handback.md> "$(cat <prompt.md>)" < /dev/null > <log> 2>&1`.
  `-o` writes the final message, which is the hand-back the orchestrator reads.
- **AGY command shape.** `-p` consumes the very next token, so put the prompt straight after it:
  `cd <worktree> && agy --model <variant> --dangerously-skip-permissions -p "$(cat <prompt.md>)" > <report.md>`.
  `agy -p --model X ...` makes `--model` the prompt.
- **No tracker, no Claude skills.** Neither CLI has this session's skills. Paste the issue's user
  value, evidence, scope and acceptance criteria into the prompt, plus the container's `Read before
  building` notes for that issue. Codex discovers the repository skills through `.agents/skills/`,
  so name `sync-docs` and `visual-review-and-fix` by that path; TDD and the deep dive are written
  out as steps.
- **One prompt preamble, one task file per layer.** The preamble carries the repository rules a
  builder needs: read `AGENTS.md`; write the deep dive to a named analysis file first; failing test
  first; render in a sandbox `CLAUDE_CONFIG_DIR`, never the real `~/.claude`; run the Pre-PR Checks
  from `AGENTS.md`; commit, but no push, no pull request, no rebase; never touch `VERSION`; the
  contention list from **AGENTS.md, "Parallel Work"**. The task file carries the issue text and the
  layer's contract notes. Namespace every scratch file per layer.
- **Reviewers get detached checkouts.** Create one detached worktree per lens at the reviewed head,
  forbid tracked edits, and give each a probe directory outside the repository for its scripts. A
  lens must reproduce before it reports, with a render or a test, and mutation-test the new guards.
  The arbiter gets every lens report and probe directory and returns confirmed, refuted and
  pre-existing verdicts, a fix list in build order with the test that must fail first, and a file
  list.
- **Fix rounds go back to Codex.** Start a fresh Codex run in the layer's worktree with the arbiter's
  fix list, the original task file and the analysis file. A builder that edits a lower layer's file
  is a restack the orchestrator does, never the builder.

## Keep the wall clock down

- **Build the next layer as soon as the lower layer hands back.** Stack the new worktree on the lower
  builder's commit, and restack it when the fix rounds land. Tell the upper builder which config keys
  and output formats are frozen.
- **Review a stacked layer on its own diff** (`git diff <lower head>..HEAD`) while the lower layer is
  in its fix round.
- **Run fix rounds in parallel across layers** when they touch disjoint files. Tell each builder what
  the other is editing.
- **Verify a fix round by re-running the arbiter's failing regressions**, not by a fresh full pass.
  Ask every arbiter to leave its reproductions in its probe directory as runnable tests or render
  commands.
- **Walk the live session while a review runs**, not after. A finding then costs one more commit on a
  layer that is already open.

## When the stages disagree

Two lenses can pull in opposite directions. The orchestrator writes one rule that satisfies both,
hands that rule to the arbiter to test, and records it in the pull request as the orchestrator's
call. Writing it to an issue as the owner's decision needs the owner's words.

## Reporting

Name, for every delegated run, the CLI, the model slug and the effort it actually ran with, and the
wall clock it took. Delegated token spend is not on the session's meter; say so rather than
reporting it as zero.
