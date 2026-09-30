## What changed

<!-- A short summary of the change. Link the issue it addresses, e.g. "Fixes #123". -->

## Why

<!-- The problem this solves, or the behavior it adds. -->

## How it was tested

<!-- Steps you took to verify the change, and anything reviewers should try. -->

## Screenshots

<!-- Required for UI changes. Before and after if possible. Delete this section otherwise. -->

## Checklist

- [ ] One focused change, with a [Conventional Commits](https://www.conventionalcommits.org) title (`feat:`, `fix:`, `docs:` …)
- [ ] Unit tests pass (`xcodebuild -project Shell.xcodeproj -scheme Shell test`)
- [ ] `./scripts/build.sh` shows no new warnings
- [ ] Tests added or updated in `Tests/ShellTests` where it makes sense
- [ ] Docs in `docs/` updated if behavior, settings or shortcuts changed
- [ ] `CHANGELOG.md` updated under **Unreleased** for user-visible changes
- [ ] `THIRD_PARTY_NOTICES.md` updated if third-party code or assets were added
