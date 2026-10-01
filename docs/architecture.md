# Architecture

Shell is a native AppKit app that embeds **libghostty** for everything inside the terminal grid. Ghostty handles VT parsing, the PTY, fonts and Metal rendering. Shell owns everything around the grid: windows, tabs, splits, the native prompt, sidebars and integrations.

```
┌────────────────────────── Shell.app (Swift) ───────────────────────────┐
│  AppKit windows, tabs, splits · SwiftUI settings, sidebars, Claude view │
│                                                                        │
│  TerminalSurfaceView ──(C API: ghostty.h)──► libghostty                │
│        ▲  keys / IME / mouse                  VT · PTY · Metal renderer│
│        │                                                               │
│  InputEditorView (native prompt) ──private key sequences──┐            │
│                                                           ▼            │
│  ControlServer (Unix socket) ◄──records── zsh integration · shellctl   │
└────────────────────────────────────────────────────────────────────────┘
```

## Source layout

```
Sources/Shell
├── App/            AppDelegate, menu bar (built from ShortcutAction), debug commands
├── Ghostty/        libghostty runtime + callbacks, TerminalSurfaceView (keys/IME/mouse), config generation
├── Model/          TerminalSession, PaneTree (splits), TerminalTab / TabGroup / Workspace, session restore
├── UI/             Window controller, tabs + sidebar, split container, panes, input editor, palette,
│                   hotkey window, Claude view, MCP manager, right inspector (session, worktrees, checks, files)
├── Settings/       AppSettings (JSON), themes, shortcuts, Settings window panes
├── Integrations/   Control socket, zsh integration glue, history, notifications, Claude/Codex,
│                   Git/GitHub, MCP, Homebrew, Node.js, Zsh, Go, scheduled maintenance
└── Automation/     App Intents (Shortcuts, Spotlight), session entities, ShellAutomation
Resources/shell/zsh  ZDOTDIR bootstrap + shell-integration.zsh
Resources/bin        shellctl
Tests/ShellTests     XCTest unit tests
```

## Key pieces

| Type | File | Responsibility |
| --- | --- | --- |
| `GhosttyRuntime` | `Ghostty/GhosttyRuntime.swift` | Owns the `ghostty_app_t`, handles runtime callbacks (clipboard, titles, actions), and reloads config |
| `ConfigController` | `Ghostty/ConfigController.swift` | Turns `AppSettings` into a Ghostty config file |
| `TerminalSurfaceView` | `Ghostty/TerminalSurfaceView.swift` | The `NSView` that hosts one `ghostty_surface_t`. Translates keyboard, IME and mouse events. |
| `TerminalSession` | `Model/TerminalSession.swift` | One shell: surface, cwd, git branch, command state, agent status |
| `PaneTree` | `Model/PaneTree.swift` | Immutable split tree for a tab |
| `Workspace` | `Model/Workspace.swift` | Tabs and tab groups for a window |
| `TerminalWindowController` | `UI/TerminalWindowController.swift` | One window: tab bar or sidebar, split container, action dispatch |
| `InputEditorView` | `UI/Editor/InputEditorView.swift` | The native prompt: highlighting, ghost text, completions, history |
| `ShellIntegration` | `Integrations/ShellIntegration.swift` | Session environment, runtime directory, and handling of messages from zsh |
| `ControlServer` | `Integrations/ControlServer.swift` | Unix-domain socket for zsh, `shellctl` and agent hooks |
| `ClaudeCodeSession` | `Integrations/Claude/ClaudeCodeSession.swift` | Runs `claude` in stream-json mode and models the transcript |
| `SettingsStore` | `Settings/AppSettings.swift` | Loads and saves `settings.json`, and notifies observers |
| `SettingsSync` | `Settings/SettingsSync.swift` | Optional iCloud Drive sync of portable settings |
| `ShellIntents` | `Automation/ShellIntents.swift` | Shortcuts and Spotlight actions (see [Automation](automation.md)) |
| `ShellAutomation` | `Automation/ShellAutomation.swift` | The operations behind the intents: open, run and wait, send text, read output, focus, close |
| `SessionWaiters` | `Automation/SessionWaiters.swift` | Lets automation await a session's next finished command, agent event or close |
| `WidgetPublisher` | `Integrations/Widgets/WidgetPublisher.swift` | Writes the widget snapshot to the app group and reloads widget timelines |
| `SystemIntegration` | `App/SystemIntegration.swift` | `openTab`, Finder services, Dock menu, recent folders |
| `Intelligence` | `Integrations/Intelligence/Intelligence.swift` | Optional Apple Intelligence features: availability, per-feature gating, prompts and output checks |
| `OnDeviceModel` | `Integrations/Intelligence/OnDeviceModel.swift` | FoundationModels calls, one fresh session per request, with a timeout |

