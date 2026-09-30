# Automation with Shortcuts

Shell exposes its tabs, panes and agents to the Shortcuts app through App Intents. Actions pass a **Shell Session** (one pane) from step to step, so a shortcut can open a tab, run a command, wait for it, and read the output. Everything also works from Spotlight, keyboard shortcuts bound in Shortcuts, and the `shortcuts run` command.

## Actions

| Action | Inputs | Returns | Brings Shell forward |
| --- | --- | --- | --- |
| New Shell Tab | Folder, Command, In New Window | Session | Yes |
| Start Claude Code in Shell | Folder, Prompt | Session | Yes |
| Run Command in Shell | Command, Session (or a new tab in Folder), Wait for Completion, Timeout | Command Result | No |
| Send Text to Shell Session | Text, Session, Press Return | Session | No |
| Get Shell Session Output | Session, Output (last command's output, visible screen, entire scrollback) | Text | No |
| Get Current Shell Session | | Session | No |
| Find Shell Sessions | Filters on title, directory, git branch, agent status, busy | Sessions | No |
| Show Shell Session | Session | | Yes |
| Close Shell Session | Session | | No |
| Wait for Agent in Shell | Session, Until (needs input, finishes, either), Timeout | Agent Update | No |
| Perform Shell Action | A menu command (New Window, Split Right, Claude Dashboard, …) | | Yes |

Actions that don't bring Shell forward still need it running. Shortcuts launches it in the background if it isn't.

### Session properties

A **Shell Session** has: Title, Directory, Git Branch, Running Command, Last Command, Last Exit Code, Is Busy, Is Focused, Agent Status (No Agent, Working, Needs Input, Finished), Agent, and Agent Message. Values are a snapshot taken when the action runs.

A **Command Result** has: Command, Exit Code, Succeeded, Output, Duration (Seconds) and Session.

An **Agent Update** has: Status, Agent, Message and Session.

Session IDs survive a relaunch when session restore is on, so a shortcut that saved a session can still find it afterwards. A pane that has been closed resolves to nothing, and actions that need it fail with "That Shell session is no longer open."

## Behavior

- **Run Command** sends the command through Shell's zsh integration, the same path as the native prompt, so history, aliases and command blocks behave normally. In a new tab, the command runs once the shell reaches its first prompt.
- **Wait for Completion** returns when the shell is back at a prompt. It needs the zsh integration; in a session without it (another shell, or integration off) the action fails instead of guessing. It also fails if a command is already running in that session. Output is the same text as *Copy Last Output* (⌥⇧⌘C), so it comes from the scrollback and can be empty after the screen is cleared.
- **Send Text** at an idle zsh prompt runs the text as a command. Otherwise it's pasted into whatever is running, such as a Claude Code or Codex prompt. If an agent is working in that pane, Shortcuts asks you to confirm first. The native Claude Code view doesn't accept text from automation.
- **Wait for Agent** needs Shell's agent hooks (Settings › Claude & Codex › Install). It returns at once if the agent is already in the requested state; otherwise it waits for the next matching hook event.
- **Close Shell Session** asks before closing a pane with a running process.
- Timeouts default to 10 minutes and can go up to 24 hours.

## Examples

**Run the tests and notify me when they fail.**

1. Run Command in Shell: `make test`, Session empty, Folder = your repo, Wait for Completion on.
2. If *Command Result › Succeeded* is false: Show Notification with *Command Result › Output*.

**Ping my phone when Claude needs me.**

1. Start Claude Code in Shell: Folder = your repo, Prompt = the task.
2. Wait for Agent in Shell: Session = the result of step 1, Until = Needs Input or Finishes, Timeout = 3600.
3. Send Notification (or a Pushcut/ntfy request) with *Agent Update › Message*.

**Answer every waiting agent.**

1. Find Shell Sessions where Agent Status is Needs Input.
2. Repeat with each: Show Shell Session, then Ask for Input, then Send Text to Shell Session.

**From the terminal.** Save any of the above as a shortcut, then run it with `shortcuts run "Shortcut Name"`.

## Security

These actions can type into your panes, run commands, and read terminal output, including scrollback that may contain secrets. That's the same trust level as Shortcuts' own *Run Shell Script* action, and every shortcut that uses them is one you created or installed. Review shared shortcuts before running them.

## For contributors

The intents live in `Sources/Shell/Automation/`:

| File | What it holds |
| --- | --- |
| `ShellIntents.swift` | The `AppIntent` types, their enums, and the `AppShortcutsProvider` |
| `SessionEntity.swift` | `SessionEntity`, `SessionQuery` (find/filter/sort), and the result entities |
| `ShellAutomation.swift` | The operations the intents call: open, run, send text, read output, focus, close, wait for agent |
| `SessionWaiters.swift` | Suspends until a session reports a finished command, an agent event, or closes |

`TerminalSession` calls `SessionWaiters.shared.notify` from `promptReady` (only after a command ran), `agentEvent` and `close`. Keep intents thin: put behavior in `ShellAutomation` so other automation surfaces can reuse it. The App Intents metadata extractor needs `AppEnum` display representations and the query's `properties` and `sortingOptions` as literal `static let` builders.
