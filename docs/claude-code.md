# Claude Code and Codex

Shell works with [Claude Code](https://docs.anthropic.com/claude-code) and [Codex](https://github.com/openai/codex) in two ways:

1. **Agent status for any terminal tab.** Spinners, badges and notifications, via hooks.
2. **A native Claude Code view** that replaces the terminal UI.

Neither one needs an API key or account in Shell. Both use the `claude` and `codex` binaries you already have installed and signed in.

## Agent status hooks

Install them from Settings › Claude & Codex. Shell makes these changes:

| Agent | What Shell adds | Where |
| --- | --- | --- |
| Claude Code | A hook for `UserPromptSubmit`, `Notification`, `Stop` and `SessionEnd` that runs `shellctl claude-hook <Event>` | `~/.claude/settings.json` |
| Codex | A top-level `notify` program that runs `shellctl codex-notify <json>` | `~/.codex/config.toml` (an existing `notify` is only replaced if you confirm) |

Once they're installed:

- the tab shows a spinner while the agent works;
- a badge appears when it needs your input;
- a native notification fires when it finishes, and clicking it focuses the pane.

The hooks are **no-ops outside Shell**. `shellctl` exits silently unless `$SHELL_APP_SOCKET` points at a live socket, so the same config is safe in other terminals. Uninstalling removes only the entries Shell added.

Any script can use the same channel:

```bash
"$SHELL_APP_CTL" notify -t "Deploy" "Staging is live"
```

```bash
"$SHELL_APP_CTL" agent other working
```

## Starting Claude from the prompt

The **Claude** split button above the native prompt (next to *Copy*) starts your default agent. *Start Claude Here* runs in the current pane; the worktree options open a new tab. Pick the agent in Settings › Claude & Codex (Claude Code today).

| Option | Available | What runs |
| --- | --- | --- |
| **Start Claude Here** (click the button) | Everywhere | `claude -n <random-name>` in this pane, as if you'd typed it |
| **Start Claude in Worktree…** | Git repositories | Opens a branch picker. Type a name to create a new branch off the default branch (spaces become dashes), or search and pick an existing local or remote branch. |
| **Start Claude in New Worktree (Random Name)** | Git repositories | A new branch with a random name (for example `swift-otter`) off the default branch, in a new worktree |

The picker lists local branches and remote-only branches, newest first, with each branch's last commit. It fetches (with `--prune`) in the background while you type, marks the default branch and branches already checked out in a worktree, and shows where the worktree will go. Use ↑/↓ and Return, or double-click.

Worktrees go in `<worktree folder>/<repo>/<branch>`. The worktree folder is Settings › Worktrees, else `$WORKTREES_HOME`, else `~/code/worktrees`. The default branch is `origin/HEAD` (else `main`, `master` or `develop`). The tab runs one visible command, so you can see each step and any error:

```bash
git fetch origin main; git worktree add --no-track -b fix-login ~/code/worktrees/Shell/fix-login origin/main && cd ~/code/worktrees/Shell/fix-login && claude -n fix-login
```

The fetch is best-effort, so it still works offline. `--no-track` keeps the new branch from tracking the default branch; `git push -u` sets its upstream. An existing local branch is checked out as is. A remote-only branch becomes a local branch tracking it (`git worktree add --track -b feat/x <path> origin/feat/x`). If the branch is already checked out in a worktree, the tab just starts Claude there. The session is named after the branch.

## Claude dashboard

While at least one Claude Code session is running, a **Claude** entry is pinned to the front of the tab bar (the top of the sidebar in vertical-tabs mode). It shows how many sessions are running and turns yellow when one needs you. Click it, or press ⌃⌘A, to replace the terminal area with a tiled view of every session in every window:

| On each tile | Source |
| --- | --- |
| Status: working, needs input, done, idle | Agent hooks (terminal UI) or the native view's own state |
| Directory, branch and PR | The pane's working directory, its live git branch, and a **PR #n** link to the branch's pull request (via `gh`), colored by state |
| Approvals | When Claude is waiting on you, the tile shows the request with its buttons, so you can answer without leaving the dashboard: the native view's permission, question and plan cards, or the numbered options of a prompt in the terminal UI |
| Command and run time | The `claude …` command line and how long it has been running (terminal UI) |
| Preview | The last few lines of the conversation, refreshed every 2 seconds while the dashboard is open |
| Location | Window, tab and pane, plus the tab group |

The first tile is **Claude Usage**:

- **Plan limits.** Current-session (5-hour) and weekly usage with reset times. Claude Code reports these to the native view as it runs; Shell keeps the latest report, so the tile fills in after you've used the native view once and shows how old the numbers are.
- **Tokens.** Today, the last 5 hours and a 7-day chart, with the input / output / cache split and the top model. Shell reads them from the transcripts in `~/.claude/projects`, so they include terminal-UI sessions too. The first read runs in the background; after that only new lines are read, once a minute while the dashboard is open.

Nothing is sent anywhere, and Shell never reads your Claude credentials.

In the terminal UI, clicking an option presses its number key, then Return if the prompt is still showing, just as if you'd typed it. Shell only offers this when it sees Claude Code's `❯ 1.` selector under a question, so numbered lists in Claude's replies are left alone.

Click a session tile to jump to that pane. Selecting any tab (or ⌃⌘A again) closes the dashboard.

A pane counts as a Claude session when it's running the native view, a `claude` command (including `command claude`, a path to the binary or `npx @anthropic-ai/claude-code`), or when Claude Code's hooks report from its running command, which covers aliases. Without the hooks, terminal sessions show as *idle*. Turn the pinned entry off in Settings › Claude & Codex.

## Desktop widget

The **Agents** widget puts the dashboard on your desktop or in Notification Center. Add it from the widget gallery (right-click the desktop › Edit Widgets, then search for Shell).

| Size | Shows |
| --- | --- |
| Small | How many agents need input, or else how many are working, plus the current-session limit |
| Medium | The top three agents (waiting ones first) with their directory and branch, the session and weekly limits, and today's tokens |
| Large | Up to five agents with their state, both limits with reset times, today's and the last 5 hours' tokens, the top model and a 7-day chart |

It lists Claude Code sessions and any agent that reports through the hooks, Codex included. Click an agent to jump to its pane, or anywhere else to open the dashboard. Both go through `shellapp://` links (`shellapp://session/<id>`, `shellapp://dashboard`).

How it stays current:

- Widgets are sandboxed and can't read `~/.claude` or talk to Shell. Shell writes a small snapshot (`widget-snapshot.json`) to the shared app group container `~/Library/Group Containers/T9PCKZ42NK.app.bethesdalabs.Shell`, and the widget renders from that. Nothing leaves the machine.
- macOS limits how often a widget can refresh. Shell refreshes it right away when an agent starts, stops or changes state. Token and message changes wait for the next refresh, at most every 5 minutes.
- While a widget is placed, Shell rereads token usage every 5 minutes, even when the dashboard is closed.
- When Shell quits, or the snapshot is more than 20 minutes old, the widget says *Shell isn't running* and keeps showing the last usage numbers.

Plan limits come from the same place as the dashboard's, so they only appear after you've used the native view.

## Native Claude Code view

Typing `claude` at a Shell prompt asks whether to open Shell's native view or Claude Code's own terminal UI. You can check "remember my choice", and change it later in Settings › Claude & Codex. `claude -p`, subcommands and pickers always use the terminal UI.

### How it works

The native view runs the same `claude` binary through its `stream-json` protocol. Your settings, CLAUDE.md, skills, hooks, plugins and MCP servers all apply. Shell renders the event stream natively instead of drawing a TUI.

Claude Code asks whether you trust a folder before it reads, edits or runs anything there, and before it starts the folder's hooks and `.mcp.json` servers. Print mode, which the native view uses, skips that prompt, so the view asks instead:

- **Trust and Start** records the same decision Claude Code's prompt would (`projects[<path>].hasTrustDialogAccepted` in `~/.claude.json`), then starts the session. The rest of the file is kept, and Shell won't write a file it can't parse.
- **Review in Terminal UI** opens Claude Code's own prompt instead.
- **Worktrees of trusted repositories** start without asking, and are recorded as trusted so the terminal UI agrees. Shell finds the main checkout from the worktree's `.git` file. Turn this off in Settings › Claude & Codex if you check out untrusted code, such as pull requests from forks, in worktrees.

### What you get

- **Permission mode.** New sessions start in **auto mode** by default. Change the default in Settings › Claude & Codex (or pick *Claude Code's default* to use `permissions.defaultMode` from its settings.json). A `--permission-mode` you type wins, and Claude Code falls back to its default when auto mode isn't available for your plan or model. Sessions started from the Claude button get the same default as a `--permission-mode` flag.
- **Header.** Switch model, effort and permission mode live (⇧⇥ cycles modes, as in the TUI). It also shows the directory, branch (ahead/behind), repository or linked worktree, and change count. It links to the repo, branch and pull request on GitHub, or offers "Create PR".
- **Transcript.** Markdown, tables, highlighted code blocks, tool calls with diffs, permission prompts (1 / 2 / 3, Return, Esc) and questions.
- **Chat text.** Settings › Chat Text (next to Text & Cursor) sets the chat's font family and size, line height, letter spacing, paragraph spacing, code font and size, and maximum reading width, like VS Code's chat font settings, with a live preview. Defaults: the system font one point larger than the terminal font, 1.6× line height, the terminal font for code, and a 700 pt (about 100 characters) reading width. Each setting is also in `settings.json` (`chatFontFamily`, `chatFontSize`, `chatLineHeight`, `chatLetterSpacing`, `chatParagraphSpacing`, `chatCodeFontFamily`, `chatCodeFontSize`, `chatMaxWidth`).
- **Edit diffs.** File edits show as a real line diff with unchanged context and the file's line numbers, and the changed part of each edited line highlighted. When the pane is wide enough (640 pt or more), the diff is side by side like `git diff` (old on the left, new on the right, each edited line paired with its new version); narrower panes use a unified view. Long runs of unchanged lines collapse to "⋯ N unchanged lines". Choose *Automatic*, *Side by side* or *Unified* in Settings › Claude & Codex › Edit diffs.
- **Tool calls.** Settings › Claude & Codex › Tool calls: *collapse all*, *collapse previous turns and show the current turn* (the default), or *show all*. A collapsed run of tool calls becomes one row, like "6 tool calls · Read 3 · Edit 2 · Bash", with a spinner while one runs and a count of failures; click it to expand. Questions, plans and to-do lists always show.
- **Composer.** Highlights markdown, code fences, `/skills`, `/commands` and `@mcp-servers`. Autocompletes skills, commands, MCP servers, subagents and files. ↑ recalls earlier prompts, Esc interrupts, and ⌃D returns to the shell.
- **Attachments.** Attach files and images with the paperclip, by pasting (⌘V), or by dropping them anywhere on the composer (it turns blue with a dashed border and "Drop to attach" while a file is over it; images dragged from a browser work too). Previews appear above the text box: a thumbnail for images, an icon or Quick Look preview with name and size for files. Click one to Quick Look it; hover to remove it. Images are sent inline, scaled to at most 1568 px and 3.75 MB (HEIC, TIFF and others are converted). Other files and folders are sent as `@path` references that Claude Code reads. Sent attachments show on your message in the transcript, including in resumed sessions. Copying cells from a spreadsheet still pastes the text.
- **Continue in Terminal UI.** Resumes the same conversation in the TUI.
- **File explorer.** In a git repository or worktree, a right-hand explorer shows git status per file (or only the changes). It opens the repo or a file in VS Code, Cursor or Sublime Text, whichever are installed.
- **Tab names.** Tabs and sessions are named `owner/repo · branch · PR #n`.

### Remote Control

Remote Control is on by default (Settings › Claude & Codex). Every native session, and every interactive terminal-UI launch from a Shell prompt, can be continued from the Claude app. The phone button in the header shows a QR code and link.

## MCP manager

Open it from Shell › MCP Servers…, or with the puzzle-piece button in the Claude view. It lists:

- the repository's `.mcp.json` servers;
- your project-only and global servers;
- plugin servers;
- claude.ai connectors.

Each shows live status. You can sign in (OAuth or claude.ai), sign out, reconnect, enable or disable, add and remove (through `claude mcp`), and browse each server's tools. For stdio servers and unauthenticated HTTP servers, tool descriptions and parameters load straight from the server. Open native sessions reconnect a server as soon as you sign in.

## Agent storage

Settings › Agent Storage shows how much disk Claude Code and Codex use: transcripts, checkpoints, per-session scratch, MCP logs, Codex sessions, caches and logs.

| Action | What it removes |
| --- | --- |
| **Clear** | Caches and logs, keeping anything touched in the last day |
| **Prune** | History older than N days. The default matches Claude Code's `cleanupPeriodDays` (30). |
| **Scheduled cleanup** | Clear on a schedule, and optionally Prune too |

Settings, credentials, plugins, skills and project memory are never touched.
