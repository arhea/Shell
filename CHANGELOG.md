# Changelog

All notable changes to Shell are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Shell uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each entry links to its pull request and, where there is one, the issue it fixes. Until 1.0, minor versions may include breaking changes to settings or behavior; these are called out under **Changed**.

## [Unreleased]

### Added

- **Past sessions** on the Claude Sessions page: a drawer lists your earlier Claude Code conversations with their worktree, branch, ahead/behind, pull request and changes, like the Worktrees sidebar. Resume one, start a new session in its folder, or open a terminal there. ([#30](https://github.com/arhea/Shell/pull/30), fixes [#29](https://github.com/arhea/Shell/issues/29))

### Changed

- **Claude Sessions now stays pinned to the top of the sidebar whenever Claude Code is installed**, not only while a session runs. Choose Always, When sessions are active, or Never in Settings › Claude & Codex. If you had turned off the old dashboard toggle, it's set to Never. ([#30](https://github.com/arhea/Shell/pull/30), fixes [#29](https://github.com/arhea/Shell/issues/29))

## [0.3.0] - 2026-09-30

Shell adds a GitHub tab: a kanban board of your repository's pull requests, with stacked PRs grouped together and review, checks, merge and checkout built in. The native Claude Code view also gets a centered composer, sign-in from inside the view, and image paste.

### Added

- **GitHub tab**: a board of the repository's open pull requests in Draft, Waiting for review, Has feedback, Changes requested and Ready columns, with a Mine / All filter. Stacked PRs are grouped into one card you can step through. Selecting a PR shows its description, conversation, checks and diff, and lets you comment, approve, request changes, mark ready or draft, re-run failed checks, merge, close, or check it out in a worktree, all through your `gh`. Open it with **View › Open GitHub** (⌃⌘H) or **Board** in the sidebar's GitHub section. ([#23](https://github.com/arhea/Shell/pull/23), fixes [#18](https://github.com/arhea/Shell/issues/18))
- The Claude view starts with the composer centered in the pane, under the welcome, and moves it to the bottom when you send your first message. Continued and resumed sessions open with it at the bottom, and the move respects Reduce Motion. ([#19](https://github.com/arhea/Shell/pull/19), fixes [#17](https://github.com/arhea/Shell/issues/17))
- Settings › Chat Text › **Composer width**: Centered (a column up to 1200 pt, the default) or Full width. The existing maximum width now sets the reading width of transcript text within that column; if you had turned it off, you get Full width. ([#19](https://github.com/arhea/Shell/pull/19), fixes [#17](https://github.com/arhea/Shell/issues/17))

### Fixed

- The native Claude Code view can sign in to Claude Code. When Claude Code is signed out, or its sign-in expires mid-conversation, the view shows a sign-in card that runs Claude Code's own login (the same choices as `/login`) instead of an error, then starts or continues the session and sends the message that failed. ([#20](https://github.com/arhea/Shell/pull/20), fixes [#16](https://github.com/arhea/Shell/issues/16))
- Pasting a copied image or screenshot into the Claude prompt attaches it, instead of doing nothing. ([#22](https://github.com/arhea/Shell/pull/22), fixes [#21](https://github.com/arhea/Shell/issues/21))

## [0.2.0] - 2026-09-30

Shell now keeps itself up to date: it checks GitHub for new releases, verifies them and installs on quit. This release also brings a refreshed installer, an app icon that follows your appearance, and a native About window, and it now requires macOS 26.

### Added

- The installer disk image opens to a styled, terminal-themed window: drag Shell onto Applications along a chevron trail, with the version shown in the corner and Shell's icon on the mounted volume. ([#6](https://github.com/arhea/Shell/pull/6), fixes [#5](https://github.com/arhea/Shell/issues/5))
- Shell's app icon follows your appearance: a light icon in light mode, the dark icon in dark mode, and the Tinted and Clear icon styles. ([#6](https://github.com/arhea/Shell/pull/6), fixes [#5](https://github.com/arhea/Shell/issues/5))
- Automatic updates from GitHub releases. Shell checks every six hours, downloads and verifies a new release in the background (checksum, Developer ID team, notarization), notifies you, and installs it when you quit or from **Help › Restart to Update**. **Help › Check for Updates…** checks on demand, and Settings › General › Software Update turns either behavior off. ([#8](https://github.com/arhea/Shell/pull/8), fixes [#7](https://github.com/arhea/Shell/issues/7))

### Changed

- **Shell now requires macOS 26 (Tahoe) or later.** ([#12](https://github.com/arhea/Shell/pull/12), fixes [#11](https://github.com/arhea/Shell/issues/11))
- **About Shell** has a cleaner, native layout modeled on macOS's About This Mac, with the libghostty version, a **View on GitHub** button and compact acknowledgements. ([#10](https://github.com/arhea/Shell/pull/10), fixes [#9](https://github.com/arhea/Shell/issues/9))

## [0.1.0]

First public release.

### Added

- Native macOS terminal built on libghostty, with GPU-accelerated Metal rendering.
- Native prompt with multi-line editing, syntax highlighting, ghost-text history suggestions, ⌃R search and command blocks in the scrollback.
- Completions from your live zsh session, with descriptions and file previews.
- Horizontal or vertical tabs, Chrome-style tab groups, splits, zoom, broadcast input, multiple windows and session restore.
- iTerm2-compatible keyboard shortcuts, all rebindable.
- About 600 bundled themes, with separate light and dark themes that follow the system.
- Claude Code and Codex integration: per-tab status, notifications, the Claude dashboard, a native Claude Code view, an MCP server manager and agent storage cleanup.
- Files, worktrees and GitHub sidebar, with pull requests and Actions runs through `gh`.
- Homebrew, Node.js, Zsh and Oh My Zsh, and Go managers, with optional scheduled maintenance.
- Optional on-device Apple Intelligence features, all off by default.
- Shortcuts and Spotlight actions, Finder services, a Dock menu, a desktop widget, Quick Look previews and optional iCloud settings sync.

[Unreleased]: https://github.com/arhea/Shell/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/arhea/Shell/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/arhea/Shell/releases/tag/v0.2.0
[0.1.0]: https://github.com/arhea/Shell/releases/tag/v0.1.0
