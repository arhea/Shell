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

When Claude Code is installed (the `claude` binary is on your `PATH` or `~/.claude` exists), a **Claude Sessions** entry is pinned to the top of the sidebar in vertical-tabs mode (the front of the tab bar with horizontal tabs). It shows how many sessions are running and turns yellow when one needs you. Settings › Claude & Codex › **Show Claude Sessions in the tabs** chooses when it appears:

| Setting | The entry shows |
| --- | --- |
| Always (default) | Whenever Claude Code is installed, even with nothing running |
| When sessions are active | Only while a Claude Code session is running |
| Never | Never; ⌃⌘A still opens the dashboard |

Click it, or press ⌃⌘A, to replace the terminal area with the **Claude Sessions** page. The toolbar shows a one-line summary ("1 needs you · 2 working"). A row at the top of the page has a **Filter sessions** field (matches title, folder or branch, in Shell and elsewhere), a **✻ New Session** button (a new tab running `claude`; its menu starts one in a chosen folder, a recent folder, or a new worktree), and a **Recent** button that shows or hides the drawer on the right.

### Usage

Below the controls, one strip shows your Claude usage. Cells without data yet are left out.

| Cell | Shows |
| --- | --- |
| **5-hour limit** / **Weekly limit** | Percent of your plan used, a bar (green, yellow above 70%, red above 90%) and when it resets. Claude Code reports these to the native view as it runs; Shell keeps the latest report, so these fill in after you've used the native view once |
| **Tokens today** | Today's total, the number of sessions and the share of input served from the prompt cache. Hover for the input / output / cache split, the top model and the last 5 hours |
| **Last 7 days** | Tokens per day, today in Claude orange, and how long ago the plan limits were reported |

Tokens come from the transcripts in `~/.claude/projects`, so they include terminal-UI sessions too. The first read runs in the background; after that only new lines are read, once a minute while the page is open. Nothing is sent anywhere, and Shell never reads your Claude credentials.

### Sessions in Shell

Every Claude session in every window is grouped by what it needs from you, in tab order:

| Section | Each session shows |
| --- | --- |
| **Needs you** (yellow) | Title, where it runs (**Native view · Tab 4**), repository and branch, uncommitted changes and how long it has been waiting, with the request and its answers right on the card. A native permission request reads as a sentence ("Claude wants to edit TabStore.swift") with the file or command, and **Deny**, **Allow once** and, when Claude Code suggests a permission update, a button named for it (**Allow edits this session** switches the session to accept edits; **Allow this session** or **Always allow** adds the suggested rule). Questions and plans show the native view's own cards. In the terminal UI, the numbered options of Claude Code's prompt become buttons |
| **Working** (orange) | Title and how long it has been working, repository, branch, PR link and changes, the last two lines of what it's doing (or an Apple Intelligence summary when that's on), and the tab, view, model and cost |
| **Idle** | A compact row per session that's done (green check), idle or exited, with its last message |

Status comes from the agent hooks (terminal UI) or the native view's own state. Times count from when Shell saw the session change state. **Open ⌘3** (or a click on the card) jumps to the pane; the shortcut shows when there's one window. Right-click a session to open its PR, copy its path or reveal it in Finder.

In the terminal UI, clicking an option presses its number key, then Return if the prompt is still showing, just as if you'd typed it. Shell only offers this when it sees Claude Code's `❯ 1.` selector under a question, so numbered lists in Claude's replies are left alone. Without the hooks, terminal sessions show as idle, but their prompts still appear under their rows.

Selecting any tab (or ⌃⌘A again) closes the page.

### Running elsewhere

Below Shell's sessions, **Running elsewhere** is a table of live Claude Code sessions that aren't in a Shell tab, from `claude agents --json`: status (**Needs permission**, **Working**, **Idle · Background**, **Idle**), session name, folder, when it started, and what you can do with it. Sessions that need you sort first. Five rows show at first; **Show N more idle sessions** shows the rest.

| Where it runs | Last column |
| --- | --- |
| **Background** (`claude --bg`, or moved to the background) | **Attach** opens a tab in its folder and runs `claude attach <id>`. It's the same live session. Close the tab (or press ← / Ctrl+Z in Claude Code) and it keeps running |
| **Claude desktop** or **Other terminal** | Where it runs. Claude Code won't open a session another terminal holds. Right-click to copy its session ID or path |

Sessions running in Shell (in the terminal or the native view) and background sessions already attached in a Shell tab aren't listed twice. The list refreshes every 5 seconds while the page is open, and nothing runs while it's closed. It needs a Claude Code version with `claude agents --json`; with older versions the section stays hidden.

