---
name: cortado-release
description: Use when cutting a Cortado release, choosing the major, minor or patch bump from what changed since the last release tag, landing the version bump, publishing the GitHub Release, confirming installs can see it, and optionally announcing it.
---

# cortado-release

One release: decide the number from the evidence, land it, publish it, confirm it is visible to
every install, and say so in a way that claims nothing the range does not contain.

Invoke `cortado-release` with no argument to analyse and propose a version. Pass a version
(`2.1.0`) to propose that one instead; the analysis still runs, so a disagreement is visible rather
than silent. Pass `--dry-run` to analyse, print the proposal and stop.

GitHub Actions checks release pull requests and pushes to `main`. This skill edits the version in
a release pull request, publishes the tag and GitHub Release, and checks the result. Follow the
"Versioning and Releases" contract in `AGENTS.md`.

## Prerequisites

- A checkout of `gcko/Cortado` with `origin` pointing at it, push access, and `gh` authenticated.
- `shellcheck`, `jq` and `bash` for the Pre-PR Checks.
- `shasum` or `sha256sum` to create the release checksum.
- For the announcement only: a channel the owner names, a way to post to it, and the
  `humanizer:humanizer` skill. All optional. Missing them costs the announcement and nothing else.

If a prerequisite for the release itself is missing, stop before any write and say which.

## 1. Pre-flight

Answer all of these before looking at any diff. Any "no" stops the run.

```bash
git fetch --prune --tags origin
git switch main && git pull --ff-only origin main
git status --porcelain                    # must be empty
LAST=$(git ls-remote --tags --refs origin 'v*' | sed 's|.*refs/tags/||' | sort -V | tail -1)
echo "last release on origin: ${LAST:-none}"
cat VERSION
```

**Read the last tag from `origin`, never from `git tag -l`.** This clone can carry `v1.5.0` to
`v1.8.0` from pstuart/Barista. Those tags do not exist on `gcko/Cortado` and are not ancestors of
`main`, so a range built on one compares two unrelated histories. On 2026-11-22 `origin` had no
release tags at all.

**`$LAST` does not survive between shell invocations.** Every block below re-derives it and checks
it first. An empty `$LAST` turns `"$LAST"..HEAD` into `..HEAD`, which git reads as `HEAD..HEAD`:
zero commits, empty diffs, exit 0, exactly like a release with nothing in it.

