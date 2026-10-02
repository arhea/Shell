# Changelog

All notable changes to Shell are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Shell uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each entry links to its pull request and, where there is one, the issue it fixes. Until 1.0, minor versions may include breaking changes to settings or behavior; these are called out under **Changed**.

## [Unreleased]

## [0.5.0] - 2026-10-02

Shell gets a calmer, more native look with one status language everywhere: an orange spinner means working, a yellow **Input** badge means Claude needs you, green means done. The review-and-fix loop now stays in Shell, with a Pull Requests board, CI checks that can go straight to Claude, a Review Changes view for staging and committing, and command blocks in the terminal.

### Added

- **Pull Requests board** with a new **For you** view (review requested or assigned, plus the rest of their stacks) next to Mine and All. Filter by Review requested or Assigned, search, and collapse stacks into one layered card. Each card can start a Claude review or open the branch in a worktree, and the detail pane has Overview, Conversation, Checks and Files tabs with Comment, Request changes and Approve. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))
- **CI checks in Claude and terminal sessions.** Shell watches the branch's checks through your `gh`. A newly failing check appears in the Claude transcript with the failing log lines and **Fix with Claude**, **Re-run** and **Full log**. Turn on **Send failures to Claude** in the inspector's Checks tab to have Claude start the fix when it's idle (off by default). The terminal prompt shows PR and Checks chips with a per-job Fix. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#41](https://github.com/arhea/Shell/issues/41))
- **Review Changes** (⇧⌘R): a full-pane diff of the working tree in Unified or Split view with word-level highlights. Stage, unstage or revert by file or hunk, mark files Viewed, click a line number to send a comment to Claude, and Commit or Commit & Push. An optional on-device **Write for me** drafts the commit message (off by default). ([#43](https://github.com/arhea/Shell/pull/43), fixes [#42](https://github.com/arhea/Shell/issues/42))
- **Command blocks** in the terminal: each command shows its duration and time, or a red Exit N pill. Failed commands are highlighted with Copy output and Rerun, and a fix bar above the prompt suggests a corrected command or **Fix with Claude**. Turn them off in Settings › Prompt & Completions. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#42](https://github.com/arhea/Shell/issues/42))
- Prompt chips for the current folder, branch and its clean/dirty state, PR, checks, and the active Node, Python or Go version. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#42](https://github.com/arhea/Shell/issues/42))
- The Claude inspector has **Session** (changed files, to-dos, background work), **Worktrees**, **Checks** and **Files** tabs. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))
- ⌃⌘S hides and shows the tab sidebar. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))

### Changed

- **⌥⌘N now opens Claude in New Worktree…; Agent Activity moved to ⌥⌘A.** ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))
- **The GitHub sidebar panel is gone.** Pull requests and workflow runs now live on the Pull Requests board and in the inspector's Checks tab. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))
- Vertical tabs are the default for new installs; existing settings are kept. The tab sidebar floats as a glass panel with the window controls inside it, a pinned Claude Sessions row with a needs-you badge, each tab's folder and branch, and a Pull Requests row with how many are waiting for your review. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))
- A unified toolbar shows the focused pane's title, repository, branch and worktree, its PR, and a red capsule when checks fail. In Claude panes it holds Model, Effort and Mode, MCP and the inspector toggle, replacing the Claude view's own header bar. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))
- The command palette groups results into Tabs, Worktrees, Folders and Actions with each tab's agent state. Start a query with `>` for actions only or `@` for folders only; ⌘⏎ opens in a new tab and ⌥⏎ starts Claude there. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))
- The Claude transcript is easier to scan: "Thought for…" timings, tool runs grouped into one card, edit cards with Unified/Split and Review, Bash cards with Passed/Failed and duration, code blocks with Copy, Save… and Run in new tab, numbered permission prompts, an end-of-turn summary, and a status line with activity, time and tokens. The composer adds Context and Skills buttons and a context-window meter. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))
- The Claude Sessions page has a compact usage strip and Needs you (approve inline), Working and Idle sections. ([#43](https://github.com/arhea/Shell/pull/43), fixes [#40](https://github.com/arhea/Shell/issues/40))

### Fixed

- Shell no longer quits without warning during long Claude Code chats. Writing to a Claude Code process that had already exited ended the app; now the pane shows that Claude Code exited. ([#39](https://github.com/arhea/Shell/pull/39), fixes [#38](https://github.com/arhea/Shell/issues/38))

## [0.4.0] - 2026-10-01

Claude Sessions becomes the place to find every Claude Code conversation: it stays pinned in the sidebar, lists past sessions you can resume, and shows sessions running outside Shell. Updates now show their progress and can restart straight from the notification, and merged worktrees can be cleaned up in one step.

### Added

- **Past sessions** on the Claude Sessions page: a drawer lists your earlier Claude Code conversations by repository, branch and first prompt, with ahead/behind, pull request and change status like the Worktrees sidebar. Resume one, start a new session in its folder, or open a terminal there. Turn it off in Settings › Claude & Codex. ([#30](https://github.com/arhea/Shell/pull/30), fixes [#29](https://github.com/arhea/Shell/issues/29))
- **Running Elsewhere** on the Claude Sessions page lists live Claude Code sessions that aren't in a Shell tab. Background (`claude --bg`) sessions open in a new tab attached to the job; sessions held by another terminal or Claude desktop are shown with where to find them. ([#34](https://github.com/arhea/Shell/pull/34), fixes [#33](https://github.com/arhea/Shell/issues/33))
- The Worktrees sidebar shows a **Clean up merged worktrees** line when worktrees whose pull request has merged have no uncommitted changes. It lists them for confirmation, then removes them and deletes each branch when it holds nothing beyond what merged. The main checkout, locked worktrees and the one you're in are never touched. ([#27](https://github.com/arhea/Shell/pull/27), fixes [#26](https://github.com/arhea/Shell/issues/26))
- Updates show download progress in Settings › General › Software Update and the Help menu, and the "update ready" notification has a **Restart Now** button. ([#31](https://github.com/arhea/Shell/pull/31))

### Changed

- **Claude Sessions now stays pinned to the top of the sidebar whenever Claude Code is installed**, not only while a session runs. Choose Always, When sessions are active, or Never in Settings › Claude & Codex. If you had turned off the old dashboard toggle, it's set to Never. ([#30](https://github.com/arhea/Shell/pull/30), fixes [#29](https://github.com/arhea/Shell/issues/29))
- The Dock icon uses the light or dark variant that matches the active theme, so a dark theme on a light Mac gets the dark icon while Shell is running. ([#28](https://github.com/arhea/Shell/pull/28), fixes [#25](https://github.com/arhea/Shell/issues/25))

### Fixed

- A failed update download no longer drops the update silently. Shell says why it failed and offers **Try Again**, and background checks retry it. ([#31](https://github.com/arhea/Shell/pull/31))

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

[Unreleased]: https://github.com/arhea/Shell/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/arhea/Shell/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/arhea/Shell/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/arhea/Shell/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/arhea/Shell/releases/tag/v0.2.0
[0.1.0]: https://github.com/arhea/Shell/releases/tag/v0.1.0
