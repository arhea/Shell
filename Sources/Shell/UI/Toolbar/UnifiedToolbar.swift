import AppKit
import SwiftUI

// The window's unified toolbar (vertical tabs): what the focused pane is
// (title, repository / branch / worktree), its PR and CI state, and its
// controls (Claude's model, effort and mode; MCP; split; the inspector).
// With splits, it follows the focused pane.

/// Asks a pane's inspector to show its CI checks. Posted by the toolbar's
/// failing-checks capsule; `object` is the `GitRepository` (when known) and
/// `userInfo["session"]` the pane's session `UUID`. The inspector (right
/// sidebar) observes it and switches to its Checks view.
enum BranchChecksRequest {
    static let notification = Notification.Name("ShellShowBranchChecks")

    @MainActor
    static func post(repository: GitRepository?, sessionID: UUID?) {
        var info: [String: Any] = [:]
        if let sessionID { info["session"] = sessionID }
        NotificationCenter.default.post(name: notification, object: repository, userInfo: info)
    }
}

/// The toolbar's subtitle text, built without views so it's unit-tested.
enum ToolbarSubtitle {
    /// "owner/repo / " before the branch glyph, the branch with ahead/behind,
    /// then "worktree · 3 changed".
    struct Repo: Equatable {
        var lead: String
        var branch: String
        var trailing: String
    }

    static func repo(slug: String, branch: String, ahead: Int, behind: Int, isWorktree: Bool, changes: Int) -> Repo {
        var b = branch
        if ahead > 0 { b += " ↑\(ahead)" }
        if behind > 0 { b += " ↓\(behind)" }
        var tail: [String] = []
        if isWorktree { tail.append("worktree") }
        if changes > 0 { tail.append("\(changes) changed") }
        return Repo(lead: slug + " /", branch: b, trailing: tail.isEmpty ? "" : " · " + tail.joined(separator: " · "))
    }

    /// "~/code/takt · zsh" outside a repository.
    static func plain(directory: String, shell: String?) -> String {
        [directory, shell].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    static var shellName: String {
        (ProcessInfo.processInfo.environment["SHELL"].map { ($0 as NSString).lastPathComponent }) ?? "zsh"
    }
}

// MARK: - Toolbar

struct UnifiedToolbar: View {
    let controller: TerminalWindowController
    @Bindable var workspace: Workspace
    @Bindable var chrome: WindowChromeState

    var body: some View {
        let palette = ChromePalette.current
        ZStack {
            WindowDragArea()
            HStack(spacing: 12) {
                if chrome.sidebarCollapsed {
                    // Room for the traffic lights, which move here with the sidebar hidden.
                    Color.clear.frame(width: chrome.isFullScreen ? 0 : 60, height: 1).allowsHitTesting(false)
                    ToolbarIconButton(symbol: "sidebar.left", help: "Show Sidebar (\(ShortcutAction.toggleTabSidebar.shortcut?.displayString ?? "⌃⌘S"))") {
                        controller.toggleTabSidebar()
                    }
                }
                leading
                Spacer(minLength: 8)
                trailing
                    .popover(isPresented: $chrome.showActivity, arrowEdge: .bottom) { ActivityPopover(controller: controller) }
            }
            .padding(.leading, chrome.sidebarCollapsed ? 10 : 20)
            .padding(.trailing, 14)
        }
        .frame(height: DS.toolbarHeight)
        .background(palette.background)
        .overlay(alignment: .bottom) { Color.primary.opacity(0.07).frame(height: 0.5) }
        .ignoresSafeArea()
    }

