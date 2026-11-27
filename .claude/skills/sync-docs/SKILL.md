---
name: sync-docs
description: Use when reconciling Cortado's docs (README, docs/, CHANGELOG, AGENTS.md, cortado.conf and module header comments) with the code before a pull request or release, or whenever the documentation may be stale.
---

# sync-docs

Keep the docs true to the code and free of bloat. This is a **docs-only** skill: it changes
Markdown, plus comment lines in `cortado.conf` and in module headers, and nothing else. Each run is
a diff-and-reconcile pass, not a rewrite.

## Hard boundaries

- **Never change behaviour.** No code line, no config value, no default. In `cortado.conf` and in
  `modules/*.sh` only lines that start with `#` may change: `cortado.conf` is sourced as bash by
  every install, so a stray edit there runs on every statusline render. If a doc is right and the
  code is wrong, report it; do not fix it here.
- **Never touch the version.** `VERSION`, the README badge, the README footer, the "What's New"
  heading, the `CHANGELOG.md` headings and the assertion in `tests/test_config_cli.sh` belong to
  `cortado-release`.
- **Never rewrite release history.** `CHANGELOG.md` and the README's "What's New" section record
  what shipped then. Correct a claim in them only if it was false when written.
- **Never edit strings the code prints.** `./install.sh --help`, `cortado.sh help` and the
  `cortado config` usage text are code. A mismatch between them and the README is a finding: report
  it, or fix the README side if the code is right.
- **Respect the exclusion list** below. Some files here are inputs to a program or a legal text.

## When to run

- **Before opening a pull request**, as step 3 of `AGENTS.md`, "PR Workflow". Scope the pass to
  what the branch touched, so the doc updates ride in the same pull request.
- **Before a release**, as a full reconcile, from `main`, as its own docs pull request.

## The doc-ownership map

| File | Owns | Rule |
|---|---|---|
| `README.md` | The short entry point: what Cortado is, the demo, a quick install, the latest release, the module tables, reading the statusline, and short configure, custom-module and troubleshooting sections that link into `docs/`. Credits and license. | Keep it short: detail belongs in `docs/`, with a link. Every module it names must exist, and every module the code ships must have a row. Plain, descriptive headings. |
| `docs/install.md` | Requirements, installer options, updating, manual install, uninstall. | Every installer flag the code accepts appears here, and nothing else. |
| `docs/configuration.md` | `cortado config`, config files and their rules, per-project settings, the settings reference, background refreshes, presets. | Every `cortado config` option the code accepts appears here. Each default matches the code. |
| `docs/custom-modules.md` | The user guide to writing a module in `cortado-modules/`. | Its header table agrees with `AGENTS.md`, "Adding a New Module". `tests/test_module_catalog.sh` runs the quick start's first three code blocks, so keep them in order: module file, config, permissions. |
| `docs/troubleshooting.md`, `docs/migrating-from-barista.md` | Fixes for common problems; what carries over from Barista. | Each message and file name it quotes must be one the code prints or uses. |
| `CHANGELOG.md` | Release history, newest first. | Written by `cortado-release`. The README's "What's New" holds only the newest entry. |
| `AGENTS.md` | **Canonical** repository contract: architecture tree, how it works, conventions, Pre-PR Checks, PR workflow, versioning, review tiers, parallel work, the skills table. | Every process command list is defined here once; other docs link to it. Never rename or move it: Codex loads it by name, and `CLAUDE.md` imports it. |
| `CLAUDE.md` | Claude-Code-only addenda. | Line 1 stays the bare `@AGENTS.md` import. Anything also true for Codex belongs in `AGENTS.md`. |
| `cortado.conf` comments | The per-setting reference every install ships with. | Comment lines only. Each documented key must be one the code reads, with the default the code uses. |
| Module header comments (`# Configuration options:`) | The per-module option reference. | Comment lines only. Each listed option must match a `${KEY:-default}` read in that module, default included. |
| `.github/workflows/ci.yml` | The automated pull request and main checks. | Read it to verify the CI policy in `AGENTS.md`. |
| `.claude/skills/*/SKILL.md` and their `references/` | Repository development skills, including this one. Not shipped. | `.claude/skills/` is canonical; each `.agents/skills/<name>` is a relative symlink to it, and each skill has its own `agents/openai.yaml`. A skill's commands must have been run before they are written down. |

