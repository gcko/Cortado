# GitHub adapter

All issues, discoveries, receipts and scope updates stay on `gcko/Cortado`.

## Prerequisites and identity

Use `gh` and authenticated `gh api` for everything, including native sub-issues, dependencies and
milestones. Require only reads under `--plan`; execution needs issue and comment writes and the
shared git and pull request capabilities.

Resolve each issue by owner, repository and number; retain its URL and API ID. REST relationship
writes use the numeric API ID (`gh api repos/gcko/Cortado/issues/<n> --jq .id`), not the issue
number. GitHub Projects boards and their custom fields are outside this adapter.

## Load

**Issue entrypoint:** read the issue and every page of its comments and native sub-issues. With
children, walk the native tree recursively, including closed intermediate parents, and deduplicate
by number. The root is the container, not an extra implementation task. Read its acceptance
criteria and those of intermediate containers. Plan unallocated acceptance as a proposed child issue
or an owner decision; do not silently execute an extra parent layer. With no children, the scope is
that one issue.

**Milestone entrypoint:** fetch the milestone and all its issues, open and closed, ordered by
creation time. Filter pull requests out of the issues endpoint:

```bash
gh api --method GET --paginate 'repos/gcko/Cortado/issues?milestone=<n>&state=all&sort=created&direction=asc&per_page=100' \
  --jq '.[] | select(.pull_request | not) | [.number, .state, .title] | @tsv'
```

A child outside that milestone is an external dependency or context, not automatic scope expansion.
A single leaf issue does not expand to its siblings merely because it has a parent or milestone.

**Issue-list entrypoint:** the scope is exactly the issues the caller named, or the issues a search
returns. For a search, add `repo:gcko/Cortado is:issue` to the caller's qualifiers and page the
search API to exhaustion:

```bash
gh api --method GET --paginate search/issues -f q='repo:gcko/Cortado is:issue is:open label:bug' \
  -f per_page=100 --jq '.items[] | [.number, .state, .title] | @tsv'
```

The search API caps a query at 1,000 results; a larger result is not a scope, so ask the caller to
narrow it. Freeze the resolved list in the plan by number, and print the query beside it: a search
re-run later can return a different set, so the plan's list, plus what this run files into it, is
the scope from then on. A listed issue with native children is expanded as a parent is; children of
an unlisted parent are not added. A list has no container to reconcile or close: the finish report
is the record.

Use native membership as authority. A Markdown checklist, a body mention and a pull request link do
not make an issue a child. Page sub-issues, comments, dependencies and issue and pull request
collections to exhaustion:

```bash
gh api 'repos/gcko/Cortado/issues/<n>/sub_issues' --jq '.[] | [.number, .state, .title] | @tsv'
gh api 'repos/gcko/Cortado/issues/<n>/dependencies/blocked_by' --jq '.[] | [.number, .state] | @tsv'
```

For each in-scope issue:

1. Read the body, all comments, labels, assignees, `state`, `state_reason`, parent and children,
   `blocked_by` and `blocking`, linked pull requests and closure evidence. Fetch outside blockers for
   status only.
2. An `open` issue is unfinished. A `closed` issue with reason `not_planned` is waived, not shipped.
   A `closed`/`completed` code issue counts as delivered only with evidence its change reached
   `origin/main`. Investigate missing or contradictory closure reasons instead of guessing.
3. GitHub's states do not encode ready, started or blocked. Use verified native blockers and an
   explicit work claim.
4. Inspect linked pull requests, branch heads and `git worktree list`. Find partial deliveries and
   existing work before opening a new pull request. A merge into a feature branch is not a delivery
   to `main`. List premature closure and stale container text as repairs.
5. Keep another author's active pull request out of autonomous edits. Reuse its plan slot or mark it
   externally owned; never open a competing one.

A parent and child edge means membership, not order. Use native dependencies for order. If issue
text names an extra prerequisite, verify it and record a proposed dependency repair in the plan.

## Understand

Use the plan-stage subagent to read the issue, comments, dependencies, linked pull requests and the
relevant code. Return a scratchpad analysis named by issue number: current behaviour (with the
rendered line, from `visual-review-and-fix`), the failure or missing capability, acceptance gaps,
files and config keys affected, dependencies, and a concrete approach.

Before building, read the contract notes in the issue, all ancestor issue comments (including a
`<!-- cortado-progress -->` comment) and its milestone description's `Read before building`. These
are contextual reads and do not expand a scope.

At work start, keep the issue open and post or update one concise work claim naming the implementer
and the branch. Reuse an existing claim, after checking it is still live. An assignee alone does not
prove anyone is working. Keep estimates in the plan; GitHub has no native estimate. Use existing
labels where they fit; do not invent workflow labels or custom fields.

## PR links

On a finishing pull request, `Closes #N` for each issue it finishes, one line each. A partial layer
says `Part of #N`, without a closing keyword. Do not put the parent's closing keyword on a pull
request that finishes only one child. GitHub acts on closing keywords only for pull requests that
target `main`; a stacked layer targeting a feature branch needs explicit reconciliation after the
stack reaches `origin/main`. Read the issue state back instead of assuming it closed.

## Reconcile

Once the finishing change is confirmed on `origin/main`, once per issue, in dependency order:

1. Verify the delivered acceptance criteria and the merge evidence. Close the issue as completed if
   GitHub has not. Keep a partial issue open; correct a premature closure as an approved repair.
2. Reconcile the container's remaining-work text with live state, using `sync-project`: the
   milestone description, or the parent issue's `<!-- cortado-progress -->` comment. Preserve the
   reporter's original body.
3. Record any new contract a remaining issue needs, as a `Read before building` bullet keyed by issue
   number. Remove obsolete bullets.
4. Re-read dependent issues. Identify newly ready work. A waived or duplicate prerequisite may still
   need an owner ruling or a replacement dependency before work can proceed.
5. Leave dependency edges in place when they remain accurate: an edge to a closed issue is
   satisfied, and it records what waited on what.
6. If the change altered what the README or `AGENTS.md` promises, confirm `sync-docs` ran in the
   landing pull request.

Post one receipt comment on the issue covering these six items, with "not applicable, because ..."
where needed, the finishing pull request, the merge commit, the Pre-PR Checks output summary and
remaining work. Update this run's own receipt on retries. Read back the posted text, the state and
the relations.

## Discoveries

A defect introduced by this work, or deferred by its review, becomes a native sub-issue of the
selected parent, or an issue in the selected milestone, or (for an issue list) a new issue added to
the run's frozen list and named in the next report. A pre-existing defect is filed outside the scope
and linked back as related context. These writes obey the shared approval and estimate limits.

## Finish

Refetch membership, states, dependencies and parent acceptance before declaring completion. Closed
children with waived work do not prove the parent's acceptance criteria were met. A closed
intermediate container with open descendants is a repair, not a completed subtree.

Close a parent only when its criteria are met and all in-scope work has a verified disposition; post
a concise final comment with the delivered behaviour, pull requests and any limitations. Close a
milestone only when its scope and acceptance are complete, and rewrite its description to the
complete form in `sync-project`. A leaf-issue run closes only that issue and reconciles its
container's progress note. An issue-list run is burned down when every issue on its frozen list, and
every discovery added to it, is closed with a receipt; it closes no container.

## API references

- [Native sub-issues](https://docs.github.com/en/rest/issues/sub-issues)
- [Native issue dependencies](https://docs.github.com/en/rest/issues/issue-dependencies)
- [Milestones](https://docs.github.com/en/rest/issues/milestones)
- [PR closing keywords](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)