    @ViewBuilder private var leading: some View {
        if workspace.showsDashboard {
            let summary = ClaudeDashboard.summary(of: ClaudeDashboard.entries())
            ToolbarTitle(title: "Claude Sessions", subtitle: Text(summary.detail.isEmpty ? "No sessions" : summary.detail))
        } else if workspace.showsGitHub {
            GitHubToolbarTitle(model: workspace.githubBoard, controller: controller)
        } else if let tab = workspace.selectedTab, let session = tab.focusedSession {
            let repo = session.nativeClaude?.repository ?? chrome.repository
            let directory = session.nativeClaude?.directory ?? session.workingDirectory ?? NSHomeDirectory()
            HStack(spacing: 12) {
                ToolbarTitle(title: tab.title, subtitle: RepoSubtitleText(repo: repo, directory: directory, isClaude: session.nativeClaude != nil))
                    .contextMenu { LocationMenu(repo: repo, directory: directory) }
                if let repo {
                    StatusCapsules(repo: repo) { controller.showChecks(for: session) }
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if workspace.showsGitHub, let board = workspace.githubBoard {
            GitHubToolbarControls(model: board)
        } else if !workspace.showsNativePage, let session = workspace.selectedTab?.focusedSession {
            if let claude = session.nativeClaude {
                ClaudeToolbarControls(
                    claude: claude,
                    inspectorOn: claude.showExplorer,
                    onToggleInspector: claude.repository == nil ? nil : { controller.toggleSidebar() },
                    onClose: { session.endNativeClaude() },
                    onContinueInTerminal: { session.continueClaudeInTerminal() },
                    extraMenu: { WindowMenuItems(controller: controller) })
            } else {
                TerminalToolbarControls(controller: controller, session: session, hasRepo: chrome.repository != nil)
            }
        } else {
            ToolbarCapsule {
                ToolbarMoreMenu { WindowMenuItems(controller: controller) }
            }
        }
    }
}

/// Title (13pt semibold) over a subtitle (11.5pt secondary).
struct ToolbarTitle<Subtitle: View>: View {
    let title: String
    let subtitle: Subtitle

    init(title: String, subtitle: Subtitle) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: DS.Size.title, weight: .semibold)).lineLimit(1)
            subtitle
                .font(.system(size: DS.Size.subtitle))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .layoutPriority(1)
    }
}

/// "owner/repo / ⎇ branch · worktree" in a repository, else "~/path · zsh".
struct RepoSubtitleText: View {
    let repo: GitRepository?
    let directory: String
    var isClaude = false

    var body: some View {
        if let repo {
            let st = repo.status
            let parts = ToolbarSubtitle.repo(slug: repo.github?.slug ?? repo.name, branch: repo.branchLabel, ahead: st.ahead,
                                             behind: st.behind, isWorktree: repo.isLinkedWorktree, changes: st.changeCount)
            Self.text(parts).help(repo.root.path)
        } else {
            let home = NSHomeDirectory()
            let short = directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
            Text(ToolbarSubtitle.plain(directory: short, shell: isClaude ? nil : ToolbarSubtitle.shellName))
                .help(directory)
        }
    }

    /// "arhea/Shell / ⎇ bug/38-… · worktree" with the separators dimmed, as designed.
    static func text(_ parts: ToolbarSubtitle.Repo) -> Text {
        let sep = Color.secondary.opacity(0.6)
        let lead = parts.lead.hasSuffix(" /") ? String(parts.lead.dropLast(2)) : parts.lead
        let slash = Text("  /  ").foregroundStyle(sep)
        let dot = Text("  ·  ").foregroundStyle(sep)
        var text = Text("\(lead)\(slash)\(Image(systemName: "arrow.triangle.branch")) \(parts.branch)")
        let tail = parts.trailing.hasPrefix(" · ") ? String(parts.trailing.dropFirst(3)) : parts.trailing
        for piece in tail.components(separatedBy: " · ") where !piece.isEmpty {
            text = Text("\(text)\(dot)\(piece)")
        }
        return text
    }
}

/// Reveal, copy and GitHub links for the toolbar title's context menu and "…" menus.
struct LocationMenu: View {
    let repo: GitRepository?
    let directory: String

    var body: some View {
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory) }
        Button("Copy Path") { copy(directory) }
        if let repo {
            if let branch = repo.status.branch { Button("Copy Branch Name") { copy(branch) } }
            if let gh = repo.github {
                Divider()
                Button("Open \(gh.slug) on GitHub") { NSWorkspace.shared.open(gh.url) }
                if let branch = repo.status.branch, repo.isBranchPublished {
                    Button("Open Branch on GitHub") { NSWorkspace.shared.open(gh.branchURL(branch)) }
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Green "● PR #39 · Open ↗" (or "Create PR ↗"), and a red "✕ 1 check
/// failing" capsule while CI fails on the branch.
struct StatusCapsules: View {
    let repo: GitRepository
    var onShowChecks: () -> Void

    var body: some View {
        let checks = BranchChecksModel.shared(for: repo)
        HStack(spacing: 6) {
            if let pr = repo.pullRequest {
                let (label, color) = Self.state(pr)
                Button { NSWorkspace.shared.open(pr.url) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text("PR #\(pr.number) · \(label)")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .regular))
                    }
                }
                .buttonStyle(StatusCapsuleStyle(color: color))
                .help("\(pr.title)\nOpen on GitHub")
            } else if let gh = repo.github, let branch = repo.status.branch, repo.isBranchPublished, branch != repo.defaultBranch {
                Button { NSWorkspace.shared.open(gh.compareURL(branch)) } label: {
                    HStack(spacing: 6) {
                        Text("Create PR")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .regular))
                    }
                }
                .buttonStyle(StatusCapsuleStyle(color: .secondary))
                .help("Open a pull request for \(branch) on GitHub")
            }
            if let snapshot = checks.snapshot, !snapshot.failing.isEmpty {
                Button(action: onShowChecks) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        Text(snapshot.summary)
                    }
                }
                .buttonStyle(StatusCapsuleStyle(color: DS.Status.failed))
                .help("Show the failing checks")
            }
        }
        .fixedSize()
        .task(id: "\(repo.root.path)|\(repo.status.branch ?? "")") { checks.refresh() }
    }

    static func state(_ pr: PullRequestInfo) -> (String, Color) {
        switch pr.state {
        case .merged: ("Merged", DS.Status.review)
        case .closed: ("Closed", DS.Status.failed)
        case .open: pr.isDraft ? ("Draft", Color.secondary) : ("Open", DS.Status.done)
        }
    }
}