- **The tree is clean and `main` is current.** The release is cut from `origin/main`.
- **`VERSION` equals `$LAST` without its `v`.** If it does not, a previous release is half
  finished: the bump merged but the Release was never published, or the reverse. Finish that one
  (step 6 on the existing number) before starting another. With no tag on `origin`, this is the
  first release; see [The first release](#the-first-release).
- **The version literals agree.** `VERSION`, the README badge, the README "What's New" heading, the
  README footer, the newest `CHANGELOG.md` entry and the assertion in `tests/test_config_cli.sh` name
  one version:

  ```bash
  V=$(tr -d '[:space:]' < VERSION)
  grep -c "Version-$V-green" README.md                      # 1
  grep -c "^## What's New in v$V" README.md                 # 1
  grep -c "Cortado v$V - " README.md                         # 1
  grep -c "^## $V$" CHANGELOG.md                            # 1
  grep -cF "\"$V\" \"\$ver\"" tests/test_config_cli.sh      # 1
  ```

  Any 0 is drift; fix it in the release pull request and say so in the proposal.
- **`main` passes the Pre-PR Checks.** Run the local checks from `AGENTS.md` on `origin/main` in a
  clean worktree and keep their output for the proposal.

## 2. Gather the evidence

Commit census first, because it is cheap and frames everything else:

```bash
LAST=$(git ls-remote --tags --refs origin 'v*' | sed 's|.*refs/tags/||' | sort -V | tail -1); [ -n "$LAST" ] || echo "STOP: no release tag on origin; see The first release"
git log --oneline "$LAST"..origin/main | grep -v 'chore(release)'
git log --format='%s' "$LAST"..origin/main | grep -v '^chore(release)' \
  | sed -E -e 's/^([a-z]+)(\([^)]*\))?!?:.*/\1/' -e t -e 's/.*/(unprefixed)/' \
  | sort | uniq -c | sort -rn
git diff --stat "$LAST"..origin/main | tail -1
```

Then the scan that decides the bump. Each section answers "can a person running Cortado see, set
or rely on something they could not before, or has something they relied on gone?":

```bash
R="$LAST..origin/main"
echo "# renamed files (the greps below see a renamed file as wholly new)"; git diff -M --name-status "$R" | grep -E '^R' || true
echo "# modules added or removed";    git diff -M --name-status "$R" -- modules/ | grep -E '^[AD]' || true
echo "# module registry";             git diff "$R" -- cortado.sh | grep -E '^[+-] +[a-z-]+\) +echo "module_' || true
echo "# config keys: defaults, documented options, reads"
git diff "$R" -- cortado.sh cortado.conf modules/ lib/ \
  | grep -E '^[+-]([A-Z][A-Z0-9_]+=|# +[A-Z][A-Z0-9_]+ +- |.*\$\{[A-Z][A-Z0-9_]+:-)' || true
echo "# project-config allowlist";    git diff "$R" -- cortado.sh lib/config-tui.sh | grep -E '^[+-].*[A-Z_]+\*?=\*\|' || true
echo "# installer flags";             git diff "$R" -- install.sh | grep -E '^[+-] +--[a-z-]+(\|[^)]*)?\)' || true
echo "# cortado config options";      git diff "$R" -- lib/config-tui.sh | grep -E '^[+-] +--[a-z-]+(\|[^)]*)?\)' || true
echo "# files and paths it owns";     git diff "$R" -- cortado.sh install.sh modules/ lib/ | grep -E '^[+-][^#]*(CLAUDE_CONFIG_DIR|CLAUDE_DIR|CACHE_DIR)[^ ]*/[A-Za-z._-]+' || true
echo "# payload fields read (jq paths)"
git diff "$R" -- cortado.sh modules/ | grep -vE '^[+-] *#' | grep -E "^[+-].*(^|[ ('|])\.[a-z][a-z_]+(\.[a-z_]+)*" || true
echo "# dependency floor";            git diff "$R" -- cortado.sh install.sh modules/ lib/ | grep -E '^[+-].*(command -v|BASH_VERSINFO|declare -A|mapfile|readarray)' || true
```

Read what comes back. A census line is evidence; a diff hunk is the fact.

Three things these greps were tuned against, on Cortado's own history:

- **Config keys hide in three shapes.** A key can arrive as a default (`KEY=` in `cortado.conf`), as
  a documented option in a module header (`#   MODEL_SHOW_THINKING - ...`), or only as a read
  (`${MODEL_SHOW_THINKING:-false}`). The thinking-and-effort segment (`d317e55`) added two keys in
  the second and third shapes and none in the first; a `KEY=`-only grep scanned it clean.
- **Payload paths sit inside multi-line `jq` programs**, so the field grep matches `.name` paths
  anywhere on a line, not only inside a quoted one-liner.
- **A renamed file reads as wholly new.** The pathspec names only the new path, so the rename
  commit (`7503194`) showed the entire module registry as added. When the first section lists a
  rename, diff the pair directly: `git diff -M "$R" -- barista.sh cortado.sh`.

## 3. Classify the bump

Cortado is past `1.0.0`, so semver applies in full. **The rule is the surface, not the commit
type.** A `feat:` prefix is how the author felt about the change.

**Major** when something a person relied on stops working without them doing anything: a module, a
config key or a `cortado config` option removed or renamed; a key whose meaning or default changed
in a way that alters an existing line; a file Cortado reads or writes moving (`$CLAUDE_CONFIG_DIR`
paths, the install directory); an installer flag removed; a raised dependency floor (Bash, `jq`,
`bc`). A migration that carries users across (as `7503194` did for `barista.conf`) softens a major;
it does not make it a minor.

**Minor** when a person can see, set or run something new and nothing they relied on changed: a new
module or segment, a new config key, a new theme, a new installer or `cortado config` option, a
newly rendered payload field.

**Patch** when every change corrects behaviour that already shipped, or is invisible to someone
running the statusline: fixes, tests, docs, refactors. Twenty fixes are still a patch.

**Run the breaking-change scan regardless of the number.** Every grep in step 2 prints removals
alongside additions, and the `-` lines are the breaking half. `BREAKING CHANGE` and the `!` suffix
are welcome but not reliable: a break does not announce itself in commit metadata, so the scan is
the detector.

## 4. Propose, and stop

A published release is visible to every install's update check within a day, and a tag that
installs have fetched cannot be taken back. So print the proposal and wait for an explicit yes.
Never release on an inferred approval.

The proposal carries:

1. The range (`$LAST..origin/main`) and the commit count with `chore(release)` excluded.
2. The census.
3. The classification, with the specific evidence that decided it. "Minor, because `modules/model.sh`
   reads `.effort` and adds `MODEL_SHOW_THINKING`" is a reason. "Minor, 4 feats" is a count.
4. Anything the breaking-change scan found, or an explicit "nothing".
5. The Pre-PR Checks output for `origin/main`.
6. The proposed version, proven free:

   ```bash
   VERSION=<the proposed number>
   git ls-remote --tags origin "refs/tags/v$VERSION"   # must print nothing
   gh release view "v$VERSION" -R gcko/Cortado         # must fail: release not found
   ```
7. The draft release note (step 6.5's shape), so the owner approves text they have read.
8. The question: cut it, and separately, should it be announced afterwards, and where?

## 5. Land the version bump

```bash
VERSION=<the number the owner just approved>
PREV=$(tr -d '[:space:]' < VERSION)
git switch -c "release/v$VERSION" origin/main
printf '%s\n' "$VERSION" > VERSION
sed -i '' "s/Version-$PREV-green/Version-$VERSION-green/" README.md
sed -i '' "s/^\*Cortado v$PREV - /*Cortado v$VERSION - /" README.md
sed -i '' "s/\"$PREV\" \"\$ver\"/\"$VERSION\" \"\$ver\"/" tests/test_config_cli.sh
```

`sed -i ''` is the macOS form; on Linux drop the `''`. Then write the release history. Add a
`## $VERSION` section to `CHANGELOG.md`, above the newest entry, with the release note's claims. In
the README, replace the `## What's New in v$PREV 🆕` section with `## What's New in v$VERSION 🆕`
holding the same claims, and keep its link to the changelog: the README shows only the latest
release. Re-run the step 1 literal check against `$VERSION` (every
count 1), run the Pre-PR Checks, and open the pull request:

```bash
git commit -am "chore(release): v$VERSION"
git push -u origin "release/v$VERSION"
gh pr create --title "chore(release): v$VERSION" --body-file <notes with a ## Verification section>
```

Merge it with a squash once the owner's approval from step 4 covers it, and record the merge
commit:

```bash
gh pr merge --squash --delete-branch
git fetch origin && SHA=$(git rev-parse origin/main)
git show "$SHA:VERSION"                         # must print $VERSION
```

If anything merged to `main` while the proposal waited, `origin/main` now holds more than you
scanned. Re-run step 2 over the wider range before publishing; the approved number may no longer be
the right one.

## 6. Publish, and confirm it landed

Package exactly the bump commit as `Cortado-source.zip`, copy `get-cortado.sh` from the same
commit, and write the SHA-256 of both to `SHA256SUMS`. `install.sh --update` downloads the zip and
`SHA256SUMS`; `get-cortado.sh` is the script people without git or Homebrew download and run
(docs/install.md, "Install without git or Homebrew"), and it checks the zip against `SHA256SUMS`
the same way. Its own line in `SHA256SUMS` lets a reader check the script before running it; both
checkers read only the line for `Cortado-source.zip`, so the extra line is safe
(`tests/test_get_cortado.sh` proves it for both). Attach all three in the release creation command
so GitHub CLI uploads them before it publishes the Release.

```bash
(
  set -e
  assets=$(mktemp -d)
  trap 'rm -rf "$assets"' EXIT
  git archive --format=zip --prefix="Cortado-$VERSION/" \
    --output="$assets/Cortado-source.zip" "$SHA"
  git show "$SHA:get-cortado.sh" > "$assets/get-cortado.sh"
  (
    cd "$assets"
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 Cortado-source.zip get-cortado.sh
    else
      sha256sum Cortado-source.zip get-cortado.sh
    fi
  ) > "$assets/SHA256SUMS"

  gh release create "v$VERSION" "$assets/Cortado-source.zip" "$assets/SHA256SUMS" \
    "$assets/get-cortado.sh" \
    -R gcko/Cortado --target "$SHA" --title "Cortado v$VERSION" --notes-file "<the approved note>"

  mkdir "$assets/downloaded"
  gh release download "v$VERSION" -R gcko/Cortado --dir "$assets/downloaded" \
    --pattern Cortado-source.zip --pattern SHA256SUMS --pattern get-cortado.sh
  cmp "$assets/Cortado-source.zip" "$assets/downloaded/Cortado-source.zip"
  cmp "$assets/SHA256SUMS" "$assets/downloaded/SHA256SUMS"
  cmp "$assets/get-cortado.sh" "$assets/downloaded/get-cortado.sh"
)
```

`--target` with a full SHA creates the tag on that commit server-side. All three `cmp` commands
must exit zero. If publication or verification fails, inspect the existing tag, Release and assets
before retrying. Confirm that the tag is on the bump commit and that installs can see the Release:

```bash
git ls-remote --tags origin "refs/tags/v$VERSION"                          # exists
git fetch --tags origin && git rev-parse "v$VERSION^{commit}"              # equals $SHA
gh release view "v$VERSION" -R gcko/Cortado --json tagName,url,isDraft     # isDraft false
gh api repos/gcko/Cortado/releases/latest --jq .tag_name                   # v$VERSION
```

The last line is what every install's `update` module and `./install.sh --check-update` read.

If the Release published but `releases/latest` names an older tag, the new one was published as a
prerelease or with `--latest=false`; fix it with `gh release edit "v$VERSION" --latest`.

### The first release

With no release tag on `origin` there is no range for step 2 to diff. Say so in the proposal and
build the evidence from what `gcko/Cortado` has shipped since it became its own project: the rename
(`7503194`, which moved every path and so makes the first release a major) and the merged pull
requests (`gh pr list -R gcko/Cortado --state merged`). The release note's upgrade section must
cover the move from Barista: `docs/migrating-from-barista.md` is the source.

## 6.5 Write the release note for a person

`--generate-notes` produces a list of merged pull request titles. That is a changelog, not a
release note, and a reader who did not follow the work learns nothing from it. Write the note by
hand, in this order:

1. What changed for someone using the statusline, as two to four plain claims, each one sentence of
   what they can now see or set and, where useful, the pull request that did it.
2. Anything the breaking-change scan found, and what the reader has to do about it.
3. How to upgrade: `./install.sh --update` from a checkout, or `git pull` and `./install.sh`.
4. What did not change, when a reader might reasonably wonder.

Never promise something the release did not ship. Every claim must trace to a commit in the range:
check each sentence against the log and delete anything you cannot point at.

## 7. Announce it, if asked

Only after step 6 confirms the Release exists. Announcing a release that has not published is worse
than not announcing.

Write for a person: the version, the one or two things worth knowing, anything breaking, and the
Release URL. If nothing in the range is worth a reader's attention, say that in a line.

Then invoke `humanizer:humanizer` on the draft. If that skill is not installed, apply the standard
by hand from the [`sync-docs` skill's "Voice and tone" section](../sync-docs/SKILL.md#voice-and-tone).

Resolve the channel at run time from the owner's answer, show the owner the final text and the
channel, and send only on an explicit yes. Report the message link back.

## Hard rules

Never change `VERSION` or its literals outside a `release/v*` pull request.

Never publish without an explicit yes in this run. Approval for a previous release is not approval
for this one.

Never read the last release from local tags.

Never announce before `gh api repos/gcko/Cortado/releases/latest` names the new tag.

Never put a claim in the note that is not in the commit range.

Never reuse a number or move a published tag. A wrong release is superseded by the next one.
