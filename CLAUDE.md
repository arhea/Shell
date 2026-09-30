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
| OS | macOS 26 (Tahoe) or later. No availability checks needed for macOS 26 APIs, including `FoundationModels`. |
| Architecture | Apple Silicon (arm64) only. libghostty is built for the native arch. |
| Language | Swift 6 language mode, strict concurrency. AppKit for windows and terminal views, SwiftUI for settings, sidebars and the Claude view. |
| Toolchain | Xcode 26+, Zig (version pinned by Ghostty's `build.zig.zon`), XcodeGen. |
| Dependencies | No Swift packages. Everything third-party comes in through `Vendor/GhosttyKit.xcframework`. |
| Distribution | Outside the App Store: Developer ID-signed, hardened runtime, notarized, as a signed and notarized `.dmg` attached to GitHub Releases. The app updates itself from the latest release (`Integrations/Updates/`), so the DMG and its `.sha256` must both be attached and the release published with `--latest`. |

## Commands

| Command | What it does |
| --- | --- |
| `make bootstrap` | Build libghostty from the pinned commit and generate `Shell.xcodeproj` (~3 min first time) |
| `make project` | Regenerate `Shell.xcodeproj` from `project.yml`. Run after adding or removing files. |
| `./scripts/build.sh` | Debug build, printing only this project's errors and warnings. Use this to check a change compiles. |
| `make run` | Debug build and launch |
| `xcodebuild -project Shell.xcodeproj -scheme Shell test` | Unit tests (isolated from real settings) |
| `make dist` | Release build, sign, notarize and staple the app, then a signed, notarized `.dmg` + `.sha256` in `build/dist/` |

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

## Issues, pull requests and CI

All work is tracked on GitHub (`arhea/Shell`), not Linear. The flow is always **issue → branch → pull request that closes the issue**:

- **Issues** use the `github-issues` skill (`.claude/skills/github-issues/`): titles `bug:`, `feature:`, `chore:`, `docs:` or `question:`, one matching type label, and a `p1`–`p3` priority. If you start work that has no issue, create one first (confirm with Alex before filing).
- **Branches** are `<type>/<issue>-<short-slug>` off `main`, e.g. `bug/42-ghost-text-completion`.
- **Pull requests** use the `github-pull-requests` skill (`.claude/skills/github-pull-requests/`): a Conventional Commits title, `Closes #N`, a specific list of changes, testing evidence, and the issue's labels.
- **Labels** are defined in `scripts/labels.sh` (re-run it after changing them). Issue forms live in `.github/ISSUE_TEMPLATE/`.
- **CI**: `.github/workflows/test.yml` runs the unit tests on macOS 26 (Apple Silicon) for every pull request to `main` and every push to `main`. It signs ad hoc and needs no secrets. libghostty is cached by the pinned `GHOSTTY_COMMIT`, so the first run after a Ghostty bump takes longer. Don't merge a PR with a red **Tests** check.
- **Merging**: `main` is protected by the *Protect main* ruleset: changes land only through pull requests, **squash merge only** (the PR title becomes the commit subject, so it must be a good Conventional Commits line), the **Build and test** check must pass on a branch that's up to date with `main`, review threads must be resolved, history stays linear, and force pushes and deletion are blocked. Merged branches are deleted automatically.

## Releasing a new version

A release is a `v<version>` tag on `main`, a GitHub Release whose notes are the curated changelog, and one app artifact: a Developer ID-signed, notarized, stapled **`Shell-<version>.dmg`** plus its `.sha256`. Never attach a zip of the app. (GitHub adds "Source code (zip/tar.gz)" to every release automatically; those are source snapshots and can't be removed.)

- Signing and notarization use Alex's **personal** Apple developer account (alex.rhea@gmail.com, team `T9PCKZ42NK`, keychain profile `shell-notary`), never the Takt account.
- Versions follow SemVer. Before 1.0, breaking changes to settings or behavior bump the minor version.
- `main` is protected: the release commit lands through a squash-merged release PR like any other change (release PRs are the one kind of PR that doesn't need an issue). **Confirm with Alex before merging the release PR and before publishing the release.**

The order is deliberate: build and notarize the DMG *before* the release PR merges, so a failed build or a notarization rejection never leaves a half-made release or a tag behind.

### Preconditions

```bash
git switch main && git pull --ff-only && git status --short
```

- The tree is clean and up to date with `origin/main`.
- Tests pass: `xcodebuild -project Shell.xcodeproj -scheme Shell test`.
- `security find-identity -v -p codesigning` lists `Developer ID Application: Alex Rhea (T9PCKZ42NK)`.
- `xcrun notarytool history --keychain-profile shell-notary` succeeds.
- `gh auth status` is signed in as `arhea`.

### 1. Gather what changed

```bash
PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)   # empty for the first release
git log --no-merges --format='%h %s (%an)' ${PREV:+$PREV..}HEAD
```

```bash
gh pr list --repo arhea/Shell --state merged --base main --limit 200 \
  ${PREV:+--search "merged:>=$(git log -1 --format=%cs "$PREV")"} \
  --json number,title,author,labels,closingIssuesReferences,url
```

GitHub's auto-generated notes are useful raw material, never the final notes:

```bash
gh api repos/arhea/Shell/releases/generate-notes -f tag_name="v$VERSION" ${PREV:+-f previous_tag_name="$PREV"} --jq .body
```

Cross-check against `CHANGELOG.md` › Unreleased. Anything user-visible that's missing from Unreleased gets added now.

### 2. Write the changelog

Branch for the release first: `git switch -c release/v$VERSION`. Then edit `CHANGELOG.md`: rename `## [Unreleased]` to `## [$VERSION] - YYYY-MM-DD` and add a fresh, empty `## [Unreleased]` above it. The new section becomes the release notes verbatim, so it must be good:

- **Open with one or two sentences** saying what the release is about, before the first heading. Lead with the change a user most cares about.
- **Group entries** under Keep a Changelog headings, in this order, omitting empty ones: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- **Write for users, not for the diff.** Describe the behavior and where to find it ("Settings › Worktrees can now…"), not the implementation. One line per change, starting with a verb or the feature name. No commit hashes, no `chore:`/`refactor:` noise unless it changes behavior or performance.
- **Link every entry to its source.** Use full URLs (relative links and bare `#123` don't resolve in `CHANGELOG.md`): the PR, and the issue it closes when there is one.

  ```markdown
  - Worktrees sidebar shows each branch's CI status. ([#42](https://github.com/arhea/Shell/pull/42), fixes [#37](https://github.com/arhea/Shell/issues/37))
  ```

  If a change landed without a PR, link the commit: `([abc1234](https://github.com/arhea/Shell/commit/abc1234))`.
- **Credit outside contributors** at the end of the entry: `Thanks @username.`
- **Call out anything that needs action** (a changed setting, a new permission prompt, reinstalling agent hooks) in bold at the start of the entry under `Changed`.
- **Security fixes** name the impact, link the published advisory (`GHSA-…`) once it's public, and credit the reporter unless they asked not to be.

Update the link references at the bottom of the file:

```markdown
[Unreleased]: https://github.com/arhea/Shell/compare/v$VERSION...HEAD
[$VERSION]: https://github.com/arhea/Shell/compare/v$PREV...v$VERSION
```

(For the first release, `[$VERSION]` links to `https://github.com/arhea/Shell/releases/tag/v$VERSION`.)

### 3. Bump the version

In `project.yml`, set `CFBundleShortVersionString` to `$VERSION` and increment `CFBundleVersion` by one, for **both** the `Shell` and `ShellWidgets` targets (they must match). Then commit on the release branch:

```bash
git commit -am "chore: release v$VERSION"
```

### 4. Build the DMG

```bash
make dist
```

`scripts/release.sh` builds Release for arm64, verifies the Developer ID signature, hardened runtime, secure timestamp and absence of `get-task-allow`, notarizes and staples the app, packages it into a styled disk image (`scripts/make-dmg.sh`: terminal-themed background, `/Applications` shortcut, volume icon), then signs, notarizes and staples the disk image and writes its checksum. Notarization runs twice, so allow 5–15 minutes.

Output:

- `build/dist/Shell-$VERSION.dmg`
- `build/dist/Shell-$VERSION.dmg.sha256`

The DMG is built from the release branch; the squash merge in step 5 puts the identical tree on `main`. If notarization fails, the script prints Apple's log. Fix the cause, amend the release commit if needed, and re-run. Never use `--skip-notarize` for a release. Before moving on, confirm:

```bash
spctl --assess --type open --context context:primary-signature --verbose=2 "build/dist/Shell-$VERSION.dmg"
xcrun stapler validate "build/dist/Shell-$VERSION.dmg"
```

### 5. Merge the release PR

```bash
git push -u origin HEAD
gh pr create --repo arhea/Shell --base main --title "chore: release v$VERSION" \
  --body "Release v$VERSION. Changelog: see CHANGELOG.md. DMG built, notarized and verified locally from this branch." \
  --label chore
```

Wait for the **Build and test** check to pass. After Alex confirms, squash-merge it and record the resulting commit on `main`:

```bash
gh pr merge --repo arhea/Shell --squash --delete-branch
git switch main && git pull --ff-only
RELEASE_SHA=$(git rev-parse HEAD)
```

### 6. Create the release

Assemble the notes from the changelog section plus an install footer, then create the release as a **draft** (drafts don't create the tag or notify watchers):

```bash
mkdir -p build
SHA=$(cut -d' ' -f1 "build/dist/Shell-$VERSION.dmg.sha256")
{
  awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {f=1; next} /^## \[|^\[/ {f=0} f' CHANGELOG.md
  cat <<EOF

## Install

Download **Shell-$VERSION.dmg** below, open it, and drag Shell to Applications. Requires macOS 26 or later on Apple Silicon. The app and disk image are signed with a Developer ID and notarized by Apple.

SHA-256: \`$SHA\`

The "Source code" archives are the source at this tag, not the app. To build it yourself, see [Building from source](https://github.com/arhea/Shell/blob/v$VERSION/docs/building.md).
EOF
  if [[ -n $PREV ]]; then printf '\n**Full changelog:** https://github.com/arhea/Shell/compare/%s...v%s\n' "$PREV" "$VERSION"; fi
} > build/release-notes.md
```

Read `build/release-notes.md` and fix anything that reads badly before continuing. Then:

```bash
gh release create "v$VERSION" --repo arhea/Shell --draft --target "$RELEASE_SHA" \
  --title "Shell $VERSION" --notes-file build/release-notes.md
```

Add `--prerelease` for `-beta`/`-rc` versions.

### 7. Upload the artifact

```bash
gh release upload "v$VERSION" --repo arhea/Shell \
  "build/dist/Shell-$VERSION.dmg#Shell $VERSION for macOS (Apple Silicon)" \
  "build/dist/Shell-$VERSION.dmg.sha256"
```

Upload only these two files.

### 8. Publish and verify

After Alex confirms:

```bash
gh release edit "v$VERSION" --repo arhea/Shell --draft=false --latest
```

Publishing creates the `v$VERSION` tag on the release commit. Tags matching `v*` are protected: they can't be moved or deleted (admins can bypass in an emergency). Then check:

- `gh release view "v$VERSION" --repo arhea/Shell` shows the notes and exactly two assets: the `.dmg` and the `.sha256`.
- `git fetch --tags && [[ $(git rev-parse "v$VERSION^{commit}") == "$RELEASE_SHA" ]] && echo tag-ok`
- Download the DMG from the release page on a Mac (or user account) that has never run a dev build, open it, and launch Shell. Gatekeeper must open it with no warning.
- Every link in the published notes resolves.

### If something goes wrong

| Where it failed | What to do |
| --- | --- |
| Before step 5 merges (build, notarization, CI) | Nothing is on `main`. Fix on the release branch, re-run from step 4. |
| After step 5, before publishing | Fix forward with a new PR, rebuild from `main`, delete and recreate the draft (`gh release delete "v$VERSION" --repo arhea/Shell`) targeting the new commit. |
| After publishing | Don't move or delete the tag. Ship `$VERSION` + 1 patch release with the fix. If the artifact itself is bad, `gh release edit --draft=true` to pull it while the fix ships. |

Full signing setup, entitlements and Time Sensitive notification notes are in `docs/releasing.md`.
