# Contributing to Shell

Thanks for helping out. Bug reports, fixes, docs and focused features are all welcome.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug.** Use the [bug report form](../../issues/new/choose). Include your macOS version, Shell version (Shell › About Shell), steps to reproduce and what you expected. A diagnostic snapshot helps a lot; see [Troubleshooting](docs/troubleshooting.md#collecting-diagnostics).
- **Suggest a feature.** Use the [feature request form](../../issues/new/choose). For anything larger than a small fix, agree on the approach in the issue before you write code.
- **Improve the docs.** Typos, unclear steps and missing troubleshooting entries are all good first contributions.
- **Fix something.** Comment on the issue you want to take so others know it's in progress.
- **Security issues.** Don't open a public issue. See [SECURITY.md](SECURITY.md).

## Development setup

You need macOS 15 or later on Apple Silicon, Xcode 26 or later, and Homebrew.

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

1. Fork the repository and branch from `main`.
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
8. Open a pull request and fill in the template. Include screenshots for UI changes.

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

A maintainer reviews every pull request. Expect questions; they're about the code, not you. Keep the PR title in Conventional Commits form, since it may become the merge commit message.

## Licensing

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE). Don't add third-party code or assets unless the license is compatible. If you do add any, update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
