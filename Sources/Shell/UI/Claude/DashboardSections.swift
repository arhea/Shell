import Foundation

// The Claude Sessions page's model: which section each session sits in,
// how long it has been there, and the text its cards show. Kept free of
// views so it can be tested and stays cheap on every render.

extension ClaudeDashboard {
    /// The page's three sections, in the order they show.
    enum Section: Int, CaseIterable, Equatable {
        /// Waiting on the user: approve right there.
        case needsYou
        /// Working or starting.
        case working
        /// Done, idle or exited.
        case idle

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .working: "Working"
            case .idle: "Idle"
            }
        }

        var status: StatusKind {
            switch self {
            case .needsYou: .needsYou
            case .working: .working
            case .idle: .idle
            }
        }
    }

    static func section(for activity: Activity) -> Section {
        switch activity {
        case .needsInput: .needsYou
        case .working, .starting: .working
        case .finished, .idle, .exited: .idle
        }
    }

    /// Items split into the page's sections, each in tab order, except that
    /// the idle section lists finished sessions before idle and exited ones.
    struct Grouped<Item> {
        var needsYou: [Item] = []
        var working: [Item] = []
        var idle: [Item] = []

        var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && idle.isEmpty }

        func items(in section: Section) -> [Item] {
            switch section {
            case .needsYou: needsYou
            case .working: working
            case .idle: idle
            }
        }
    }

    static func grouped<Item>(_ items: [Item], activity: (Item) -> Activity) -> Grouped<Item> {
        var g = Grouped<Item>()
        var idle: [(rank: Int, index: Int, item: Item)] = []
        for (i, item) in items.enumerated() {
            let a = activity(item)
            switch section(for: a) {
            case .needsYou: g.needsYou.append(item)
            case .working: g.working.append(item)
            case .idle:
                let rank = switch a {
                case .finished: 0
                case .exited: 2
                default: 1
                }
                idle.append((rank, i, item))
            }
        }
        g.idle = idle.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.item)
        return g
    }

    /// Whether a session matches the page's filter: its title, folder or branch.
    static func matches(_ query: String, title: String, directory: String, branch: String?) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q) || directory.localizedCaseInsensitiveContains(q)
            || (branch?.localizedCaseInsensitiveContains(q) ?? false)
    }

    static func matches(_ query: String, entry: Entry) -> Bool {
        matches(query, title: title(for: entry), directory: fullDirectory(for: entry.session), branch: branch(for: entry.session))
    }

    /// "42s", "2m 41s", "14m", "1h 5m": seconds while short, then coarser.
    static func elapsed(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        switch s {
        case ..<60: return "\(s)s"
        case ..<600: return "\(s / 60)m \(s % 60)s"
        case ..<3600: return "\(s / 60)m"
        default:
            let m = (s % 3600) / 60
            return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
        }
    }

    /// "waiting <1 min", "waiting 4 min", "waiting 2 h".
    static func waiting(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval)) / 60
        if minutes < 1 { return "waiting <1 min" }
        if minutes < 60 { return "waiting \(minutes) min" }
        return "waiting \(minutes / 60) h"
    }

    /// The Select Tab shortcut for a zero-based tab index ("⌘3"), if it has one.
    static func tabShortcut(_ index: Int) -> String? {
        let actions: [ShortcutAction] = [.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8]
        guard actions.indices.contains(index) else { return nil }
        return actions[index].shortcut?.displayString
    }

    /// "Shell" for arhea/Shell (a worktree's folder name says less than its repo).
    static func repoName(slug: String?, folder: String) -> String {
        guard let slug, let name = slug.split(separator: "/").last, !name.isEmpty else { return folder }
        return String(name)
    }
}

/// When each Shell session entered its current section, so cards can say
/// "waiting 4 min" or "2m 41s". Noted whenever the tab strip or the page
/// computes a summary; not observed, so noting never re-renders anything.
@MainActor
final class ActivityClock {
    static let shared = ActivityClock()
    private var marks: [UUID: (section: ClaudeDashboard.Section, since: Date)] = [:]

    /// The time `id` entered `section`, starting the clock if it just did.
    @discardableResult
    func note(_ id: UUID, section: ClaudeDashboard.Section, now: Date = Date()) -> Date {
        if let mark = marks[id], mark.section == section { return mark.since }
        marks[id] = (section, now)
        if marks.count > 64 { prune() }
        return now
    }

    func since(_ id: UUID, section: ClaudeDashboard.Section, now: Date = Date()) -> Date {
        note(id, section: section, now: now)
    }

    /// Forgets sessions that closed.
    func prune(keeping live: Set<UUID>? = nil) {
        let keep = live ?? Set(SessionRegistry.shared.all.map(\.id))
        marks = marks.filter { keep.contains($0.key) }
    }

    var count: Int { marks.count }
}

/// What a native permission request asks for, in a sentence: "Claude wants to
/// edit TabStore.swift", plus the files or command it touches.
enum DashboardRequestText {
    static func headline(toolName: String, input: [String: Any]) -> String {
        let file = (input["file_path"] ?? input["notebook_path"]) as? String
        let name = file.map { ($0 as NSString).lastPathComponent }
        switch toolName {
        case "Edit", "MultiEdit": return "Claude wants to edit " + (name ?? "a file")
        case "Write": return "Claude wants to write " + (name ?? "a file")
        case "NotebookEdit": return "Claude wants to edit " + (name ?? "a notebook")
        case "Bash": return "Claude wants to run a command"
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host() }
            return "Claude wants to fetch " + (host ?? "a web page")
        case "WebSearch": return "Claude wants to search the web"
        case "Read": return "Claude wants to read " + (name ?? "a file")
        default:
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 { return "Claude wants to use \(parts[1])’s \(parts[2...].joined(separator: "_"))" }
            }
            return "Claude wants to use \(toolName)"
        }
    }

    /// Monospaced chips under the headline: the file's short path, the command.
    static func chips(toolName: String, input: [String: Any]) -> [String] {
        if toolName == "Bash", let command = input["command"] as? String {
            let line = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command
            return [line.count > 80 ? String(line.prefix(79)) + "…" : line]
        }
        if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
            return [ClaudeToolFormat.shortPath(path)]
        }
        if let pattern = input["pattern"] as? String { return [pattern] }
        return []
    }

    /// The button label for applying Claude Code's suggested permission
    /// update, named for what it actually does. Nil when there's no
    /// suggestion (so only Allow once and Deny show).
    static func alwaysLabel(suggestions: [Any]) -> String? {
        let updates = suggestions.compactMap { $0 as? [String: Any] }
        guard !suggestions.isEmpty else { return nil }
        if updates.contains(where: { $0["type"] as? String == "setMode" && $0["mode"] as? String == "acceptEdits" }) {
            let session = updates.contains { $0["type"] as? String == "setMode" && $0["destination"] as? String == "session" }
            return session ? "Allow edits this session" : "Always allow edits"
        }
        if updates.contains(where: { $0["type"] as? String == "addDirectories" }) { return "Allow this folder" }
        if !updates.isEmpty, updates.allSatisfy({ $0["destination"] as? String == "session" }) { return "Allow this session" }
        return "Always allow"
    }
}
