# Configuration

Settings › (⌘,) covers everything. Under the hood, settings are a plain JSON file that you can edit by hand or keep in your dotfiles.

## Files and locations

| Path | What it is |
| --- | --- |
| `~/Library/Application Support/Shell/settings.json` | All settings. Pretty-printed with sorted keys. Missing keys fall back to defaults, so older files keep loading. |
| `~/Library/Application Support/Shell/ghostty.conf` | libghostty config **generated** from `settings.json`. Don't edit it, because Shell overwrites it. |
| `~/Library/Logs/Shell/` | Logs from background maintenance jobs (Homebrew, Node.js, worktree and agent-storage cleanup) and `update.log` from installing updates. |
| `~/Library/Application Support/Shell/updates.json` | When Shell last checked for updates, and the latest release it saw. |

Shell does **not** read `~/.config/ghostty/config`. To pass raw Ghostty options through, use Settings › Advanced (`extraGhosttyConfig`). That text is appended to the generated config, so it overrides anything Shell sets. See the [Ghostty config reference](https://ghostty.org/docs/config/reference).

Changes made in the Settings window apply live. `settings.json` is read at launch, so quit Shell before you edit it by hand; otherwise Shell's next save overwrites your edits. **Reload Configuration** (⇧⌘,) regenerates `ghostty.conf` from the current settings and reloads libghostty.

## Common keys

The full model, with defaults, is `AppSettings` in [`Sources/Shell/Settings/AppSettings.swift`](../Sources/Shell/Settings/AppSettings.swift). The most useful keys:

| Key | Default | Notes |
| --- | --- | --- |
| `appearance` | `"system"` | `system`, `light` or `dark`. While Shell runs, its Dock icon uses the light or dark variant that matches the active theme, even when that differs from the system appearance. |
| `lightTheme` / `darkTheme` | `"Shell Light"` / `"Shell Dark"` | Any bundled Ghostty theme name |
| `lightOverrides` / `darkOverrides` | `{}` | `background`, `foreground`, `cursor`, `selectionBackground`, `selectionForeground`, and `palette` (index → hex) |
| `fontFamily` / `fontSize` | `""` / `13` | An empty family uses JetBrains Mono |
| `lineHeight`, `letterSpacing`, `ligatures` | `1.0`, `1.0`, `true` | |
| `backgroundOpacity` / `backgroundBlur` | `1.0` / `true` | |
| `cursorStyle` / `cursorBlink` | `"bar"` / `true` | `block`, `bar`, `underline` or `block_hollow` |
| `scrollbackMB` | `50` | Per pane |
| `optionKey` | `"left"` | `false` (type special characters), `true` (both Option keys send Esc+), `left` or `right` |
| `copyOnSelect`, `pasteProtection`, `highlightLinks` | `false`, `true`, `true` | |
| `shellPath` | `""` | Empty uses your login shell |
| `shellIntegration` | `true` | Needed for the native prompt, completions and command tracking |
| `environment` | `{}` | Extra environment variables for new sessions |
| `inputEditor` | `true` | The native prompt. Toggle it live with ⌃⌘E. |
| `inputPosition` | `"bottom"` | `top` or `bottom` |
| `promptStyle` | `"compact"` | `compact` (Shell's header) or `shell` (your theme's prompt) |
| `completions`, `completionsWhileTyping`, `historySuggestions`, `syntaxHighlighting` | `true` | |
| `tabBarStyle` | `"horizontal"` | `horizontal` or `vertical` |
| `newTabDirectory` | `"inherit"` | `inherit`, `home` or `custom` (with `customDirectory`) |
| `notifyCommandFinished` / `commandFinishedThreshold` | `true` / `10` | Seconds a command must run before Shell notifies you |
| `claudeLaunchMode` | `"ask"` | `ask`, `native` or `terminal` |
| `chatComposerWidth` | `"centered"` | Width of the native Claude view's chat column: `centered` (capped at 1200 pt) or `full` (the whole pane). The composer fills the column. |
| `chatMaxWidth` | `700` | Reading width of the Claude transcript text, in points, within the chat column. `0` uses the whole column. |
| `claudeRemoteControl` | `true` | See [Claude Code and Codex](claude-code.md#remote-control) |
| `claudeSessionsButton` | `"always"` | When Claude Sessions is pinned to the tabs: `always` (whenever Claude Code is installed), `whenActive` (while a session runs) or `never`. Replaces `claudeDashboard`; `false` there becomes `never`. |
| `claudeSessionsHistory` | `true` | Show the past sessions drawer on the Claude Sessions page |
| `worktreeRoot` | `""` | Empty uses `$WORKTREES_HOME`, then `~/code/worktrees` |
| `worktreeStaleDays` | `7` | |
| `brewAutoUpdate`, `nodeAutoUpdate`, `worktreeCleanupSchedule`, `agentStorageSchedule` | `"off"` | `off`, `daily`, `weekly` or `monthly` |
| `hotkeyWindow` / `hotkey` | `false` / ⌥\` | Quake-style window |
| `shortcuts` | `{}` | Action id → shortcut. `null` unbinds the action. See [Keyboard shortcuts](keyboard-shortcuts.md). |
| `extraGhosttyConfig` | `""` | Raw Ghostty config lines |
| `timeSensitiveAgentAlerts` | `false` | Deliver "needs your input" agent alerts as Time Sensitive |
| `iCloudSync` | `false` | Sync portable settings through iCloud Drive (below) |
| `checkForUpdates` | `true` | Check GitHub for a new release every six hours |
| `installUpdatesAutomatically` | `true` | Download new releases in the background and install them when Shell quits |
| `intelligenceBranchNames`, `intelligencePaletteIntents`, `intelligenceCommandFixes`, `intelligenceSessionSummaries`, `intelligenceTabNames`, `intelligenceCommitMessages` | `false` | Apple Intelligence features. See [Features](features.md#apple-intelligence). |
| `intelligenceAnnouncementShown` | `false` | Set once the one-time Apple Intelligence banner has been shown |

## iCloud settings sync

Sync is **completely optional and off by default**. Turn it on in Settings › General › Sync. It needs iCloud Drive to be on for this Mac.

- Shell mirrors the portable settings to `iCloud Drive/Shell/settings.json`. Other Macs with sync on apply changes from that file within a few seconds.
- When you turn it on and a synced copy already exists, Shell asks which to keep: the iCloud copy or this Mac's settings.
- **What syncs:** appearance and themes, color overrides, font and cursor, terminal behavior, prompt and completion preferences, tab style, notification, software update and Claude preferences, the Claude view's composer width, the hotkey window, keyboard shortcuts, and `extraGhosttyConfig`.
- **What never syncs:** `environment` (it can hold secrets), `shellPath`, worktree, Go, Homebrew, Node.js and agent-storage settings, UI state such as sidebar tabs and widths, `iCloudSync` itself, Apple Intelligence settings (availability differs from Mac to Mac), and command history.
- When two Macs change settings at the same time, the most recent write wins.
- Turning sync off stops syncing and leaves the file in iCloud Drive. Delete `iCloud Drive/Shell` to remove it.

It works through the iCloud Drive folder, so it needs no iCloud entitlement and works in builds from source. The list of synced keys is `SettingsSync.portableKeys` in [`Sources/Shell/Settings/SettingsSync.swift`](../Sources/Shell/Settings/SettingsSync.swift). New settings stay local until they're added there.

## Environment variables

### Set by Shell in every session

| Variable | Meaning |
| --- | --- |
| `SHELL_APP_SESSION` | This pane's session ID |
| `SHELL_APP_SOCKET` | Path of the app's control socket (mode `0600`) |
| `SHELL_APP_CTL` | Path of the bundled `shellctl` |
| `SHELL_APP_RUNTIME` | Private (`0700`) directory under `$TMPDIR` used to hand commands and completion requests to zsh |
| `SHELL_APP_VERSION` | App version |
| `SHELL_APP_ZDOTDIR`, `SHELL_APP_ORIG_ZDOTDIR` | Used to inject the zsh integration and then restore your real `ZDOTDIR` |
| `SHELL_APP_EDITOR`, `SHELL_APP_PROMPT`, `SHELL_APP_CLAUDE`, `SHELL_APP_CLAUDE_RC` | Initial native-prompt, prompt-style and Claude settings for the integration |

Scripts can check `[[ -n $SHELL_APP_SESSION ]]` to tell whether they're running inside Shell.

### Read by Shell (for development)

| Variable | Effect |
| --- | --- |
| `SHELL_APP_DRY_RUN=1` | Maintenance jobs log their commands instead of running them |
| `SHELL_APP_BREW=/path/to/brew` | Use a stand-in `brew` binary |
| `WORKTREES_HOME` | Root for worktrees Shell creates (when `worktreeRoot` is empty) |