## Files that are not documentation: never reconcile these

| Path | Why |
|---|---|
| `LICENSE`, `NOTICE` | Apache 2.0 text and the upstream Barista MIT notice the MIT licence requires. Edits are legal changes. |
| `demo.tape` | A VHS script that renders `demo.gif`. It is a program. |
| `tests/**` | Test input; its content is asserted on. |
| `VERSION` and the version literals | Owned by `cortado-release`. |
| `.git/`, `.claude/worktrees/` | Not source. |

Before editing any Markdown file this table and the map do not list, check whether a program reads
it (`grep -rn "$(basename "$F")" --include='*.sh' .`) and whether it is tracked
(`git ls-files --error-unmatch "$F"`). When in doubt, leave it alone and list it under `Unresolved:`
in the report.

## Voice and tone

The prose docs are written for people. An agent topping them up in model-default voice, one sync at
a time, is how that erodes. Step 6 of the procedure applies this standard and check (e) in step 7
is its mechanical backstop, since nothing else enforces tone.

**This section is the contract, not the `humanizer` skill.** That skill automates the pass where a
harness has it, but this repository does not vendor it, so everything needed to apply the standard
by hand is here.

In scope: `README.md`, `CHANGELOG.md` and `docs/*.md`. Out of scope, deliberately: `AGENTS.md`
and `CLAUDE.md` (agent contracts loaded verbatim), the skills (agent instructions), and config and
code comments.

The standard, in order of how often it is violated:

- No em dashes, en dashes, or curly quotes in prose you write. Use a period, a comma, a colon, or
  parentheses.
- No mechanical boldface, and no inline-header lists where every item starts with a bolded label.
  The changelog's feature lists predate this rule; do not add new ones.
- Sentence case in new headings. Headings say what the section holds; keep the coffee name to the
  tagline.
- Prefer `is`/`are`/`has` over "serves as", "stands as", "boasts", "features".
- Cut the AI-vocabulary words: crucial, pivotal, seamless, robust, leverage, delve, showcase,
  underscore, testament, landscape (figurative), tapestry.
- No participle tails bolted on for depth ("..., ensuring reliability").
- No generic upbeat closers. End on the last concrete fact.

Never drop a fact to make a sentence flow, and never add one to make it land: the pass keeps the
information and changes only the shape.

The 2026-11-27 rewrite brought the README and `docs/` to this standard. Check (e) scans only the
lines a pass adds, so it stops new drift without forcing a rewrite. A full tone pass over the docs
is its own docs pull request, with the owner's yes.

## Extract the code truth

Run this from the repository root. The output is what the docs must match.

```bash
# Modules: one name per source. Every list must hold the same names.
echo "# modules on disk";          ls modules/*.sh | xargs -n1 basename | sed 's/\.sh$//' | grep -v '^utils$' | sort | tr '\n' ' '; echo
echo "# registry (cortado.sh)";    sed -n '/^get_module_function()/,/^}/p' cortado.sh | grep -oE '^ +[a-z-]+\)' | tr -d ' )' | sort | tr '\n' ' '; echo
echo "# config catalog";           grep -oE '^    "[a-z-]+:(true|false):' lib/config-tui.sh | cut -d'"' -f2 | cut -d: -f1 | sort | tr '\n' ' '; echo
echo "# MODULE_* in cortado.conf"; grep -oE '^MODULE_[A-Z_]+=' cortado.conf | grep -v ORDER | sed 's/^MODULE_//; s/=$//' | tr 'A-Z_' 'a-z-' | sort | tr '\n' ' '; echo
echo "# README module rows";       grep -oE '^\| \*\*[a-z-]+\*\* \|' README.md | grep -oE '[a-z-]+' | sort | tr '\n' ' '; echo
# Installer flags: the parser, its help, and the docs
echo "# install.sh flags";         sed -n '/^parse_args()/,/^}/p' install.sh | grep -oE -- '--[a-z-]+' | sort -u | tr '\n' ' '; echo
echo "# install.sh --help";        sed -n '/^show_help()/,/^}/p' install.sh | grep -oE -- '--[a-z-]+' | sort -u | tr '\n' ' '; echo
echo "# docs installer flags";     grep -ohE -- '\./install\.sh --[a-z-]+' README.md docs/*.md | awk '{print $2}' | sort -u | tr '\n' ' '; echo
# cortado config options: the parser, its usage, and the docs
echo "# config parser";            sed -n '/^cortado_config_main()/,/^}/p' lib/config-tui.sh | grep -oE -- '--[a-z-]+' | sort -u | tr '\n' ' '; echo
echo "# config usage";             sed -n '/^_cfg_usage()/,/^}/p' lib/config-tui.sh | grep -oE -- '--[a-z-]+' | sort -u | tr '\n' ' '; echo
echo "# docs config options";      grep -ohE -- 'cortado config --[a-z-]+' README.md docs/*.md | awk '{print $3}' | sort -u | tr '\n' ' '; echo
# Themes and the files Cortado keeps
echo "# themes (apply_theme)";     sed -n '/^apply_theme()/,/^}/p' modules/utils.sh | grep -oE '^ +[a-z]+\)' | tr -d ' )' | sort -u | tr '\n' ' '; echo
echo "# CLAUDE_CONFIG_DIR files";  grep -rhoE 'CLAUDE_CONFIG_DIR(:-\$HOME/\.claude)?\}?/[A-Za-z._-]+' cortado.sh modules lib | sed -E 's|.*/||' | sort -u | tr '\n' ' '; echo
echo "# test suites";              ls tests/test_*.sh | xargs -n1 basename | sed 's/\.sh$//' | tr '\n' ' '; echo
echo "# version";                  cat VERSION
```

