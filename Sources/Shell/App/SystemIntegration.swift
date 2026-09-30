import AppKit

// macOS integration points outside the window: Finder services, the Dock
// menu, and the shared "open a tab here" entry point they and Shortcuts use.

extension AppDelegate {
    /// Opens a tab in `directory` (in the active window, or a new window), and
    /// optionally runs `command` once the shell is ready.
    @discardableResult
    func openTab(directory: String?, command: String? = nil, newWindow: Bool = false) -> TerminalSession? {
        let dir = directory.map { ($0 as NSString).expandingTildeInPath }
        let session: TerminalSession?
        if !newWindow, let c = activeController {
            session = c.newTab(directory: dir).focusedSession
            c.showWindow(nil)
        } else {
            session = self.newWindow(directory: dir).workspace.selectedTab?.focusedSession
        }
        if let command, !command.isEmpty, let session {
            session.pendingCommand = command
            // Without the integration no prompt event will ever run it.
            if session.state == .unmanaged { session.flushPendingCommandWithoutIntegration() }
        }
        NSApp.activate()
        return session
    }

    // MARK: Dock menu

    func buildDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(dockItem("New Window") { AppDelegate.shared.openTab(directory: nil, newWindow: true) })
        menu.addItem(dockItem("New Tab") { AppDelegate.shared.openTab(directory: nil) })

        // Agents waiting on you, like the Dock badge counts.
        let waiting = SessionRegistry.shared.all.compactMap { s -> (TerminalSession, String)? in
            switch s.agent {
            case .needsInput(let kind, _): return (s, "\(kind.displayName) needs input")
            case .finished(let kind, _): return (s, "\(kind.displayName) is done")
            default: return nil
            }
        }
        if !waiting.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Needs You"))
            for (session, status) in waiting.prefix(8) {
                let item = dockItem("\(session.displayTitle) — \(status)") { [weak session] in
                    NSApp.activate()
                    session?.onRequestFocus?()
                }
                item.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        let recent = RecentDirectories.list.filter { FileManager.default.fileExists(atPath: $0) }.prefix(8)
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Recent Folders"))
            for dir in recent {
                let item = dockItem((dir as NSString).abbreviatingWithTildeInPath) { AppDelegate.shared.openTab(directory: dir) }
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        return menu
    }

    private func dockItem(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
        let target = ClosureMenuTarget(action)
        item.target = target
        item.representedObject = target // the menu item keeps its target alive
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem { .sectionHeader(title: title) }
}

@MainActor
private final class ClosureMenuTarget: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}

// MARK: - Recent folders

/// Folders recently used as a working directory, newest first (for the Dock menu).
@MainActor
enum RecentDirectories {
    private static let key = "RecentDirectories"
    private static let limit = 12

    static var list: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func note(_ directory: String) {
        let path = (directory as NSString).standardizingPath
        guard path != NSHomeDirectory(), path != "/" else { return }
        var items = list.filter { $0 != path }
        items.insert(path, at: 0)
        UserDefaults.standard.set(Array(items.prefix(limit)), forKey: key)
    }
}

// MARK: - Finder services

/// "New Shell Tab Here" / "New Shell Window Here" in Finder's context menu
/// (Services). Declared under `NSServices` in project.yml.
@MainActor
final class ServicesProvider: NSObject {
    @objc func openTabHere(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pboard, newWindow: false)
    }

    @objc func openWindowHere(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pboard, newWindow: true)
    }

    private func open(_ pboard: NSPasteboard, newWindow: Bool) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for (i, url) in urls.enumerated() {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let dir = isDir.boolValue ? url.path : url.deletingLastPathComponent().path
            // Several folders in "new window" mode: one window, one tab each.
            AppDelegate.shared.openTab(directory: dir, newWindow: newWindow && i == 0)
        }
    }
}
