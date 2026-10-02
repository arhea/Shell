import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Colors for window chrome derived from the active terminal theme, so tabs,
/// sidebar and terminal read as one surface (like Warp).
struct ChromePalette {
    var background: Color
    var bar: Color
    var selected: Color
    var hover: Color
    var foreground: Color
    var secondary: Color
    var border: Color
    var accent: Color
    var red: Color
    var green: Color
    var yellow: Color
    var purple: Color

    @MainActor
    static var current: ChromePalette {
        let t = ConfigController.shared.theme
        let bg = t.background, fg = t.foreground
        func c(_ rgb: RGB) -> Color { Color(nsColor: rgb.nsColor) }
        return ChromePalette(
            background: c(bg),
            bar: c(bg.mixed(with: fg, t.isDark ? 0.045 : 0.035)),
            selected: c(bg.mixed(with: fg, t.isDark ? 0.12 : 0.085)),
            hover: c(bg.mixed(with: fg, t.isDark ? 0.08 : 0.06)),
            foreground: c(fg),
            secondary: c(bg.mixed(with: fg, 0.55)),
            border: c(bg.mixed(with: fg, 0.13)),
            accent: c(t.accent),
            red: c(t.palette[1]), green: c(t.palette[2]), yellow: c(t.palette[3]), purple: c(t.palette[5]))
    }
}

/// Lets the user drag the window from SwiftUI chrome and double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
                return
            }
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Tab presentation

/// How a tab presents itself in the sidebar, tab bar and palette: its tile,
/// status and the words for its agent state.
@MainActor
enum TabPresentation {
    static func tile(for tab: TerminalTab) -> TileKind {
        if let s = tab.focusedSession {
            if s.nativeClaude != nil || s.isClaude { return .claude }
            if s.agent?.kind == .codex { return .codex }
        }
        switch tab.agent?.kind {
        case .claude: return .claude
        case .codex: return .codex
        default: return .terminal
        }
    }

    /// "Claude needs input", "Codex working", "Claude done"; nil without an agent.
    static func agentSummary(_ tab: TerminalTab) -> String? {
        switch tab.agent {
        case .working(let k): "\(k.displayName) working"
        case .needsInput(let k, _): "\(k.displayName) needs input"
        case .finished(let k, _): "\(k.displayName) done"
        case nil: nil
        }
    }

    /// What the trailing status shows, for VoiceOver.
    static func accessibilityStatus(_ tab: TerminalTab) -> String? {
        if let agent = tab.agent {
            switch agent {
            case .working(let k): return "\(k.displayName) working"
            case .needsInput(let k, _): return "\(k.displayName) needs input"
            case .finished(let k, _): return "\(k.displayName) done"
            }
        }
        if tab.isBusy { return "Running" }
        if tab.hasBell { return "Bell" }
        if tab.lastExitFailed { return "Last command failed" }
        if tab.hasUnseenOutput { return "New output" }
        return nil
    }
}

/// The trailing slot of a tab row or chip, in priority order: the close
/// button on hover; the agent's status (spinner, "Input" pill, check); a
/// running command's spinner; bell, failure or new-output marks; else the
/// tab's ⌘N shortcut.
struct TabTrailingStatus: View {
    let tab: TerminalTab
    let index: Int
    let hovering: Bool
    var compact = false
    let onClose: () -> Void

    var body: some View {
        Group {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
            } else if tab.agent != nil {
                StatusIndicator(status: StatusKind(tab.agent))
            } else if tab.isBusy {
                SpinnerRing(color: .secondary)
            } else if tab.hasBell {
                Image(systemName: "bell.fill").font(.system(size: 10)).foregroundStyle(DS.Status.needsYou)
            } else if tab.lastExitFailed {
                Circle().fill(DS.Status.failed).frame(width: 6, height: 6).help("Last command failed")
            } else if tab.hasUnseenOutput {
                Circle().fill(DS.Status.info).frame(width: 6, height: 6).help("New output")
            } else if index < 9 {
                KeyHint("⌘\(index + 1)")
            }
        }
        .frame(minWidth: compact ? 18 : 22, alignment: .trailing)
    }
}

