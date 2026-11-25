# Build, review and land

Read this when an approved group is ready to build. Read [reconciliation](reconciliation.md) after
each landing, before reporting an issue finished.

## 4. Build a layer

In the layer's worktree, under `.claude/worktrees/`. Items 1, 2 and 5 are the build stage, 4 is the
review stage, and 3 is the orchestrator's. A build subagent stops after item 2 and hands back its
worktree.

1. **REQUIRED SUB-SKILL:** invoke `superpowers:test-driven-development`. Write the failing test
   first and watch it fail, then the code. A test of something the reader sees pipes a payload to
   `cortado.sh` with a sandboxed `CLAUDE_CONFIG_DIR` and asserts the rendered text, as
   `visual-review-and-fix`, "Behavioural testing first" says. Run the touched test files while
   iterating; the whole Pre-PR Checks block runs in item 5.
2. Invoke `sync-docs` in the layer that ships the behaviour, never once for a whole stack. The README
   and `AGENTS.md` change in the layer that changes what they describe.
3. **REQUIRED SUB-SKILL:** the orchestrator invokes `visual-review-and-fix` in
   `Mode 2: after development`. What this layer introduced goes to item 5; what predates it is filed
   with the base render that proves so.

   **Walk a live session at the first layer that changes which payload field a module reads, how the
   line wraps, or the module loop**, not only at the final verification. Use the recipe in
   `visual-review-and-fix`, Mode 2, step 6. It costs no model call unless you send a prompt; ask the
   owner before sending one. Put what it showed in the pull request's `## Verification`.
4. Review the layer at the depth its tier sets (**AGENTS.md, "Calibrating Effort"**), before it is
   submitted. Self-verify is the orchestrator's own read of the diff and the checks; the other tiers
   are reviewer subagents at the review stage's model. Spend the depth on the layer that makes
   behaviour reachable, and review the combined diff of the layers below it there. A layer nothing
   calls yet is not submitted on its own: build the reachable layer on top, review the two together
   at the higher of their tiers, and submit them together. Freeze the stack while a reviewer is
   reading: a restack rewrites the layers above under them and turns correct findings into false
   refutations. File what a review defers.
5. Fix what the walk and the review found. One correction round per layer is the default; after a
   round with several fixes, render again, because fix rounds produce new defects. The orchestrator
   makes a small fix (a few lines and its test) inline; a larger round goes back to the builder.
   Then, once per pull request and before it is submitted, run the canonical Pre-PR Checks from
   **AGENTS.md, "Pre-PR Checks"**, from there rather than from a copy, and keep the output.

## 5. Stack, submit and land

**Re-run the local gate yourself.** GitHub Actions checks each pull request. Before submitting and
again before merging, the orchestrator runs the Pre-PR Checks on the commit it will push or merge
and pastes that output into the pull request's `## Verification`.

**Title and body.** The title follows **AGENTS.md, "PR Workflow"**: the shipped behaviour in a plain
sentence, ready for release notes. The body carries the adapter's issue links (closing keywords only
on the layer that finishes an issue) and a `## Verification` section naming what ran and what it
printed: the Pre-PR Checks, the renders, and the live session if one was owed.

**An independent group** is an ordinary pull request on `main`: `gh pr create`, then, once its
review threads are resolved and the gate is green on its head, `gh pr merge <n> --squash
--delete-branch`. If `main` moved underneath it, rebase onto `origin/main`, re-run the gate, and
push before merging.

**A stack**, for groups that must land in order on a shared contention file:

- Layer by layer in one worktree: `gh stack init --base main <branch-1>`, commit, then
  `gh stack add <branch-2>` for the next layer, and so on.
- `gh stack submit --auto --open` opens a ready pull request for every layer that has none. Without
  `--open` new pull requests are drafts. `submit` writes the title and body only when it creates a
  pull request, and takes them from the branch names, so then run
  `gh pr edit <n> --title "<title>" --body-file <file>` for each layer.
- **Fix a lower layer:** `gh stack checkout <branch-k>`, commit, then `gh stack rebase --upstack`,
  then `gh stack push`. Re-run the gate on every layer from k up. A clean rebase can still break at
  runtime: grep the renamed symbols across every layer.
- **Main moved:** once no review is reading the stack, `gh stack sync`. When the local stack and the
  one on GitHub disagree about which pull requests belong to it, a non-interactive `sync` prints
  `Sync aborted` and **exits 0 having pushed nothing**: import the remote stack with
  `gh stack checkout <pr-url>` and sync again. Either way, confirm each layer's pushed head
  (`gh pr view <n> --json headRefOid`) is the local branch tip.
- **Land it:** `git fetch origin main:main` first, because `gh stack view --json` judges
  `needsRebase` against your local `main` and does not fetch. Merge when no rebase is needed, the
  gate is green on every layer's current head, and every review thread is resolved:

  ```bash
  gh stack merge --squash --yes
  gh stack sync --prune
  ```

  Always pass `--squash`; otherwise `gh stack merge` uses your last-used method.
- **Never, on a stacked branch:** `gh pr merge` (it merges a layer into its parent branch, leaving
  its code off `main`), `gh pr update-branch`, a plain `git rebase origin/main`, or
  `--delete-branch`. A pull request whose base is another feature branch but is not in a native
  stack gets closed when its base branch is deleted; link it with `gh stack link` or do not create
  it.

Never commit or push to another author's pull request branch without the owner's explicit
confirmation, including when a plan authorizes its eventual merge.

## Parallel work

Read **AGENTS.md, "Parallel Work"** before starting a second builder, and hand its contention list to
every one.

- Groups sharing a contention file are serial. Independent groups may run in their own worktrees
  with their own subagents.
- Every render and live session uses its own sandbox `CLAUDE_CONFIG_DIR`. The test suites sandbox
  themselves and are safe to run concurrently.
- Dispatch subagents from the repository root, at their stage's model and effort, and confirm each
  produced work before calling it running.
- Give every agent a time limit when you dispatch it, about twice what that stage usually takes,
  and stop it when the limit passes. Where the dispatch takes no timeout (the Claude Code `Agent`
  tool does not), arm a wake-up at dispatch, such as a `Monitor` or a scheduled check.
- Use unnamed agents for one-shot work (a lens, an arbiter, a deep dive), and stop each one once it
  has delivered. Keep a builder that handed back until its layer needs no further round, so a
  correction round can resume it with its context.

## Delivery invariants

- Never edit `VERSION` or its literals. `cortado-release` owns them.
- Never trust an exit status from `gh stack sync` as proof that it pushed.
- Never trust a builder's or reviewer's "checks pass": re-run the gate on the head you merge.
- Never rewrite a branch (restack, rebase, amend, reset) while a check run or a review is reading it.
- Never widen an issue's scope to make it feel complete. File the rest.
- Never promote a deferred review finding into the layer in flight when it costs another round.