struct StatusCapsuleStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DS.Size.subtitle, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .contentShape(Capsule())
    }
}

// MARK: - Grouped capsules

/// The toolbar's grouped capsule: items share one rounded background.
struct ToolbarCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 3)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            .fixedSize()
    }
}

/// A hairline between items in a capsule.
struct ToolbarDivider: View {
    var body: some View { Color.primary.opacity(0.1).frame(width: 1, height: 14) }
}

/// An item inside a capsule: hover fill, 24pt tall.
struct ToolbarItemStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarItemBody(label: configuration.label, pressed: configuration.isPressed, active: active)
    }
}

private struct ToolbarItemBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let active: Bool
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: DS.Size.body))
            // An active toggle (the inspector) is a filled item, not a blue icon.
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 24)
            .background(Capsule().fill(Color.primary.opacity(pressed ? 0.14 : active ? 0.1 : hovering ? 0.08 : 0)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
        }
        .buttonStyle(ToolbarItemStyle(active: active))
        .help(help)
        .accessibilityLabel(help.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A menu inside a capsule, labeled like a button.
struct ToolbarMenu<Label: View, Content: View>: View {
    var help: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        // A menu button's label drops custom views (the ▼, the mode dot, the
        // dimmed "Effort"), so draw the label ourselves and lay a
        // see-through menu over it to take the click.
        label()
            .font(.system(size: DS.Size.body))
            .fixedSize()
            .accessibilityHidden(true)
            .padding(.horizontal, 10)
            .frame(minWidth: 28, minHeight: 24)
            .overlay {
                Menu(content: content) { label() }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.011)
            }
        .background(Capsule().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// "…": more commands for the focused pane.
struct ToolbarMoreMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ToolbarMenu(help: "More", content: content) {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
        }
        .accessibilityLabel("More")
    }
}

/// The right-hand inspector (files, worktrees, checks) toggle (⌃⌘B).
struct InspectorToggle: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        ToolbarIconButton(symbol: "sidebar.right",
                          help: (on ? "Hide Inspector" : "Show Inspector") + " (\(ShortcutAction.toggleSidebar.shortcut?.displayString ?? "⌃⌘B"))",
                          active: on, action: action)
    }
}

/// Window-level commands every "…" menu ends with.
struct WindowMenuItems: View {
    let controller: TerminalWindowController

    var body: some View {
        Divider()
        Button("Agent Activity") { controller.toggleActivityPopover() }
        Button(SettingsStore.shared.settings.tabBarStyle == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs") {
            controller.toggleTabBarStyle()
        }
    }
}

// MARK: - Claude controls

/// Model ▾ | Effort ▾ | ● Mode, then MCP, "…" and the inspector toggle.
/// Used by the unified toolbar and by the Claude view's own header in
/// horizontal-tabs mode.
struct ClaudeToolbarControls<Extra: View>: View {
    @Bindable var claude: ClaudeCodeSession
    var inspectorOn: Bool
    var onToggleInspector: (() -> Void)?
    var onClose: () -> Void
    var onContinueInTerminal: () -> Void
    @ViewBuilder var extraMenu: () -> Extra
    @State private var showRemote = false

