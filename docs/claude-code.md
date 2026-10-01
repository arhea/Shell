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

Click it, or press ⌃⌘A, to replace the terminal area with a tiled view of every session in every window:

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

### Running elsewhere

Below the tiles, **Running Elsewhere** lists live Claude Code sessions that aren't in a Shell tab, from `claude agents --json`. Each one shows its name, status (working, waiting on a permission prompt, idle), folder, start time, and where it runs:

| Where it runs | Click it to |
| --- | --- |
| **Background** (`claude --bg`, or moved to the background) | Open a tab in its folder and run `claude attach <id>`. It's the same live session. Close the tab (or press ← / Ctrl+Z in Claude Code) and it keeps running |
| **Claude desktop** or **Other terminal** | Nothing: Claude Code won't open a session another terminal holds. The tile says where to find it. Right-click to copy its session ID or path |

Sessions running in Shell (in the terminal or the native view) and background sessions already attached in a Shell tab aren't listed twice. The list refreshes every 5 seconds while the dashboard is open, and nothing runs while it's closed. It needs a Claude Code version with `claude agents --json`; with older versions the section stays hidden.

### Past sessions

A drawer on the right of the dashboard lists your past Claude Code conversations, newest first, read from the transcripts in `~/.claude/projects` (up to the 200 most recent; sessions in temporary folders are left out). Hide it with its sidebar button and bring it back with the clock button in the dashboard's header. Type in the filter box to search by title, prompt, folder or branch.

Each card leads with the repository and branch (with ahead/behind or **not pushed**, and **main** for the main checkout), then the session's first prompt. The `/rename` or Claude-generated title stands in when there's no prompt. Below that are the branch's pull request, whether the worktree is clean or has changes, the folder, and when the session was last active, the same details as the Worktrees sidebar. Git details are read only for cards on screen, and pull requests come from your `gh`, once per repository.

Hover a card for its actions, or right-click it:

| Action | What it does |
| --- | --- |
| **Resume** | Opens a tab in the session's folder and runs `claude --resume <id>` (double-click does the same) |
| **New** | Opens a tab in the session's folder and runs `claude` |
| **Terminal** | Opens a tab in the session's folder |
| **Show** | Replaces Resume when the conversation is already open in a native view, and jumps to that pane |

