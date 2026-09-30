# Contributing to Shell

Thanks for helping out. Bug reports, fixes, docs and focused features are all welcome.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## How work flows

Every change starts with an issue and ends with a pull request that closes it:

1. **Issue.** Find an existing issue or open one with the matching form. Titles use a type prefix, and labels mirror it:

| Type | Title | Label | Example |
| --- | --- | --- | --- |
| Bug | `bug: …` | `bug` | `bug: Ghost text disappears after closing the completion menu` |
| Feature | `feature: …` | `feature` | `feature: Show CI status for each worktree in the sidebar` |
| Chore | `chore: …` | `chore` | `chore: Move ProcessRunner timeouts into a shared constant` |
| Docs | `docs: …` | `docs` | `docs: Explain how to load the zsh integration inside tmux` |
| Question | `question: …` | `question` | `question: Can Shell read my existing Ghostty config?` |

   New issues get `needs-triage`. A maintainer then confirms the type and adds a priority:

| Priority | Meaning |
| --- | --- |
| `p1` | Broken core workflow, crash, data loss or a regression in the latest release. Fixed next. |
| `p2` | Important; degraded experience with a workaround. Planned soon. |
| `p3` | Minor or nice to have. Picked up when time allows, and often a good first contribution. |

2. **Branch.** Comment on the issue to claim it, then branch from `main` as `<type>/<issue>-<short-slug>`, e.g. `bug/42-ghost-text-completion`.
3. **Pull request.** Open it against `main` with a Conventional Commits title (`fix:`, `feat:`, `chore:`, `docs:` …) and `Closes #42` in the body, and fill in the template. CI builds Shell and runs the tests on every pull request.

Trivial fixes such as typos or broken links can go straight to a pull request.

## Ways to contribute

- **Report a bug.** Use the [bug report form](../../issues/new/choose). Include your macOS version, Shell version (Shell › About Shell), steps to reproduce and what you expected. A diagnostic snapshot helps a lot; see [Troubleshooting](docs/troubleshooting.md#collecting-diagnostics).
- **Suggest a feature.** Use the [feature request form](../../issues/new/choose). For anything larger than a small fix, agree on the approach in the issue before you write code.
- **Improve the docs.** Typos, unclear steps and missing troubleshooting entries are all good first contributions.
- **Fix something.** Issues labeled `good first issue` or `help wanted` are a good place to start. Comment on the issue you want to take so others know it's in progress.
- **Security issues.** Don't open a public issue. See [SECURITY.md](SECURITY.md).

## Development setup

You need macOS 26 or later on Apple Silicon, Xcode 26 or later, and Homebrew.

```bash
brew install zig xcodegen
```

```bash
make bootstrap && make run
```

`make bootstrap` builds libghostty from a pinned commit (about 3 minutes the first time) and generates `Shell.xcodeproj`. See [Building from source](docs/building.md) for details and troubleshooting, and [Development](docs/development.md) for the debug tooling.

Things to know:

- **The Xcode project is generated.** Edit [`project.yml`](project.yml), not `Shell.xcodeproj`, and run `make project` after adding or removing files.
- **No Apple Developer account needed.** Debug builds are ad-hoc signed.
- **Tests are isolated.** They run inside the app but use a throwaway settings folder, so they never touch your real configuration.

## Making a change

1. Fork the repository and branch from `main`, named after the issue (`<type>/<issue>-<short-slug>`).
2. Keep the change focused: one logical change per pull request.
3. Follow the [code conventions](docs/development.md#code-conventions). The most important ones:
   - Swift 6 strict concurrency; UI and model types are `@MainActor`.
   - Keep per-keystroke and per-frame work off the main thread and proportional to what's visible.
   - Run external tools through `ProcessRunner` or `GitRepository.run`.
   - New settings need a default value; new commands are a `ShortcutAction` case.
   - Anything installed into a user's `~/.claude`, `~/.codex` or `.zshrc` must be a no-op outside Shell.
   - Don't patch Ghostty. Send libghostty changes upstream.
4. Add or update tests in `Tests/ShellTests` where it makes sense, and run them:

```bash
xcodebuild -project Shell.xcodeproj -scheme Shell test
```

5. Build with no new warnings:

```bash
./scripts/build.sh
```

6. Update the docs in `docs/` if behavior, settings or shortcuts change. Shortcut changes also go in [`docs/keyboard-shortcuts.md`](docs/keyboard-shortcuts.md).
7. Add a line to [`CHANGELOG.md`](CHANGELOG.md) under **Unreleased** for anything a user would notice.
8. Open a pull request against `main`, fill in the template, and link the issue with `Closes #N`. Include screenshots for UI changes. Make sure the **Tests** check passes.

## Commit messages and PR titles

Use [Conventional Commits](https://www.conventionalcommits.org):

| Type | For |
| --- | --- |
| `feat:` | A new user-facing feature |
| `fix:` | A bug fix |
| `perf:` | A performance improvement |
| `refactor:` | A code change that doesn't change behavior |
| `docs:` | Documentation only |
| `test:` | Tests only |
| `chore:` | Build, tooling and maintenance |

Example: `fix: keep ghost text when the completion menu closes`.

## Review

A maintainer reviews every pull request. Expect questions; they're about the code, not you.

Pull requests are **squash-merged** into `main`, so the PR title becomes the commit message on `main`: keep it in Conventional Commits form. Before merging, the **Tests** check must pass, the branch must be up to date with `main` (use *Update branch* on the PR), and all review conversations must be resolved. Your branch is deleted after merge.

## Licensing

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE). Don't add third-party code or assets unless the license is compatible. If you do add any, update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
