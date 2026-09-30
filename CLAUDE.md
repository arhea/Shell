# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**Shell** is a fast, native macOS terminal for people who live in zsh and work alongside coding agents. It embeds **libghostty** for everything inside the terminal grid (VT parsing, PTY, fonts, Metal rendering) and builds its own native chrome around it: windows, tabs, splits, a Warp-style native prompt with zsh completions, sidebars, and first-class Claude Code / Codex / git worktree / GitHub tooling.

Goals, in priority order:

1. **Fast and correct.** Never fork or patch Ghostty. Keep per-keystroke and per-frame work off the main thread and O(visible).
2. **Use the user's real tools.** Completions come from their zsh, the Claude view drives their `claude`, PR data comes from their `gh`. No parallel configuration.
3. **Private and local.** No accounts, no telemetry, no cloud AI. Apple Intelligence features are on-device and off by default.
4. **Leave dotfiles alone.** Integration is injected at launch. Anything that edits a user config file is opt-in, minimal, reversible, and a no-op outside Shell.

This is a personal open-source project (MIT, bundle ID `app.bethesdalabs.Shell`). It is **not** Takt work: don't use Linear issues, and don't require ticket IDs in branches or commits.

## Target platform

| | |
| --- | --- |
| OS | macOS 15 (Sequoia) or later. Apple Intelligence features need macOS 26+ (`FoundationModels` is weak-linked; guard with availability checks). |
| Architecture | Apple Silicon (arm64) only. libghostty is built for the native arch. |
| Language | Swift 6 language mode, strict concurrency. AppKit for windows and terminal views, SwiftUI for settings, sidebars and the Claude view. |
| Toolchain | Xcode 26+, Zig (version pinned by Ghostty's `build.zig.zon`), XcodeGen. |
| Dependencies | No Swift packages. Everything third-party comes in through `Vendor/GhosttyKit.xcframework`. |
| Distribution | Outside the App Store: Developer ID-signed, hardened runtime, notarized, as a zip on GitHub Releases. |

## Commands

| Command | What it does |
| --- | --- |
| `make bootstrap` | Build libghostty from the pinned commit and generate `Shell.xcodeproj` (~3 min first time) |
| `make project` | Regenerate `Shell.xcodeproj` from `project.yml`. Run after adding or removing files. |
| `./scripts/build.sh` | Debug build, printing only this project's errors and warnings. Use this to check a change compiles. |
| `make run` | Debug build and launch |
| `xcodebuild -project Shell.xcodeproj -scheme Shell test` | Unit tests (isolated from real settings) |
| `make dist` | Release build, sign, notarize, staple, zip into `build/dist/` |

`Shell.xcodeproj` is generated and git-ignored. Edit `project.yml`, never the project file.

## Code navigation

```
Sources/Shell
├── App/            AppDelegate, main menu (built from ShortcutAction), debug commands, logging, quit cleanup
├── Ghostty/        libghostty runtime + callbacks, TerminalSurfaceView (keys/IME/mouse), config generation
├── Model/          TerminalSession, PaneTree (splits), Workspace (tabs/groups), session restore
├── UI/             Window controller, tabs, split container, panes, native prompt (Editor/), palette,
│                   hotkey window, Claude view + dashboard (Claude/), MCP manager, right sidebar
├── Settings/       AppSettings (settings.json), SettingsSync (iCloud), themes, ShortcutAction, Settings panes
├── Integrations/   ControlServer socket, zsh glue, history, notifications, Claude/Codex, Git/GitHub,
│                   MCP, Homebrew, Node, Zsh, Go, maintenance jobs, Apple Intelligence, widget publisher
└── Automation/     App Intents (Shortcuts, Spotlight), session entities, ShellAutomation
Sources/ShellWidgets  WidgetKit extension (sandboxed; reads a snapshot from the app group)
Sources/Shared        Code shared by the app and the widget
Resources/shell/zsh   ZDOTDIR bootstrap + shell-integration.zsh
Resources/bin         shellctl (zsh script speaking the control-socket protocol)
Tests/ShellTests      XCTest unit tests
scripts/              bootstrap.sh, build.sh, release.sh
docs/                 User and contributor docs
```

Where to start for common tasks:

| Task | Start here |
| --- | --- |
| New menu command or shortcut | Add a case to `ShortcutAction` (`Settings/ShortcutAction.swift`); menu, palette and Settings are built from it. Update `docs/keyboard-shortcuts.md`. |
| New setting | Add a property with a default to `AppSettings` (`Settings/AppSettings.swift`), a control in `Settings/Panes/`, and add it to `SettingsSync.portableKeys` if it should sync. Update `docs/configuration.md`. |
| Terminal input, IME, mouse | `Ghostty/TerminalSurfaceView.swift` |
| Ghostty config options | `Ghostty/ConfigController.swift` |
| Native prompt, completions, highlighting | `UI/Editor/` |
| zsh ↔ app messages | `Integrations/ControlServer.swift`, `Integrations/ShellIntegration.swift`, `Resources/shell/zsh/shell-integration.zsh`, `Resources/bin/shellctl` |
| Claude Code native view | `Integrations/Claude/ClaudeCodeSession.swift` (process + stream-json), `UI/Claude/` (views) |
| Agent status hooks | `Integrations/Agents/AgentIntegrations.swift` |
| Git, worktrees, PRs | `Integrations/Git/` and `UI/Sidebar/` |
| Shortcuts actions | `Automation/` (keep intents thin; behavior goes in `ShellAutomation`) |

Deeper references: `docs/architecture.md` (key types, data flow, threading, quit sequence), `docs/shell-integration.md` (socket protocol), `docs/development.md` (conventions, `shellctl debug`).

## Conventions

- `@MainActor` for UI and model types; prefer `@Observable`. Cross-thread state is queue-confined or locked and marked `@unchecked Sendable` with a comment saying which.
- Run external tools with `ProcessRunner` or `GitRepository.run`, quote with `ShellQuote`, share repos via `GitRepository.discover` (balance each with `stop()`).
- Log through the per-area loggers in `Log`; don't swallow failed writes with a bare `try?`.
- To inspect the running app without Screen Recording, use `"$SHELL_APP_CTL" debug snapshot <dir>` from a Shell tab.
- Update `docs/` when behavior, settings or shortcuts change, and add user-visible changes to `CHANGELOG.md` under **Unreleased**.
- Commits use Conventional Commits: `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `test:`, `chore:`. No Linear ID.

## Releasing a new version

Releases are Developer ID-signed and notarized with Alex's **personal** Apple developer account (alex.rhea@gmail.com, keychain profile `shell-notary`), not the Takt account. Versions follow SemVer and tags are `v<version>`.

Release commits go straight to `main`. **Confirm with Alex before pushing to `main`.**

### Preconditions

```bash
git switch main && git pull --ff-only && git status --short
```

- The tree is clean and up to date.
- Tests pass: `xcodebuild -project Shell.xcodeproj -scheme Shell test`.
- The notary profile exists: `xcrun notarytool history --keychain-profile shell-notary` succeeds.
- `gh auth status` is signed in with push access.

### Steps

1. **Pick the version.** Read `CHANGELOG.md` › Unreleased and choose the next SemVer (`VERSION=0.2.0`). Increment the build number by one (`BUILD=2`).

2. **Bump the version.** In `project.yml`, set `CFBundleShortVersionString` to `$VERSION` and `CFBundleVersion` to `$BUILD` for **both** the `Shell` and `ShellWidgets` targets (they must match).

3. **Update the changelog.** Rename `## [Unreleased]` to `## [$VERSION] - YYYY-MM-DD`, add a fresh empty `## [Unreleased]` above it, and update the compare links at the bottom.

4. **Commit locally.**

   ```bash
   git commit -am "chore: release v$VERSION"
   ```

5. **Create a draft release** with the changelog section as notes. Drafts don't create the tag yet.

   ```bash
   mkdir -p build
   awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {f=1; next} /^## \[|^\[/ {f=0} f' CHANGELOG.md > build/release-notes.md
   gh release create "v$VERSION" --draft --target main --title "Shell $VERSION" --notes-file build/release-notes.md
   ```

6. **Build, sign and notarize.** `make dist` runs `scripts/release.sh`: a Release arm64 build signed with Developer ID and a secure timestamp, checked for hardened runtime and no `get-task-allow`, notarized, stapled, verified with `spctl`, and zipped.

   ```bash
   make dist
   ```

   Output: `build/dist/Shell-$VERSION-$BUILD.zip`. If notarization fails, the script prints Apple's log. Fix the cause and re-run; don't use `--skip-notarize` for a release.

7. **Attach the build** and a checksum.

   ```bash
   cd build/dist && shasum -a 256 "Shell-$VERSION-$BUILD.zip" > "Shell-$VERSION-$BUILD.zip.sha256" && cd -
   gh release upload "v$VERSION" "build/dist/Shell-$VERSION-$BUILD.zip" "build/dist/Shell-$VERSION-$BUILD.zip.sha256"
   ```

8. **Push to `main`** (after Alex confirms).

   ```bash
   git push origin main
   ```

9. **Publish the release.** This creates the `v$VERSION` tag on the pushed release commit.

   ```bash
   gh release edit "v$VERSION" --draft=false --latest
   ```

10. **Verify.** `gh release view "v$VERSION"` shows both assets, and `git fetch --tags && git rev-parse "v$VERSION"` matches `git rev-parse main`.

If something fails before step 8, nothing is public: fix it, amend the local commit, and re-run from the failed step (`gh release delete "v$VERSION"` removes the draft). Full signing setup, entitlements and Time Sensitive notification notes are in `docs/releasing.md`.