The commands are typed at your prompt, so your **Typing `claude` opens** choice (native view or terminal UI) applies. The actions are disabled when the folder no longer exists. Shell only reads the transcripts; it never changes or deletes them.

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
- **Transcript.** Your messages are right-aligned bubbles; Claude's replies are plain text with markdown, tables and links in blue. Inline code is neutral, not accent-colored. Thinking folds into one row, "▸ Thought for 6s" ("Thinking… 4s" while it streams); click it to read the thought.
- **Code blocks.** A header with the language and the file name when the fence names one (` ```bash repro.sh`, `title="a.ts"` or ` ```bash:repro.sh`), a line-number gutter, **Copy**, **Save…**, and, for `sh`, `bash`, `zsh` and `shell` blocks, **Run in new tab**: a terminal tab opens in the session's folder and runs it (several lines run from a temporary script, so the prompt shows one command).
- **Permission prompts.** A yellow card says what Claude wants ("Claude wants to run a command"), shows the command or diff and why it's asking, then numbered choices: **1 Allow once** (Return), **2 Always allow `<rule>` in this repo** (Claude Code's suggested rule, when there is one), **3 Deny, and tell Claude what to do instead** (Esc). Type instructions in the composer and press Return (or click 3) to deny with them; they show in the transcript and go to Claude. Plans and questions use the same card and keys.
- **Chat text.** Settings › Chat Text (next to Text & Cursor) sets the chat's font family and size, line height, letter spacing, paragraph spacing, code font and size, and maximum reading width, like VS Code's chat font settings, with a live preview. Defaults: the system font one point larger than the terminal font, 1.6× line height, the terminal font for code, and a 700 pt (about 100 characters) reading width. **Composer width** sets the chat column the composer fills: Centered (up to 1200 pt, the default) or Full width; the reading width limits transcript text within it. Each setting is also in `settings.json` (`chatFontFamily`, `chatFontSize`, `chatLineHeight`, `chatLetterSpacing`, `chatParagraphSpacing`, `chatCodeFontFamily`, `chatCodeFontSize`, `chatMaxWidth`, `chatComposerWidth`).
- **Starting a conversation.** A new Claude view opens with the composer in the middle of the pane under the welcome. Sending the first message moves it to the bottom and widens it to the chat column (instantly, without the animation, when Reduce Motion is on). Continued and resumed sessions open with it at the bottom.
- **Edit diffs.** File edits show as a real line diff with unchanged context and the file's line numbers, and the changed part of each edited line highlighted. When the pane is wide enough (640 pt or more), the diff is side by side like `git diff` (old on the left, new on the right, each edited line paired with its new version); narrower panes use a unified view. Long runs of unchanged lines collapse to "⋯ N unchanged lines". Choose *Automatic*, *Side by side* or *Unified* in Settings › Claude & Codex › Edit diffs.
- **Tool calls.** Consecutive reads, searches and quick commands show as one card, "Explored the code · Grep 1 · Read 3", with a row per step: ✓, spinner or ✕, the tool, its argument (folders dimmed so file names stand out) and a detail such as `L1–184`, `5 lines` or `+9 −2`. Hover a file step for **Open ↗**; click a step for its result or diff. A single edit shows its diff card ("✓ Edit `AppDelegate.swift` +4 −1", **Unified | Split**, **Copy**, **Review ⌘⇧R**); consecutive edits share one card. Builds, tests and failed commands get an output card with **Passed 41.2s** or **Failed exit 1**, the last 10 lines of output (colors stripped) and **Show all N lines · Copy output · Open in terminal tab**.
- **Folding.** Settings › Claude & Codex › Tool calls: *collapse all*, *collapse previous turns and show the current turn* (the default), or *show all*. A finished turn's work folds into one row with its last reply left out, like "▸ Worked for 6m 12s · 28 tool calls · Read 9 · Edit 3 · committed 74c838f · opened PR #39". Commits and pull requests come from the `git commit` and `gh pr create` output in the turn. Questions, plans and to-do lists always show.
- **End-of-turn summary.** A turn that changed files or committed ends with a card: what it did ("Committed 74c838f"), how long it took and what it cost, and rows for the pull request, branch, commit or changed files (+/−) and test results (XCTest, Jest/Vitest and pytest summaries) when they can be read from the transcript. **Review changes**, **Open PR on GitHub ↗** (when there is one) and **Copy summary**.
- **Status line.** Above the composer while Claude works: a spinner, what it's doing (the to-do in progress, else the running tool, "Thinking" or "Writing"), the turn's time and output tokens ("2m 41s · ↓ 18.2k tokens"), and `esc` to interrupt. While a prompt waits: "● Waiting for your approval · Press 1, 2 or 3, or type different instructions".
- **CI failures.** A failed check can land in the transcript as a red card: the job, workflow, commit and run time, the failed step and test count, and the failing log lines with errors tinted. **Fix with Claude** sends "Fix the failing check: Test / Build and test." with the log attached as a file Claude reads (a **LOG** chip on your message), **Re-run failed jobs** reruns the job, and **Full log ↗** opens it on GitHub.
- **Composer.** A rounded field ("Reply to Claude…") with **+** (attach), **@ Context** and **/ Skills & commands** buttons, which start a mention or command and open its suggestions, and a stop button while Claude works (send otherwise). Under it: the keys (⏎ send · ⇧⏎ new line · ↑ previous prompt), a context meter ("143k / 1M") and the session's cost. The context window is 1M for models with the `[1m]` suffix, a picker entry "with 1M context", Opus 5 and later, or once more than 200k is in use; otherwise 200k. The field highlights markdown, code fences, `/skills`, `/commands` and `@mcp-servers`, and autocompletes skills, commands, MCP servers, subagents and files. ↑ recalls earlier prompts, Esc interrupts, and ⌃D returns to the shell.
- **Attachments.** Attach files and images with **+**, by pasting (⌘V), or by dropping them anywhere on the composer (it turns blue with a dashed border and "Drop to attach" while a file is over it; images dragged from a browser work too). Previews appear above the text box: a thumbnail for images, an icon or Quick Look preview with name and size for files. Click one to Quick Look it; hover to remove it. Images are sent inline, scaled to at most 1568 px and 3.75 MB (HEIC, TIFF and others are converted). Other files and folders are sent as `@path` references that Claude Code reads. Sent attachments show on your message in the transcript, including in resumed sessions. Copying cells from a spreadsheet still pastes the text.
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
