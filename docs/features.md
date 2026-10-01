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
- [Inspector](#inspector)
- [GitHub tab](#github-tab)
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
- **Command blocks.** Each block's header line shows how it went at the right edge: `✓ 3.2s · 13:52` when it succeeded, a red **Exit 65** and its duration when it failed. Failed blocks get a red tint and border, plus **Copy output** (that block's output, from the scrollback) and **Rerun** (runs the command again through the prompt). The buttons never take keyboard focus or change the terminal selection. Blocks are found by their header lines, so decorations disappear for output that was cleared or trimmed from the scrollback. Turn them off in Settings › Prompt & Completions (*Show command block status and actions*).
- **After a failure**, a bar above the prompt offers **✻ Fix with Claude**: it starts Claude in this pane's folder with the failing command and its output (saved to a temporary file) as the prompt. With Apple Intelligence command fixes on, the bar also shows the corrected command with **Run it** (the same suggestion is still ghost text, → to accept). Esc or ✕ dismisses it. It isn't shown for ^C and other signals, or for failures that printed nothing.
- **Context chips** above the input: the directory (click to reveal in Finder), the git branch with a green ✓ when clean or an orange dot and count of changed files, the folder's runtime (`node 22.9` from `.nvmrc`, `.node-version` or `package.json` resolved with `node --version`; `python 3.12` from `.python-version`; `go 1.23` from `go.mod`), and the last command's exit status and duration. When the branch has a pull request, **PR #212 ↗** opens it and a **Checks** chip shows failing, running or passing CI; click it for each job with a per-job **Fix**, **Fix N failing with Claude**, **Re-run failed** and **Open on GitHub**. Git status, the PR lookup and `node --version` run in the background when the prompt returns, never while you type.
- On the right: **✻ Start Claude ▾** and **Copy output ▾**. While the input is focused and empty (or showing a suggestion), dim hints below it list → accept, ⇥ completions and ⌃R history.
- Turn it off in Settings › Prompt & Completions, or with ⌃⌘E, to type straight into zsh like iTerm2. The switch applies live to every open tab.

## Completions

- Completions come from **your live zsh session**, so aliases, functions, plugins and the current directory all apply.
- They appear in a menu with descriptions and previews of files, folders and commands.
- They're captured with a temporary `compadd` override (the same technique [fzf-tab](https://github.com/Aloxaf/fzf-tab) uses). Nothing is inserted until you pick one.

## Tabs, splits and windows

- Horizontal tabs or a vertical sidebar (⌃⌘T). The sidebar floats inside the window on the system's sidebar glass, tinted by your terminal theme (opaque with Reduce Transparency), with the window's traffic lights in its top row. Hide and show it with ⌃⌘S or the button next to the traffic lights. Drag its edge to resize it; double-click the edge to reset.
- Each sidebar row shows what the tab is (terminal, Claude, Codex), its folder, branch and PR, and one status: an orange spinner while an agent works, a yellow **Input** pill when it needs you, a green check when it finished, otherwise the tab's ⌘ number. A running command shows a gray spinner; a bell, a failed command and unseen output show small marks. The **Pull Requests** row shows how many PRs wait on your review.
- The sidebar opens with **Go to anything…** (the command palette) and ends with **New Tab** (⌘T) and **Claude in New Worktree…** (⌥⌘N), which asks for a branch, creates a worktree for it and starts Claude there in a new tab.
- With vertical tabs, a unified toolbar above the content shows the focused pane: its title, the repository, branch and worktree (or folder and shell), its pull request (click to open it) and a red capsule when CI checks fail on the branch. On the right: Claude's model, effort and permission mode, MCP servers, a **…** menu (continue in the terminal UI, Remote Control, close Claude) and the inspector toggle (⌃⌘B) for Claude panes; **Split**, **…** and the inspector toggle for terminal panes. With splits it follows the focused pane, and the Claude view drops its own header so there's one bar.
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

- The native prompt has a **Copy output** button. A click copies the last command's output, taken from the scrollback between the command's header and the next prompt.
- Its menu adds **Copy Command** (what you're typing, or the last command if the box is empty), **Copy Last Command** (⇧⌘C) and **Copy Last Output** (⌥⇧⌘C).
- A failed command block has its own **Copy output** button.

## Claude Code and Codex

See [Claude Code and Codex](claude-code.md) for the full guide.

- **Agent status per tab.** A one-click hook install gives each tab a spinner while an agent works, a badge when it needs you, and a native notification when it finishes. Clicking the notification jumps to that pane.
- **Start Claude from the prompt.** A split button next to *Copy output* starts Claude in a new tab: here, or (in a git repository) in a worktree: pick an existing branch or name a new one off the default branch in a searchable branch picker.
- **Claude Sessions.** When Claude Code is installed, a *Claude Sessions* entry is pinned to the top of the sidebar (the front of the tab bar with horizontal tabs); Settings › Claude & Codex can show it always, only while sessions run, or never. It opens a dashboard (⌃⌘A) that tiles every session across your windows with its status (working, needs input, done, idle), directory, branch, how long it has been running and a live preview of the conversation. Click a tile to jump to that pane. Sessions running outside Shell are listed too: click a background session to attach to it in a new tab. The first tile shows plan limits (5-hour and weekly) and token usage from your local transcripts. A drawer on the right lists past sessions with their worktree, branch, PR and changes, so you can resume one, start a new session in its folder, or open a terminal there.
- **Native Claude Code view.** Shell can open a native transcript and composer instead of Claude Code's terminal UI. It drives the same `claude` binary, so your settings, CLAUDE.md, skills, hooks, plugins and MCP servers all apply.
  - Attach files and images with the paperclip, ⌘V or drag and drop, with previews above the text box.
  - Replies render as GitHub Flavored Markdown: tables with alignment, task lists, strikethrough, autolinks, footnotes, nested quotes, `> [!NOTE]`-style alerts, `<details>` and images. File references such as `[App.swift:42](Sources/App.swift:42)` or a backticked path open in your editor at that line.
  - Claude's questions appear as a card: pick an option (or press 1–9), choose several for multi-select, or type your own answer. Option previews show beside the choices, and the transcript keeps each question with the answer you gave.
  - In plan mode, the plan renders as markdown for review: approve with auto-accept edits (1), approve and keep asking before edits (2), or keep planning (3). Type feedback and press Return to send it back. Todo lists show as a live checklist.
- **MCP manager** (Shell › MCP Servers…): status, sign in and out, enable and disable, add and remove, and browse each server's tools.
- **Agent storage** (Settings › Agent Storage): see and reclaim the disk Claude Code and Codex use.

## Inspector

The right inspector shows the focused pane's repository. Toggle it with ⌃⌘B, or the sidebar button at the top right of the window (in the tab bar, or the toolbar in vertical-tabs mode) when the pane is in a git repository. It's always available in the Claude view. Tabs across the top switch panels; Claude panes start on **Session**, terminal panes remember the last tab you picked.

- **Session** (Claude panes). **Changes** lists each uncommitted file with its status letter (M modified, A added, D deleted) and the lines added and removed, from `git diff --numstat HEAD` plus untracked files. Click a file to open it, or **Review** for the diff. **To-dos** shows the agent's task list (done, in progress, not started). **Running in background** shows subagents and background tasks with what they're doing, how long they've run, *View transcript* or *Output*, and *Stop*.
- **Worktrees.** The repository's worktrees and their total disk use. Filter chips narrow the list to **Changes**, **Not pushed** (no upstream, or commits ahead of it) and **Stale**, each with a count. Worktrees are grouped: **Open in tabs** (with each tab's agent state, e.g. *Claude needs approval*, and the PR's checks), **Main checkout** (how far it's behind its upstream, with a **Pull** button that runs `git pull --ff-only`), and the rest, newest first (**Show N more** expands the list). Each row shows the branch, clean or how many changes, pushed or not, last activity and size. Hover a row to open it in a new tab, start Claude there or delete it (`git worktree remove`, optionally `git branch -d`); right-click for more, including *Go to Tab*. Worktrees that are clean and idle for 7+ days (configurable) are stale: a card at the bottom totals their size, and **Review & Remove…** removes them after confirmation. When any clean worktree's PR has merged, **Clean up merged worktrees** lists them for confirmation and removes them, deleting each branch only when it has nothing beyond what merged. The worktree you're in is never included.
- **Checks** (repositories on GitHub, via `gh`). The checks on the current branch's pull request: counts of failing, running, passed and skipped jobs, each failing job expanded with its steps and **Fix with Claude**, **Re-run** and **Log ↗**, then the other jobs. The tab shows a red dot while a check is failing. Fix with Claude saves the job's failing log to a file and asks Claude to fix it: in the prompt of a Claude pane, or in a new tab running `claude` from a terminal pane. In Claude panes, **Send failures to Claude** does that automatically when a check newly fails (auto mode still asks before pushing). Below the jobs: *Create pull request* when the branch has none, the count of open pull requests and those waiting on your review with **Open board** for the [GitHub tab](#github-tab), and **All workflow runs**, the repository's recent Actions runs (all branches or this one) with jobs, cancel and re-run failed. Checks refresh every 10 seconds while a run is active.
- **Files.** The repository tree with git status per file (the same letters and colors as Session › Changes), or just the changed files.
- **Scheduled worktree cleanup** (Settings › Worktrees). List repositories or folders of repositories, and Shell removes stale worktrees daily, weekly or monthly, with a preview first. Worktrees with uncommitted changes are never removed. Branches are only deleted when merged, and only if you opt in.

## GitHub tab

A board of the repository's open pull requests, in its own tab next to your terminals. Open it with **View › Open GitHub** (⌃⌘H), the command palette, or **Open board** in the inspector's Checks tab. It shows the focused pane's repository; the menu next to the repository name switches to another one open in the window. Close it with the × on its tab.

Everything comes from your `gh`: one `gh api graphql` request per refresh, when the tab opens, when you come back to the window (if the board is older than 30 seconds), every 2 minutes while it's showing, and after each action. Nothing polls while the tab is hidden. Without `gh`, or signed out, the tab says how to set it up.

**Columns**

| Column | A PR is here when |
| --- | --- |
| Draft | It's a draft. |
| Waiting for review | It's open and nobody has reviewed it yet (or, with no review required, its checks aren't passing yet). |
| Has feedback | It has reviews or unresolved threads but no approval or change request, or it's approved but its checks are pending or failing. |
| Changes requested | A reviewer requested changes. |
| Ready | It's approved (or needs no review and has nothing outstanding) and its checks pass. |

**Filters.** The toolbar's **For you** (the default) shows PRs assigned to you or waiting on your review, plus the rest of their stacks; **Mine** shows PRs you opened (with their stacks); **All** shows everyone's. Each segment shows its count, and the choice is remembered. The search field filters by title, branch, author, label or number (`#45`). Below the toolbar a line says what the board is showing, and the **Review requested** and **Assigned** chips narrow it to just that reason (click again to clear). **Collapse stacks** draws each stack as one compact card until you expand it. **Open on GitHub ↗** opens the repository's pull requests.

**Cards** show the number, why it's on your board (**Review requested** or **Assigned**), the author's initials, the title, branch, checks (`✓ 6/6`, `✕ 1 failing`, or a spinner while they run), size, unresolved threads and age. A PR with requested changes shows who asked and **✻ Fix with Claude**, which checks the branch out into a worktree and starts Claude on the review feedback. When a tab in the window is already on the branch, the card links to it ("Open in Tab 3 with Claude"). Hovering a card shows **✻ Review** (a Claude review in the PR's worktree), **Worktree ▾** (where the checkout goes, then Open in Terminal, Start Claude There, Start Claude Review…, Open on github.com and Copy Branch Name) and **↗**. The right-click menu copies the link, branch or `gh pr checkout` command.

**Stacks.** A PR whose base branch is another open PR's head branch is stacked on it. A stack is one card: collapsed, it's named for the title prefix its PRs share (or the top PR) and lists one line per layer with a state dot, how many wait on your review, and the stack's checks and size; **Expand** shows a connected list of layers, top to bottom, each with its state and checks, ending in the branch the stack merges into. Branching stacks indent each branch. The card sits in the leftmost column any of its PRs is in, since the stack is only as far along as its least-ready layer. When the PR underneath is merged or closed, the next one starts its own stack. Clicking a layer opens it (and expands the stack).

**Details and actions.** Selecting a PR opens a pane on the right with its state, title and branches, then **Check Out in Worktree ▾** (or **Open Worktree** once it's checked out; the menu has the Worktree actions plus mark ready / convert to draft, re-run failed checks, close and copy link), **✻ Review with Claude** and **↗ GitHub**. Its tabs: **Overview** (description, reviewers and their state, the checks with failures and running jobs first, and for a stacked PR the other layers to switch between), **Conversation** (comments, reviews and inline review comments), **Checks** and **Files** (the diff). Along the bottom: **Comment…** and **Request changes** (each opens a composer, ⌘⏎ to send), **Merge** with any method the repository allows (green when the PR is ready) and **Approve**. Merging and closing ask first; GitHub doesn't let you approve or request changes on your own PR, so those hide there.

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

Optional features that use Apple's on-device model (FoundationModels). They need a Mac with Apple Intelligence turned on. **Each one is off until you turn it on** in Settings › Apple Intelligence. Everything runs on your Mac: nothing is sent to Apple or anyone else, and no suggestion ever runs by itself. On a Mac without Apple Intelligence, the features and their settings don't appear.

| Feature | What it does |
| --- | --- |
| Branch names | In *Start in Worktree…*, describe the work ("fix login redirect on expired session") and pick from up to three suggested branch names. The suggestions follow the style of the repository's recent branches, and each one is checked against git's naming rules. |
| Command palette | A request of three or more words ("make the text bigger") adds the matching command, or Settings pane, to the top of the palette. |
| Command fixes | After a command fails, a corrected command appears as ghost text in the native prompt and in the fix bar above it. Press → to take it, click **Run it** to run it, or Esc to dismiss it. Shell doesn't ask about ^C or other signals, or about silent failures such as `grep` finding nothing. A suggestion is dropped if it adds a destructive word (`rm`, `--force`, `reset --hard`, and so on) that your command didn't have, or `sudo` when the error wasn't about permissions. |
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
- Command palette (⇧⌘P): tabs, worktrees, recent folders, actions, themes and history, grouped by kind. Type `>` to search actions only or `@` for folders and worktrees. ⏎ goes to a result (an open tab, else a new one), ⌘⏎ opens it in a new tab and ⌥⏎ starts Claude there.
- Find (⌘F).
- Jump between commands (⇧⌘↑ / ⇧⌘↓).
- Notifications for long-running commands.
- Session restore.
- Secure keyboard entry.