Read it as a set of lists that must agree. On 2026-11-22 it showed two disagreements on `main`:
`cortado.conf` carried no `MODULE_UPDATE` or `MODULE_VERSION` default although every other list
named both modules, and the README named four of the eight `cortado config` options. The installer
also accepts `--check` as an alias for `--check-update`, which its help does not list. `default` is
missing from the themes line because `apply_theme` handles it as the fallthrough case.

For a module's own options, compare its header comment with what it reads:

```bash
M=modules/rate-limits.sh
grep -oE '^#   [A-Z][A-Z0-9_]+ +- .*\(default: [^)]*\)' "$M"
grep -oE '\$\{[A-Z][A-Z0-9_]+:-[^}]*\}' "$M" | sort -u
```

Cross-check every count a doc states ("25 modules", "five themes", a threshold, a default). Stale
counts are the most common drift.

## Procedure

1. **Scope the diff.** For a pre-PR run, what the branch changed:
   ```bash
   git log --oneline "$(git merge-base origin/main HEAD)"..HEAD
   git diff --stat "$(git merge-base origin/main HEAD)"..HEAD -- '*.sh' cortado.conf
   ```
   For a pre-release run, everything since the last release tag on `origin` (read it as
   `cortado-release` step 1 does), or the whole tree when there is none. The `--stat` output says
   which surfaces moved; the extraction above is the ground truth.
2. **Reconcile each doc against the code truth.** Every real item must appear correctly wherever it
   is documented, and every doc claim must still match the code. Build the full list of edits
   before making any. **Prune as you go:** tighten entries that bloated into specs, collapse an
   explanation repeated across docs down to its owner plus a link, and delete caveats that no
   longer apply.
3. **Diff the command lists against each other.** `AGENTS.md`, "Pre-PR Checks" is canonical. The
   README's test instructions and any skill that runs checks must match it or link to it. Run any
   command you document for the first time.
4. **Fix cross-references.** After renaming or deleting a doc or a heading, repoint everything that
   referenced it:
   ```bash
   grep -rn --exclude-dir={.git,worktrees} -e '<the-old-name-or-anchor>' .
   ```
   Comments in `.sh` files count, and repointing them is allowed: a comment naming a doc is a doc
   reference, not behaviour.
5. **Update the pointers.** Keep the `AGENTS.md` architecture tree and skills table current, and
   check that no `CLAUDE.md` bullet has become true for Codex too (move it up) or obsolete (delete
   it).
6. **Bring the tone back to the standard.** Apply Voice and tone to every human-facing line this pass
   wrote, and re-read the result: it must keep every fact and lose only the tells. The `humanizer`
   skill does this in file mode where the harness has it.