/// "~/code/Shell · ⎇ main", "Shell · ⎇ bug/38-sigpipe… · #39".
struct TabSubtitle: View {
    let controller: TerminalWindowController
    let tab: TerminalTab

    var body: some View {
        let parts = Self.parts(controller: controller, tab: tab)
        Group {
            if let branch = parts.branch {
                Text("\(parts.folder) · \(Image(systemName: "arrow.triangle.branch")) \(branch)\(parts.trailing)")
            } else {
                Text(parts.folder + parts.trailing)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    static func parts(controller: TerminalWindowController, tab: TerminalTab) -> (folder: String, branch: String?, trailing: String) {
        guard let s = tab.focusedSession else { return (tab.subtitle, nil, "") }
        var trailing = ""
        let folder: String
        let branch: String?
        if let claude = s.nativeClaude, let repo = claude.repository {
            folder = repo.github?.name ?? repo.mainWorktree?.lastPathComponent ?? repo.name
            branch = repo.branchLabel
            if let pr = repo.pullRequest { trailing += " · #\(pr.number)" }
        } else {
            if let claude = s.nativeClaude {
                folder = ClaudeToolFormat.shortPath(claude.directory)
            } else if tab.agent != nil {
                // Agent tabs lead with the project, like native Claude tabs:
                // "Shell · ⎇ bug/38-sigpipe… · #39".
                folder = s.directoryName
            } else {
                folder = s.abbreviatedDirectory
            }
            branch = s.gitBranch
            if let pr = controller.repository(for: s)?.pullRequest { trailing += " · #\(pr.number)" }
        }
        if tab.sessions.count > 1 { trailing += " · \(tab.sessions.count) panes" }
        return (folder, branch, trailing)
    }
}

// MARK: - Horizontal tab bar

struct HorizontalTabBar: View {
    let controller: TerminalWindowController
    @Bindable var workspace: Workspace
    @Bindable var chrome: WindowChromeState

    var body: some View {
        let palette = ChromePalette.current
        let dashboard = DashboardVisibility(workspace: workspace)
        HStack(spacing: 0) {
            WindowDragArea().frame(width: chrome.isFullScreen ? 8 : 78)
            if let summary = dashboard.summary {
                DashboardTabChip(controller: controller, workspace: workspace, summary: summary, palette: palette)
            }
            if workspace.githubTabOpen {
                GitHubTabChip(controller: controller, workspace: workspace, palette: palette)
            }
            if dashboard.summary != nil || workspace.githubTabOpen {
                palette.border.frame(width: 1, height: 18).padding(.horizontal, 6)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.items) { item in
                            switch item {
                            case .tab(let tab):
                                HorizontalTabChip(controller: controller, workspace: workspace, tab: tab, group: nil, palette: palette)
                                    .id(tab.id)
                            case .group(let group, let tabs):
                                GroupChip(controller: controller, workspace: workspace, group: group, count: tabs.count, palette: palette)
                                if !group.isCollapsed {
                                    ForEach(tabs) { tab in
                                        HorizontalTabChip(controller: controller, workspace: workspace, tab: tab, group: group, palette: palette)
                                            .id(tab.id)
                                    }
                                }
                            }
                        }
                        Button { controller.newTab() } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.secondary)
                        .help("New Tab (⌘T)")
                    }
                    .padding(.vertical, 5)
                }
                .onChange(of: workspace.selectedTabID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            WindowDragArea().frame(minWidth: 24)
            SidebarToggleButton(controller: controller, workspace: workspace, palette: palette)
            ChromeButtons(controller: controller, palette: palette, vertical: false)
                .padding(.trailing, 10)
        }
        .frame(height: 38)
        .background(palette.bar)
        .overlay(alignment: .bottom) { palette.border.frame(height: 1) }
        .ignoresSafeArea()
    }
}

struct ChromeButtons: View {
    let controller: TerminalWindowController
    let palette: ChromePalette
    let vertical: Bool

