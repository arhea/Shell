# Features

A full tour of what Shell does. For key bindings see [Keyboard shortcuts](keyboard-shortcuts.md). For the settings behind each feature see [Configuration](configuration.md).

- [Terminal](#terminal)
- [Native prompt](#native-prompt)
- [Completions](#completions)
- [Tabs, splits and windows](#tabs-splits-and-windows)
- [Themes and appearance](#themes-and-appearance)
- [Links and paths](#links-and-paths)
- [Copying commands and output](#copying-commands-and-output)
- [Claude Code and Codex](#claude-code-and-codex)
- [Files, worktrees and GitHub sidebar](#files-worktrees-and-github-sidebar)
- [Developer toolchain managers](#developer-toolchain-managers)
- [Apple Intelligence](#apple-intelligence)
- [macOS integration](#macos-integration)
- [Everything else](#everything-else)

## Terminal

- **libghostty does the heavy lifting.** Rendering (Metal, GPU-accelerated), VT parsing and the PTY all come from [Ghostty](https://ghostty.org), so Shell gets the same correctness and speed. The window chrome is AppKit plus SwiftUI.
- **Nothing extra runs in your shell.** Programs you run (vim, ssh, REPLs, TUIs) get the terminal directly.
- **Your dotfiles stay yours.** Shell injects its zsh integration via `ZDOTDIR` and never edits `.zshrc` (except the Zsh manager, which asks first and keeps a backup). See [Shell integration](shell-integration.md).

## Native prompt

There is one place to type: a native editor pinned to the top or bottom of each pane.

- Mouse selection, multi-line editing, syntax highlighting, ghost-text history suggestions and ⌃R history search.
- The terminal shows output only. zsh's own prompt is hidden while idle. Each command is recorded in scrollback as a `header ❯ command` block, using either Shell's compact header or your theme's prompt.
- Turn it off in Settings › Prompt & Completions, or with ⌃⌘E, to type straight into zsh like iTerm2. The switch applies live to every open tab.

## Completions

- Completions come from **your live zsh session**, so aliases, functions, plugins and the current directory all apply.
- They appear in a menu with descriptions and previews of files, folders and commands.
- They're captured with a temporary `compadd` override (the same technique [fzf-tab](https://github.com/Aloxaf/fzf-tab) uses). Nothing is inserted until you pick one.

## Tabs, splits and windows

- Horizontal tabs or a vertical sidebar (⌃⌘T). Drag the sidebar's edge to resize it; double-click the edge to reset.
- Chrome-style tab groups: named, colored and collapsible.
- Drag to reorder tabs, or move a tab to a new window.
- Splits go right (⌘D) and down (⇧⌘D). Dividers are draggable, and you can zoom a pane or broadcast input to every pane.
- Multiple windows, and session restore on relaunch.
- iTerm2 keyboard shortcuts by default, including the "Natural Text Editing" key mappings. Everything is rebindable.

## Themes and appearance

- Separate light and dark themes follow the system appearance.
- About 600 bundled themes (from iTerm2-Color-Schemes, via Ghostty).
- Override any color. Set the font, line height, letter spacing, ligatures, cursor style, opacity and blur.

## Links and paths

- http and https URLs get a solid underline as soon as they appear, including URLs wrapped across lines.
- Local file and folder paths that exist on disk get a dotted underline. Detected forms: absolute, `~/…`, `./…`, relative paths containing a `/`, `name.ext`, and compiler-style `path:line:col`. Relative paths resolve against the pane's current directory.
- Hovering shows a hint. ⌘-click opens a URL, or reveals a file or folder in Finder.

## Copying commands and output

- The native prompt has a Copy button. A click copies the command you're typing, or the last command if the box is empty.
- Its menu adds **Copy Last Command** (⇧⌘C) and **Copy Last Output** (⌥⇧⌘C). Last output is taken from the scrollback between the command's header and the next prompt.

## Claude Code and Codex

See [Claude Code and Codex](claude-code.md) for the full guide.

- **Agent status per tab.** A one-click hook install gives each tab a spinner while an agent works, a badge when it needs you, and a native notification when it finishes. Clicking the notification jumps to that pane.
- **Start Claude from the prompt.** A split button next to *Copy* starts Claude in a new tab: here, or (in a git repository) in a worktree: pick an existing branch or name a new one off the default branch in a searchable branch picker.
- **Claude dashboard.** While any Claude Code session is running, a *Claude* entry is pinned to the front of the tabs (⌃⌘A). It tiles every session across your windows with its status (working, needs input, done, idle), directory, branch, how long it has been running and a live preview of the conversation. Click a tile to jump to that pane. The first tile shows plan limits (5-hour and weekly) and token usage from your local transcripts.
- **Native Claude Code view.** Shell can open a native transcript and composer instead of Claude Code's terminal UI. It drives the same `claude` binary, so your settings, CLAUDE.md, skills, hooks, plugins and MCP servers all apply.
  - Attach files and images with the paperclip, ⌘V or drag and drop, with previews above the text box.
  - Replies render as GitHub Flavored Markdown: tables with alignment, task lists, strikethrough, autolinks, footnotes, nested quotes, `> [!NOTE]`-style alerts, `<details>` and images. File references such as `[App.swift:42](Sources/App.swift:42)` or a backticked path open in your editor at that line.
  - Claude's questions appear as a card: pick an option (or press 1–9), choose several for multi-select, or type your own answer. Option previews show beside the choices, and the transcript keeps each question with the answer you gave.
  - In plan mode, the plan renders as markdown for review: approve with auto-accept edits (1), approve and keep asking before edits (2), or keep planning (3). Type feedback and press Return to send it back. Todo lists show as a live checklist.
- **MCP manager** (Shell › MCP Servers…): status, sign in and out, enable and disable, add and remove, and browse each server's tools.
- **Agent storage** (Settings › Agent Storage): see and reclaim the disk Claude Code and Codex use.

## Files, worktrees and GitHub sidebar

Toggle it with ⌃⌘B, or the sidebar button at the top right of the window (in the tab bar, or the title row in vertical-tabs mode) when the pane is in a git repository. It's always available in the Claude view.

- **Files.** The repository tree with git status per file, or just the changed files.
- **Worktrees.** Every worktree of the repo with its branch, ahead/behind or "not pushed", the branch's PR (open, draft, merged, closed, review state), uncommitted changes, last activity and disk size. Worktrees that are clean and idle for 7+ days (configurable) are highlighted as stale, and merged ones are badged. Open a worktree in a new tab, start Claude there, or delete it (`git worktree remove`, optionally `git branch -d`).
- **GitHub.** Opens by itself in a terminal pane inside a GitHub repository (turn that off per pane with ⌃⌘B). It links to the repo and the current branch's PR (or *Create PR*), and lists open pull requests and recent Actions runs. The list refreshes every 10 seconds while any run is queued or running, and shows jobs, cancel and re-run failed.
- **Pull requests** (via `gh`). Open PRs with checks, review state, labels, size and whether you're a requested reviewer (filter: All / Review / Mine). One click switches to the PR's worktree, focusing a tab that's already there, or creates one (`git worktree add` + `gh pr checkout`, in `$WORKTREES_HOME/<repo>/<branch>`). *Review* also starts Claude there with a review prompt.
- **Scheduled worktree cleanup** (Settings › Worktrees). List repositories or folders of repositories, and Shell removes stale worktrees daily, weekly or monthly, with a preview first. Worktrees with uncommitted changes are never removed. Branches are only deleted when merged, and only if you opt in.

## Developer toolchain managers

Background jobs log to `~/Library/Logs/Shell/`. You get a notification when something was upgraded or a run failed.

- **Homebrew.** Browse installed packages, updates and search. Install, upgrade or uninstall formulae and casks. Shell can install Homebrew itself. Optional auto-update (Daily / Weekly / Monthly) runs `brew update && brew upgrade && brew doctor`.
- **Node.js.**
  - Works with **n** (recommended) or **nvm**, auto-detected. Shell can install either one and keep it updated.
  - Pick a version and a track to follow: latest LTS, latest Current, a pinned major, or pinned exactly.
  - Keeps npm, pnpm, yarn and bun installed and updated. Corepack-managed tools are updated through corepack.
  - Health checks flag end-of-life Node, pending security releases, conflicting managers, shadowed `node` binaries, N_PREFIX/sudo problems, the removal of corepack in Node 25+, and cached versions taking disk space. Fix buttons are included where possible.
  - Optional auto-update uses the same background engine as Homebrew and finishes with `npm doctor`.
- **Zsh and Oh My Zsh.** Install Oh My Zsh, pick a theme, toggle plugins, install popular plugins or Powerlevel10k, and make zsh your default shell. Edits to `.zshrc` are minimal and a backup is kept.
- **Go.** Shows the toolchain and the size of Go's caches (build, modules, fuzz, gopls, golangci-lint, goimports). You can clear them with Go's own commands, get a warning past a size limit, and optionally clear the build cache automatically.

## Apple Intelligence

Optional features that use Apple's on-device model (FoundationModels). They need macOS 26 or later with Apple Intelligence turned on. **Each one is off until you turn it on** in Settings › Apple Intelligence. Everything runs on your Mac: nothing is sent to Apple or anyone else, and no suggestion ever runs by itself. On a Mac without Apple Intelligence, the features and their settings don't appear.

| Feature | What it does |
| --- | --- |
| Branch names | In *Start in Worktree…*, describe the work ("fix login redirect on expired session") and pick from up to three suggested branch names. The suggestions follow the style of the repository's recent branches, and each one is checked against git's naming rules. |
| Command palette | A request of three or more words ("make the text bigger") adds the matching command, or Settings pane, to the top of the palette. |
| Command fixes | After a command fails, a corrected command appears as ghost text in the native prompt. Press → to take it, or Esc to dismiss it. Shell doesn't ask about ^C or other signals, or about silent failures such as `grep` finding nothing. A suggestion is dropped if it adds a destructive word (`rm`, `--force`, `reset --hard`, and so on) that your command didn't have, or `sudo` when the error wasn't about permissions. |
| Session summaries | Each tile on the Claude dashboard gets a one-line summary of what Claude is doing. It updates at most every 20 seconds per session, and only while the dashboard is open and the session's activity changes. |
| Tab names | *Rename Tab*, *New Tab Group* and *Rename Group* fill in a suggested name based on each pane's folder, branch and commands. Anything you type wins. |

The first time Shell sees that Apple Intelligence is available, it shows a one-time banner pointing to these settings.

## macOS integration

- **Shortcuts and Spotlight.** Script Shell from the Shortcuts app: open tabs, run a command and get its exit code and output back, send text to a pane, read its screen, find sessions by directory, branch or agent status, wait until Claude Code or Codex needs input, and trigger menu commands. Actions pass sessions between steps, and the common ones also run from Spotlight ("New Shell tab"). See [Automation](automation.md).
- **Desktop widget** (agents + Claude usage).
- **Finder.** Right-click a folder › Services › **New Shell Tab Here** or **New Shell Window Here**. You can also drop a folder on the Dock icon, or run `open -a Shell <dir>`. If the services don't appear, enable them in System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders.
- **Dock menu.** Right-click the Dock icon for New Window, New Tab, agents waiting on you (click to jump to the pane), and recent folders.
- **Time Sensitive agent alerts** (opt-in, Settings › Claude & Codex). "Needs your input" alerts can break through Focus if you allow Time Sensitive notifications for Shell. See [Releasing](releasing.md#time-sensitive-notifications) for the entitlement this needs.
- **Quick Look.** Completion previews show thumbnails for images, PDFs, video and other non-text files. In the file explorer, press Space or use *Quick Look* from the context menu.
- **iCloud settings sync** (optional, off by default, Settings › General › Sync). See [Configuration](configuration.md#icloud-settings-sync).

## Everything else

- Hotkey window (quake-style, default ⌥\`).
- Command palette (⇧⌘P).
- Find (⌘F).
- Jump between commands (⇧⌘↑ / ⇧⌘↓).
- Notifications for long-running commands.
- Session restore.
- Secure keyboard entry.
