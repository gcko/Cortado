# Plan and understand the work

Read this after selecting the scope and loading the GitHub adapter. Steps 1 and 2 are read-only.
Under `--plan`, stop after step 2; do not run deep dives, render walks or repairs.

## 1. Load the milestone

Use the adapter's **Load** section to enumerate the complete scope, classify states, read
dependencies and find work already in flight. Page every collection to exhaustion. A link in an
issue body is context, not scope membership. Keep external blockers visible without adding them to
the work list.

Record stale descriptions, incomplete reconciliations and metadata changes as **repairs**. Execute
them only after the plan is approved, never under `--plan`. Report unavailable reads rather than
inventing an empty result.

Unless the run is `--plan`, start the [run ledger](cleanup.md#the-run-ledger) now, before the first
write, and add a line for every worktree, branch, tmux session, process and monitor as it is
created.

## 2. Plan: group, order, estimate, choose models

Read each open issue's `blocked_by`, labels, scope (the modules, files and config keys it names)
and acceptance criteria.

**Tag each issue:**

- **Surface.** Which contention files it touches, from **AGENTS.md, "Parallel Work"**: `cortado.sh`,
  `cortado.conf`, `lib/config-tui.sh`, `install.sh`, `modules/utils.sh`, `README.md`, `AGENTS.md`.
  Adding or renaming a module touches most of them (**AGENTS.md, "Adding a New Module"**). An issue
  confined to one non-utils module and its test touches none.
- **Review tier**, from **AGENTS.md, "Calibrating Effort"**: self-verify, two lenses plus an arbiter,
  or full adversarial. Mark the layer that makes a behaviour reachable (the one that wires a module
  into the registry, adds the config key, or exposes the flag), because review depth is spent there,
  on the combined diff of the layers it exposes.
- **Rendered path.** Whether it changes what the statusline prints, which decides how much of
  `visual-review-and-fix` it owes (that skill's calibration table).
- **Real payloads.** Where an issue reads a payload field, plan its fixture from a captured real
  payload (the live-session recipe in `visual-review-and-fix`), redacted, not from a payload written
  by the same hand as the code.
- **Estimate.** Most issues carry none. Use XS 1, S 2, M 3, L 5, and mark an inferred estimate as
  yours. GitHub has no native estimate field; a plan estimate does not authorize creating one.

**Group.** Prefer one pull request per conflict surface to one pull request per issue: issues are
units of reasoning, pull requests are units of merge risk. Issues share one pull request when all of
these hold: they change the same module or the same contention file; no issue outside the group lies
on a `blocked_by` path between two issues in it; they share a review tier; and their estimates sum to
no more than 7 points (L 5 plus S 2). A self-verify issue groups only with other self-verify issues.
Keep a full-adversarial issue out of a group that would inflate its review with unrelated diff.

One exception overrides the tier rule: code that nothing calls yet groups with the issue that makes
it reachable, whatever their tiers, and the group is reviewed at the higher tier. The 7-point cap
still holds; above it they stay two layers, and the lower one waits unsubmitted for the review of
the one above.

**Arrange.**

- Groups that touch the same contention file land in order, either as layers of one native stack
  (`gh stack`), each built on its parent from the start, or one after another on `main`. Never in
  parallel.
- A group that touches no contention file and no file another in-flight group touches is an
  independent pull request on `main`, built in parallel.
- Order by: an unblocked security issue or a defect that makes the statusline lie first (the
  `visual-review-and-fix` defect class); then the longest estimate-weighted `blocked_by` path; then
  the smaller estimate.

**Estimate.** Give wall clock and tokens at the recommended model settings. Review dominates here,
since the local gate (the Pre-PR Checks) takes under a minute (47 seconds on 2026-11-22).

**Choose a model and effort for each stage.** The work is dispatched to subagents in three stages,
each at its own model and effort, so a cheap stage is not paid for at the expensive one's price:

| Stage | What the subagent does | Steps |
|---|---|---|
| Plan | the deep dive, the User value brief, a decision issue's recommendation | 3 |
| Build | the failing test, the code, the Pre-PR Checks, `sync-docs`; after the walk and review, the fixes | 4.1, 4.2, 4.5 |
| Review | the lenses and the arbiter at the group's tier | 4.4 |

The orchestrating session keeps steps 1, 2, 5, 6 and 7, both `visual-review-and-fix` live-session
checks, issue writes, and a self-verify review, on its own model.

Recommend from the plan table you just built; do not read code to decide. The families below are
Claude Code's. Before recommending names, check the models and efforts the current harness offers;
where a family is not available, recommend the closest available equivalent and say so.

| Stage | Default | Step up | Step down |
|---|---|---|---|
| Plan | Sonnet · medium | Opus · high when the group holds a decision issue or a full-adversarial issue | Sonnet · low when every open issue is S or smaller and self-verify |
| Build | Sonnet · medium | Sonnet · high for a group touching `cortado.sh`, `modules/utils.sh` or `install.sh`; Opus · high for a full-adversarial group | Haiku · medium for a self-verify group of XS or S that changes prose or tests only |
| Review | lenses Sonnet · medium, arbiter Sonnet · high | Opus · high for both on a full-adversarial group | none: a self-verify group has no reviewer subagent, and Haiku never reviews |

A step-up or step-down applies to the groups that earn it, not the whole run. Record each answer as
a rule keyed on the table's conditions, so a group the plan gains later takes its setting from the
rule. Never recommend `xhigh` or `max` unless the caller asks for one.

Under `--delegate`, the plan, build and review stages run on Codex and AGY instead: take the
models, efforts and dispatch rules from [delegation mode](delegation.md).

Ask the three stage questions together with the plan, so the caller answers once: in Claude Code,
one structured question per stage with the recommendation first and labelled `(Recommended)`, plus
a question approving the plan when the run is waiting for that yes. Skip a stage `--models` already
answered. Under `--plan`, print the recommendations in the plan block and ask nothing.

Every subagent dispatched for a stage gets the chosen model and effort; in Claude Code that is the
Agent tool's `model` and `effort`. A forked subagent ignores those overrides, so do not fork stage
work. Never change a stage's setting on your own: when a stage keeps failing at it, stop and
recommend the step up.

**Print the plan** as one block: a table of groups (issues, surface, tier, estimate, stack position
or independent, base), the repairs, the issues left out and why, the order, the estimate, and the
model and effort per stage with what each recommendation rests on. With `--plan`, stop here.
Otherwise wait for the caller's yes, unless they passed `--merge`, and for the model answers. Then
do the repairs, reading each write back.

## 3. Understand each issue in the group

Use the adapter's **Understand** section for the deep dive, at the plan stage's model and effort.
This workflow owns issue lifecycle, branches and merging. An unresolved design choice becomes a
decision issue.

Record that work has started with the adapter's work claim. A GitHub issue stays open.

**REQUIRED SUB-SKILL:** invoke `visual-review-and-fix` in `Mode 1: before development` for every
issue and let its calibration table decide how deep to go. The orchestrator runs any live session
itself. The acceptance criteria come out of that walk rather than out of the issue text, because a
criterion written from source can state the wrong thing about what the reader sees. Anything it
finds that predates the issue is filed. If the walk contradicts the issue's plan, correct the issue
before writing code; plan approval covers that write.

Draft a missing User value brief before the walk: two sentences, who notices and when, in terms of
what the statusline shows them. At least one acceptance criterion is rendered text a reader can see,
with its own `Verified by:` clause; when no reader sees the change, the brief says so and why.

**A decision issue** has no build. Make the question answerable, recommend one answer, and stop for
the ruling, for that issue and its dependents only. It closes when the ruling is written where its
acceptance criteria say, usually `AGENTS.md`, and that docs change is its layer. When the owner
delegates a ruling, record their words with it.

**A research issue** (its scope is to find something out, and it names no change) has no layer.
Dispatch the research at the build stage's setting, verify its main claim yourself, and close the
issue on a findings comment. File what the findings call for as new issues.

Next: after plan approval and issue understanding, read [delivery](delivery.md) for steps 4 and 5.
