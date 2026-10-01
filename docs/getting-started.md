# Getting started

This guide takes you from download to a working setup in about ten minutes. For the full feature list see [Features](features.md).

- [Requirements](#requirements)
- [Install](#install)
- [First launch](#first-launch)
- [Your first ten minutes](#your-first-ten-minutes)
- [Set up Claude Code and Codex](#set-up-claude-code-and-codex)
- [Set up GitHub](#set-up-github)
- [Make it yours](#make-it-yours)
- [Coming from iTerm2, Warp or Ghostty](#coming-from-iterm2-warp-or-ghostty)
- [Updating](#updating)
- [Uninstalling](#uninstalling)

## Requirements

| | Required | Optional |
| --- | --- | --- |
| **macOS** | 26 (Tahoe) or later | Apple Intelligence turned on, for the Apple Intelligence features |
| **Mac** | Apple Silicon (M1 or later) | |
| **Shell** | Any shell works as a plain terminal | **zsh** for the native prompt, completions and command tracking (the macOS default) |
| **Tools** | | [`claude`](https://docs.anthropic.com/claude-code), [`codex`](https://github.com/openai/codex), [`gh`](https://cli.github.com), `git`, [Homebrew](https://brew.sh) |

Shell has no account, no sign-in and no telemetry. Features that need an external tool light up when that tool is installed and stay out of the way when it isn't.

## Install

### Download a release

1. Download `Shell-<version>.dmg` from the latest release on the [Releases page](../../../releases). (Ignore the "Source code" archives; those are the source, not the app.)
2. Open the disk image and drag `Shell` onto the `Applications` shortcut.
3. Open it. Release builds are signed with a Developer ID and notarized by Apple, so Gatekeeper opens them without a warning.

Shell checks for new releases every six hours. When one is found it downloads and verifies it in the background, notifies you, and installs it when you quit, or right away from the notification's **Restart Now** button or **Help › Restart to Install Shell <version>**. **Help › Check for Updates…** checks on demand and offers **Install and Restart**, which downloads the update, quits, installs it and reopens Shell with your tabs restored. Download progress shows in the Help menu and in Settings › General › Software Update; if a download fails, Shell tells you and lets you try again. Turn either behavior off in Settings › General › Software Update. Updates install only into a copy you can write to, such as `/Applications/Shell.app` for an admin user.

### Build from source

You need Xcode 26 or later and Homebrew.

```bash
brew install zig xcodegen
```

```bash
git clone <this-repo> Shell && cd Shell
```

```bash
make bootstrap && make run
```

The first `make bootstrap` builds libghostty and takes about 3 minutes. To install your own build in `/Applications` without a Developer ID certificate, build Release and copy it:

```bash
make release && ditto build/DerivedData/Build/Products/Release/Shell.app /Applications/Shell.app
```

Release builds are configured for Developer ID signing. If you don't have a certificate, run the Debug build (`make run`) instead, or see [Building from source](building.md#code-signing-for-local-builds).

## First launch

Shell opens one window with one tab running your login shell. A few things happen once:

- **Notifications.** macOS asks whether Shell may send notifications. Allow them to hear about finished commands and agents that need you.
- **Privacy prompts.** When a program you run needs the camera, contacts, a protected folder and so on, macOS asks on Shell's behalf. That's normal for any terminal. See [Releasing › Entitlements](releasing.md#entitlements) for why.
- **Apple Intelligence.** With Apple Intelligence on, a one-time banner points you to Settings › Apple Intelligence. Every feature there is off until you turn it on.

Your dotfiles aren't touched. Shell injects its zsh integration at launch through `ZDOTDIR`, so your `.zshrc`, theme and plugins load as usual. See [Shell integration](shell-integration.md).

## Your first ten minutes

### Type a command

The box at the bottom of the pane is the **native prompt**. It's a real text editor:

- Click to place the cursor, select with the mouse, and press ⇧↩ (or ⌥↩) for a new line. An unclosed quote or a trailing `\` continues onto the next line too.
- History suggestions show as grey ghost text. Press → to accept, or ⌥→ for one word.
- ⌃R searches history. ↑ and ↓ step through it.
- Tab opens completions from your real zsh: aliases, functions, plugins and all.

Each command you run is recorded in the scrollback as a block, with your prompt header and the command, followed by its output.

Prefer typing straight into zsh? Press ⌃⌘E to turn the native prompt off. It applies to every tab, and you can switch back any time.

### Tabs and splits

| Do this | Press |
| --- | --- |
| New tab | ⌘T |
| Split right / split down | ⌘D / ⇧⌘D |
| Move between panes | ⌥⌘ + arrow keys |
| Maximize the current pane | ⇧⌘↩ |
| Switch to vertical tabs | ⌃⌘T |
| Group tabs | ⌃⌘G |

Right-click a tab to rename it, duplicate it, add it to a group or move it to a new window. Right-click a group to rename, color or collapse it.

### Find anything

Press ⇧⌘P for the **command palette**. Every menu command and Settings pane is there, with its shortcut. When you don't know where something lives, start here.

### Copy what you need

| Do this | Press |
| --- | --- |
| Copy the last command | ⇧⌘C |
| Copy the last command's output | ⌥⇧⌘C |
| Jump between commands in the scrollback | ⇧⌘↑ / ⇧⌘↓ |
| Open a URL, or reveal a file in Finder | ⌘-click it |

### Get notified

Commands that run longer than 10 seconds post a notification when they finish, unless you're already looking at that pane. Change the threshold, or turn it off, in Settings › General › Notifications.

## Set up Claude Code and Codex

Shell works with the `claude` and `codex` you already have installed and signed in. Nothing to configure in Shell itself.

1. **Install the status hooks.** Open Settings (⌘,) › Claude & Codex and click **Install**. This adds a small hook to `~/.claude/settings.json` and a `notify` entry to `~/.codex/config.toml`. The hooks do nothing outside Shell, and Uninstall removes only what Shell added.
2. **Run an agent.** Type `claude` in a tab. The first time, Shell asks whether to open its **native Claude view** or Claude Code's own **terminal UI**. Try the native view; you can switch any time in Settings › Claude & Codex.
3. **Watch your agents.** Each agent tab shows a spinner while it works and a badge when it needs you. While any Claude session is running, a **Claude** entry is pinned at the front of the tabs. Press ⌃⌘A to see every session across your windows, with plan limits and token usage.
4. **Work in parallel.** In a git repository, click the arrow next to the **Claude** button above the prompt and choose **Start Claude in Worktree…**. Name a new branch or pick an existing one, and Shell creates a worktree and starts Claude there in a new tab.

The [Claude Code and Codex](claude-code.md) guide covers the native view, the MCP manager, the desktop widget and agent storage.

## Set up GitHub

The sidebar's GitHub, pull request and Actions views use the [GitHub CLI](https://cli.github.com). Install it and sign in once:

```bash
brew install gh
```

```bash
gh auth login
```

Then open a tab in a GitHub repository and press ⌃⌘B. The sidebar shows the file tree with git status, every worktree with its PR state, and the repository's open pull requests and recent Actions runs. Click a pull request to check it out into its own worktree.

Worktrees go in `~/code/worktrees/<repo>/<branch>` by default. Change it in Settings › Worktrees, or set `$WORKTREES_HOME`.

## Make it yours

| Change | Where |
| --- | --- |
| Theme (separate light and dark) | Settings › Themes & Colors. About 600 themes are bundled. |
| Font, size, line height, cursor | Settings › Text & Cursor |
| Prompt position, style, completions | Settings › Prompt & Completions |
| Keyboard shortcuts | Settings › Keyboard Shortcuts. Every action can be rebound or unbound. |
| Quake-style hotkey window | Settings › General (default ⌥\`) |
| New-tab directory, session restore | Settings › General |
| Tab bar style, tab groups, splits | Settings › Tabs & Windows |
| Shell program (defaults to your login shell) | Settings › Advanced |
| Raw Ghostty options | Settings › Advanced |
| Sync settings across Macs | Settings › General › Sync (iCloud Drive, off by default) |

Everything is stored in `~/Library/Application Support/Shell/settings.json`, so you can keep it in your dotfiles. See [Configuration](configuration.md).

To add your own themes, drop Ghostty-format theme files into `~/.config/ghostty/themes` or `~/Library/Application Support/Shell/themes`.

## Coming from iTerm2, Warp or Ghostty

| If you're used to… | In Shell |
| --- | --- |
| **iTerm2** | Shortcuts match iTerm2 by default, including the "Natural Text Editing" key mappings. Shell doesn't import iTerm2 profiles; pick a theme with the same name (most iTerm2 color schemes are bundled). |
| **Warp** | The native prompt and command blocks work like Warp's input and blocks. Completions come from your own zsh instead of a separate spec set. There's no account and no cloud AI. |
| **Ghostty** | The terminal engine is the same. Shell doesn't read `~/.config/ghostty/config`; paste any options you want into Settings › Advanced. Themes in `~/.config/ghostty/themes` are picked up. |

## Updating

Shell doesn't update itself yet. To update, download the new release and replace `/Applications/Shell.app`. Quit Shell first; your tabs are restored on the next launch. Your settings live outside the app bundle and carry over.

From source:

```bash
git pull && make bootstrap && make run
```

## Uninstalling

1. In Settings › Claude & Codex, click **Uninstall** for any agent hooks you installed. This removes Shell's entries from `~/.claude/settings.json` and `~/.codex/config.toml` and leaves the rest of those files alone. (The hooks are harmless if you skip this step: they exit silently outside Shell.)
2. Quit Shell and move `/Applications/Shell.app` to the Trash.
3. Optionally remove Shell's data:

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/Shell` | Settings, generated Ghostty config, prompt history, saved session layout, custom themes |
| `~/Library/Logs/Shell` | Background maintenance job logs |
| `~/Library/Group Containers/T9PCKZ42NK.app.bethesdalabs.Shell` | Desktop widget snapshot |
| `iCloud Drive/Shell` | Synced settings, only if you turned on iCloud sync |

If you used the Zsh manager, it saved a backup of your `.zshrc` as `~/.zshrc.shell-backup` before editing it. Shell never removes Homebrew, Node.js, Oh My Zsh or anything else it helped you install.
