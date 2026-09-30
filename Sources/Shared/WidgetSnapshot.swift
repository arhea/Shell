import Foundation

/// What Shell's desktop widgets show: running agents, plan limits and token
/// totals. The app writes it to the shared app group container; the sandboxed
/// widget extension only reads it (it can't see ~/.claude or the control socket).
struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Team-prefixed so Developer ID builds need no provisioning profile.
    static let appGroup = "T9PCKZ42NK.app.bethesdalabs.Shell"
    static let widgetKind = "app.bethesdalabs.Shell.agents"
    static let fileName = "widget-snapshot.json"
    /// Older than this and the app is assumed gone (the app rewrites it every few minutes).
    static let staleAfter: TimeInterval = 20 * 60

    enum Activity: String, Codable, Sendable, CaseIterable {
        case needsInput, working, starting, finished, idle, exited

        var title: String {
            switch self {
            case .needsInput: "Needs input"
            case .working: "Working"
            case .starting: "Starting"
            case .finished: "Done"
            case .idle: "Idle"
            case .exited: "Exited"
            }
        }

        /// Sort order: what wants attention first.
        var rank: Int { Self.allCases.firstIndex(of: self)! }
    }

    struct Agent: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        /// "Claude", "Codex", …
        var kind: String
        var title: String
        /// Home-relative ("~/code/shell").
        var directory: String
        var branch: String?
        var activity: Activity
        var message: String?
        /// "Window 2 · Tab 3".
        var location: String
    }

    struct Limit: Codable, Equatable, Sendable {
        /// 0…1 of the window used.
        var utilization: Double
        var resetsAt: Date?
    }

    struct Day: Codable, Equatable, Identifiable, Sendable {
        var day: Date
        var tokens: Int
        var id: Date { day }
    }

    struct Model: Codable, Equatable, Sendable {
        /// Display name ("Opus 5.5").
        var name: String
        var tokens: Int
    }

    var generatedAt: Date
    var appRunning: Bool
    var agents: [Agent] = []
    var fiveHour: Limit?
    var sevenDay: Limit?
    var limitsUpdatedAt: Date?
    var tokensToday: Int?
    var tokensLastFiveHours: Int?
    var sessionsToday: Int?
    var days: [Day] = []
    var models: [Model] = []

    static let empty = WidgetSnapshot(generatedAt: .distantPast, appRunning: false)

    // MARK: Derived

    func isLive(at now: Date = Date()) -> Bool {
        appRunning && now.timeIntervalSince(generatedAt) < Self.staleAfter
    }

    func count(_ activity: Activity) -> Int { agents.filter { $0.activity == activity }.count }

    /// Agents that want attention first, then by title.
    static func sorted(_ agents: [Agent]) -> [Agent] {
        agents.sorted { a, b in
            a.activity.rank != b.activity.rank ? a.activity.rank < b.activity.rank
                : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// A limit whose window has already reset reads as nothing used.
    static func current(_ limit: Limit?, at now: Date = Date()) -> Limit? {
        guard let limit else { return nil }
        if let r = limit.resetsAt, r < now { return nil }
        return limit
    }

    /// Changes worth spending a widget reload on right away: an agent
    /// appearing, leaving, or changing state. Token and message churn waits.
    func statusSignature() -> [String] {
        agents.map { "\($0.id.uuidString):\($0.activity.rawValue)" }.sorted() + ["running:\(appRunning)"]
    }

    // MARK: Storage

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }

    static func load(from url: URL? = fileURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save(to url: URL? = Self.fileURL) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Formatting

    /// 1234567 → "1.2M".
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(n)"
        }
    }
}

/// `shellapp://` links from widgets (and anything else) into Shell.
enum ShellAppURL: Equatable {
    static let scheme = "shellapp"

    /// shellapp://dashboard
    case dashboard
    /// shellapp://session/<uuid>
    case session(UUID)

    var url: URL {
        switch self {
        case .dashboard: URL(string: "\(Self.scheme)://dashboard")!
        case .session(let id): URL(string: "\(Self.scheme)://session/\(id.uuidString)")!
        }
    }

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "dashboard":
            self = .dashboard
        case "session":
            guard let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:)) else { return nil }
            self = .session(id)
        default:
            return nil
        }
    }
}