    var body: some View {
        HStack(spacing: 8) {
            ToolbarCapsule {
                modelMenu
                ToolbarDivider()
                effortMenu
                ToolbarDivider()
                modeMenu
            }
            ToolbarCapsule {
                mcpButton
                if claude.remoteControlURL != nil || claude.remoteControlBusy {
                    Button { showRemote = true } label: {
                        if claude.remoteControlBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                        }
                    }
                    .buttonStyle(ToolbarItemStyle(active: true))
                    .help("Remote Control is on — continue this session in the Claude app")
                }
                ToolbarMoreMenu { moreItems }
                    .popover(isPresented: $showRemote, arrowEdge: .bottom) {
                        RemoteControlPopover(claude: claude, palette: ClaudePalette.current)
                    }
                if let onToggleInspector {
                    InspectorToggle(on: inspectorOn, action: onToggleInspector)
                }
            }
        }
    }

    private var modelMenu: some View {
        ToolbarMenu(help: "Model" + (claude.resolvedModel.map { " — using \($0)" } ?? "")) {
            if claude.models.isEmpty {
                ForEach(["default", "opus", "sonnet", "haiku"], id: \.self) { m in
                    Toggle(m.capitalized, isOn: Binding(get: { claude.model == m }, set: { _ in claude.setModel(m) }))
                }
            } else {
                ForEach(claude.models) { m in
                    Toggle(isOn: Binding(get: { claude.model == m.value }, set: { _ in claude.setModel(m.value) })) {
                        Text(m.label)
                        if !m.detail.isEmpty { Text(m.detail) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(claude.modelTitle)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 6)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var effortMenu: some View {
        if !claude.effortLevels.isEmpty {
            ToolbarMenu(help: "Effort: how much Claude thinks before acting") {
                Toggle("Auto (model default)", isOn: Binding(get: { claude.effort.isEmpty }, set: { _ in claude.setEffort("") }))
                Divider()
                ForEach(claude.effortLevels, id: \.self) { level in
                    Toggle(Self.effortTitle(level), isOn: Binding(get: { claude.effort == level }, set: { _ in claude.setEffort(level) }))
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Effort").foregroundStyle(.secondary)
                    Text(claude.effort.isEmpty ? "Auto" : Self.effortTitle(claude.effort))
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 6)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modeMenu: some View {
        ToolbarMenu(help: "Permission mode (⇧⇥ to cycle)") {
            ForEach(claude.availableModes) { mode in
                Toggle(isOn: Binding(get: { claude.permissionMode == mode }, set: { _ in claude.setPermissionMode(mode) })) {
                    Text(mode.title)
                    Text(mode.detail)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Self.modeColor(claude.permissionMode)).frame(width: 7, height: 7)
                Text(claude.permissionMode.title)
                Text("⇧⇥").font(.system(size: DS.Size.caption)).foregroundStyle(.secondary)
            }
        }
    }

    private var mcpButton: some View {
        let waiting = claude.mcpNeedsAuth.count
        return Button {
            MCPManagerWindowController.show(directory: claude.directory, binary: claude.request.binary,
                                            environment: claude.request.environment, select: claude.mcpNeedsAuth.first?.name)
        } label: {
            HStack(spacing: 5) {
                Text("MCP").foregroundStyle(.secondary)
                Text("\(claude.mcpServers.count)").fontWeight(.semibold).foregroundStyle(waiting > 0 ? DS.Status.needsYou : DS.Status.done)
            }
        }
        .buttonStyle(ToolbarItemStyle())
        .help(waiting > 0 ? "MCP servers — \(waiting) need sign-in" : "MCP servers (\(claude.mcpServers.count))")
    }

    @ViewBuilder private var moreItems: some View {
        Button("Continue in Terminal UI") { onContinueInTerminal() }.disabled(claude.sessionID == nil)
        Button("Interrupt") { claude.interrupt() }.disabled(!claude.isRunning)
        Button("Remote Control…") { showRemote = true }.disabled(claude.hasExited)
        Divider()
        LocationMenu(repo: claude.repository, directory: claude.directory)
        extraMenu()
        Divider()
        Button("Close Claude") { onClose() }
    }

    static func effortTitle(_ level: String) -> String { level == "xhigh" ? "Extra high" : level.capitalized }

    /// Auto mode is Claude orange; risky modes stand out.
    static func modeColor(_ mode: ClaudePermissionMode) -> Color {
        switch mode {
        case .default, .dontAsk: Color.secondary
        case .acceptEdits: DS.Status.review
        case .plan: Color(nsColor: .systemTeal)
        case .auto: DS.claude
        case .bypassPermissions: DS.Status.failed
        }
    }
}

// MARK: - Terminal controls

/// "Split", "…" and the inspector toggle for a terminal pane.
struct TerminalToolbarControls: View {
    let controller: TerminalWindowController
    let session: TerminalSession
    let hasRepo: Bool

    var body: some View {
        ToolbarCapsule {
            Button { controller.split(.horizontal) } label: {
                Label("Split", systemImage: "rectangle.split.2x1")
            }
            .buttonStyle(ToolbarItemStyle())
            .help("Split Right (\(ShortcutAction.splitRight.shortcut?.displayString ?? "⌘D"))")
            ToolbarMoreMenu { items }
            InspectorToggle(on: session.showSidebar) { controller.toggleSidebar() }
                .disabled(!hasRepo)
                .opacity(hasRepo ? 1 : 0.4)
        }
    }

    @ViewBuilder private var items: some View {
        let tab = controller.workspace.selectedTab
        Button("Split Right") { controller.split(.horizontal) }
        Button("Split Down") { controller.split(.vertical) }
        if (tab?.sessions.count ?? 0) > 1 {
            Button(tab?.zoomedSessionID == nil ? "Maximize Pane" : "Restore Panes") { controller.perform(.zoomPane) }
            Button("Equalize Pane Sizes") { controller.perform(.equalizePanes) }
            Toggle("Broadcast Input to All Panes", isOn: Binding(get: { tab?.broadcastInput ?? false },
                                                                 set: { tab?.broadcastInput = $0 }))
        }
        Divider()
        Button("Start Claude Here") { AgentLauncher.start(.here, from: session) { _, _ in } }
        Button("Claude in New Worktree…") { controller.startClaudeInNewWorktree() }
            .disabled(session.gitBranch == nil)
        Divider()
        Button("Clear Buffer") { controller.perform(.clearBuffer) }
        if let tab { Button("Rename Tab…") { controller.renameTab(tab) } }
        Divider()
        LocationMenu(repo: controller.repository(for: session), directory: session.workingDirectory ?? NSHomeDirectory())
        WindowMenuItems(controller: controller)
    }
}

// MARK: - GitHub controls

/// "Pull Requests" over "arhea/Shell ▾ · 14 open · updated 40s ago". The
/// repository switches to another GitHub repository open in this window.
struct GitHubToolbarTitle: View {
    let model: GitHubBoardModel?
    let controller: TerminalWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pull Requests").font(.system(size: DS.Size.title, weight: .semibold)).lineLimit(1)
            Group {
                if let model {
                    HStack(spacing: 4) {
                        repository(model)
                        Text("· \(model.pullRequests.count) open")
                        if let updated = model.lastUpdated {
                            TimelineView(.periodic(from: .now, by: 15)) { _ in
                                Text("· updated \(ActionsView.ago(updated))")
                            }
                            .help("Refreshes every 2 minutes while this tab is showing")
                        }
                        if model.isLoading { ProgressView().controlSize(.mini) }
                    }
                } else {
                    Text("GitHub")
                }
            }
            .font(.system(size: DS.Size.subtitle))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .layoutPriority(1)
    }

    @ViewBuilder private func repository(_ model: GitHubBoardModel) -> some View {
        let others = controller.githubRepositories.filter { $0.root != model.repoRoot }
        if others.isEmpty {
            Text(model.remote.slug)
        } else {
            Menu {
                ForEach(others, id: \.root) { repo in
                    Button(repo.remote.slug) { controller.showGitHub(repoRoot: repo.root, remote: repo.remote) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(model.remote.slug)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: DS.Size.subtitle))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show another repository open in this window")
        }
    }
}

/// For you / Mine / All, the search field, refresh and "Open on GitHub ↗".
struct GitHubToolbarControls: View {
    @Bindable var model: GitHubBoardModel

    var body: some View {
        let counts = model.layout.counts
        HStack(spacing: 8) {
            SegmentedTabs(items: PullRequestBoard.Filter.allCases.map { .init(id: $0, title: $0.title, count: counts.count($0)) },
                          selection: $model.filter)
                .fixedSize()
                .help("For you: assigned to you or waiting on your review. Mine: opened by you. Stacks come along whole.")
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Title, branch, author, label", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.Size.body))
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear the search")
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 120, idealWidth: 230, maxWidth: 240, minHeight: 26, maxHeight: 26)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.row).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            ToolbarCapsule {
                ToolbarIconButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            Button { NSWorkspace.shared.open(model.remote.url.appendingPathComponent("pulls")) } label: {
                HStack(spacing: 4) {
                    Text("Open on GitHub")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(.labeled(.neutral))
            .fixedSize()
            .help("Open \(model.remote.slug)'s pull requests on github.com")
        }
    }
}
