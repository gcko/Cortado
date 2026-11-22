---
name: sync-project
description: Use when reconciling Cortado's GitHub milestones, parent issues and issue bodies after a merge, before picking work, or whenever a tracker description has grown past what a reader needs to act.
---

# sync-project

Keep the tracker worth reading. A GitHub milestone or issue is opened to decide what to do next, so
it holds what the person using the statusline gets, the decisions in force, and the work still to
do. Everything else has a better home, and this skill says which.

`sync-docs` owns the repository's Markdown. This skill owns the milestone descriptions, the shape of
an issue, and the maintained progress comment on a parent issue, all on `gcko/Cortado`. Run
`sync-docs` first when both are owed: the repository is the source and the tracker describes it.

## The three questions

Apply these to every block, every time. Most blocks fail at least one.

1. **Would a reader act differently for having read this?** If not, cut it.
2. **Is it about the past?** Build history belongs in the pull request that shipped it. A tracker
   surface describes what is true now and what is left.
3. **Does GitHub already display it?** Open and closed counts, progress bars, assignees, linked pull
   requests and dates are on the page already. Restating them creates a second number that goes
   stale.

## User value comes first

Every surface opens with who notices and when. Not the mechanism, not the history, not the plan.

- A **milestone** description opens with one bold sentence naming what the person running Cortado
  gets.
