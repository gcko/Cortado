---
name: burndown
description: Use when burning down Cortado GitHub work (an issue with sub-issues, a list of issues, an issue search, a milestone or a single issue); also when planning how to group and stack that work, or when the session should coordinate and delegate it to Codex and Antigravity.
---

# burndown

Plan a bounded work scope on `gcko/Cortado`, group its issues, build and review independent or
stacked pull requests, land them on `main`, and reconcile every issue. All tracker reads and writes
go through [the GitHub adapter](references/github.md).

## Select the scope

| Input | Route |
|---|---|
| `https://github.com/gcko/Cortado/issues/N`, `gcko/Cortado#N` or `#N` | One issue; with native sub-issues, the parent tree |
| `https://github.com/gcko/Cortado/milestone/N` or a milestone name | The milestone |
| Several issue references (`#12 #15`, one URL per line) | An issue list |
| `https://github.com/gcko/Cortado/issues?q=...` or `--issues "<qualifiers>"` | An issue list, resolved from that search |

A bare number is an issue number, not a milestone number. A milestone name must match exactly one
milestone; ask on several matches. Confirm `origin` is `gcko/Cortado` before building. A reference
to another repository needs that repository's checkout, not a pull request against this one. A
failed or denied read is reported, never treated as an empty scope.

Record the canonical target and the exact scope in the plan.

## Invocation

- `burndown <target>`: plan, present model recommendations, wait for plan and model approval, then
  build, land and reconcile until complete or blocked.
- `--plan`: read and print the plan, then stop. No issue or git writes, no claims, no repairs, no
  deep dives, no builds, no dispatches. Read access alone suffices.
- `--merge`: pre-approve the printed plan and its merges. Still print it before any write; ask the
  model questions unless `--models` answers them.
- `--models recommended`, or `--models plan=<model>:<effort>,build=...,review=...`: answer the
  planning stage's model questions. Ask only for stages not answered.
- `--delegate`: the session coordinates and hands the plan, build and review stages to Codex and
  Antigravity (AGY). A request in the caller's own words ("coordinate and delegate to Codex and
  agy") means the same. It combines with every flag above; `--models` then names Codex and AGY
  models.

Examples:

```text
burndown gcko/Cortado#2 --plan
burndown https://github.com/gcko/Cortado/issues/2 --merge --models recommended
burndown "https://github.com/gcko/Cortado/issues?q=is:open+label:bug" --plan
burndown "v2.1 statusline accuracy" --delegate
```

## Load only the current stage

| When | Read | Owns |
|---|---|---|
| Every run, after selecting the scope | [GitHub adapter](references/github.md) | Loading the scope, work claims, PR links, receipts, discoveries, closing containers |
| Planning and issue understanding | [Planning, steps 1-3](references/planning.md) | Scope inventory, grouping, dependencies, estimates, review tiers, stage models, issue analysis |
| An approved group is ready to build | [Delivery, steps 4-5](references/delivery.md) | TDD, render walks, reviews, stacks, the local gate, merges, parallel work |
| After each landing and at closeout | [Reconciliation, steps 6-7](references/reconciliation.md) | Receipts, discoveries, replanning, completion |
| Run start (the ledger), closeout, and any stop | [Cleanup pass](references/cleanup.md) | The run ledger, this run's teardown, the census of older leftovers, the cleanup questions |
| `--delegate`, from planning on | [Delegation mode](references/delegation.md) | Who runs each stage, live model choice, Codex and AGY dispatch mechanics |

Do not preload all references. "Milestone" in the shared stages means the selected scope, including
a parent tree, an issue list or one issue. "Container" means its milestone or parent issue, if any;
an issue list has none.

## What "burned down" means

A scope is burned down only when every issue in it is closed: implemented with its change on
`origin/main`, or closed as not planned or duplicate with the reason in a comment. "Every issue" is
the scope's membership when you refetch it at the end, so it includes discoveries and follow-ups
this run filed into the scope. Shipping the issues the plan started with is not enough.

Before saying a scope is burned down, refetch it and confirm nothing in it is open. If anything is,
either keep going, or stop and report the scope as not burned down, naming each open issue and why
it is open. Moving an issue to another scope so this one reads complete needs the owner's approval,
and the report says it moved.

## Authorization and stop rules

Plan approval authorizes its merges, listed repairs and planned issue corrections. Approval and
`--merge` also cover discoveries caused by this work within the estimate, a small fix riding an
open layer, and issues moving later because of blockers. New product scope, a changed review tier
or a reordered stack needs fresh approval. Neither approval nor `--merge` answers a decision issue
or authorizes committing or pushing to another author's pull request branch.

During execution, file a missing decision as an issue in the scope, link it as a native blocker of
the issues it affects, and recommend an answer before stopping for the owner's ruling. Under
`--plan`, list those writes as repairs instead. Continue independent groups only under an approved
replan. Stop and ask when a full-adversarial review says NO-GO, a second correction round lacks a
named user-visible regression, the Pre-PR Checks fail twice on the same head after a fix that
passed locally, the plan changes beyond its authorization, a chosen stage model repeatedly fails,
or the run exceeds its estimate by half.

On stopping, report written tracker and git changes and every branch, worktree, stack, pull
request, tmux session, process and subagent this run started, then run the
[cleanup pass](references/cleanup.md) on what it no longer needs. Between landings, report
current-head check results, read-back issue states, receipts and live background work. Stop before
an operation whose required capability is missing.

## Shared prerequisites and boundaries

Execution needs `superpowers:test-driven-development` (or the same discipline by hand),
`sync-docs`, `visual-review-and-fix`, and the canonical **AGENTS.md, "Pre-PR Checks"**. Stacked
delivery needs `gh stack` (the `gh-stack` extension) at v0.3.0 or later. The live-session check
needs `tmux` and a logged-in `claude` on PATH; without them, say so in the pull request rather than
skipping it silently.

The trunk is `main`. GitHub Actions runs on pull requests and pushes to `main`. The builder runs
the local Pre-PR Checks and the orchestrator reruns them on the commit being merged. Every pull
request records their output. Code issues finish only when their change reaches `origin/main`.
Research and decision issues may finish on their verified findings or ruling. Merge with `--squash`, and leave
`VERSION` and its literals to `cortado-release`.
