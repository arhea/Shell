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

/// Spinner / agent / bell / failure indicator for a tab.
struct TabStatusIcon: View {
    let tab: TerminalTab
    let palette: ChromePalette

    var body: some View {
        Group {
            if let agent = tab.agent {
                switch agent {
                case .working:
                    ProgressView().controlSize(.mini).tint(palette.purple)
                case .needsInput:
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(palette.yellow)
                case .finished:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.green)
                }
            } else if tab.isBusy {
                ProgressView().controlSize(.mini)
            } else if tab.hasBell {
                Image(systemName: "bell.fill").foregroundStyle(palette.yellow)
            } else if tab.lastExitFailed {
                Circle().fill(palette.red).frame(width: 6, height: 6)
            } else if tab.hasUnseenOutput {
                Circle().fill(palette.accent).frame(width: 6, height: 6)
            } else {
                Image(systemName: "terminal").foregroundStyle(palette.secondary)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 14, height: 14)
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
            ChromeIconButton(symbol: "bell.badge", help: "Agent Activity (⌥⌘N)", palette: palette) {
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
        let selected = workspace.selectedTabID == tab.id && !workspace.showsDashboard
        let index = workspace.tabs.firstIndex { $0.id == tab.id } ?? 0
        HStack(spacing: 6) {
            TabStatusIcon(tab: tab, palette: palette)
            Text(tab.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.foreground : palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            ZStack {
                if hovering || selected {
                    Button { controller.closeTab(tab) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(hovering ? palette.hover : .clear))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondary)
                } else if index < 9 {
                    Text("⌘\(index + 1)").font(.system(size: 10)).foregroundStyle(palette.secondary.opacity(0.7))
                }
            }
            .frame(width: 22)
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(minWidth: 110, idealWidth: 170, maxWidth: 220, minHeight: 28, maxHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? palette.selected : hovering ? palette.hover : .clear))
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
        .help(tab.subtitle)
        .tabAccessibility(tab: tab, index: index, selected: selected, group: group) { controller.select(tab) }
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

struct VerticalTabSidebar: View {
    let controller: TerminalWindowController
    @Bindable var workspace: Workspace
    @Bindable var chrome: WindowChromeState

    var body: some View {
        let palette = ChromePalette.current
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                WindowDragArea().frame(width: chrome.isFullScreen ? 8 : 74)
                WindowDragArea()
                ChromeButtons(controller: controller, palette: palette, vertical: true)
            }
            .frame(height: 38)
            .padding(.trailing, 8)

            if let summary = DashboardVisibility(workspace: workspace).summary {
                DashboardSidebarRow(controller: controller, workspace: workspace, summary: summary, palette: palette)
                    .padding(.horizontal, 8)
                palette.border.frame(height: 1).padding(.horizontal, 14).padding(.vertical, 6)
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.items) { item in
                        switch item {
                        case .tab(let tab):
                            SidebarTabRow(controller: controller, workspace: workspace, tab: tab, group: nil, palette: palette)
                        case .group(let group, let tabs):
                            SidebarGroupHeader(controller: controller, workspace: workspace, group: group, count: tabs.count, palette: palette)
                            if !group.isCollapsed {
                                ForEach(tabs) { tab in
                                    SidebarTabRow(controller: controller, workspace: workspace, tab: tab, group: group, palette: palette)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider().overlay(palette.border)
            HStack(spacing: 4) {
                Button { controller.newTab() } label: {
                    Label("New Tab", systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
                Spacer()
                Button {
                    if let tab = workspace.selectedTab { controller.newGroup(with: tab) }
                } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
                .help("New Tab Group")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
        .background(palette.bar)
        .overlay(alignment: .trailing) { palette.border.frame(width: 1) }
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: 7)
                .contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in controller.resizeTabSidebar(by: v.translation.width) }
                    .onEnded { _ in controller.finishTabSidebarResize() })
                .onTapGesture(count: 2) { SettingsStore.shared.settings.sidebarWidth = 240 }
                .help("Drag to resize · double-click to reset")
        }
        .ignoresSafeArea()
    }
}

struct SidebarGroupHeader: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let group: TabGroup
    let count: Int
    let palette: ChromePalette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .foregroundStyle(palette.secondary)
            Circle().fill(group.color.color).frame(width: 8, height: 8)
            Text(group.name.isEmpty ? "Untitled group" : group.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            Spacer()
            Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary)
        }
        .padding(.horizontal, 6)
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

struct SidebarTabRow: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let tab: TerminalTab
    let group: TabGroup?
    let palette: ChromePalette
    @State private var hovering = false

    var body: some View {
        let selected = workspace.selectedTabID == tab.id && !workspace.showsDashboard
        let index = workspace.tabs.firstIndex { $0.id == tab.id } ?? 0
        HStack(alignment: .top, spacing: 8) {
            TabStatusIcon(tab: tab, palette: palette).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? palette.foreground : palette.foreground.opacity(0.85))
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 0)
            if hovering {
                Button { controller.closeTab(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
            } else if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 10)).foregroundStyle(palette.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.leading, group != nil ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? palette.selected : hovering ? palette.hover : .clear))
        .overlay(alignment: .leading) {
            if let group {
                Capsule().fill(group.color.color).frame(width: 2).padding(.vertical, 6).padding(.leading, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { controller.renameTab(tab) })
        .contextMenu { TabContextMenu(controller: controller, workspace: workspace, tab: tab) }
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(controller: controller, workspace: workspace, target: tab))
        .tabAccessibility(tab: tab, index: index, selected: selected, group: group) { controller.select(tab) }
    }

    @ViewBuilder private var subtitle: some View {
        if let agent = tab.agent {
            Text(agentText(agent)).font(.system(size: 11)).foregroundStyle(agentColor(agent)).lineLimit(2)
        } else {
            HStack(spacing: 4) {
                Text(tab.subtitle).lineLimit(1).truncationMode(.head)
                if let branch = tab.focusedSession?.gitBranch {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                    Text(branch).lineLimit(1)
                }
                if tab.sessions.count > 1 {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 9))
                    Text("\(tab.sessions.count)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.secondary)
        }
    }

    private func agentText(_ a: AgentStatus) -> String {
        switch a {
        case .working(let k): "\(k.displayName) is working…"
        case .needsInput(_, let m): m
        case .finished(_, let m): m
        }
    }

    private func agentColor(_ a: AgentStatus) -> Color {
        switch a {
        case .working: palette.purple
        case .needsInput: palette.yellow
        case .finished: palette.green
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

extension TabStatusIcon {
    /// What the icon shows, for VoiceOver.
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

extension View {
    /// Tabs are drawn as custom views with tap gestures; expose them to
    /// VoiceOver and Full Keyboard Access as selectable buttons.
    func tabAccessibility(tab: TerminalTab, index: Int, selected: Bool, group: TabGroup?, select: @escaping () -> Void) -> some View {
        var parts = [tab.title]
        if let status = TabStatusIcon.accessibilityStatus(tab) { parts.append(status) }
        if let group { parts.append("in group \(group.name.isEmpty ? "untitled" : group.name)") }
        return self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(parts.joined(separator: ", "))
            .accessibilityHint(index < 9 ? "Tab \(index + 1), Command-\(index + 1)" : "Tab \(index + 1)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }
}
