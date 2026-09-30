import AppKit

/// Saves windows, tabs, groups and split layouts (with each pane's working
/// directory) on quit, and recreates them on launch.
@MainActor
enum SessionRestore {
    struct Snapshot: Codable {
        var windows: [WindowSnapshot]
    }

    struct WindowSnapshot: Codable {
        var frame: [Double]
        var selected: Int
        var groups: [GroupSnapshot]
        var tabs: [TabSnapshot]
    }

    struct GroupSnapshot: Codable {
        var id: UUID
        var name: String
        var color: TabGroupColor
        var collapsed: Bool
    }

    struct TabSnapshot: Codable {
        var title: String?
        var group: UUID?
        var tree: PaneTreeSnapshot
        var focusedIndex: Int
    }

    static var fileURL: URL { SettingsStore.supportDirectory.appendingPathComponent("session.json") }

    static func save(controllers: [TerminalWindowController]) {
        guard SettingsStore.shared.settings.restoreSession else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let windows = controllers.compactMap { c -> WindowSnapshot? in
            guard let window = c.window, !c.workspace.tabs.isEmpty else { return nil }
            let f = window.frame
            return WindowSnapshot(
                frame: [f.minX, f.minY, f.width, f.height],
                selected: c.workspace.selectedIndex ?? 0,
                groups: c.workspace.groups.map { GroupSnapshot(id: $0.id, name: $0.name, color: $0.color, collapsed: $0.isCollapsed) },
                tabs: c.workspace.tabs.map { tab in
                    TabSnapshot(
                        title: tab.customTitle,
                        group: tab.groupID,
                        tree: snapshot(tab.tree, tab: tab),
                        focusedIndex: tab.tree.leaves.firstIndex(of: tab.focusedSessionID) ?? 0)
                })
        }
        guard let data = try? JSONEncoder().encode(Snapshot(windows: windows)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func snapshot(_ tree: PaneTree, tab: TerminalTab) -> PaneTreeSnapshot {
        switch tree {
        case .leaf(let id):
            return PaneTreeSnapshot(leafDirectory: tab.sessions[id]?.workingDirectory, leafSessionID: id)
        case .split(_, let dir, let ratio, let a, let b):
            return PaneTreeSnapshot(direction: dir, ratio: ratio, children: [snapshot(a, tab: tab), snapshot(b, tab: tab)])
        }
    }

    /// Returns true if at least one window was restored.
    static func restore(into app: AppDelegate) -> Bool {
        guard SettingsStore.shared.settings.restoreSession,
              let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snap.windows.isEmpty else { return false }

        for w in snap.windows {
            let frame = w.frame.count == 4 ? NSRect(x: w.frame[0], y: w.frame[1], width: w.frame[2], height: w.frame[3]) : nil
            let visibleFrame = frame.flatMap { f in NSScreen.screens.contains { $0.visibleFrame.intersects(f) } ? f : nil }
            let controller = app.newWindowController(frame: visibleFrame)
            for g in w.groups {
                let group = TabGroup(id: g.id, name: g.name, color: g.color)
                group.isCollapsed = g.collapsed
                controller.workspace.groups.append(group)
            }
            for t in w.tabs {
                guard let firstDir = firstDirectory(t.tree) else { continue }
                let tab = controller.newTab(directory: firstDir, sessionID: restorableID(firstLeaf(t.tree)), select: false)
                tab.customTitle = t.title
                tab.groupID = controller.workspace.groups.contains { $0.id == t.group } ? t.group : nil
                if let root = tab.focusedSession {
                    rebuild(t.tree, at: root, in: tab, controller: controller)
                }
                let leaves = tab.tree.leaves
                if leaves.indices.contains(t.focusedIndex) { tab.focusedSessionID = leaves[t.focusedIndex] }
            }
            controller.workspace.normalizeGroups()
            guard !controller.workspace.tabs.isEmpty else {
                controller.close()
                continue
            }
            let idx = min(max(w.selected, 0), controller.workspace.tabs.count - 1)
            controller.select(controller.workspace.tabs[idx])
            controller.showWindow(nil)
        }
        return !app.controllers.isEmpty
    }

    private static func firstLeaf(_ s: PaneTreeSnapshot) -> PaneTreeSnapshot {
        if let children = s.children, let first = children.first { return firstLeaf(first) }
        return s
    }

    /// The saved session ID, unless a live session already has it.
    private static func restorableID(_ leaf: PaneTreeSnapshot) -> UUID? {
        guard let id = leaf.leafSessionID, SessionRegistry.shared.session(id) == nil else { return nil }
        return id
    }

    private static func firstDirectory(_ s: PaneTreeSnapshot) -> String? {
        if let children = s.children, let first = children.first { return firstDirectory(first) }
        let dir = s.leafDirectory ?? NSHomeDirectory()
        return FileManager.default.fileExists(atPath: dir) ? dir : NSHomeDirectory()
    }

    /// Recreates splits: `anchor` already occupies the snapshot's first leaf.
    private static func rebuild(_ s: PaneTreeSnapshot, at anchor: TerminalSession, in tab: TerminalTab, controller: TerminalWindowController) {
        guard let children = s.children, children.count == 2, let dir = s.direction else { return }
        let secondDir = firstDirectory(children[1])
        let second = controller.makeSession(directory: secondDir, id: restorableID(firstLeaf(children[1])))
        tab.split(anchor.id, with: second, direction: dir)
        if case .split(let sid, _, _, _, _) = findSplit(tab.tree, containing: anchor.id, and: second.id) {
            tab.setRatio(s.ratio ?? 0.5, forSplit: sid)
        }
        rebuild(children[0], at: anchor, in: tab, controller: controller)
        rebuild(children[1], at: second, in: tab, controller: controller)
    }

    private static func findSplit(_ tree: PaneTree, containing a: UUID, and b: UUID) -> PaneTree? {
        guard case .split(_, _, _, let x, let y) = tree else { return nil }
        if case .leaf(let l) = x, case .leaf(let r) = y, l == a, r == b { return tree }
        return findSplit(x, containing: a, and: b) ?? findSplit(y, containing: a, and: b)
    }
}