    var body: some View {
        HStack(spacing: 2) {
            ChromeIconButton(symbol: "bell.badge",
                             help: "Agent Activity (\(ShortcutAction.toggleNotifications.shortcut?.displayString ?? "⌥⌘A"))", palette: palette) {
                controller.toggleActivityPopover()
            }
            .popover(isPresented: Binding(get: { controller.chrome.showActivity }, set: { controller.chrome.showActivity = $0 })) {
                ActivityPopover(controller: controller)
            }
            ChromeIconButton(symbol: vertical ? "rectangle.split.1x2" : "sidebar.left",
                             help: vertical ? "Horizontal Tabs (⌃⌘T)" : "Vertical Tabs (⌃⌘T)", palette: palette) {
                controller.toggleTabBarStyle()
            }
        }
    }
}

struct ChromeIconButton: View {
    let symbol: String
    let help: String
    let palette: ChromePalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression))
    }
}

struct HorizontalTabChip: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let tab: TerminalTab
    let group: TabGroup?
    let palette: ChromePalette
    @State private var hovering = false

    var body: some View {
        let selected = workspace.selectedTabID == tab.id && !workspace.showsNativePage
        let index = workspace.tabs.firstIndex { $0.id == tab.id } ?? 0
        HStack(spacing: 6) {
            KindTile(kind: TabPresentation.tile(for: tab), size: 18)
            Text(tab.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? palette.foreground : palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            TabTrailingStatus(tab: tab, index: index, hovering: hovering || selected, compact: true) { controller.closeTab(tab) }
        }
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .frame(minWidth: 110, idealWidth: 170, maxWidth: 220, minHeight: 28, maxHeight: 28)
        .rowBackground(selected: selected, hovering: hovering)
        .overlay(alignment: .bottom) {
            if let group {
                Capsule().fill(group.color.color).frame(height: 2).padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { controller.renameTab(tab) })
        .contextMenu { TabContextMenu(controller: controller, workspace: workspace, tab: tab) }
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(controller: controller, workspace: workspace, target: tab))
        .help(agentHelp ?? tab.subtitle)
        .tabAccessibility(tab: tab, index: index, selected: selected, group: group) { controller.select(tab) }
    }

    private var agentHelp: String? {
        switch tab.agent {
        case .needsInput(_, let m), .finished(_, let m): m
        default: nil
        }
    }
}

struct GroupChip: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let group: TabGroup
    let count: Int
    let palette: ChromePalette

    var body: some View {
        HStack(spacing: 4) {
            Text(group.name.isEmpty ? " " : group.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if group.isCollapsed {
                Text("\(count)").font(.system(size: 10, weight: .bold)).opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(group.color.color))
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { group.isCollapsed.toggle() } }
        .contextMenu { GroupContextMenu(controller: controller, workspace: workspace, group: group) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tab group \(group.name.isEmpty ? "untitled" : group.name), \(count) tab\(count == 1 ? "" : "s")")
        .accessibilityValue(group.isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { group.isCollapsed.toggle() }
        .onDrop(of: [UTType.text], delegate: GroupDropDelegate(controller: controller, workspace: workspace, group: group))
        .help(group.isCollapsed ? "Expand group" : "Collapse group")
    }
}

struct TabContextMenu: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let tab: TerminalTab

    var body: some View {
        Button("Rename Tab…") { controller.renameTab(tab) }
        Menu("Add Tab to Group") {
            Button("New Group…") { controller.newGroup(with: tab) }
            if !workspace.groups.isEmpty { Divider() }
            ForEach(workspace.groups) { g in
                Button(g.name.isEmpty ? "Untitled group" : g.name) { workspace.addToGroup(tab, g) }
            }
        }
        if tab.groupID != nil {
            Button("Remove from Group") { workspace.removeFromGroup(tab) }
        }
        Divider()
        Button("Move Tab to New Window") { controller.moveTabToNewWindow(tab) }
        Button("Duplicate Tab") { controller.duplicate(tab) }
        Divider()
        Button("Close Tab") { controller.closeTab(tab) }
        Button("Close Other Tabs") { controller.closeOtherTabs(except: tab) }
    }
}

struct GroupContextMenu: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let group: TabGroup

    var body: some View {
        Button("Rename Group…") { controller.renameGroup(group) }
        Menu("Color") {
            ForEach(TabGroupColor.allCases) { c in
                Button { group.color = c } label: { Label(c.title, systemImage: group.color == c ? "checkmark.circle.fill" : "circle.fill") }
            }
        }
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { group.isCollapsed.toggle() }
        Button("New Tab in Group") { controller.newTab(inGroup: group) }
        Divider()
        Button("Ungroup") { workspace.ungroup(group) }
        Button("Close Group") { controller.closeGroup(group) }
    }
}

