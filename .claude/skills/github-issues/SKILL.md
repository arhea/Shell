---
name: github-issues
description: Create, rewrite, triage or QA high-quality GitHub issues for the Shell repo (arhea/Shell) using its type prefixes (bug, feature, chore, question, docs), type labels and p1–p3 priority labels. Use whenever work needs to be tracked before it's built — a bug found while coding, a feature idea, a refactor or cleanup, a docs gap, an open question — or when asked to "file an issue", "open a ticket", "write this up", "triage this issue" or "clean up issue #N", even if the user never says "GitHub". Every code change in this repo starts from an issue; hand off to the github-pull-requests skill once work begins.
---

# GitHub issues for Shell

Every unit of work in this repo is tracked by a GitHub issue on `arhea/Shell`, and every pull request closes one. This skill writes those issues so that a contributor who has never seen the conversation can pick one up and act on it. Contributors filing through the issue forms in `.github/ISSUE_TEMPLATE/` produce the same shape, so issues read the same whoever wrote them.

The workflow is always: **issue → branch → pull request that closes the issue** (see the `github-pull-requests` skill).

## 1. Classify the issue

| Type | Title prefix | Label | Use for | Leads to a PR titled |
| --- | --- | --- | --- | --- |
| Bug | `bug:` | `bug` | Shell behaves differently from what it should or what the docs say | `fix: …` |
| Feature | `feature:` | `feature` | New user-visible capability, or a meaningful change to an existing one | `feat: …` |
| Chore | `chore:` | `chore` | Refactors, tech debt, dependency or Ghostty bumps, build/CI, tests, cleanup — no user-visible behavior change | `chore:`, `refactor:`, `test:`, `perf:` … |
| Docs | `docs:` | `docs` | Missing, wrong or unclear documentation (README, `docs/`, in-app help text) | `docs: …` |
| Question | `question:` | `question` | Something that needs an answer or decision before work can be defined | Usually none; close with the answer, or convert into another type |

If one request mixes types (a bug plus a feature idea), file separate issues and cross-link them. Security vulnerabilities are **never** filed as public issues: stop and point to `SECURITY.md` (private vulnerability reporting).

## 2. Check for duplicates and gather context

```bash
gh issue list --repo arhea/Shell --state all --search "<key words>" --limit 20
```

If a match exists, add a comment with the new information (`gh issue comment`) instead of filing a duplicate, and tell the user.

Then gather what a fixer will need:

- **Where in the code.** Find the relevant files with the "Where to start" table in `CLAUDE.md` and link them as permalinks pinned to a commit, so links don't rot: `https://github.com/arhea/Shell/blob/<sha>/Sources/Shell/UI/Editor/InputEditorView.swift#L516-L540` (get the sha with `git rev-parse origin/main`).
- **Evidence.** Exact error text, log lines (`log stream --predicate 'subsystem == "app.bethesdalabs.Shell"'`), screenshots, a `shellctl debug snapshot` excerpt.
- **Environment** for bugs: Shell version or commit, macOS version, and relevant tool versions (`zsh`, `claude`, `codex`, `gh`).
- **Related issues and PRs** to link with `#N`.

Strip secrets, tokens, customer data, private paths and hostnames from anything you paste.

## 3. Write the title

`<type>: <summary>`

- Lowercase prefix, then a specific, sentence-case summary. Aim for under 70 characters.
- Bugs: state the broken behavior and where. `bug: Ghost text disappears after closing the completion menu`
- Features: name the capability from the user's view. `feature: Show CI status for each worktree in the sidebar`
- Chores: state the task. `chore: Move ProcessRunner timeouts into a shared constant`
- Docs: name the page and the gap. `docs: Explain how to load the zsh integration inside tmux`
- Questions: ask the question. `question: Should the hotkey window share session restore with normal windows?`
- No vague titles (`bug: prompt broken`, `feature: improvements`), no trailing period, no issue numbers or emoji.

## 4. Write the body

Use GitHub-flavored Markdown with `###` headings that match the issue forms, so skill-filed and form-filed issues look the same. Keep each section tight; omit optional sections that would be empty rather than writing "N/A".

### Bug

```markdown
### What happened?
<One or two sentences on the observed behavior.>

### Steps to reproduce
1. …
2. …
3. …

### What did you expect to happen?
<The correct behavior, and the doc or precedent that says so if there is one.>

### Area
<One of the areas from the bug form, e.g. "Native prompt or completions".>

### Environment
- Shell: 0.1.0 (1) / commit abc1234
- macOS: 15.5
- Tools: zsh 5.9, claude 2.x

### Logs, screenshots or diagnostic snapshot
<Trimmed, secrets removed. Use a fenced block with a language tag, and <details> for anything longer than ~20 lines.>

### Suspected cause
<Optional. Permalinked code and your reasoning. Mark it as a hypothesis unless verified.>

### Acceptance criteria
- [ ] <Observable result that proves it's fixed>
- [ ] Regression test in `Tests/ShellTests` where practical
```

