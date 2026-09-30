<!--
Title: Conventional Commits, e.g. "fix: keep ghost text when the completion menu closes".
Branch: <type>/<issue>-<short-slug>, e.g. bug/42-ghost-text-completion.
-->

## What changed

<!-- One or two sentences a reviewer can read in five seconds. -->

Closes #

<!-- One "Closes #N" per issue this PR resolves. Use "Refs #N" for related issues it doesn't finish. Trivial fixes (typos, broken links) may skip the issue; say so here. -->

## Why

<!-- The problem from the issue, plus the root cause (bugs) or design choice (features). -->

## Changes

<!-- Specific, grouped by area, naming files or types:
- **Native prompt** (`Sources/Shell/UI/Editor/InputEditorView.swift`): …
- **Tests** (`Tests/ShellTests/…`): …
-->

## How it was tested

<!-- Commands and their results, plus the manual steps you took in the app. -->

## Screenshots

<!-- Required for UI changes; before and after if possible. Delete for non-UI changes. -->

## Risks and follow-ups

<!-- What could break, what you left out on purpose, issues to file. Delete if genuinely none. -->

## Checklist

- [ ] Linked the issue with `Closes #N`, and the PR has the issue's type and priority labels
- [ ] Unit tests pass (`xcodebuild -project Shell.xcodeproj -scheme Shell test`)
- [ ] `./scripts/build.sh` shows no new warnings
- [ ] Tests added or updated in `Tests/ShellTests` where it makes sense
- [ ] Docs in `docs/` updated if behavior, settings or shortcuts changed
- [ ] `CHANGELOG.md` updated under **Unreleased** for user-visible changes, linking this PR and the issue
- [ ] `THIRD_PARTY_NOTICES.md` updated if third-party code or assets were added
