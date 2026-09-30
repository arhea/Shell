# Development

## Workflow

1. Run `make bootstrap` once (see [Building](building.md)).
2. Open `Shell.xcodeproj` in Xcode, or work from the command line:

```bash
./scripts/build.sh
```

```bash
make run
```

```bash
xcodebuild -project Shell.xcodeproj -scheme Shell test
```

Tests run inside Shell (it's the test host), but they never touch your real files: `AppEnvironment.isRunningTests` makes launch skip windows, the terminal engine, the control socket, iCloud sync, the hotkey, scheduled jobs and session restore, and points `SettingsStore.supportDirectory` (settings, the Ghostty config, history, session restore, themes) at a throwaway `$TMPDIR/ShellTests-<pid>` folder. `TestIsolationTests` checks this.

After adding or removing source files, run `make project` (or `xcodegen generate`). The Xcode project is generated from `project.yml` and isn't checked in.

## Driving the app without Screen Recording

`shellctl debug …` drives a running Shell over the control socket, so you (or a coding agent) can inspect the app from a Shell terminal tab without granting Screen Recording:

| Command | What it does |
| --- | --- |
| `snapshot DIR` | Writes window PNGs plus a text report of tabs, panes, shell state and terminal contents |
| `action newTab` | Runs any `ShortcutAction` by its raw value |
| `type TEXT`, `submit`, `complete` | Drive the native prompt |
| `key TEXT` | Send raw text to the focused terminal (for example `q` to quit a pager; `\r` for Return) |
| `set key=value` | Change one of a handful of settings used in testing |
| `brew-run`, `node-run` | Run a maintenance job now |
| `node-refresh` | Rescan the Node toolchain and add a summary to the snapshot trace |
| `settings pane` | Open a Settings pane |
| `sheet TEXT` | Complete a pending prompt sheet |
| `tree TITLE` | Dump a window's view hierarchy |
| `quit` | Quit the app |

For example:

```bash
"$SHELL_APP_CTL" debug snapshot /tmp/shell-snap
```

The Metal terminal renders into snapshots. SwiftUI `NavigationSplitView` content (the Settings window) does not.

## Testing maintenance jobs safely

| Variable | Effect |
| --- | --- |
| `SHELL_APP_DRY_RUN=1` | Jobs log the commands they would run instead of running them |
| `SHELL_APP_BREW=/path/to/fake-brew` | Swap in a stand-in `brew` |

## Code conventions

- **Swift 6 language mode (strict concurrency), macOS 15 SDK features are fine.** UI and model types are `@MainActor`. Prefer `@Observable` over `ObservableObject`. Cross-thread state is either confined to one queue (`ControlServer`, `StreamJSONDecoder`) or behind a lock; mark such types `@unchecked Sendable` with a comment saying which. Use `Task { @MainActor in … }` rather than `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` in new code.
- **Views read narrow state.** Reading `SettingsStore.shared.settings` in a view body re-renders it on every settings change; the native Claude view reads `ChatPreferences.shared` instead. App-wide models are plain `let x = X.shared` references, not `@State`.
- **Shared helpers.** Run external tools with `ProcessRunner` (drains stdout and stderr together, with a timeout and cancellation) or `GitRepository.run`; quote command lines with `ShellQuote`; share repositories through `GitRepository.discover` (one instance and FSEvents stream per checkout, reference-counted: balance each `discover` with one `stop()`).
- **Logging.** Use the per-area loggers in `Log` (`app`, `settings`, `claude`, `git`, `control`, `process`) and log failed writes and launches instead of dropping them with `try?`.
- **Keep the main thread free.** Run `git`, `gh`, `brew`, filesystem scans and anything network-bound off the main actor, and publish results back. Per-keystroke and per-frame paths (the input editor, link detection, surface callbacks) should do O(visible) work, not O(history) or O(scrollback).
- **Shortcuts are data.** Add new commands as a `ShortcutAction` case with a title, category and default. The menu bar, command palette and Settings › Keyboard Shortcuts are built from it.
- **Settings are additive.** New `AppSettings` properties need a default value. Older `settings.json` files are merged over the defaults, so no migration is needed.
- **Don't patch Ghostty.** If something needs a libghostty change, send it upstream first.
- **Integration code must be a no-op outside Shell.** Anything installed into a user's `~/.claude`, `~/.codex` or `.zshrc` must check for `$SHELL_APP_SOCKET` and exit silently otherwise.

## Logging

Shell logs through `OSLog` under the subsystem `app.bethesdalabs.Shell`:

```bash
log stream --predicate 'subsystem == "app.bethesdalabs.Shell"' --level debug
```

Background maintenance jobs also write to `~/Library/Logs/Shell/`.