/// Reorders tabs by dropping one onto another (adopting the target's group).
struct TabDropDelegate: DropDelegate {
    let controller: TerminalWindowController
    let workspace: Workspace
    let target: TerminalTab

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, let id = UUID(uuidString: str) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let dragged = workspace.tabs.first(where: { $0.id == id }), dragged.id != target.id,
                          let targetIndex = workspace.tabs.firstIndex(where: { $0.id == target.id }) else { return }
                    let from = workspace.tabs.firstIndex { $0.id == id } ?? 0
                    workspace.move(dragged, toIndex: from < targetIndex ? targetIndex + 1 : targetIndex, group: target.groupID)
                }
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

struct GroupDropDelegate: DropDelegate {
    let controller: TerminalWindowController
    let workspace: Workspace
    let group: TabGroup

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, let id = UUID(uuidString: str) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let tab = workspace.tabs.first(where: { $0.id == id }) else { return }
                    workspace.addToGroup(tab, group)
                }
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

// MARK: - Vertical sidebar

/// The floating glass sidebar: traffic lights and the hide button on top,
/// "Go to anything…", the pinned Claude Sessions and Pull Requests rows, the
/// tabs (with their groups), and New Tab / Claude in New Worktree at the bottom.
struct VerticalTabSidebar: View {
    let controller: TerminalWindowController
    @Bindable var workspace: Workspace
    @Bindable var chrome: WindowChromeState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var headerHovering = false

    /// The panel's default width: 260pt including the window inset, as designed.
    static let defaultWidth: Double = 252

