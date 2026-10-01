import Foundation
import Observation

// Plain inputs for the right inspector's panels. The views take these values
// (not the Claude session or a terminal pane), so whoever owns the data can
// feed them without the inspector knowing where it came from.

/// The inspector's tabs, left to right. Session shows only for Claude panes;
/// Checks only when the repository has a GitHub remote.
enum InspectorTab: String, CaseIterable, Hashable, Sendable {
    case session, worktrees, checks, files

    var title: String {
        switch self {
        case .session: "Session"
        case .worktrees: "Worktrees"
        case .checks: "Checks"
        case .files: "Files"
        }
    }

    /// The persisted sidebar tab this maps to. Session has no stored value:
    /// Claude panes remember it in memory (`InspectorTabMemory`).
    var storedTab: SidebarTab? {
        switch self {
        case .session: nil
        case .worktrees: .worktrees
        case .checks: .github
        case .files: .files
        }
    }

    init(_ stored: SidebarTab) {
        switch stored {
        case .files: self = .files
        case .worktrees: self = .worktrees
        case .github: self = .checks
        }
    }

    /// The tabs a pane shows, in order.
    static func available(isClaude: Bool, hasGitHub: Bool) -> [InspectorTab] {
        var tabs: [InspectorTab] = isClaude ? [.session] : []
        tabs.append(.worktrees)
        if hasGitHub { tabs.append(.checks) }
        tabs.append(.files)
        return tabs
    }

    /// The selected tab, falling back when the preferred one isn't shown:
    /// Claude panes land on Session, terminal panes on Files.
    static func resolve(preferred: InspectorTab, available: [InspectorTab]) -> InspectorTab {
        if available.contains(preferred) { return preferred }
        return available.first == .session ? .session : .files
    }
}

/// The tab Claude panes last showed. Terminal panes keep theirs in
/// `AppSettings.sidebarTab`; Claude panes start on Session, which has no
/// stored setting, so their choice lives here for the app's lifetime.
@MainActor
@Observable
final class InspectorTabMemory {
    static let shared = InspectorTabMemory()
    var claudeTab: InspectorTab = .session
}

/// One changed file in the working tree, with its line counts.
struct InspectorChange: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case modified, added, deleted, renamed, conflicted
    }

    /// Repository-relative path.
    var path: String
    var kind: Kind
    /// Nil for binary files and folders.
    var additions: Int?
    var deletions: Int?
    /// Not yet in the index (`git add` would add it).
    var isUntracked = false

    var id: String { path }
    var fileName: String { (path.hasSuffix("/") ? String(path.dropLast()) as NSString : path as NSString).lastPathComponent }
    /// The containing folder's last component ("Tests", "Claude"), or nil at the root.
    var folder: String? {
        let dir = ((path.hasSuffix("/") ? String(path.dropLast()) : path) as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : (dir as NSString).lastPathComponent
    }

    var letter: String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "C"
        }
    }
}

/// Files, additions and deletions across a list of changes: "3 files +79 −3".
struct InspectorChangeTotals: Equatable, Sendable {
    var files = 0
    var additions = 0
    var deletions = 0

    init(_ changes: [InspectorChange]) {
        files = changes.count
        additions = changes.compactMap(\.additions).reduce(0, +)
        deletions = changes.compactMap(\.deletions).reduce(0, +)
    }
}

/// One entry of the agent's to-do list.
struct InspectorTodo: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable { case pending, inProgress, completed }
    var id: String
    var title: String
    var state: State

    init(id: String? = nil, title: String, state: State) {
        self.id = id ?? title
        self.title = title
        self.state = state
    }
}

/// A subagent or background task the session started.
struct InspectorBackgroundItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case subagent, backgroundTask

        var label: String { self == .subagent ? "Subagent" : "Background task" }
    }

    /// A job row inside a CI-watcher style task ("lint 32s", "Build and test 3m 12s").
    struct Job: Identifiable, Hashable, Sendable {
        var id: String { name }
        var name: String
        var state: CheckJob.State
        /// "32s", "queued".
        var detail: String?
    }

    var id: String
    /// "code-reviewer", "CI · PR #39".
    var name: String
    var kind: Kind
    var startedAt: Date?
    var isRunning = true
    /// "Reading StreamWriter.swift · Read 4", or the command line for a task.
    var detail: String?
    /// Show `detail` in the code font (a command line).
    var detailIsCommand = false
    var jobs: [Job] = []
}
