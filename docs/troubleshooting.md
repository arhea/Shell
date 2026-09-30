# Troubleshooting and FAQ

Start here when something doesn't behave as expected. If your problem isn't covered, see [SUPPORT.md](../SUPPORT.md).

- [Collecting diagnostics](#collecting-diagnostics)
- [Prompt and completions](#prompt-and-completions)
- [Claude Code and Codex](#claude-code-and-codex)
- [Git and GitHub](#git-and-github)
- [Appearance and input](#appearance-and-input)
- [macOS integration](#macos-integration)
- [FAQ](#faq)

## Collecting diagnostics

These help when you file a bug.

**A snapshot of the running app.** From a Shell tab, this writes window screenshots and a text report of tabs, panes, shell state and terminal contents:

```bash
"$SHELL_APP_CTL" debug snapshot ~/Desktop/shell-snapshot
```

The report includes the text on screen in every pane. Check it for secrets before you attach it to an issue.

**Live logs.**

```bash
log stream --predicate 'subsystem == "app.bethesdalabs.Shell"' --level debug
```

**Versions.** Shell › About Shell, plus `sw_vers -productVersion` and `zsh --version`.

**Background job logs** (Homebrew, Node.js, worktree and agent-storage cleanup) are in `~/Library/Logs/Shell/`.

## Prompt and completions

**There's no native prompt, and Tab does nothing special.**
The native prompt, completions and command blocks need zsh and the zsh integration.

- Check that Settings › Advanced › *Enable zsh integration* is on.
- Check that the shell is zsh: Settings › Advanced › *Shell* should be empty (your login shell) or a zsh path, and `echo $SHELL` should end in `zsh`.
- Check that the prompt isn't just turned off: press ⌃⌘E.
- Inside tmux, or after `exec zsh`, the integration isn't loaded. See [Shell integration › How it loads](shell-integration.md#how-it-loads) for the one line to add to your `.zshrc`.

**My prompt theme looks different, or zsh's prompt is missing.**
While the native prompt is on, zsh's prompt is hidden while idle and each command is recorded as a block with a header. Set the prompt style in Settings › Prompt & Completions to *My zsh prompt (PS1 / theme)* to use your theme's prompt in those headers, or turn the native prompt off (⌃⌘E) for the unmodified zsh prompt.

**A completion I get in another terminal is missing.**
Completions come from your live zsh session, so they should match. Check that the completion is loaded in that tab (`which _git`, for example). Plugins that only set up completions in interactive widgets, rather than through `compdef`, may not show up.

**The prompt feels slow in a huge repository.**
The branch shown in the header comes from git. If `git status` is slow in that repository, try `git config core.fsmonitor true` and `git config core.untrackedCache true`.

## Claude Code and Codex

**Tabs don't show a spinner or badge for my agent.**

- Install the hooks: Settings › Claude & Codex › Install.
- Restart the agent. Claude Code and Codex read their config at startup.
- Check the Claude hook is present: `grep shellctl ~/.claude/settings.json`.
- For Codex, check `notify` in `~/.codex/config.toml`. If you already had a `notify` program, Shell only replaces it when you confirm.

**Typing `claude` doesn't ask which view to use.**
You chose "remember my choice" earlier. Change it in Settings › Claude & Codex. `claude -p`, subcommands and pickers always use the terminal UI.

**The native view asks me to trust a folder.**
That's Claude Code's own folder-trust check, which print mode skips, so Shell asks instead. *Trust and Start* records the same decision Claude Code would. See [Claude Code and Codex › How it works](claude-code.md#how-it-works).

**The dashboard's plan limits are empty.**
Claude Code reports plan limits to the native view while it runs. Use the native view once and the numbers fill in. Token counts come from local transcripts and appear without it.

**The desktop widget says "Shell isn't running".**
Shell must be running for the widget to update. If it is running and you built Shell from source with the Debug configuration, try a Release build; see [Building › Code signing](building.md#code-signing-for-local-builds).

## Git and GitHub

**The GitHub sidebar or pull requests list is empty.**
Those views use the GitHub CLI. Install it and sign in:

```bash
brew install gh
```

```bash
gh auth login
```

Then check `gh pr list` works in that repository.

**Worktrees go somewhere I don't want.**
Set the location in Settings › Worktrees, or export `WORKTREES_HOME`. The default is `~/code/worktrees/<repo>/<branch>`.

## Appearance and input

**My Ghostty config isn't applied.**
Shell doesn't read `~/.config/ghostty/config`. Paste the options you want into Settings › Advanced; they're appended to the generated config and override Shell's own settings.

**Option key types special characters instead of acting as Meta (or the reverse).**
Settings › Terminal › Keyboard controls this. The default is that left Option acts as Meta (Esc+) and right Option types special characters.

**My edits to `settings.json` were overwritten.**
Shell reads `settings.json` at launch and saves it when anything changes. Quit Shell before editing it by hand.

**Something is badly misconfigured.**
Settings › Advanced › *Reset All Settings…* restores the defaults. To start completely fresh, quit Shell and move `~/Library/Application Support/Shell` somewhere else.

## macOS integration

**"New Shell Tab Here" isn't in Finder's Services menu.**
Enable it in System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders.

**A program I run gets "Operation not permitted" on a protected folder.**
macOS attributes file access from programs in a terminal to the terminal. Allow Shell under System Settings › Privacy & Security › Files and Folders, or Full Disk Access.

**Agent alerts don't break through Focus.**
Time Sensitive alerts are opt-in (Settings › Claude & Codex), must be allowed for Shell in System Settings › Notifications, and need a build signed with the Time Sensitive entitlement. See [Releasing](releasing.md#time-sensitive-notifications).

## FAQ

**Does Shell send any data anywhere?**
No telemetry or analytics. Shell's own network requests are read-only: the update check against GitHub's releases API (every six hours, off in Settings › General) and metadata fetches for the Node.js manager. Everything else goes through tools you run, such as `git`, `gh`, `brew` and `claude`. See [SECURITY.md](../SECURITY.md#security-model).

**Does Shell need an API key for Claude?**
No. It drives the `claude` and `codex` binaries you already have, with their own sign-in.

**Does it work on Intel Macs?**
No. libghostty is built for Apple Silicon only.

**Does it support bash or fish?**
They run as plain terminals. The native prompt, completions, command blocks and command notifications are zsh-only today.

**Will Shell change my dotfiles?**
Not unless you ask. The zsh integration is injected at launch. The agent hooks, the Zsh manager and the toolchain installers edit config files only when you click the button, and they keep their changes minimal and reversible.

**Is it a fork of Ghostty?**
No. Shell embeds libghostty, unmodified, for the terminal itself, and builds its own app around it. See [Architecture](architecture.md).

**How do I uninstall it?**
See [Getting started › Uninstalling](getting-started.md#uninstalling).
