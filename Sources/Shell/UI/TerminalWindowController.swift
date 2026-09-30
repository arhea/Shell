import AppKit
import GhosttyKit
import Observation
import SwiftUI

@MainActor
@Observable
final class WindowChromeState {
    var isFullScreen = false
    var showActivity = false
    /// The window is on screen and not fully covered (drives animations).
    var isVisible = true
}

/// A terminal window that handles ⌃Tab tab cycling before the terminal sees it.
final class TerminalWindow: NSWindow {
    weak var terminalController: TerminalWindowController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 0x30 /* tab */,
           event.modifierFlags.intersection([.control, .command, .option]) == .control {
            if event.modifierFlags.contains(.shift) { terminalController?.selectRelativeTab(-1) } else { terminalController?.selectRelativeTab(1) }
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Root content view: arranges the tab bar or sidebar and the terminal area.
@MainActor
final class WindowContentView: NSView {
    var tabBar: NSView?
    var sidebar: NSView?
    var titleBar: NSView?
    /// Right-hand file explorer (native Claude view in a git repository).
    var explorer: NSView?
    var explorerWidth: CGFloat = 280
    /// A notice across the top of the terminal area (the Apple Intelligence announcement).
    var banner: NSView?
    static let bannerHeight: CGFloat = 46
    let terminalArea = NSView()
    var sidebarWidth: CGFloat = 240
    var vertical = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        terminalArea.wantsLayer = true
        addSubview(terminalArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let barHeight: CGFloat = 38
        if vertical {
            sidebar?.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: b.height)
            titleBar?.frame = NSRect(x: sidebarWidth, y: 0, width: b.width - sidebarWidth, height: barHeight)
            terminalArea.frame = NSRect(x: sidebarWidth, y: barHeight, width: b.width - sidebarWidth, height: b.height - barHeight)
        } else {
            let showBar = tabBar != nil && tabBar?.isHidden == false
            tabBar?.frame = NSRect(x: 0, y: 0, width: b.width, height: barHeight)
            let top = showBar ? barHeight : 28
            terminalArea.frame = NSRect(x: 0, y: top, width: b.width, height: b.height - top)
        }
        if let banner {
            let h = min(WindowContentView.bannerHeight, terminalArea.frame.height / 2)
            banner.frame = NSRect(x: terminalArea.frame.minX, y: terminalArea.frame.minY, width: terminalArea.frame.width, height: h)
            terminalArea.frame.origin.y += h
            terminalArea.frame.size.height -= h
        }
        if let explorer, !explorer.isHidden {
            let w = min(explorerWidth, max(160, terminalArea.frame.width - 320))
            var area = terminalArea.frame
            area.size.width -= w
            terminalArea.frame = area
            explorer.frame = NSRect(x: area.maxX, y: area.minY, width: w, height: area.height)
        }
        for sub in terminalArea.subviews { sub.frame = terminalArea.bounds }
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, ShortcutActionHandling, NSMenuItemValidation {
    let workspace = Workspace()
    let chrome = WindowChromeState()
    private var paneViews: [UUID: PaneView] = [:]
    private var containers: [UUID: SplitContainerView] = [:]
    private var contentView: WindowContentView!
    private var tabBarHost: NSView?
    private var sidebarHost: NSView?
    private var titleBarHost: NSView?
    private var observers: [NSObjectProtocol] = []
    private var explorerHost: NSHostingView<AnyView>?
    private var explorerOwner: String?
    private var explorerObservedKey: String?
    /// Bumped on each registration so an older, superseded observation that
    /// fires later is ignored instead of registering yet another one.
    private var explorerObservationGeneration = 0
    private var terminalRepos: [UUID: (directory: String, repo: GitRepository?)] = [:]
    private var discoveringRepos: Set<UUID> = []
    private var worktreeModels: [String: WorktreesModel] = [:]
    private var pullRequestModels: [String: PullRequestsModel] = [:]
    private var actionsModels: [String: ActionsModel] = [:]
    private var explorerDragBase: CGFloat?
    private var sidebarDragBase: CGFloat?
    private var dashboardHost: NSHostingView<ClaudeDashboardView>?

    var onClose: ((TerminalWindowController) -> Void)?

    // MARK: Creation

    static func make(frame: NSRect? = nil) -> TerminalWindowController {
        let window = TerminalWindow(
            contentRect: frame ?? NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 260)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        if frame == nil { window.center() }
        let controller = TerminalWindowController(window: window)
        window.terminalController = controller
        return controller
    }

    override init(window: NSWindow?) {
        super.init(window: window)
        guard let window else { return }
        window.delegate = self
        contentView = WindowContentView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        rebuildChrome()
        applyTheme()

        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.chrome.isFullScreen = true }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.chrome.isFullScreen = false }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .nativeClaudeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateExplorer() }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Chrome

    func rebuildChrome() {
        let s = SettingsStore.shared.settings
        tabBarHost?.removeFromSuperview()
        sidebarHost?.removeFromSuperview()
        titleBarHost?.removeFromSuperview()
        tabBarHost = nil
        sidebarHost = nil
        titleBarHost = nil

        contentView.vertical = s.tabBarStyle == .vertical
        contentView.sidebarWidth = CGFloat(s.sidebarWidth)
        if contentView.vertical {
            let sidebar = NSHostingView(rootView: VerticalTabSidebar(controller: self, workspace: workspace, chrome: chrome))
            let title = NSHostingView(rootView: TitleBarView(controller: self, workspace: workspace))
            contentView.addSubview(sidebar)
            contentView.addSubview(title)
            sidebarHost = sidebar
            titleBarHost = title
            contentView.sidebar = sidebar
            contentView.titleBar = title
            contentView.tabBar = nil
        } else {
            let bar = NSHostingView(rootView: HorizontalTabBar(controller: self, workspace: workspace, chrome: chrome))
            contentView.addSubview(bar)
            tabBarHost = bar
            contentView.tabBar = bar
            contentView.sidebar = nil
            contentView.titleBar = nil
        }
        contentView.needsLayout = true
    }

    func applyTheme() {
        let t = ConfigController.shared.theme
        let opacity = SettingsStore.shared.settings.backgroundOpacity
        window?.isOpaque = opacity >= 1
        window?.backgroundColor = opacity >= 1 ? t.background.nsColor : t.background.nsColor.withAlphaComponent(opacity)
        window?.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        contentView.layer?.backgroundColor = window?.backgroundColor.cgColor
        let divider = t.background.mixed(with: t.foreground, 0.16).nsColor
        for c in containers.values { c.dividerColor = divider }
        for p in paneViews.values { p.applyTheme() }
        // SwiftUI chrome observes ConfigController.theme and re-renders itself.
        if opacity < 1, SettingsStore.shared.settings.backgroundBlur, let window, let app = GhosttyRuntime.shared.app {
            ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
        }
    }

    // MARK: Right sidebar (files, worktrees)

    /// Shows the right sidebar for the focused pane's repository: always
    /// available in native Claude sessions, and in terminal panes when toggled
    /// on (⌃⌘B).
    func updateExplorer() {
        pruneTerminalRepos()
        guard !workspace.showsDashboard, let session = focusedSession else { return hideExplorer() }
        let claude = session.nativeClaude
        let repo: GitRepository?
        let visible: Bool
        if let claude {
            repo = claude.repository
            visible = claude.showExplorer && !claude.needsTrust
        } else {
            // Discover the pane's repo so a GitHub remote can open the sidebar automatically.
            repo = terminalRepository(for: session)
            let s = SettingsStore.shared.settings
            let automatic = s.terminalSidebar || (s.sidebarAutoShowGitHub && repo?.github != nil)
            visible = session.sidebarChoice ?? automatic
            if session.showSidebar != (visible && repo != nil) { session.showSidebar = visible && repo != nil }
        }
        // Re-run when the repository, the toggle or the directory changes.
        let key = claude.map { "claude-\(ObjectIdentifier($0).hashValue)" } ?? "term-\(session.id)"
        if explorerObservedKey != key {
            explorerObservedKey = key
            explorerObservationGeneration &+= 1
            let generation = explorerObservationGeneration
            withObservationTracking {
                if let claude {
                    _ = claude.repository
                    _ = claude.showExplorer
                } else {
                    _ = session.sidebarChoice
                    _ = session.workingDirectory
                }
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, generation == self.explorerObservationGeneration else { return }
                        self.explorerObservedKey = nil
                        self.updateExplorer()
                    }
                }
            }
        }
        guard visible, let repo else { return hideExplorer() }
        let owner = key + "|" + repo.root.path
        if explorerOwner != owner {
            explorerHost?.removeFromSuperview()
            let tree = FileTreeModel(root: repo.root, expanded: claude?.explorerExpanded ?? session.sidebarExpanded)
            tree.onExpandedChange = { [weak claude, weak session] set in
                if let claude { claude.explorerExpanded = set } else { session?.sidebarExpanded = set }
            }
            let worktreeKey = repo.mainWorktree?.path ?? repo.root.path
            let worktrees = worktreeModels[worktreeKey] ?? WorktreesModel(repoRoot: worktreeKey, environment: MCPManager.defaultEnvironment())
            worktreeModels[worktreeKey] = worktrees
            let context = SidebarContext(
                directory: claude?.directory ?? session.workingDirectory ?? repo.root.path,
                insert: claude != nil
                    ? { [weak claude] text in claude?.insertIntoPrompt?(text) }
                    : { [weak session] text in session?.insertIntoEditor(text) },
                isClaude: claude != nil,
                openTab: { [weak self] dir, command in
                    guard let self else { return }
                    let tab = self.newTab(directory: dir)
                    if let command { tab.focusedSession?.pendingCommand = command }
                },
                switchTo: { [weak self] dir in self?.switchToDirectory(dir) })
            let env = MCPManager.defaultEnvironment()
            let view = RightSidebarView(
                context: context, repo: repo, tree: tree, worktrees: worktrees,
                pullRequests: { [weak self] _ in
                    if let m = self?.pullRequestModels[worktreeKey] { return m }
                    let m = PullRequestsModel(repoRoot: worktreeKey, environment: env)
                    m.isPaused = self?.chrome.isVisible == false
                    self?.pullRequestModels[worktreeKey] = m
                    return m
                },
                actions: { [weak self] _ in
                    if let m = self?.actionsModels[worktreeKey] { return m }
                    let m = ActionsModel(repoRoot: worktreeKey, environment: env)
                    m.isPaused = self?.chrome.isVisible == false
                    self?.actionsModels[worktreeKey] = m
                    return m
                },
                onResize: { [weak self] delta in self?.resizeExplorer(by: delta) },
                onResizeEnded: { [weak self] in self?.finishExplorerResize() },
                onClose: { [weak claude, weak session] in
                    if let claude {
                        claude.showExplorer = false
                        SettingsStore.shared.settings.claudeFileExplorer = false
                    } else if let session {
                        session.sidebarChoice = false
                    }
                })
            let host = NSHostingView(rootView: AnyView(view))
            host.sizingOptions = []
            contentView.addSubview(host)
            explorerHost = host
            explorerOwner = owner
            contentView.explorer = host
            if SettingsStore.shared.settings.sidebarTab == .worktrees { worktrees.refreshIfNeeded() }
        }
        contentView.explorerWidth = CGFloat(SettingsStore.shared.settings.claudeExplorerWidth)
        contentView.needsLayout = true
    }

    private func hideExplorer() {
        guard explorerHost != nil else { return }
        explorerHost?.removeFromSuperview()
        explorerHost = nil
        explorerOwner = nil
        contentView.explorer = nil
        contentView.needsLayout = true
    }

    /// Brings forward a pane already in `dir` (in any window), else opens a new tab there.
    func switchToDirectory(_ dir: String) {
        let target = URL(fileURLWithPath: dir).standardizedFileURL.path
        for controller in AppDelegate.shared.controllers {
            for tab in controller.workspace.tabs {
                for session in tab.orderedSessions {
                    guard let cwd = session.nativeClaude?.directory ?? session.workingDirectory else { continue }
                    let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
                    if path == target || path.hasPrefix(target + "/") {
                        controller.reveal(session)
                        return
                    }
                }
            }
        }
        newTab(directory: dir)
    }

    /// Toggles the sidebar for the focused pane (terminal or Claude).
    func toggleSidebar() {
        guard let session = focusedSession else { return }
        if let claude = session.nativeClaude {
            claude.showExplorer.toggle()
            SettingsStore.shared.settings.claudeFileExplorer = claude.showExplorer
        } else {
            session.sidebarChoice = !session.showSidebar
        }
        updateExplorer()
    }

    /// The repository a terminal pane's directory is in, discovered in the
    /// background and cached until the pane leaves it.
    private func terminalRepository(for session: TerminalSession) -> GitRepository? {
        let dir = session.workingDirectory ?? NSHomeDirectory()
        let cached = terminalRepos[session.id]
        if let cached, cached.directory == dir { return cached.repo }
        // Still inside the same repository: keep it.
        if let repo = cached?.repo, dir == repo.root.path || dir.hasPrefix(repo.root.path + "/") {
            terminalRepos[session.id] = (dir, repo)
            return repo
        }
        guard !discoveringRepos.contains(session.id) else { return cached?.repo }
        discoveringRepos.insert(session.id)
        Task { [weak self] in
            let repo = await GitRepository.discover(from: dir, environment: MCPManager.defaultEnvironment())
            guard let self else { repo?.stop(); return }
            self.discoveringRepos.remove(session.id)
            self.terminalRepos[session.id]?.repo?.stop()
            self.terminalRepos[session.id] = (dir, repo)
            self.updateExplorer()
        }
        return cached?.repo
    }

    private func pruneTerminalRepos() {
        let live = Set(workspace.tabs.flatMap { $0.sessions.keys })
        for (id, entry) in terminalRepos where !live.contains(id) {
            entry.repo?.stop()
            terminalRepos[id] = nil
        }
        // Sidebar models (worktrees, PRs, Actions polling) for repos no pane here uses any more.
        let repos = terminalRepos.values.compactMap(\.repo)
            + workspace.tabs.flatMap { $0.sessions.values.compactMap { $0.nativeClaude?.repository } }
        let keys = Set(repos.map { $0.mainWorktree?.path ?? $0.root.path })
        for key in worktreeModels.keys where !keys.contains(key) { worktreeModels[key] = nil }
        for key in pullRequestModels.keys where !keys.contains(key) { pullRequestModels[key] = nil }
        for key in actionsModels.keys where !keys.contains(key) { actionsModels[key] = nil }
    }

    private func resizeExplorer(by delta: CGFloat) {
        if explorerDragBase == nil { explorerDragBase = contentView.explorerWidth }
        contentView.explorerWidth = min(max((explorerDragBase ?? 280) + delta, 180), 640)
        contentView.needsLayout = true
    }

    private func finishExplorerResize() {
        explorerDragBase = nil
        SettingsStore.shared.settings.claudeExplorerWidth = Double(contentView.explorerWidth)
    }

    // MARK: Left tab sidebar

    /// Live resize while dragging the tab sidebar's edge (`delta` = total drag distance).
    func resizeTabSidebar(by delta: CGFloat) {
        if sidebarDragBase == nil { sidebarDragBase = contentView.sidebarWidth }
        contentView.sidebarWidth = min(max((sidebarDragBase ?? 240) + delta, 160), 480)
        contentView.needsLayout = true
    }

    func finishTabSidebarResize() {
        sidebarDragBase = nil
        SettingsStore.shared.settings.sidebarWidth = Double(contentView.sidebarWidth.rounded())
    }

    func settingsChanged(old: AppSettings, new: AppSettings) {
        if old.tabBarStyle != new.tabBarStyle {
            rebuildChrome()
        } else if old.sidebarWidth != new.sidebarWidth, sidebarDragBase == nil {
            // Every window follows (and Settings' slider works) without rebuilding the chrome.
            contentView.sidebarWidth = CGFloat(new.sidebarWidth)
            contentView.needsLayout = true
        }
        if old.inputEditor != new.inputEditor || old.promptStyle != new.promptStyle || old.claudeLaunchMode != new.claudeLaunchMode
            || old.claudeRemoteControl != new.claudeRemoteControl {
            for tab in workspace.tabs {
                for s in tab.sessions.values { ShellIntegration.refreshPrompt(in: s, settings: new) }
            }
        }
        // Sidebar state, schedules and the like: don't re-theme every pane.
        guard !new.differsOnlyInNonVisualState(from: old) else { return }
        applyTheme()
        for p in paneViews.values { p.settingsChanged() }
        focusSelected()
    }

    // MARK: Tabs

    func defaultDirectory(for anchor: TerminalSession?) -> String? {
        let s = SettingsStore.shared.settings
        switch s.newTabDirectory {
        case .inherit: return anchor?.workingDirectory ?? NSHomeDirectory()
        case .home: return NSHomeDirectory()
        case .custom: return (s.customDirectory as NSString).expandingTildeInPath
        }
    }

    @discardableResult
    func newTab(directory: String? = nil, command: String? = nil, sessionID: UUID? = nil, inGroup group: TabGroup? = nil,
                select: Bool = true) -> TerminalTab {
        let anchor = workspace.selectedTab
        let dir = directory ?? defaultDirectory(for: anchor?.focusedSession)
        let session = makeSession(directory: dir, command: command, id: sessionID)
        let tab = TerminalTab(session: session)
        if let group {
            let last = workspace.tabs.last { $0.groupID == group.id }
            workspace.insert(tab, after: last)
            tab.groupID = group.id
        } else if SettingsStore.shared.settings.newTabPlacement == .afterCurrent {
            workspace.insert(tab, after: anchor)
        } else {
            workspace.tabs.append(tab)
            if let last = workspace.tabs.dropLast().last, last.groupID != nil { tab.groupID = nil }
        }
        workspace.normalizeGroups()
        if select || workspace.selectedTabID == nil { self.select(tab) }
        return tab
    }

    func newTab(inGroup group: TabGroup) { newTab(inGroup: group, select: true) }

    func makeSession(directory: String?, command: String? = nil, id: UUID? = nil) -> TerminalSession {
        let session = TerminalSession(id: id ?? UUID(), workingDirectory: directory, command: command)
        let pane = PaneView(session: session)
        pane.onFocus = { [weak self] pane in self?.paneDidFocus(pane) }
        wireBroadcast(pane)
        session.onRequestFocus = { [weak self, weak session] in
            guard let self, let session else { return }
            self.reveal(session)
        }
        paneViews[session.id] = pane
        return session
    }

    /// Mirrors typing and submitted commands to sibling panes when the tab has
    /// broadcast input enabled (iTerm2's ⌥⌘I).
    private func wireBroadcast(_ pane: PaneView) {
        let sessionID = pane.session.id
        pane.session.surfaceView.broadcastTargets = { [weak self] in
            guard let self, let tab = self.workspace.tabs.first(where: { $0.sessions[sessionID] != nil }), tab.broadcastInput else { return [] }
            return tab.sessions.values.filter { $0.id != sessionID }.map(\.surfaceView)
        }
        pane.editor.onSubmit = { [weak self] command in
            guard let self, let tab = self.workspace.tabs.first(where: { $0.sessions[sessionID] != nil }), tab.broadcastInput else { return }
            for other in tab.sessions.values where other.id != sessionID {
                if other.state == .idle {
                    other.submit(command: command)
                } else {
                    other.surfaceView.sendText(command)
                    other.surfaceView.writeRaw("\r")
                }
            }
        }
    }

    /// Adopts an existing tab (moved from another window).
    func adopt(_ tab: TerminalTab, panes: [UUID: PaneView]) {
        for (id, pane) in panes {
            paneViews[id] = pane
            pane.onFocus = { [weak self] pane in self?.paneDidFocus(pane) }
            wireBroadcast(pane)
            pane.session.onRequestFocus = { [weak self, weak session = pane.session] in
                guard let self, let session else { return }
                self.reveal(session)
            }
        }
        tab.groupID = nil
        workspace.tabs.append(tab)
        select(tab)
    }

    /// Shows `tab`. Leaves the Claude dashboard up when `keepDashboard` is set
    /// (a tab closed or moved away underneath it).
    func select(_ tab: TerminalTab, keepDashboard: Bool = false) {
        workspace.selectedTabID = tab.id
        if !keepDashboard { workspace.showsDashboard = false }
        if let gid = tab.groupID, let group = workspace.group(gid), group.isCollapsed, !workspace.showsDashboard { group.isCollapsed = false }
        syncTerminalArea()
        focusSelected()
        updateExplorer()
    }

    func selectRelativeTab(_ delta: Int) {
        guard let idx = workspace.selectedIndex, !workspace.tabs.isEmpty else { return }
        let next = (idx + delta + workspace.tabs.count) % workspace.tabs.count
        select(workspace.tabs[next])
    }

    func selectTab(at index: Int) {
        guard workspace.tabs.indices.contains(index) else { return }
        select(workspace.tabs[index])
    }

    func closeTab(_ tab: TerminalTab, confirm: Bool = true) {
        if confirm, tab.sessions.values.contains(where: { $0.surfaceView.needsConfirmQuit }) {
            confirmClose(message: "Close this tab?", info: "A process is still running in this tab.") { [weak self] in
                self?.closeTab(tab, confirm: false)
            }
            return
        }
        for id in tab.sessions.keys {
            paneViews[id]?.removeFromSuperview()
            paneViews[id] = nil
        }
        containers[tab.id]?.removeFromSuperview()
        containers[tab.id] = nil
        tab.closeAll()
        workspace.remove(tab)
        if workspace.tabs.isEmpty {
            window?.close()
            return
        }
        if let sel = workspace.selectedTab { select(sel, keepDashboard: true) }
    }

    func closeOtherTabs(except keep: TerminalTab) {
        for tab in workspace.tabs where tab.id != keep.id { closeTab(tab, confirm: false) }
    }

    func closeGroup(_ group: TabGroup) {
        for tab in workspace.closeGroupTabs(group) { closeTab(tab, confirm: false) }
    }

    func duplicate(_ tab: TerminalTab) {
        let t = newTab(directory: tab.focusedSession?.workingDirectory)
        t.groupID = tab.groupID
        workspace.normalizeGroups()
    }

    func renameTab(_ tab: TerminalTab) {
        let context = Self.namingContext(for: [tab])
        prompt(title: "Rename Tab", message: "Leave empty to use the automatic title.", value: tab.customTitle ?? tab.title,
               suggest: tabNameSuggester(context: context, group: false)) { name in
            tab.customTitle = name.isEmpty ? nil : name
        }
    }

    func newGroup(with tab: TerminalTab) {
        let context = Self.namingContext(for: [tab])
        prompt(title: "New Tab Group", message: "Name the group.", value: "",
               suggest: tabNameSuggester(context: context, group: true)) { [weak self] name in
            self?.workspace.createGroup(name: name, with: tab)
        }
    }

    func renameGroup(_ group: TabGroup) {
        let context = Self.namingContext(for: workspace.tabs.filter { $0.groupID == group.id })
        prompt(title: "Rename Group", message: "", value: group.name,
               suggest: tabNameSuggester(context: context, group: true)) { name in group.name = name }
    }

    /// Asks Apple Intelligence for a name, when that feature is on.
    private func tabNameSuggester(context: String, group: Bool) -> (() async -> String?)? {
        guard Intelligence.isEnabled(.tabNames), !context.isEmpty else { return nil }
        return { await Intelligence.tabName(context: context, group: group) }
    }

    /// What each tab's panes are doing, as plain text for naming.
    static func namingContext(for tabs: [TerminalTab]) -> String {
        var lines: [String] = []
        for (i, tab) in tabs.enumerated() {
            if tabs.count > 1 { lines.append("Tab \(i + 1):") }
            for session in tab.orderedSessions {
                lines.append("- Folder: \(session.abbreviatedDirectory)")
                if let branch = session.gitBranch { lines.append("  Git branch: \(branch)") }
                if let cmd = session.runningCommand { lines.append("  Running: \(cmd.prefix(200))") }
                if let cmd = session.lastCommand { lines.append("  Last command: \(cmd.prefix(200))") }
                if let claude = session.nativeClaude, let ask = claude.items.first(where: { $0.kind == .user })?.text {
                    lines.append("  Asked Claude: \(ask.prefix(300))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Banner

    func showBanner<Content: View>(_ view: Content) {
        hideBanner()
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        contentView.addSubview(host)
        contentView.banner = host
        contentView.needsLayout = true
    }

    func hideBanner() {
        contentView.banner?.removeFromSuperview()
        contentView.banner = nil
        contentView.needsLayout = true
    }

    func moveTabToNewWindow(_ tab: TerminalTab) {
        guard workspace.tabs.count > 1 else { return }
        var panes: [UUID: PaneView] = [:]
        for id in tab.sessions.keys {
            if let p = paneViews.removeValue(forKey: id) {
                p.removeFromSuperview()
                panes[id] = p
            }
        }
        containers[tab.id]?.removeFromSuperview()
        containers[tab.id] = nil
        workspace.remove(tab)
        if let sel = workspace.selectedTab { select(sel, keepDashboard: true) }
        let controller = AppDelegate.shared.newWindowController()
        controller.adopt(tab, panes: panes)
        controller.showWindow(nil)
    }

    func toggleTabBarStyle() {
        var s = SettingsStore.shared.settings
        s.tabBarStyle = s.tabBarStyle == .horizontal ? .vertical : .horizontal
        SettingsStore.shared.settings = s
    }

    func toggleActivityPopover() { chrome.showActivity.toggle() }

    // MARK: Claude dashboard

    func toggleDashboard() {
        if workspace.showsDashboard { hideDashboard() } else { showDashboard() }
    }

    func showDashboard() {
        guard !workspace.showsDashboard else { return }
        workspace.showsDashboard = true
        syncTerminalArea()
        focusSelected()
        updateExplorer()
    }

    func hideDashboard() {
        guard workspace.showsDashboard else { return }
        workspace.showsDashboard = false
        if !ClaudeDashboard.controllers.contains(where: { $0.workspace.showsDashboard }) {
            DashboardRepos.shared.releaseAll()
        }
        syncTerminalArea()
        focusSelected()
        updateExplorer()
    }

    // MARK: Panes

    func split(_ direction: SplitDirection, before: Bool = false) {
        guard let tab = workspace.selectedTab, let current = tab.focusedSession else { return }
        workspace.showsDashboard = false
        let session = makeSession(directory: current.workingDirectory)
        tab.split(current.id, with: session, direction: direction, before: before)
        syncTerminalArea()
        focusSelected()
    }

    func closeFocusedPane() {
        guard let tab = workspace.selectedTab, let session = tab.focusedSession else {
            window?.performClose(nil)
            return
        }
        closePane(session, in: tab, confirm: true)
    }

    func closePane(_ session: TerminalSession, in tab: TerminalTab, confirm: Bool) {
        if confirm && session.surfaceView.needsConfirmQuit {
            confirmClose(message: "Close this pane?", info: "A process is still running in this pane.") { [weak self] in
                self?.closePane(session, in: tab, confirm: false)
            }
            return
        }
        paneViews[session.id]?.removeFromSuperview()
        paneViews[session.id] = nil
        if tab.remove(session.id) {
            containers[tab.id]?.removeFromSuperview()
            containers[tab.id] = nil
            workspace.remove(tab)
            if workspace.tabs.isEmpty {
                window?.close()
                return
            }
            if let sel = workspace.selectedTab { select(sel, keepDashboard: true) }
        } else {
            syncTerminalArea()
            focusSelected()
        }
        updateExplorer()
    }

    func focusPane(_ direction: FocusDirection) {
        guard let tab = workspace.selectedTab,
              let next = tab.tree.neighbor(of: tab.focusedSessionID, direction) else { return }
        tab.focusedSessionID = next
        tab.zoomedSessionID = nil
        syncTerminalArea()
        focusSelected()
    }

    func cyclePane(_ delta: Int) {
        guard let tab = workspace.selectedTab else { return }
        let leaves = tab.tree.leaves
        guard let idx = leaves.firstIndex(of: tab.focusedSessionID), leaves.count > 1 else { return }
        tab.focusedSessionID = leaves[(idx + delta + leaves.count) % leaves.count]
        if tab.zoomedSessionID != nil { tab.zoomedSessionID = tab.focusedSessionID }
        syncTerminalArea()
        focusSelected()
    }

    func toggleZoom() {
        guard let tab = workspace.selectedTab, tab.sessions.count > 1 else { return }
        tab.zoomedSessionID = tab.zoomedSessionID == nil ? tab.focusedSessionID : nil
        syncTerminalArea()
        focusSelected()
    }

    private func paneDidFocus(_ pane: PaneView) {
        guard let tab = workspace.tabs.first(where: { $0.sessions[pane.session.id] != nil }) else { return }
        if tab.focusedSessionID != pane.session.id {
            tab.focusedSessionID = pane.session.id
            updateActivePanes()
        }
        updateSessionFocus()
        if !workspace.showsDashboard { window?.title = tab.title }
        updateExplorer()
    }

    /// Brings a session's window, tab and pane to the front.
    func reveal(_ session: TerminalSession) {
        guard let tab = workspace.tabs.first(where: { $0.sessions[session.id] != nil }) else { return }
        tab.focusedSessionID = session.id
        if tab.zoomedSessionID != nil { tab.zoomedSessionID = session.id }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        select(tab)
    }

    func session(for surface: TerminalSurfaceView) -> (TerminalTab, TerminalSession)? {
        for tab in workspace.tabs {
            if let s = tab.sessions.values.first(where: { $0.surfaceView === surface }) { return (tab, s) }
        }
        return nil
    }

    var focusedSession: TerminalSession? { workspace.selectedTab?.focusedSession }
    func paneView(for session: TerminalSession) -> PaneView? { paneViews[session.id] }
    var focusedPane: PaneView? { focusedSession.flatMap { paneViews[$0.id] } }

    // MARK: Terminal area sync

    func syncTerminalArea() {
        guard let tab = workspace.selectedTab else { return }
        let divider = ConfigController.shared.theme.background.mixed(with: ConfigController.shared.theme.foreground, 0.16).nsColor
        let container: SplitContainerView
        if let c = containers[tab.id] {
            container = c
        } else {
            container = SplitContainerView(frame: contentView.terminalArea.bounds)
            container.autoresizingMask = [.width, .height]
            container.dividerColor = divider
            container.onRatioChange = { [weak self, weak tab] id, ratio in
                guard let self, let tab else { return }
                tab.setRatio(ratio, forSplit: id)
                self.containers[tab.id]?.update(tree: tab.tree, panes: self.panes(for: tab), zoomed: tab.zoomedSessionID)
            }
            containers[tab.id] = container
            contentView.terminalArea.addSubview(container)
        }
        container.frame = contentView.terminalArea.bounds
        container.update(tree: tab.tree, panes: panes(for: tab), zoomed: tab.zoomedSessionID)
        let dashboard = workspace.showsDashboard
        for (id, c) in containers {
            let visible = id == tab.id && !dashboard
            c.isHidden = !visible
            if let t = workspace.tabs.first(where: { $0.id == id }) {
                for s in t.sessions.values { s.surfaceView.setOcclusion(visible: visible) }
            }
        }
        syncDashboard()
        updateActivePanes()
        window?.title = dashboard ? "Claude Sessions" : tab.title
    }

    /// The dashboard lives in the terminal area only while it's showing, so its
    /// live previews stop refreshing when it's hidden.
    private func syncDashboard() {
        if workspace.showsDashboard {
            guard dashboardHost == nil else { return }
            let host = NSHostingView(rootView: ClaudeDashboardView(controller: self))
            host.sizingOptions = []
            host.frame = contentView.terminalArea.bounds
            contentView.terminalArea.addSubview(host)
            dashboardHost = host
        } else {
            dashboardHost?.removeFromSuperview()
            dashboardHost = nil
        }
    }

    private func panes(for tab: TerminalTab) -> [UUID: PaneView] {
        var result: [UUID: PaneView] = [:]
        for id in tab.sessions.keys { result[id] = paneViews[id] }
        return result
    }

    private func updateActivePanes() {
        guard let tab = workspace.selectedTab else { return }
        for (id, pane) in panes(for: tab) { pane.isActivePane = id == tab.focusedSessionID }
    }

    func focusSelected() {
        if workspace.showsDashboard {
            // Keep typing away from the hidden terminal; menu shortcuts still reach us.
            window?.makeFirstResponder(nil)
            updateSessionFocus()
            return
        }
        guard let pane = focusedPane else { return }
        pane.focus()
        updateSessionFocus()
    }

    private func updateSessionFocus() {
        let key = (window?.isKeyWindow ?? false) && !workspace.showsDashboard
        for tab in workspace.tabs {
            for s in tab.sessions.values {
                s.focusChanged(key && tab.id == workspace.selectedTabID && s.id == tab.focusedSessionID)
            }
        }
        NotificationManager.shared.updateDockBadge()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        updateSessionFocus()
        AppDelegate.shared.lastFocusedController = self
    }

    func windowDidResignKey(_ notification: Notification) { updateSessionFocus() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = workspace.tabs.flatMap { $0.sessions.values }.contains { $0.surfaceView.needsConfirmQuit }
        guard running else { return true }
        confirmClose(message: "Close this window?", info: "Processes are still running in this window.") { [weak self] in
            self?.forceClose()
        }
        return false
    }

    private func forceClose() {
        window?.delegate = nil
        window?.close()
        windowWillCloseCleanup()
    }

    func windowWillClose(_ notification: Notification) { windowWillCloseCleanup() }

    private var cleanedUp = false
    private func windowWillCloseCleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        for tab in workspace.tabs { tab.closeAll() }
        // The SwiftUI chrome holds this controller, and the window (which this
        // controller owns) holds the chrome: take it out of the view tree so
        // the window, its panes and their transcripts are freed.
        for view in [tabBarHost, sidebarHost, titleBarHost, explorerHost, dashboardHost].compactMap({ $0 as NSView? }) {
            view.removeFromSuperview()
        }
        tabBarHost = nil
        sidebarHost = nil
        titleBarHost = nil
        explorerHost = nil
        dashboardHost = nil
        contentView.tabBar = nil
        contentView.sidebar = nil
        contentView.titleBar = nil
        contentView.explorer = nil
        for container in containers.values { container.removeFromSuperview() }
        for pane in paneViews.values { pane.removeFromSuperview() }
        paneViews.removeAll()
        containers.removeAll()
        // Stop background git watchers and polling models for this window.
        for entry in terminalRepos.values { entry.repo?.stop() }
        terminalRepos.removeAll()
        worktreeModels.removeAll()
        pullRequestModels.removeAll()
        actionsModels.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        onClose?(self)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window?.occlusionState.contains(.visible) ?? true
        if chrome.isVisible != visible { chrome.isVisible = visible }
        // No GitHub polling for a window nobody can see.
        for m in pullRequestModels.values { m.isPaused = !visible }
        for m in actionsModels.values { m.isPaused = !visible }
        guard let tab = workspace.selectedTab else { return }
        // Terminals behind the dashboard stay paused.
        for s in tab.sessions.values { s.surfaceView.setOcclusion(visible: visible && !workspace.showsDashboard) }
    }

    // MARK: Dialogs

    /// A one-field sheet. With `suggest`, the field fills in with the
    /// suggestion when it arrives, unless the user has already edited it.
    func prompt(title: String, message: String, value: String, suggest: (() async -> String?)? = nil,
                completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: value)
        var suggestionTask: Task<Void, Never>?
        if let suggest {
            let note = NSTextField(labelWithString: "Suggesting a name…")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
            field.frame = NSRect(x: 0, y: 20, width: 260, height: 24)
            note.frame = NSRect(x: 0, y: 0, width: 260, height: 16)
            box.addSubview(field)
            box.addSubview(note)
            alert.accessoryView = box
            suggestionTask = Task { @MainActor in
                let name = await suggest()
                guard !Task.isCancelled, field.stringValue == value, let name, name != value else {
                    note.stringValue = ""
                    return
                }
                field.stringValue = name
                field.currentEditor()?.selectAll(nil)
                note.stringValue = "Suggested by Apple Intelligence"
            }
        } else {
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            suggestionTask?.cancel()
            if resp == .alertFirstButtonReturn { completion(field.stringValue.trimmingCharacters(in: .whitespaces)) }
            self?.focusSelected()
        }
    }

    func confirmClose(message: String, info: String, onConfirm: @escaping () -> Void) {
        guard let window else { return onConfirm() }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn { onConfirm() }
        }
    }

    // MARK: Actions

    @objc func performShortcutAction(_ sender: Any?) {
        guard let action = ShortcutAction.from(sender: sender) else { return }
        perform(action)
    }

    func perform(_ action: ShortcutAction) {
        let session = focusedSession
        let surface = session?.surfaceView
        switch action {
        case .newTab: newTab()
        case .closePane: closeFocusedPane()
        case .closeTab: if let t = workspace.selectedTab { closeTab(t) }
        case .closeWindow: window?.performClose(nil)
        case .splitRight: split(.horizontal)
        case .splitDown: split(.vertical)
        case .selectPaneLeft: focusPane(.left)
        case .selectPaneRight: focusPane(.right)
        case .selectPaneUp: focusPane(.up)
        case .selectPaneDown: focusPane(.down)
        case .nextPane: cyclePane(1)
        case .previousPane: cyclePane(-1)
        case .zoomPane: toggleZoom()
        case .equalizePanes:
            workspace.selectedTab?.equalize()
            syncTerminalArea()
        case .broadcastInput:
            if let tab = workspace.selectedTab { tab.broadcastInput.toggle() }
        case .nextTab: selectRelativeTab(1)
        case .previousTab: selectRelativeTab(-1)
        case .moveTabLeft: if let t = workspace.selectedTab { workspace.move(t, by: -1) }
        case .moveTabRight: if let t = workspace.selectedTab { workspace.move(t, by: 1) }
        case .renameTab: if let t = workspace.selectedTab { renameTab(t) }
        case .newTabGroup: if let t = workspace.selectedTab { newGroup(with: t) }
        case .moveTabToNewWindow: if let t = workspace.selectedTab { moveTabToNewWindow(t) }
        case .tab1: selectTab(at: 0)
        case .tab2: selectTab(at: 1)
        case .tab3: selectTab(at: 2)
        case .tab4: selectTab(at: 3)
        case .tab5: selectTab(at: 4)
        case .tab6: selectTab(at: 5)
        case .tab7: selectTab(at: 6)
        case .tab8: selectTab(at: 7)
        case .lastTab: selectTab(at: workspace.tabs.count - 1)
        case .toggleTabBarStyle: toggleTabBarStyle()
        case .copyLastCommand: focusedPane?.editor.copy(.lastCommand)
        case .copyLastOutput: focusedPane?.editor.copy(.lastOutput)
        case .clearBuffer:
            surface?.perform("clear_screen")
        case .find: focusedPane?.showFind()
        case .findNext:
            if session?.search == nil { focusedPane?.showFind() } else { surface?.perform("navigate_search:next") }
        case .findPrevious: surface?.perform("navigate_search:previous")
        case .jumpToPreviousPrompt: surface?.perform("jump_to_prompt:-1")
        case .jumpToNextPrompt: surface?.perform("jump_to_prompt:1")
        case .scrollToTop: surface?.perform("scroll_to_top")
        case .scrollToBottom: surface?.perform("scroll_to_bottom")
        case .scrollPageUp: surface?.perform("scroll_page_up")
        case .scrollPageDown: surface?.perform("scroll_page_down")
        case .increaseFontSize: adjustFontSize(1)
        case .decreaseFontSize: adjustFontSize(-1)
        case .resetFontSize: adjustFontSize(0)
        case .toggleInputEditor:
            SettingsStore.shared.settings.inputEditor.toggle()
        case .toggleInputPosition:
            let s = SettingsStore.shared.settings
            SettingsStore.shared.settings.inputPosition = s.inputPosition == .bottom ? .top : .bottom
        case .focusInput:
            if let pane = focusedPane, pane.session.acceptsEditorInput { pane.editor.focus() }
        case .toggleNotifications: toggleActivityPopover()
        case .toggleSidebar: toggleSidebar()
        case .claudeDashboard: toggleDashboard()
        case .copy, .paste, .selectAll, .toggleFullScreen:
            break
        case .newWindow, .settings, .commandPalette, .homebrew, .nodeSetup, .zshSetup, .mcpServers, .reloadConfig:
            AppDelegate.shared.perform(action)
        }
    }

    /// Per-pane zoom like iTerm2; the default size lives in Settings › Text.
    private func adjustFontSize(_ delta: Int) {
        guard let surface = focusedSession?.surfaceView else { return }
        switch delta {
        case 0: surface.perform("reset_font_size")
        case let d where d > 0: surface.perform("increase_font_size:\(d)")
        default: surface.perform("decrease_font_size:\(-delta)")
        }
    }

    @objc func splitRight(_ sender: Any?) { split(.horizontal) }
    @objc func splitDown(_ sender: Any?) { split(.vertical) }
    @objc func clearBuffer(_ sender: Any?) { focusedSession?.surfaceView.perform("clear_screen") }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = ShortcutAction.from(sender: item) else { return true }
        let tab = workspace.selectedTab
        switch action {
        case .zoomPane, .equalizePanes, .nextPane, .previousPane, .selectPaneLeft, .selectPaneRight, .selectPaneUp, .selectPaneDown:
            if action == .zoomPane { item.state = tab?.zoomedSessionID != nil ? .on : .off }
            return (tab?.sessions.count ?? 0) > 1
        case .broadcastInput:
            item.state = tab?.broadcastInput == true ? .on : .off
            return true
        case .moveTabToNewWindow:
            return workspace.tabs.count > 1
        case .toggleSidebar:
            let s = focusedSession
            item.state = (s?.nativeClaude?.showExplorer ?? s?.showSidebar ?? false) ? .on : .off
            return true
        case .toggleInputEditor:
            item.state = SettingsStore.shared.settings.inputEditor ? .on : .off
            return true
        case .toggleTabBarStyle:
            item.state = SettingsStore.shared.settings.tabBarStyle == .vertical ? .on : .off
            return true
        case .claudeDashboard:
            item.state = workspace.showsDashboard ? .on : .off
            return true
        case .findNext, .findPrevious:
            return true
        default:
            return true
        }
    }
}