### Feature

```markdown
### What problem are you trying to solve?
<The user and the workflow that's painful today. Problem first, not the solution.>

### What would you like Shell to do?
<The proposed behavior from the user's point of view: where it lives, how it's triggered, what it shows.>

### Alternatives and prior art
<Workarounds today; how iTerm2, Warp, Ghostty or others handle it.>

### Scope
- In: …
- Out: …

### Acceptance criteria
- [ ] …
- [ ] Docs updated (`docs/…`), shortcut added to `docs/keyboard-shortcuts.md` if any
```

Check features against the project goals in `CLAUDE.md` (fast, uses the user's real tools, private and local, leaves dotfiles alone) and note any tension in the issue.

### Chore

```markdown
### What needs doing?
<The task in one or two sentences.>

### Why
<The cost of not doing it: risk, slowness, duplication, blocked work.>

### Approach
<Files and steps, permalinked. Call out anything that must not change.>

### Acceptance criteria
- [ ] No user-visible behavior change (or: the exact change, if any)
- [ ] Tests pass; `./scripts/build.sh` shows no new warnings
```

### Docs

```markdown
### Which page?
<Path or URL, e.g. docs/shell-integration.md#how-it-loads>

### What's missing or wrong?
<Quote the current text if it's wrong. Say who gets stuck and how.>

### Suggested change
<Draft wording if you have it.>
```

### Question

```markdown
### Question
<The question, stated so a yes/no or concrete answer is possible.>

### Context
<What prompted it, what you've already checked, links.>

### Options considered
<Optional: the candidate answers and their trade-offs.>

### What depends on the answer
<Issues or work blocked on this.>
```

## 5. Label and prioritize

Every issue gets exactly **one type label** and, once triaged, exactly **one priority label**.

| Priority | Label | Meaning | Examples |
| --- | --- | --- | --- |
| P1 | `p1` | Broken core workflow, crash, data loss, security-adjacent, or a regression in the latest release. Fix before anything else and ship in the next release. | App crashes on launch; typing in the prompt drops keys; release DMG fails Gatekeeper |
| P2 | `p2` | Important. Degraded experience with a workaround, or a feature that matters to many users. Plan for an upcoming release. | Completions missing for a common tool; dashboard shows stale status |
| P3 | `p3` | Minor or nice to have. Polish, edge cases, small features. Picked up when time allows, good for contributors. | Tooltip wording; a rarely used setting |

- When you file for the maintainer, propose the priority with a one-line reason and apply it after they agree.
- Contributor-filed issues arrive with `needs-triage`. Triage means: confirm or fix the type label, add a priority, remove `needs-triage`, and ask for anything missing.
- Add `good first issue` to well-scoped P3s with clear acceptance criteria and code pointers, and `help wanted` when the maintainer won't get to it soon.
- Don't use `enhancement` or `documentation`; they're replaced by `feature` and `docs`.

## 6. Confirm, then create

Creating an issue is public. Show the user the title, labels and body, and create it only after they approve.

```bash
gh issue create --repo arhea/Shell \
  --title "bug: Ghost text disappears after closing the completion menu" \
  --label bug --label p2 \
  --body-file /path/to/body.md
```

Write the body to a file in the scratchpad (not the repo) and pass `--body-file`, so Markdown, backticks and checklists survive shell quoting. Add `--assignee @me` only when the maintainer is taking it now.

Report the issue URL back. If work is starting now, suggest the branch name (`<type>/<number>-<short-slug>`, e.g. `bug/42-ghost-text-completion`) and continue with the `github-pull-requests` skill.

## Updating and triaging existing issues

- Read it first: `gh issue view <N> --repo arhea/Shell --comments`.
- Fix titles and labels in place: `gh issue edit <N> --title "…" --add-label p2 --remove-label needs-triage`.
- Don't rewrite a contributor's body wholesale; add a comment with the structured summary, missing details or reproduction instead, and thank them.
- Close questions with the answer, and duplicates with `gh issue close <N> --reason "not planned" --comment "Duplicate of #M"`.

## Quality bar

Before creating, check that:

- [ ] The title follows `<type>: <specific summary>` and would make sense in a list of 100 issues.
- [ ] Someone new to the codebase could start work from the body alone.
- [ ] Bugs have numbered reproduction steps, expected vs. actual, and an environment.
- [ ] Acceptance criteria are observable and checkable, not "works better".
- [ ] Code references are permalinks; related issues and PRs are linked with `#N`.
- [ ] Exactly one type label, and a priority label (or `needs-triage`).
- [ ] No secrets, tokens or personal data.
