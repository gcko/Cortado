# Cleanup pass

Read this when the run starts (the ledger), at closeout after the last landing, and whenever the
run stops early. It tears down what this run made without asking, then counts what earlier runs and
other sessions left behind and asks the owner which of that to remove.

A burndown makes a lot of things: a worktree per layer and per reviewer, branches, tmux sessions,
`claude` processes for live-session walks, monitors and delegated CLI runs. None removes itself, and
the next run cannot tell an orphan from a sibling's live work without the checks below.

## The run ledger

Start it before the first write of the run, in the session scratchpad as `ledger.txt`, one line per
thing the run creates, written when it is created:

```text
worktree  .claude/worktrees/<name>  <branch or detached>  <purpose>
branch    <name>                    <PR number once opened>
ref       <backup or temporary ref>
tmux      <session name>            <what runs in it>
pid       <pid>                     <command>  <how it stops>
monitor   <task id>                 <what it watches>
sandbox   <path>                    <CLAUDE_CONFIG_DIR for a render or live session>
```

Record a delegated Codex or AGY run by the pid its wrapper prints, a `nohup` job by `$!`, and a live
session by its tmux session name. The ledger is what makes "this run started it" a fact rather than
a guess from a name.

## 1. Tear down this run's own artifacts

No question needed: [reconciliation step 7](reconciliation.md#7-next-landing-or-close-the-milestone)
already owns this, scoped to the ledger. Keep a stack's worktrees until the whole stack has merged.

- **Sessions and processes first.** `tmux kill-session -t <name>` for each ledger session. Stop each
  ledger pid with `kill -TERM`, then confirm with `kill -0` that it is gone. A `claude` process can
  take a few seconds to exit after its tmux session is killed, so check again by name
  (`pgrep -fl <pattern>`) before treating it as a survivor. Stop a monitor with its task stop.
- **Worktrees, then branches.** Remove each ledger worktree whose tracked tree is clean
  (`git worktree remove <path>`). Then delete its branch only when `gh pr view <branch> --json
  state` says `MERGED`: a squash merge leaves the branch's commits off `main`, so `git branch -d`
  refuses every merged branch and `-D` is the only delete, which is why the pull request state is
  the check.
- **Sandboxes.** Remove each ledger sandbox directory. Never remove the real `~/.claude` or anything
  under it.
- **Then** `git worktree prune`, and `gh stack sync --prune` from a stack worktree before removing
  it.

## 2. Census what else is left

Count before asking, so the question carries numbers.

| Category | How to find it | Exclude |
|---|---|---|
| Older worktrees | `git worktree list --porcelain`, those under `.claude/worktrees/` not in the ledger | the main checkout, any listed in the ledger |
| Merged branches | local branches with no worktree whose pull request is `MERGED` | branches with no pull request or an open one: report them with `git rev-list --count origin/main..<b>` |
| Inherited tags | local tags not on `origin` (`git tag -l` against `git ls-remote --tags origin`) | none to remove without asking: report them, because a release read from local tags builds the wrong range |
| Orphaned processes | `ps -axo pid,ppid,%cpu,etime,command` with ppid 1, at least an hour old, matching `claude --settings`, `codex exec`, `agy`, `tmux` or a test runner | the owner's own Claude Code sessions, system services, anything you cannot name |
| Stray tmux sessions | `tmux ls` | sessions the owner started |
| Old scratch | earlier sessions' scratch directories under the harness temp root, older than a week | the current session's scratchpad, and any directory holding an unread hand-back |

For each candidate, collect the evidence the question will show: age, CPU, working directory
(`lsof -a -p <pid> -d cwd`), and what launched it if the parent still exists.

## 3. Check each candidate is safe to remove

A candidate passes only if every check holds. Anything that fails is reported, not removed.

- **A worktree** is clean (`git status --porcelain --untracked-files=no` prints nothing), and no live
  Claude, Codex or AGY session has its working directory inside it.
- **A branch** has a `MERGED` pull request. Never delete one that is ahead of `main` without one.
- **A process** is named: its command, working directory and age say what it is and that nothing
  depends on it. Stop it with `kill -TERM`, confirm it is gone, and use `kill -KILL` only after a
  TERM that did not take.
- Never touch `git stash` (shared by every worktree), the real `~/.claude`, or another author's
  branch.

## 4. Ask the owner

Ask once, with every category that has candidates, after this run's own teardown. In Claude Code use
one structured question per category with the census numbers in the question and the recommendation
first; elsewhere one plain-text block with the same options. A category with no candidates is
reported, not asked.

| Category | Options |
|---|---|
| Older worktrees | Remove the clean ones (Recommended) · Remove only those whose branch merged · Keep them |
| Merged branches | Delete them (Recommended) · Keep them |
| Inherited tags | Keep them (Recommended) · Delete the local copies |
| Orphaned processes | Stop the named ones (Recommended) · Show me each first · Leave them |
| Stray tmux sessions | Kill the ones this tooling names (Recommended) · Leave them |
| Old scratch | Remove those older than a week · Keep them (Recommended, since a hand-back may be unread) |

An orphaned process the census could not name is never an option: report it with its pid, command
and working directory for the owner to decide.

## 5. Report

Say what was removed, by category and count, what was kept and why (dirty, unmerged, unnamed,
excluded), and what was skipped by the owner's answer. Then run `git worktree list`, `tmux ls` and
the process check once more, and quote what remains.

## Keeping the next run cleaner

- Write the ledger line when you create the thing, not at the end.
- Give every reviewer worktree a run-specific prefix and remove it as soon as its verdict is read.
- Bound every delegated or background job (`perl -e 'alarm shift; exec @ARGV' <seconds> ...` on
  macOS, which has no `timeout`) so a hung one ends on its own.
