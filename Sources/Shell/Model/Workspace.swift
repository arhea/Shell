import AppKit
import Observation
import SwiftUI

enum TabGroupColor: String, Codable, CaseIterable, Identifiable {
    case gray, blue, purple, pink, red, orange, yellow, green, teal
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .gray: .gray
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        }
    }
    var title: String { rawValue.capitalized }
}

@MainActor
@Observable
final class TabGroup: Identifiable {
    let id: UUID
    var name: String
    var color: TabGroupColor
    var isCollapsed = false

    init(id: UUID = UUID(), name: String, color: TabGroupColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// A tab: a tree of split panes, each running a session.
@MainActor
@Observable
final class TerminalTab: Identifiable {
    let id: UUID
    private(set) var tree: PaneTree
    private(set) var sessions: [UUID: TerminalSession]
    var focusedSessionID: UUID
    var zoomedSessionID: UUID?
    var customTitle: String?
    var groupID: UUID?
    var broadcastInput = false

    init(id: UUID = UUID(), session: TerminalSession) {
        self.id = id
        tree = .leaf(session.id)
        sessions = [session.id: session]
        focusedSessionID = session.id
    }

    var focusedSession: TerminalSession? { sessions[focusedSessionID] }

    /// Sessions in visual (tree) order.
    var orderedSessions: [TerminalSession] { tree.leaves.compactMap { sessions[$0] } }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return focusedSession?.displayTitle ?? "Shell"
    }

    /// Full path, or the last command when the path would just repeat the title.
    var subtitle: String {
        guard let s = focusedSession else { return "" }
        if s.abbreviatedDirectory != title { return s.abbreviatedDirectory }
        return s.lastCommand.map { "$ " + $0.replacingOccurrences(of: "\n", with: " ") } ?? ""
    }

    var isBusy: Bool { sessions.values.contains { $0.isBusy } }
    var hasBell: Bool { sessions.values.contains { $0.bell } }
    var hasUnseenOutput: Bool { sessions.values.contains { $0.hasUnseenOutput } }

    /// The most urgent agent status across panes.
    var agent: AgentStatus? {
        let statuses = sessions.values.compactMap(\.agent)
        if let s = statuses.first(where: { if case .needsInput = $0 { true } else { false } }) { return s }
        if let s = statuses.first(where: { if case .working = $0 { true } else { false } }) { return s }
        return statuses.first
    }

    var lastExitFailed: Bool {
        guard let code = focusedSession?.lastExitCode else { return false }
        return code != 0
    }

    func split(_ target: UUID, with session: TerminalSession, direction: SplitDirection, before: Bool = false) {
        sessions[session.id] = session
        tree = tree.inserting(session.id, nextTo: target, direction: direction, before: before)
        zoomedSessionID = nil
        focusedSessionID = session.id
    }

    /// Removes a pane. Returns true if the tab is now empty.
    @discardableResult
    func remove(_ sessionID: UUID) -> Bool {
        guard let session = sessions.removeValue(forKey: sessionID) else { return sessions.isEmpty }
        session.close()
        if zoomedSessionID == sessionID { zoomedSessionID = nil }
        guard let newTree = tree.removing(sessionID) else { return true }
        let previous = tree
        tree = newTree
        if focusedSessionID == sessionID {
            // Focus the pane that took the closed pane's place.
            let frames = previous.layout()
            let closed = frames[sessionID] ?? .zero
            let remaining = newTree.leaves
            focusedSessionID = remaining.min { a, b in
                let fa = frames[a] ?? .zero, fb = frames[b] ?? .zero
                return hypot(fa.midX - closed.midX, fa.midY - closed.midY) < hypot(fb.midX - closed.midX, fb.midY - closed.midY)
            } ?? remaining[0]
        }
        return false
    }

    func setRatio(_ ratio: Double, forSplit id: UUID) {
        tree = tree.settingRatio(ratio, forSplit: id)
    }

    func equalize() { tree = tree.equalized() }

    /// Moves every session out of this tab (used when merging/moving).
    func detachAll() -> [TerminalSession] {
        let list = orderedSessions
        sessions.removeAll()
        return list
    }

    func closeAll() {
        for s in sessions.values { s.close() }
        sessions.removeAll()
    }
}

/// Everything shown in one window: tabs, groups and selection.
@MainActor
@Observable
final class Workspace {
    var tabs: [TerminalTab] = []
    var groups: [TabGroup] = []
    var selectedTabID: UUID?
    /// The Claude dashboard is showing in place of the selected tab.
    var showsDashboard = false
    /// The GitHub tab's board, while that tab is open (it stays in the tab
    /// bar after you switch away, until closed).
    var githubBoard: GitHubBoardModel?
    /// The GitHub tab is open but has no repository to show yet.
    var githubTabOpen = false
    /// The GitHub tab is showing in place of the selected tab.
    var showsGitHub = false
    /// A native page (Claude dashboard or GitHub tab) covers the terminals.
    var showsNativePage: Bool { showsDashboard || showsGitHub }
    /// Bumped whenever the pane layout of the selected tab changes so the
    /// AppKit split view knows to rebuild.
    private(set) var layoutRevision = 0

