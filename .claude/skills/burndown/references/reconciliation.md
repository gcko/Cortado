# Reconcile landings and finish the scope

## 6. Reconcile every issue that landed

Only once the merge is confirmed on `origin/main`, reconcile once per finished issue in dependency
order, using the adapter's **Reconcile** section. Its receipt records the delivered criteria, the
pull request and merge commit, the gate output, remaining scope, dependent work and any doc changes.
Read back every write. A partially delivered issue stays open. A research or decision issue may close
on its findings or ruling, as the planning rules allow.

## 7. Next landing, or close the milestone

Tear down what the landing finished, scoped to what this run started: its worktrees (before their
branches), tmux sessions, processes and subagents. Keep a stack's worktree until the whole stack has
merged. The [cleanup pass](cleanup.md) owns how.

Then refetch the scope (issues move outside this session), recompute the plan, and continue. A
changed plan needs approval as the Invocation section sets out.

**Discoveries.** Use the adapter to file a defect this scope's work created, or a gap a review
deferred, in the current scope. Burn it in this run while the run is inside its estimate. A small fix
may ride the next open layer instead. Group a review's minor deferred items into one issue rather
than one each. When burning the discoveries would take the run past its estimate, stop and ask, with
the discoveries grouped and sized, before starting them: reviews of new work keep finding more, so
"burn every discovery" has no natural end. A pre-existing defect is filed outside the scope, and the
report names it.

**Final verification.** Once every other issue is finished, render the statusline from `origin/main`
through the stages the scope touched (`visual-review-and-fix`, Mode 2) and, when the scope changed a
payload field or the module loop, walk one live session. A defect this finds is fixed or filed as
above.

**The scope is complete** when every issue in it on a final refetch, including the discoveries this
run filed into it, has a verified disposition, every issue this run closed has its receipt, and the
container's acceptance is met. A planned issue list that is all closed while a filed discovery is
open is not complete; see [What "burned down" means](../SKILL.md#what-burned-down-means). Use the
adapter's **Finish** section to reconcile or close the container. Closed children alone do not prove
that a parent's promised behaviour shipped.

For a multi-issue scope, check that every landing ran `sync-docs`; if one did not, run it once from
`main` over the merged range as its own docs pull request. Report the issue count, pull request
count and date range.

**The scope is blocked** when no open issue can start: name each blocker and stop.