    var body: some View {
        let palette = ChromePalette.current
        VStack(spacing: 0) {
            topRow
            GoToAnythingField { CommandPalette.show(for: controller) }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            let summary = DashboardVisibility(workspace: workspace).summary
            VStack(spacing: 2) {
                if let summary {
                    DashboardSidebarRow(controller: controller, workspace: workspace, summary: summary, palette: palette)
                }
                if workspace.githubTabOpen {
                    GitHubSidebarRow(controller: controller, workspace: workspace, palette: palette)
                }
            }
            .padding(.horizontal, 6)
            if summary != nil || workspace.githubTabOpen {
                Color.primary.opacity(0.08).frame(height: 0.5).padding(.horizontal, 14).padding(.vertical, 8)
            }

            // The design shows only the count; New Tab Group appears on hover
            // and in the header's context menu (also ⌃⌘G and the palette).
            SectionHeader("Tabs", count: workspace.tabs.count,
                          trailing: AnyView(newGroupButton.opacity(headerHovering ? 1 : 0)))
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onHover { headerHovering = $0 }
                .contextMenu {
                    Button("New Tab Group…") { if let tab = workspace.selectedTab { controller.newGroup(with: tab) } }
                        .disabled(workspace.selectedTab == nil)
                }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.items) { item in
                        switch item {
                        case .tab(let tab):
                            SidebarTabRow(controller: controller, workspace: workspace, tab: tab, group: nil)
                        case .group(let group, let tabs):
                            SidebarGroupHeader(controller: controller, workspace: workspace, group: group, count: tabs.count)
                            if !group.isCollapsed {
                                ForEach(tabs) { tab in
                                    SidebarTabRow(controller: controller, workspace: workspace, tab: tab, group: group)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }

            VStack(spacing: 6) {
                SidebarFooterRow(title: "New Tab", shortcut: ShortcutAction.newTab.shortcut?.displayString) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                } action: { controller.newTab() }
                SidebarFooterRow(title: "Claude in New Worktree…", shortcut: ShortcutAction.claudeInNewWorktree.shortcut?.displayString) {
                    ClaudeMark(size: 12)
                } action: { controller.startClaudeInNewWorktree() }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .overlay(alignment: .top) { Color.primary.opacity(0.08).frame(height: 0.5) }
        }
        .background { background(palette) }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .overlay(alignment: .trailing) { resizeHandle }
        .ignoresSafeArea()
    }

    /// The traffic lights sit here (moved by the window); the hide button on the right.
    private var topRow: some View {
        ZStack {
            WindowDragArea()
            HStack {
                Spacer()
                ToolbarIconButton(symbol: "sidebar.left",
                                  help: "Hide Sidebar (\(ShortcutAction.toggleTabSidebar.shortcut?.displayString ?? "⌃⌘S"))") {
                    controller.toggleTabSidebar()
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 44)
    }

    private var newGroupButton: some View {
        Button {
            if let tab = workspace.selectedTab { controller.newGroup(with: tab) }
        } label: {
            Image(systemName: "folder.badge.plus").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New Tab Group (\(ShortcutAction.newTabGroup.shortcut?.displayString ?? "⌃⌘G"))")
        .accessibilityLabel("New Tab Group")
    }

    /// Window glass tinted with the terminal theme, so custom themes stay
    /// coherent; an opaque fill with Reduce Transparency.
    @ViewBuilder private func background(_ palette: ChromePalette) -> some View {
        if reduceTransparency {
            palette.bar
        } else {
            ZStack {
                GlassPanel()
                palette.bar.opacity(0.55)
            }
        }
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in controller.resizeTabSidebar(by: v.translation.width) }
                .onEnded { _ in controller.finishTabSidebarResize() })
            .onTapGesture(count: 2) { SettingsStore.shared.settings.sidebarWidth = Self.defaultWidth }
            .help("Drag to resize · double-click to reset")
    }
}

/// "Go to anything… ⇧⌘P": opens the command palette.
struct GoToAnythingField: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                Text("Go to anything…").frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                KeyHint(ShortcutAction.commandPalette.shortcut?.displayString ?? "⇧⌘P")
            }
            .font(.system(size: DS.Size.body))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: DS.Radius.row).fill(Color.primary.opacity(hovering ? 0.1 : 0.07)))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Go to anything")
        .accessibilityHint("Opens the command palette")
    }
}