## Data flow for a command

1. You type into `InputEditorView` and press Return.
2. Shell writes the command to `$SHELL_APP_RUNTIME/<session>.cmd` and sends the private sequence `ESC [ 9001 ~` into the PTY.
3. The zsh widget reads the file and runs the command as if you had typed it, so history, aliases and `preexec` hooks all behave normally.
4. The integration reports `exec` (and later `prompt`, with exit status, cwd and branch) back over the control socket.
5. `TerminalSession` updates its state. The tab title, command-finished notifications and "copy last output" all key off these marks.

Completions use the same pattern. Shell writes the buffer to `<session>.req` and sends `ESC [ 9002 ~`. zsh runs its real completion system with `compadd` overridden to record candidates, and the results come back over the socket.

See [Shell integration](shell-integration.md) for the protocol details.

## Threading

- The app builds in Swift 6 language mode, so data-race safety is checked by the compiler. UI and model types are `@MainActor`. Most observable state uses Swift's `Observation` (`@Observable`).
- `ControlServer` accepts and reads on its own dispatch queue, then hops to the main actor to apply messages.
- Git, `gh`, `brew` and other external commands run as `Process` off the main thread. Their results are published back on the main actor.
- The native Claude view decodes Claude Code's stream-json output on the pipe's background queue and delivers it to the main actor in batches (about 30 per second). The transcript's markdown is parsed incrementally and cached.
- Timers and polling pause when nothing is visible: link detection runs only for visible panes, dashboard tiles read terminals only while the dashboard is open, and the Claude logo only animates in visible windows.

## Quitting

On Quit (and on SIGTERM, for example `killall Shell`), `AppDelegate.prepareToTerminate` does four things in order:

1. Saves the session layout and settings.
2. Closes every terminal surface. libghostty sends SIGHUP to each shell's process group and waits for the shell to exit, which is standard terminal behavior. Jobs you detached (`nohup`, `disown`, tmux) keep running.
3. Calls `ProcessCleanup.terminateDescendants()`. Everything else Shell started (native `claude` sessions and their MCP servers, `git`/`gh`, MCP inspectors, maintenance jobs) gets SIGTERM, then SIGKILL after a 2-second grace period.
4. Removes the control socket.

If a maintenance job is running, the quit confirmation says so.

A crash or `kill -9` skips all of this. Children whose stdin is a pipe from Shell (such as `claude`) usually exit on their own when the pipe closes.

## Design principles

- **Don't fork the terminal.** Anything inside the grid belongs to libghostty. Shell adds chrome around it instead of patching Ghostty.
- **Use the user's real tools.** Completions come from their zsh; the Claude view drives their `claude`; PR data comes from their `gh`. There's no parallel configuration to keep in sync.
- **Never break other terminals.** Hooks and integration code are no-ops outside Shell.
- **Leave dotfiles alone.** The integration is injected, not installed. Features that do edit config files (hooks, `.zshrc`) are opt-in, minimal and reversible.