    var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedTabID } }

    func group(_ id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func layoutChanged() { layoutRevision &+= 1 }

    func insert(_ tab: TerminalTab, after anchor: TerminalTab?) {
        if let anchor, let idx = tabs.firstIndex(where: { $0.id == anchor.id }) {
            // Keep new tabs inside the anchor's group so groups stay contiguous.
            tab.groupID = anchor.groupID
            tabs.insert(tab, at: idx + 1)
        } else {
            tabs.append(tab)
        }
    }

    func remove(_ tab: TerminalTab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if selectedTabID == tab.id {
            let next = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)]
            selectedTabID = next?.id
        }
        pruneEmptyGroups()
    }

    func move(_ tab: TerminalTab, by offset: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let target = min(max(idx + offset, 0), tabs.count - 1)
        guard target != idx else { return }
        tabs.remove(at: idx)
        tabs.insert(tab, at: target)
        // Adopt the group of the tab we moved next to, keeping groups contiguous.
        let neighbors = [target > 0 ? tabs[target - 1] : nil, target + 1 < tabs.count ? tabs[target + 1] : nil].compactMap { $0 }
        if !neighbors.contains(where: { $0.groupID == tab.groupID }) {
            // Join a group only when both neighbors belong to it.
            let shared = neighbors.first?.groupID
            tab.groupID = shared != nil && neighbors.allSatisfy { $0.groupID == shared } ? shared : nil
        }
        pruneEmptyGroups()
    }

    func move(_ tab: TerminalTab, toIndex index: Int, group groupID: UUID?) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        let target = min(max(index > idx ? index - 1 : index, 0), tabs.count)
        tabs.insert(tab, at: target)
        tab.groupID = groupID
        normalizeGroups()
    }

    func addToGroup(_ tab: TerminalTab, _ group: TabGroup) {
        tab.groupID = group.id
        normalizeGroups()
    }

    func removeFromGroup(_ tab: TerminalTab) {
        guard tab.groupID != nil else { return }
        // Move it after the group's last member so the group stays contiguous.
        let gid = tab.groupID
        tab.groupID = nil
        if let lastIdx = tabs.lastIndex(where: { $0.groupID == gid }), let idx = tabs.firstIndex(where: { $0.id == tab.id }), idx < lastIdx {
            tabs.remove(at: idx)
            tabs.insert(tab, at: lastIdx)
        }
        pruneEmptyGroups()
    }

    @discardableResult
    func createGroup(name: String, with tab: TerminalTab) -> TabGroup {
        let used = Set(groups.map(\.color))
        let color = TabGroupColor.allCases.dropFirst().first { !used.contains($0) } ?? .blue
        let group = TabGroup(name: name, color: color)
        groups.append(group)
        addToGroup(tab, group)
        return group
    }

    func ungroup(_ group: TabGroup) {
        for t in tabs where t.groupID == group.id { t.groupID = nil }
        groups.removeAll { $0.id == group.id }
    }

    func closeGroupTabs(_ group: TabGroup) -> [TerminalTab] {
        tabs.filter { $0.groupID == group.id }
    }

    /// Makes grouped tabs contiguous, ordered by each group's first appearance.
    func normalizeGroups() {
        var result: [TerminalTab] = []
        var placed = Set<UUID>()
        for tab in tabs where !placed.contains(tab.id) {
            if let gid = tab.groupID {
                for member in tabs where member.groupID == gid {
                    result.append(member)
                    placed.insert(member.id)
                }
            } else {
                result.append(tab)
                placed.insert(tab.id)
            }
        }
        tabs = result
        pruneEmptyGroups()
    }

    private func pruneEmptyGroups() {
        let used = Set(tabs.compactMap(\.groupID))
        groups.removeAll { !used.contains($0.id) }
    }

    /// Tabs arranged for display: ungrouped tabs and groups in order.
    enum Item: Identifiable {
        case tab(TerminalTab)
        case group(TabGroup, [TerminalTab])
        var id: UUID {
            switch self {
            case .tab(let t): t.id
            case .group(let g, _): g.id
            }
        }
    }

    var items: [Item] {
        var result: [Item] = []
        var seenGroups = Set<UUID>()
        for tab in tabs {
            if let gid = tab.groupID, let group = group(gid) {
                guard seenGroups.insert(gid).inserted else { continue }
                result.append(.group(group, tabs.filter { $0.groupID == gid }))
            } else {
                result.append(.tab(tab))
            }
        }
        return result
    }
}
