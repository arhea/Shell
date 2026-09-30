# Changelog

All notable changes to Shell are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Shell uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each entry links to its pull request and, where there is one, the issue it fixes. Until 1.0, minor versions may include breaking changes to settings or behavior; these are called out under **Changed**.

## [Unreleased]

### Added

- The installer disk image opens to a styled, terminal-themed window: drag Shell onto Applications along a chevron trail, with the version shown in the corner and Shell's icon on the mounted volume. ([#6](https://github.com/arhea/Shell/pull/6), fixes [#5](https://github.com/arhea/Shell/issues/5))
- Shell's app icon follows your appearance on macOS 26: a light icon in light mode, the dark icon in dark mode, and the Tinted and Clear icon styles. On macOS 15, Shell uses the light icon. ([#6](https://github.com/arhea/Shell/pull/6), fixes [#5](https://github.com/arhea/Shell/issues/5))

### Changed

- **About Shell** has a cleaner, native layout modeled on macOS's About This Mac, with the libghostty version, a **View on GitHub** button and compact acknowledgements.

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
- Optional on-device Apple Intelligence features (macOS 26+), all off by default.
- Shortcuts and Spotlight actions, Finder services, a Dock menu, a desktop widget, Quick Look previews and optional iCloud settings sync.

[Unreleased]: https://github.com/arhea/Shell/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/arhea/Shell/releases/tag/v0.1.0
