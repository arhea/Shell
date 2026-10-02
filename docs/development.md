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

Test classes run in parallel: the scheme marks `ShellTests` parallelizable, so Xcode spreads classes across several clones of the test host (one per core by default), each with its own `ShellTests-<pid>` folder. The suite takes about 35 seconds on an M-series Mac. Add `-parallel-testing-enabled NO` to run serially, for example to read one test's log in order or to time individual tests.

`make coverage` (`scripts/coverage.sh`) runs the suite with coverage and prints line coverage per file, the total (same exclusions as CI) and the pass/fail counts. `FILTER=UI/Claude make coverage` limits the per-file list; extra arguments go to `xcodebuild`, e.g. `./scripts/coverage.sh -only-testing:ShellTests/ThemeTests`.

### Writing tests

- **Helpers.** `Tests/ShellTests/Support/TestSupport.swift` has `render(_:size:)` (lays out and draws a SwiftUI or AppKit view so its body runs), `withSettings` (changes settings and restores them), `makeTemporaryDirectory()` and `waitUntil`. `ClaudeViewTestSupport.swift` hosts views in an offscreen key window with `press(_:)` to trigger real SwiftUI button actions. `AppDelegate.shared.newWindowController()` and `newTab(directory:)` work in tests (no terminal engine); close every controller you open.
- **Stand-in tools.** Never run the real `claude`, `gh`, `brew`, `npm`, `go` or `zsh` completion. Services take an injectable executable, runner or environment; tests write small `#!/bin/sh` stand-ins into a temp folder with `writeExecutable(_:to:)` (see `ClaudeCodeSessionProcessTests`, `MCPTestSupport`, `GitFixtureSupport`). Don't write executables directly: macOS scans every new executable on its first run (about 170 ms each). `writeExecutable` hard-links one shared launcher that's scanned once and keeps the script beside it in a hidden `.<name>.body` file. Git runs only on throwaway repos with `GIT_CONFIG_GLOBAL=/dev/null`.
- **Your real state.** The test host shares Shell's bundle ID, so `UserDefaults.standard` is your real Shell preferences: code that writes defaults uses the `app.bethesdalabs.Shell.tests` suite under tests, and windows skip frame autosave. Files go under `SettingsStore.supportDirectory` or a temp folder, never `~`. Don't name temp folders `ShellTests-*`: launch removes stale ones.
- **SwiftUI tasks run in tests.** `.task` and `.onAppear` run inside `render`, so a view that scans real files or spawns tools when it appears takes injected data or checks `AppEnvironment.isRunningTests`.
- **Async tests.** `waitUntil` spins the run loop, which doesn't let main-actor tasks progress inside an `async` test; poll with `try await Task.sleep(for: .milliseconds(10))` there.
- **Fixed delays.** Wrap a fixed wait in app code (a debounce, a settle delay, a status poll, a kill grace period) in `AppEnvironment.wait(_:)`. It's a 20th as long under tests, so the suite doesn't sit through it. In tests, wait for the condition itself (`waitUntil`, `eventually`), not for a set time; if a test must wait out a delay, use `AppEnvironment.wait(delay)` plus a margin.
- **No sleeping until something is ready.** Have the stand-in signal readiness (print a line, write a file) and wait for that. A fixed sleep before acting is a flake under a loaded CI runner.
- **No modals.** `runModal`, `NSAlert`, `NSOpenPanel` and sheets hang the suite.
- **Unique names.** All test files share one module; keep helpers `private` or prefix them with their area.

### Test reports in CI

`.github/workflows/test.yml` runs the tests on every pull request and push to `main`. The `swift-test-report` action (`.github/actions/swift-test-report`) reads the `.xcresult` bundle and keeps a single, updated comment on the PR with pass, fail and skip counts plus line coverage. The job summary shows the same numbers, followed by detail for failures only: each failed test gets its message, source location, a code excerpt, any failing arguments, and its activity log. Passing and skipped tests are only counted. Failures also appear as inline annotations on the diff. Test files are left out of the coverage number.

To render the same report locally:

```bash
xcodebuild -project Shell.xcodeproj -scheme Shell test -resultBundlePath build/TestResults.xcresult -enableCodeCoverage YES
```

```bash
.github/actions/swift-test-report/report.py build/TestResults.xcresult --output build/test-report.md
```

After adding or removing source files, run `make project` (or `xcodegen generate`). The Xcode project is generated from `project.yml` and isn't checked in.

## App icon

The icon is an Icon Composer document, `Resources/AppIcon.icon`: two vector layers (`chevron.svg`, `cursor.svg`) with a light fill and a dark fill for each layer and for the background. Open it in Icon Composer (Xcode › Open Developer Tool) to edit it. The system renders the light, dark, tinted and clear styles from it. Xcode also generates `AppIcon.icns` from the light appearance, and the disk image uses that file as its volume icon.

Keep the SVG layers as filled shapes, not strokes: the layer fill replaces the SVG's colors, and on a stroked path it floods the whole enclosed area. To check every style without switching your Mac's appearance:

```bash
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon.icon \
  --export-image --output-file dark.png --platform macOS --rendition Dark --width 512 --height 512 --scale 1
```

Renditions: `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight`, `ClearDark`.

## Driving the app without Screen Recording

`shellctl debug …` drives a running Shell over the control socket, so you (or a coding agent) can inspect the app from a Shell terminal tab without granting Screen Recording:

| Command | What it does |
| --- | --- |
| `snapshot DIR` | Writes window PNGs plus a text report of tabs, panes, shell state and terminal contents |
| `action newTab` | Runs any `ShortcutAction` by its raw value |
| `github-select N` | Opens PR #N's detail pane in the GitHub tab (no number closes it) |
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
| `SHELL_APP_SUPPORT_DIR=/path` | Debug builds only: use this folder instead of `~/Library/Application Support/Shell`, so a dev build runs beside the installed app without sharing settings, history or session restore (`open --env SHELL_APP_SUPPORT_DIR=/tmp/shell-dev build/…/Shell.app`) |
| `SHELL_APP_DRY_RUN=1` | Jobs log the commands they would run instead of running them |
| `SHELL_APP_BREW=/path/to/fake-brew` | Swap in a stand-in `brew` |

## Code conventions

- **Swift 6 language mode (strict concurrency), macOS 26 SDK features are fine (no availability checks needed).** UI and model types are `@MainActor`. Prefer `@Observable` over `ObservableObject`. Cross-thread state is either confined to one queue (`ControlServer`, `StreamJSONDecoder`) or behind a lock; mark such types `@unchecked Sendable` with a comment saying which. Use `Task { @MainActor in … }` rather than `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` in new code.
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