7. **Verify.** All five checks, every run. Use `git status` and `git diff HEAD`, not plain
   `git diff`, which shows neither new untracked docs nor staged changes:
   ```bash
   # a. Only docs and comment lines changed.
   git status --porcelain -uall | awk '{print $NF}' | grep -vE '\.md$' || true
   git diff HEAD -U0 -- cortado.conf modules/ | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
     | grep -vE '^[+-][[:space:]]*(#|$)' || echo "non-doc files: comment lines only"

   # b. No version literal moved.
   git diff HEAD -- VERSION tests/test_config_cli.sh | grep -E '^[+-]' || echo "version untouched"
   git diff HEAD -U0 -- README.md | grep -E '^[+-].*(Version-[0-9]|Cortado v[0-9]|What.s New in v)' || true

   # c. Every relative link and anchor resolves: run The link check below.

   # d. If a comment in cortado.conf or a module changed, the scripts still parse and pass.
   bash -n cortado.conf && for f in modules/*.sh; do bash -n "$f"; done && echo "syntax ok"

   # e. Tone: no em/en dashes or curly quotes in the human-facing lines this pass added.
   if git diff HEAD -U0 -- README.md CHANGELOG.md docs/ | grep -E '^\+[^+]' \
        | sed 's/`[^`]*`//g' | grep -n '—\|–\|[“”‘’]'; then
     echo "TONE DRIFT: reapply Voice and tone to the lines listed above"
   else
     echo "tone clean"
   fi
   ```
   Check (d) covers only parsing. When a pass edited comments in a `.sh` file or `cortado.conf`, also
   run the full Pre-PR Checks in `AGENTS.md`: a comment edit that swallowed a line break is not a
   comment edit.

   **Then decide whether you owe the full gate, by who authors the pull request.** A pre-PR run on
   someone's feature branch: checks a to e, because that branch's author runs the Pre-PR Checks. A
   standalone run: you are the author, so run the whole Pre-PR Checks block before opening anything.
8. **Stage, commit in the right place, then report.** Never commit to `main`. Stage explicitly, since
   new docs are untracked and `git commit -a` would skip them:
   ```bash
   git add -A -- '*.md' cortado.conf modules/   # comment-only edits from steps 2 and 4
   git status --short                            # confirm the staged set is what you expect
   ```
   - **Pre-PR run**, on an existing feature branch before `gh pr create`: commit onto that same
     branch; the doc updates ride in the pull request about to open.
   - **Standalone run**, from `main` with no feature work in flight: create a `docs/...` branch,
     commit, and open its own pull request with the Pre-PR Checks output in its `## Verification`.

   End with a one-line report:
   `Added: ... | Corrected: ... | Removed: ... | Unresolved: ...`.

## The link check

Cortado has no link validator, so this is it. Run it from the repository root; it reads every
tracked and new Markdown file outside `tests/`, and resolves each relative link and `#anchor` the
way GitHub renders headings.

```bash
python3 - $(git ls-files -co --exclude-standard -- '*.md' | grep -v '^tests/') <<'PY'
import os, re, sys
FENCE = re.compile("`" * 3 + ".*?" + "`" * 3, re.S)
def slug(h):
    h = re.sub(r"[`*_]", "", h.strip().lower())
    return re.sub(r"[^a-z0-9 -]", "", h).replace(" ", "-")
def anchors(path):
    text = FENCE.sub("", open(path, encoding="utf-8").read())
    return {slug(m) for m in re.findall(r"^#{1,6} +(.+?) *$", text, re.M)}
bad = 0
for src in sys.argv[1:]:
    text = FENCE.sub("", open(src, encoding="utf-8").read())
    for target in re.findall(r"\]\(([^)\s]+)\)", text):
        if re.match(r"[a-z]+:", target):
            continue
        path, _, frag = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(src), path)) if path else src
        if not os.path.exists(dest):
            print(f"{src}: missing file {target}"); bad += 1
        elif frag and dest.endswith(".md") and frag not in anchors(dest):
            print(f"{src}: missing anchor {target}"); bad += 1
print("links clean" if not bad else f"{bad} broken link(s)")
PY
```

## When not to change something

- A doc that deliberately records a known gap or an accepted trade-off: the README's privacy and
  security notes, the `AGENTS.md` note that the rate-limits module never reads the Keychain.
  Remove such a note only when the underlying code changed; quietly deleting an honest caveat is
  worse than the caveat.
- The upstream-history notes: `NOTICE`, the README's credit to Barista, the `AGENTS.md` note that
  `#21`, `#24` and `#28` point to pstuart/Barista.
- Version fields and past release notes, per the hard boundaries.
- Any file in the exclusion table, or any file whose classification you are unsure of.
