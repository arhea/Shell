---
name: github-pull-requests
description: Open, describe, update and shepherd pull requests for the Shell repo (arhea/Shell) — branch naming from the linked issue, Conventional Commits titles, a body that documents the specific changes, testing and risks, and closing keywords that link the issues it resolves. Use whenever work is ready for review or needs a PR: "open a PR", "put this up for review", "write the PR description", "update the PR body", "address review comments", even if the user doesn't say "pull request". Pairs with the github-issues skill, which creates the issue a PR closes.
---

# GitHub pull requests for Shell

Every pull request on `arhea/Shell` targets `main`, closes at least one issue, and explains itself well enough that a reviewer never has to reverse-engineer the diff. CI (`.github/workflows/test.yml`) builds and runs the unit tests on every PR.

## 1. Start from an issue

- Find the issue the work belongs to: `gh issue list --repo arhea/Shell --search "<key words>"`.
- If there isn't one, create it first with the `github-issues` skill. The only exceptions are trivial fixes (a typo, a broken link) — those may skip the issue, but say so in the PR body.
- Branch from an up-to-date `main`, named `<type>/<issue>-<short-slug>`:

```bash
git switch main && git pull --ff-only && git switch -c bug/42-ghost-text-completion
```

| Issue type | Branch prefix | PR / commit type |
| --- | --- | --- |
| `bug` | `bug/` | `fix:` |
| `feature` | `feature/` | `feat:` |
| `chore` | `chore/` | `chore:`, `refactor:`, `perf:`, `test:`, `build:`, `ci:` — whichever is most precise |
| `docs` | `docs/` | `docs:` |

## 2. Get it ready before opening

Run the same checks CI runs, plus the build warnings check:

```bash
xcodebuild -project Shell.xcodeproj -scheme Shell test
./scripts/build.sh
```

Then make sure the branch is complete:

- Tests added or updated in `Tests/ShellTests` for behavior changes and bug fixes, where practical.
- Docs updated in `docs/` when behavior, settings or shortcuts change.
- A line in `CHANGELOG.md` under **Unreleased** for anything user-visible, in the house style: user-facing wording plus full-URL links to the PR and issue, e.g.
  `- Ghost text survives closing the completion menu. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#42](https://github.com/arhea/Shell/issues/42))`
  Open the PR first if you need its number, then push the changelog line as a follow-up commit.
- Commits follow Conventional Commits (`fix: …`). Keep history readable; squash fixup commits.

## 3. Write the title

`<type>: <what the change does>` — Conventional Commits, imperative, lowercase type, no trailing period, under 72 characters. The title may become the merge commit, so it should read well in `git log`.

- `fix: keep ghost text when the completion menu closes`
- `feat: show CI status for each worktree in the sidebar`
- `docs: explain loading the zsh integration inside tmux`

Don't put the issue number in the title; the body links it.

## 4. Write the body

Gather the facts from the branch, not from memory:

```bash
git log --no-merges --format='%h %s' origin/main..HEAD
git diff --stat origin/main...HEAD
git diff origin/main...HEAD
```

Fill in `.github/PULL_REQUEST_TEMPLATE.md`'s structure:

```markdown
## What changed

<One or two sentences a reviewer can read in five seconds.>

Closes #42

## Why

<The problem from the issue, in a sentence or two, plus anything learned while fixing it — root cause for bugs, design choice for features.>

## Changes

- **Native prompt** (`Sources/Shell/UI/Editor/InputEditorView.swift`): keep the ghost-text suggestion when the completion popup hides without a selection.
- **Completions** (`Sources/Shell/UI/Editor/CompletionPopup.swift`): report dismissal separately from acceptance.
- **Tests** (`Tests/ShellTests/…`): cover dismiss-then-accept.
- **Docs**: none needed / `docs/…` updated.

## How it was tested

- `xcodebuild … test` — all tests pass (N tests).
- `./scripts/build.sh` — no new warnings.
- Manual: <exact steps you ran in the app and what you saw>.

## Screenshots

<Before/after for any UI change. Delete for non-UI changes.>

## Risks and follow-ups

<What could break, what you deliberately left out, related issues to file. Delete if genuinely none.>

## Checklist

<Keep the template's checklist and tick what's done.>
```

Rules for a good body:

- **Link issues with closing keywords** so they close on merge: `Closes #42`, `Fixes #42`, one per line for several issues. Use `Refs #57` for related issues the PR doesn't finish. Keywords only work in the PR body, not the title.
- **Changes are specific.** Group by area, name the file or type, and say what changed in behavior, not "updated X.swift". Call out anything reviewers should look at hardest (concurrency, main-thread work, files written in the user's home, anything installed into `~/.claude`, `~/.codex` or `.zshrc`).
- **Testing is evidence**, not "tested locally": the commands, the result, and the manual steps.
- **No secrets** or personal data in the body, screenshots or logs.

## 5. Confirm, then open

Opening a PR is public. Show the user the title and body, then:

```bash
git push -u origin HEAD
gh pr create --repo arhea/Shell --base main \
  --title "fix: keep ghost text when the completion menu closes" \
  --body-file /path/to/pr-body.md \
  --label bug --label p2 \
  --assignee @me
```

- Copy the type and priority labels from the linked issue.
- Write the body to a scratchpad file and use `--body-file` so Markdown survives quoting.
- Use `--draft` when the work isn't ready for review yet; mark it ready with `gh pr ready <N>` once it is.
- Report the PR URL back.

## 6. After opening

- Check CI with `gh pr checks <N> --repo arhea/Shell`. If the `Tests` job fails, read the log (`gh run view <run-id> --log-failed`), fix on the branch and push. Don't merge red.
- Address review comments with focused commits, reply to each thread with what changed, and update the PR body if the scope moved (`gh pr edit <N> --body-file …`).
- Keep the branch current with `main` when it falls behind or conflicts (`git fetch origin && git rebase origin/main`, then `git push --force-with-lease`).
- Merging is the maintainer's call. Never merge, close or force-push someone else's PR without being asked.

## Quality bar

- [ ] Branch is `<type>/<issue>-<slug>` off current `main`; PR targets `main`.
- [ ] Title is Conventional Commits and describes the change, not the ticket.
- [ ] Body has `Closes #N` (or explains why there's no issue).
- [ ] Changes list is specific enough to review from, grouped by area.
- [ ] Testing section shows commands and results; UI changes have screenshots.
- [ ] Tests, docs and `CHANGELOG.md` updated where the change calls for it.
- [ ] Labels match the issue; CI is green before asking for merge.