### Recent sessions

The **Recent** drawer on the right lists your past Claude Code conversations, newest first and grouped by day (Today, Yesterday, then weekdays and dates), read from the transcripts in `~/.claude/projects` (up to the 200 most recent; sessions in temporary folders are left out). Hide or refresh it from its **…** menu, and bring it back with **Recent**. Type in its search field to filter by title, prompt, folder or branch.

Each row shows the repository and branch, the session's first prompt in bold (the `/rename` or Claude-generated title when there's no prompt), and the branch's pull request (**#674 open** in green, **merged** in purple, **draft** in gray), whether the worktree is clean or has changes, and when the session was last active. Repository details are read only for rows on screen, and pull requests come from your `gh`, once per repository.

Hover a row for its actions, or right-click it:

| Action | What it does |
| --- | --- |
| **Resume** | Opens a tab in the session's folder and runs `claude --resume <id>` (double-click does the same) |
| **New** | Opens a tab in the session's folder and runs `claude` |
| **Terminal** | Opens a tab in the session's folder |
| **Show** | Replaces Resume when the conversation is already open in a native view, and jumps to that pane |

The commands are typed at your prompt, so your **Typing `claude` opens** choice (native view or terminal UI) applies. The actions are disabled when the folder no longer exists. Shell only reads the transcripts; it never changes or deletes them.

A pane counts as a Claude session when it's running the native view, a `claude` command (including `command claude`, a path to the binary or `npx @anthropic-ai/claude-code`), or when Claude Code's hooks report from its running command, which covers aliases. Turn the pinned entry off in Settings › Claude & Codex.

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

### Signing in

Print mode can't run `/login`, so the view checks `claude auth status` before it starts. When Claude Code isn't signed in, or a session's sign-in expires or is revoked mid-conversation, the view shows a **Sign in to Claude Code** card instead of an error:

1. Choose the account type, as in `/login`: **Claude account with subscription** (Pro, Max, Team or Enterprise) or **Anthropic Console account** (API usage billing). Check **Use single sign-on (SSO)** to force the SSO flow.
2. Claude Code opens the sign-in page in your browser. If it didn't open, click **Open Sign-in Page**.
3. If the page shows a code, paste it into the card and click **Submit**.

The card runs Claude Code's own `claude auth login`, so the result is the same as `/login` in the terminal UI: Claude Code stores the credentials, and `claude` in every terminal is signed in too. Shell never reads, stores or copies them. Once you're signed in, the session starts, or restarts and continues the conversation, and a message that failed for want of a sign-in is sent again. Text in the composer stays there while you sign in. If sign-in is cancelled or fails, the card says why and offers the account types again.

Sessions that use Amazon Bedrock, Google Vertex AI or another provider aren't gated, since signing in to Anthropic doesn't apply to them.

### What you get

- **Permission mode.** New sessions start in **auto mode** by default. Change the default in Settings › Claude & Codex (or pick *Claude Code's default* to use `permissions.defaultMode` from its settings.json). A `--permission-mode` you type wins, and Claude Code falls back to its default when auto mode isn't available for your plan or model. Sessions started from the Claude button get the same default as a `--permission-mode` flag.
- **Header.** Switch model, effort and permission mode live (⇧⇥ cycles modes, as in the TUI). It also shows the directory, branch (ahead/behind), repository or linked worktree, and change count. It links to the repo, branch and pull request on GitHub, or offers "Create PR".
- **Transcript.** Markdown, tables, highlighted code blocks, tool calls with diffs, permission prompts (1 / 2 / 3, Return, Esc) and questions.
- **Chat text.** Settings › Chat Text (next to Text & Cursor) sets the chat's font family and size, line height, letter spacing, paragraph spacing, code font and size, and maximum reading width, like VS Code's chat font settings, with a live preview. Defaults: the system font one point larger than the terminal font, 1.6× line height, the terminal font for code, and a 700 pt (about 100 characters) reading width. **Composer width** sets the chat column the composer fills: Centered (up to 1200 pt, the default) or Full width; the reading width limits transcript text within it. Each setting is also in `settings.json` (`chatFontFamily`, `chatFontSize`, `chatLineHeight`, `chatLetterSpacing`, `chatParagraphSpacing`, `chatCodeFontFamily`, `chatCodeFontSize`, `chatMaxWidth`, `chatComposerWidth`).
- **Starting a conversation.** A new Claude view opens with the composer in the middle of the pane under the welcome. Sending the first message moves it to the bottom and widens it to the chat column (instantly, without the animation, when Reduce Motion is on). Continued and resumed sessions open with it at the bottom.
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