/// Title strip shown above the terminal in vertical-tabs mode.
struct TitleBarView: View {
    let controller: TerminalWindowController
    @Bindable var workspace: Workspace

    var body: some View {
        let palette = ChromePalette.current
        ZStack {
            WindowDragArea()
            HStack(spacing: 6) {
                if workspace.showsDashboard {
                    ClaudeLogo(size: 13)
                    Text("Claude Sessions").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.foreground)
                } else if let tab = workspace.selectedTab {
                    TabStatusIcon(tab: tab, palette: palette)
                    Text(tab.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.foreground)
                    Text(tab.subtitle).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .allowsHitTesting(false)
            HStack {
                Spacer()
                SidebarToggleButton(controller: controller, workspace: workspace, palette: palette)
            }
            .padding(.trailing, 10)
        }
        .frame(height: 38)
        .background(palette.background)
        .overlay(alignment: .bottom) { palette.border.frame(height: 1) }
        .ignoresSafeArea()
    }
}

/// Toggles the files, worktrees and GitHub sidebar for the focused terminal
/// pane (⌃⌘B). Shown in the window's header when the pane is in a git
/// repository; the native Claude view has its own toggle in its header.
struct SidebarToggleButton: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let palette: ChromePalette

    var body: some View {
        if !workspace.showsDashboard, let session = workspace.selectedTab?.focusedSession,
           session.nativeClaude == nil, session.gitBranch != nil {
            let on = session.showSidebar
            Button { controller.toggleSidebar() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? palette.selected : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(on ? palette.accent : palette.secondary)
            .help("Files, worktrees & GitHub sidebar (⌃⌘B)")
            .accessibilityLabel("Files, worktrees and GitHub sidebar")
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}