/// "+ New Tab ⌘T" and "✻ Claude in New Worktree… ⌥⌘N".
struct SidebarFooterRow<Icon: View>: View {
    let title: String
    let shortcut: String?
    @ViewBuilder var icon: Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon.frame(width: 16)
                Text(title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                if let shortcut { KeyHint(shortcut) }
            }
            .font(.system(size: DS.Size.body))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .rowBackground(selected: false, hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SidebarGroupHeader: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let group: TabGroup
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
            Circle().fill(group.color.color).frame(width: 8, height: 8)
            Text(group.name.isEmpty ? "Untitled group" : group.name)
                .font(.system(size: DS.Size.small, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Text("\(count)").font(.system(size: DS.Size.small, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { group.isCollapsed.toggle() } }
        .contextMenu { GroupContextMenu(controller: controller, workspace: workspace, group: group) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tab group \(group.name.isEmpty ? "untitled" : group.name), \(count) tab\(count == 1 ? "" : "s")")
        .accessibilityValue(group.isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { group.isCollapsed.toggle() }
        .onDrop(of: [UTType.text], delegate: GroupDropDelegate(controller: controller, workspace: workspace, group: group))
    }
}

/// A tab: 24pt tile, title over "folder · ⎇ branch", and the trailing status.
struct SidebarTabRow: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let tab: TerminalTab
    let group: TabGroup?
    @State private var hovering = false

    var body: some View {
        let selected = workspace.selectedTabID == tab.id && !workspace.showsNativePage
        let index = workspace.tabs.firstIndex { $0.id == tab.id } ?? 0
        HStack(spacing: 10) {
            KindTile(kind: TabPresentation.tile(for: tab))
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: DS.Size.title, weight: .medium))
                    .lineLimit(1)
                TabSubtitle(controller: controller, tab: tab)
                    .font(.system(size: DS.Size.subtitle))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            TabTrailingStatus(tab: tab, index: index, hovering: hovering) { controller.closeTab(tab) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .padding(.leading, group != nil ? 8 : 0)
        .rowBackground(selected: selected, hovering: hovering)
        .overlay(alignment: .leading) {
            if let group {
                Capsule().fill(group.color.color).frame(width: 2).padding(.vertical, 8).padding(.leading, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { controller.renameTab(tab) })
        .contextMenu { TabContextMenu(controller: controller, workspace: workspace, tab: tab) }
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(controller: controller, workspace: workspace, target: tab))
        .help(agentHelp ?? "")
        .tabAccessibility(tab: tab, index: index, selected: selected, group: group) { controller.select(tab) }
    }

    /// The agent's message ("Claude needs your permission to use Bash").
    private var agentHelp: String? {
        switch tab.agent {
        case .needsInput(_, let m), .finished(_, let m): m
        default: nil
        }
    }
}

/// Lists panes with agent activity across all windows.
struct ActivityPopover: View {
    let controller: TerminalWindowController

    var body: some View {
        let sessions = SessionRegistry.shared.all.filter { $0.agent != nil || $0.bell || ($0.lastExitCode ?? 0) != 0 && $0.hasUnseenOutput }
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity").font(.headline).padding(12)
            Divider()
            if sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash").font(.title2).foregroundStyle(.secondary)
                    Text("No agent activity").foregroundStyle(.secondary)
                    Text("Claude Code and Codex report here once hooks are installed in Settings › Integrations.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else {
                ForEach(sessions) { s in
                    Button {
                        controller.chrome.showActivity = false
                        s.onRequestFocus?()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(s)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(s)).font(.system(size: 12, weight: .medium))
                                Text(s.abbreviatedDirectory).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 320)
    }

    private func icon(_ s: TerminalSession) -> String {
        switch s.agent {
        case .working: "ellipsis.circle"
        case .needsInput: "exclamationmark.bubble"
        case .finished: "checkmark.circle"
        case nil: s.bell ? "bell" : "xmark.octagon"
        }
    }

    private func title(_ s: TerminalSession) -> String {
        switch s.agent {
        case .working(let k): "\(k.displayName) is working"
        case .needsInput(_, let m): m
        case .finished(_, let m): m
        case nil: s.bell ? "Bell in \(s.displayTitle)" : "\(s.displayTitle) exited with \(s.lastExitCode ?? 0)"
        }
    }
}

extension View {
    /// Tabs are drawn as custom views with tap gestures; expose them to
    /// VoiceOver and Full Keyboard Access as selectable buttons.
    func tabAccessibility(tab: TerminalTab, index: Int, selected: Bool, group: TabGroup?, select: @escaping () -> Void) -> some View {
        var parts = [tab.title]
        if let status = TabPresentation.accessibilityStatus(tab) { parts.append(status) }
        if let group { parts.append("in group \(group.name.isEmpty ? "untitled" : group.name)") }
        return accessibilityElement(children: .ignore)
            .accessibilityLabel(parts.joined(separator: ", "))
            .accessibilityHint(index < 9 ? "Tab \(index + 1), Command-\(index + 1)" : "Tab \(index + 1)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }
}
