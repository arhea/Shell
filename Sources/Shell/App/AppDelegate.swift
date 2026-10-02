import AppKit
import GhosttyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ShortcutActionHandling, GhosttyRuntimeDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var controllers: [TerminalWindowController] = []
    weak var lastFocusedController: TerminalWindowController?
    private var settingsObserver: UUID?
    private var isTerminating = false
    private let servicesProvider = ServicesProvider()
    private var sigtermSource: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Make libghostty use our bundled resources even if we were launched
        // from inside another Ghostty (which would export its own path).
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path {
            setenv("GHOSTTY_RESOURCES_DIR", res, 1)
        }
        // Don't leak a parent terminal's identity into our shells.
        for key in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "GHOSTTY_BIN_DIR", "SHELL_APP_SESSION"] {
            unsetenv(key)
        }
        Self.installBrokenPipeHandler()
    }

    /// Writing to a child's stdin after it exits (Claude Code, an MCP server,
    /// the login helper) raises SIGPIPE, whose default action ends the app
    /// silently: no crash report, no error. With a handler installed the
    /// write fails with EPIPE instead, which the callers already catch.
    /// A no-op handler rather than SIG_IGN, for the reason in
    /// `installTerminationSignalHandler`.
    nonisolated static func installBrokenPipeHandler() {
        signal(SIGPIPE) { _ in }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppEnvironment.isRunningTests {
            // Unit tests only need the settings (in a temp folder) and the
            // theme: no windows, terminal engine, control socket, iCloud sync,
            // hotkey, scheduled jobs or session restore.
            _ = SettingsStore.shared
            ConfigController.shared.start()
            Self.removeStaleTestFolders()
            return
        }
        _ = SettingsStore.shared
        SettingsSync.shared.start()
        ShellIntegration.start()
        // Resolves appearance + theme and writes the libghostty config.
        ConfigController.shared.start()
        AppIcon.start()
        guard GhosttyRuntime.shared.start(configPath: ConfigController.configURL.path) else {
            let alert = NSAlert()
            alert.messageText = "Shell couldn't start the terminal engine"
            alert.informativeText = "libghostty failed to initialize. See Console.app for details."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        GhosttyRuntime.shared.delegate = self
        NotificationManager.shared.start()
        _ = ThemeLibrary.shared
        MainMenu.install()

        settingsObserver = SettingsStore.shared.observe { old, new in
            MainActor.assumeIsolated { AppDelegate.shared.settingsChanged(old: old, new: new) }
        }
        installTerminationSignalHandler()
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        HotkeyWindow.shared.configure()
        ScheduledMaintenance.configureAll()
        SoftwareUpdater.shared.start()
        GoService.shared.startMonitoring()
        Task.detached(priority: .background) {
            ClaudeAttachment.removeStaleFiles()
            AppDelegate.removeStaleScratchFiles()
        }

        if !SessionRestore.restore(into: self) {
            newWindow()
        }
        // After the first window settles, so the banner isn't lost in launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let controllers = AppDelegate.shared.controllers
                guard let controller = controllers.first(where: { $0.window?.isKeyWindow == true }) ?? controllers.first else { return }
                IntelligenceAnnouncement.showIfNeeded(in: controller)
            }
        }
        WidgetPublisher.shared.start()
    }

    /// Earlier test runs' throwaway support folders.
    private static func removeStaleTestFolders() {
        let tmp = FileManager.default.temporaryDirectory
        let current = SettingsStore.supportDirectory.lastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        where name.hasPrefix("ShellTests-") && name != current {
            // Leave folders of test runs that are still going (parallel runs).
            if let pid = pid_t(name.dropFirst("ShellTests-".count)), kill(pid, 0) == 0 || errno == EPERM { continue }
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    /// Snippet scripts and failed-command logs handed to commands in earlier
    /// sessions; a day is long past any command that could still read them.
    nonisolated static func removeStaleScratchFiles(olderThan age: TimeInterval = 86400) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        for folder in ["ShellSnippets", "shell-fixes"] {
            let dir = fm.temporaryDirectory.appendingPathComponent(folder, isDirectory: true)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? fm.removeItem(at: file) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = SessionRegistry.shared.all.contains { $0.surfaceView.needsConfirmQuit }
        let jobs = ScheduledMaintenance.all.filter(\.isRunning).map(\.job.title)
        guard running || !jobs.isEmpty, SettingsStore.shared.settings.confirmQuitWithRunningProcesses else {
            prepareToTerminate()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit Shell?"
        var detail = running ? "Processes are still running. Quitting will end them." : ""
        if !jobs.isEmpty {
            detail += (detail.isEmpty ? "" : "\n\n") + "\(jobs.joined(separator: ", ")) maintenance is running and will be stopped."
        }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            prepareToTerminate()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        prepareToTerminate()
    }

    private func prepareToTerminate() {
        guard !isTerminating else { return }
        isTerminating = true
        SessionRestore.save(controllers: controllers)
        SettingsStore.shared.saveNow()
        WidgetPublisher.shared.stop()
        // Hang up every shell (libghostty SIGHUPs its process group and waits)
        // and end native Claude sessions.
        for session in SessionRegistry.shared.all { session.close() }
        // Then stop anything else Shell started: claude and MCP servers, git/gh,
        // maintenance jobs.
        ProcessCleanup.terminateDescendants()
        ShellIntegration.stop()
        // Last, so the install helper isn't among the descendants stopped above.
        SoftwareUpdater.shared.installOnQuit()
    }

    /// `kill`/`killall Shell` sends SIGTERM, which would otherwise end the app
    /// without any cleanup. Treat it like Quit, skipping the confirmation.
    private func installTerminationSignalHandler() {
        // A no-op handler, not SIG_IGN: an ignored signal would be inherited
        // by every shell and child process across exec; a caught one resets.
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppDelegate.shared.prepareToTerminate()
                exit(0)
            }
        }
        source.resume()
        sigtermSource = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if controllers.isEmpty { newWindow() } else { controllers.first?.showWindow(nil) }
        }
        return true
    }

    /// Opening folders (Dock drop, `open -a Shell dir`) creates a tab there;
    /// `shellapp://` links (from the widgets) show a session or the dashboard.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == ShellAppURL.scheme {
                if let link = ShellAppURL(url) { open(link) }
                continue
            }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let dir = isDir.boolValue ? url.path : url.deletingLastPathComponent().path
            if let c = activeController {
                c.newTab(directory: dir)
                c.showWindow(nil)
            } else {
                newWindow(directory: dir)
            }
        }
    }

    func open(_ link: ShellAppURL) {
        switch link {
        case .session(let id):
            if let controller = ClaudeDashboard.controllers.first(where: { c in c.workspace.tabs.contains { $0.sessions[id] != nil } }),
               let session = SessionRegistry.shared.session(id) {
                controller.hideDashboard()
                controller.reveal(session)
                return
            }
            fallthrough // gone since the widget last refreshed
        case .dashboard:
            let controller = activeController ?? newWindow()
            controller.showWindow(nil)
            NSApp.activate()
            controller.showDashboard()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { buildDockMenu() }

    // MARK: Windows

    var activeController: TerminalWindowController? {
        if let key = NSApp.keyWindow?.windowController as? TerminalWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? TerminalWindowController { return main }
        return lastFocusedController ?? controllers.last
    }

    func newWindowController(frame: NSRect? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController.make(frame: frame)
        controller.onClose = { [weak self] c in
            self?.controllers.removeAll { $0 === c }
        }
        if frame == nil, let anchor = activeController?.window {
            controller.window?.setFrame(anchor.frame, display: false)
            controller.window?.setFrameTopLeftPoint(NSPoint(x: anchor.frame.minX + 24, y: anchor.frame.maxY - 24))
        }
        controllers.append(controller)
        return controller
    }

    @discardableResult
    func newWindow(directory: String? = nil) -> TerminalWindowController {
        let dir = directory ?? activeController?.defaultDirectory(for: activeController?.focusedSession) ?? NSHomeDirectory()
        let controller = newWindowController()
        controller.newTab(directory: dir)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusSelected()
        return controller
    }

    private func settingsChanged(old: AppSettings, new: AppSettings) {
        if old.shortcuts != new.shortcuts { MainMenu.install() }
        if old.hotkeyWindow != new.hotkeyWindow || old.hotkey != new.hotkey { HotkeyWindow.shared.configure() }
        if old.brewAutoUpdate != new.brewAutoUpdate { ScheduledMaintenance.homebrew.configure() }
        if old.agentStorageSchedule != new.agentStorageSchedule { ScheduledMaintenance.agentStorage.configure() }
        if old.worktreeCleanupSchedule != new.worktreeCleanupSchedule || old.worktreeCleanupPaths != new.worktreeCleanupPaths {
            ScheduledMaintenance.worktrees.configure()
        }
        if old.nodeAutoUpdate != new.nodeAutoUpdate { ScheduledMaintenance.node.configure() }
        if old.checkForUpdates != new.checkForUpdates { SoftwareUpdater.shared.configure() }
        for c in controllers { c.settingsChanged(old: old, new: new) }
        HotkeyWindow.shared.controller?.settingsChanged(old: old, new: new)
    }

    // MARK: Actions

    @objc func performShortcutAction(_ sender: Any?) {
        guard let action = ShortcutAction.from(sender: sender) else { return }
        perform(action)
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .newWindow: newWindow()
        case .settings: SettingsWindowController.shared.show()
        case .checkForUpdates: SoftwareUpdater.shared.checkInteractively()
        case .homebrew: SettingsWindowController.shared.show(pane: .homebrew)
        case .nodeSetup: SettingsWindowController.shared.show(pane: .node)
        case .zshSetup: SettingsWindowController.shared.show(pane: .shell)
        case .mcpServers: MCPManagerWindowController.show(for: activeController?.focusedSession)
        case .commandPalette:
            if let c = activeController { CommandPalette.show(for: c) }
        case .reloadConfig:
            ConfigController.shared.writeConfig()
            GhosttyRuntime.shared.reload(configPath: ConfigController.configURL.path)
        default:
            if let c = activeController {
                c.perform(action)
            } else if action == .newTab {
                newWindow()
            }
        }
    }

    /// Runs a command in a new tab of the active window so the user can watch
    /// it and answer prompts (sudo passwords, confirmations).
    func runInTerminal(_ command: String, title: String? = nil) {
        let controller = activeController ?? newWindow()
        let tab = controller.newTab(directory: NSHomeDirectory())
        tab.customTitle = title
        if let session = tab.focusedSession {
            if session.state == .unmanaged {
                session.pendingCommand = command
                session.flushPendingCommandWithoutIntegration()
            } else {
                session.pendingCommand = command
            }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func showAbout(_ sender: Any?) {
        let info = ghostty_info()
        let version = info.version.map { String(decoding: Data(bytes: $0, count: Int(info.version_len)), as: UTF8.self) } ?? "?"
        AboutWindowController.show(ghosttyVersion: version)
    }

    // MARK: GhosttyRuntimeDelegate

    private func controller(for surface: TerminalSurfaceView) -> (TerminalWindowController, TerminalTab, TerminalSession)? {
        for c in controllers + [HotkeyWindow.shared.controller].compactMap({ $0 }) {
            if let (tab, s) = c.session(for: surface) { return (c, tab, s) }
        }
        return nil
    }

    func ghosttyNewWindow(from surface: TerminalSurfaceView?) { newWindow() }

    func ghosttyNewTab(from surface: TerminalSurfaceView?) {
        if let surface, let (c, _, _) = controller(for: surface) { c.newTab() } else { activeController?.newTab() }
    }

    func ghosttyNewSplit(from surface: TerminalSurfaceView, direction: SplitDirection) {
        controller(for: surface)?.0.split(direction)
    }

    func ghosttyCloseSurface(_ surface: TerminalSurfaceView, processAlive: Bool) {
        guard let (c, tab, session) = controller(for: surface) else { return }
        c.closePane(session, in: tab, confirm: processAlive)
    }

    func ghosttyGotoSplit(from surface: TerminalSurfaceView, direction: ghostty_action_goto_split_e) {
        guard let (c, _, _) = controller(for: surface) else { return }
        switch direction {
        case GHOSTTY_GOTO_SPLIT_LEFT: c.focusPane(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: c.focusPane(.right)
        case GHOSTTY_GOTO_SPLIT_UP: c.focusPane(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: c.focusPane(.down)
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: c.cyclePane(-1)
        default: c.cyclePane(1)
        }
    }

    func ghosttyToggleSplitZoom(from surface: TerminalSurfaceView) {
        controller(for: surface)?.0.toggleZoom()
    }

    func ghosttyCloseAllWindows() {
        for c in controllers { c.window?.performClose(nil) }
    }
}