- An **issue** opens with `## User value`: two sentences, who notices this and when, in terms of
  what the statusline shows them ("Someone near their 5-hour limit sees a reading that is six hours
  old and plans around it").

Write it so the person who owns the outcome can read it. If a sentence only makes sense to someone
who has read `cortado.sh`, it is a mechanism note and it belongs further down or in the pull
request.

## Ownership: one surface per subject

Nothing goes stale here so much as it accretes: every landing leaves a paragraph behind and no
single paragraph looks like too much.

| Surface | Owns | Never |
|---|---|---|
| Milestone description | The user value for that group, what is left as one line per issue, what it waits on, a decision owed before building, and a contract note a named remaining issue must read. | Anything about one issue that its own issue could carry. Any dated build narrative. |
| Parent issue body | The reporter's original request and its acceptance criteria. | Progress. Edit a contributor's body only to correct it, never to track it. |
| Parent issue progress comment | One maintained comment: what is left, what waits on what, contract notes for remaining children. Update it in place. | A new comment per landing. |
| Issue body | That issue's user value, scope, acceptance criteria with `Verified by:` clauses, and dated staleness notes. | Another issue's status. A post-mortem of its own build. |
| Issue comment | Findings, build post-mortems, corrections to the body, cross-issue consequences, the `burndown` receipt. | Anything the body should have said instead. |
| Labels | Type (`bug`, `enhancement`, `documentation`, `question`) and disposition (`duplicate`, `invalid`, `wontfix`). | Prose restating a label. |
| Native sub-issues and dependencies | Membership and order. | A Markdown checklist standing in for either. |

**A closing burndown makes the milestone description shorter.** If it grew, something is in the
wrong place.

## Where the cut material goes

Cutting is not deleting. Each kind of prose has one home:

- **How it was built, and what went wrong on the way.** The pull request that shipped it.
- **A lesson that changes how the next person builds.** A comment on the issue that taught it, or,
  if re-deriving it would cost a day, `AGENTS.md`, which every agent loads.
- **A correction to a claim.** A comment on the issue that carried the wrong claim. Never edit the
  mistake away silently, because whoever read it needs to see the correction.
- **A number.** Nowhere. GitHub derives it live.

## Templates

Match these shapes. Add a section only when it changes what someone does next.

### Milestone description

```markdown
**[What the person running Cortado gets, one sentence.]**

## What is left

#N: one line of user value, in the user's words.

## Waits on

Nothing. [Or the blocking issue, linked.]

## Decide before building        <- only when a real question is open
[The question, why it is owed now, and what it costs to get wrong.]

## Read before building          <- only when a merge changed a contract a remaining issue needs
- #N: the one line that changes what that issue's builder does.
```

`Read before building` is written by the `burndown` skill's GitHub reconciliation and read at its
issue-understanding step. Preserve it through a rewrite, keyed by issue number, and drop a bullet
once its issue is closed. It is the one exception to the no-build-history rule, and it earns it by
changing what the next builder does.

A complete milestone is two lines: the bold sentence and `Complete. Nothing is left, and nothing is
waiting.` Resist adding a retrospective to a finished milestone.

### Issue

```markdown
## User value

[Who notices, and when, in terms of what the statusline shows them.]

## Scope

[The modules, files and config keys it changes.]

## Acceptance criteria

- [ ] [Rendered text a reader can see.] Verified by: [the render or test that settles it].
```

Leave existing acceptance criteria and measured evidence alone: an issue body has to be buildable,
and a criterion with its `Verified by:` clause is what makes it so. Reshape only the top, so it
opens with `## User value`, and move a post-mortem into a comment.

## Reading and writing GitHub

```bash
gh api 'repos/gcko/Cortado/milestones?state=all&per_page=100' --jq '.[] | [.number, .state, .title] | @tsv'
gh api 'repos/gcko/Cortado/milestones/<n>' --jq .description
gh api --paginate 'repos/gcko/Cortado/issues?milestone=<n>&state=all&per_page=100' \
  --jq '.[] | select(.pull_request | not) | [.number, .state, .title] | @tsv'
gh api 'repos/gcko/Cortado/issues/<n>/sub_issues' --jq '.[] | [.number, .state, .title] | @tsv'
gh api 'repos/gcko/Cortado/issues/<n>/dependencies/blocked_by' --jq '.[] | [.number, .state] | @tsv'
```

Write from a scratch file, after the verification below:

```bash
gh api -X PATCH 'repos/gcko/Cortado/milestones/<n>' -F description=@<draft.md>
gh issue edit <n> -R gcko/Cortado --body-file <draft.md>
```

A parent issue's progress comment starts with the line `<!-- cortado-progress -->`, and is updated
in place by that marker:

```bash
CID=$(gh api --paginate 'repos/gcko/Cortado/issues/<n>/comments'   --jq '.[] | select(.body | contains("<!-- cortado-progress -->")) | .id' | head -1)
if [ -n "$CID" ]; then
  gh api -X PATCH "repos/gcko/Cortado/issues/comments/$CID" -F body=@<draft.md>
else
  gh issue comment <n> -R gcko/Cortado --body-file <draft.md>
fi
```

Do not use `gh issue comment --edit-last` for this: it edits whichever comment you posted last,
which after a landing is usually the `burndown` receipt. Read each write back before reporting it.

## Voice

Invoke the `humanizer` skill on any description you rewrite. A clean checkout will not have it, so
the rules that matter here are written out rather than delegated:

- No em dashes or en dashes, and no curly quotes. A period, a comma, a colon or parentheses.
- One bold sentence per milestone, the user value. Bold on every other line reads as machine output
  and hides the sentence that matters.
- Sentence case in headings.
- Plain verbs. `is`, `are`, `has`. Not "serves as", "stands as", "boasts", "represents".
- Cut the stock words: crucial, key, pivotal, seamless, robust, leverage, delve, showcase,
  underscore, testament, landscape, vibrant, enduring, interplay.
- No participle tails bolted on for depth, such as "..., ensuring reliability".
- No groups of three for rhythm. Say the two things that are true.
- End on the last concrete fact. No summary paragraph and no send-off.

Keep the specifics. A measured number, a named failure mode, a rendered line and a rejected
alternative are the parts worth reading.

## Procedure

1. **Read the whole surface before editing**: the milestone description, every issue in it, the
   parent issue and its comments. Note where each block would live under the ownership table. Most
   blocks that fail the three questions are already recorded in a pull request.
2. **Refresh the facts from a fresh query**, not by adjusting a number already on the page. Then ask
   whether the number belongs at all. Usually GitHub shows it.
3. **Rewrite from the template** rather than trimming in place. Trimming keeps the old skeleton, and
   the old skeleton is the problem.
4. **Relocate before you cut.** If a lesson has no home yet, give it one and link it. Say in your
   report what moved and where.
5. **Check the labels.** Every open issue carries a type label. Report the ones that do not; do not
   set them here, because a type is a triage call and setting it without reading the issue is the
   drift this check exists to catch.
6. **Check the relations.** Native sub-issues and `blocked_by` dependencies are the record of
   membership and order. Leave an edge to a closed issue in place: GitHub already treats it as
   satisfied, and it records what waited on what. A Markdown checklist that disagrees with the
   native sub-issues is the thing to correct.
7. **Apply the voice pass** to everything you touched, then read it back once as the person who owns
   the outcome rather than as the person who built it.

## Verification

Write each description to a scratch file, then run this. It names the characters by code point
rather than printing them, so the checker does not itself trip a tone grep:

```bash
python3 - <draft.md> <<'CHECK'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
banned = {"em dash": "—", "en dash": "–",
          "curly double": "“”", "curly single": "‘’"}
for label, chars in banned.items():
    hits = sum(text.count(ch) for ch in chars)
    print(f"{label:14} {hits}")
bold = re.findall(r"\*\*[^*]+\*\*", text)
print(f"{'bold spans':14} {len(bold)}   (expect 1 for a milestone, 0 for an issue)")
CHECK
```

Every dash and quote count must be zero.

Then read the surface against the three questions one more time. If a block survives all three,
keep it. If you are unsure, it fails.

## Why this skill exists

It is adapted from the skill Compass uses on its own tracker, where the failure was measured: one
project overview had grown to about 25,000 characters of which three lines were current state, and
a rewrite to these templates cut it and the milestone descriptions by roughly 88 percent without
losing a fact anyone needed. The cause was not one bad edit. It was an agent appending a true
paragraph after every merge, each one defensible on its own, with nothing that ever removed one.
Cortado's tracker is new, which is the cheapest time to hold the line.
