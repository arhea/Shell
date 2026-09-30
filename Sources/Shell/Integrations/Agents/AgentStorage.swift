import AppKit
import Observation

/// One kind of data Claude Code or Codex keeps on disk.
struct StorageCategory: Identifiable {
    enum Agent: String { case claude = "Claude Code", codex = "Codex" }
    enum Kind {
        /// Rebuilt on demand; "Clear" removes everything not touched in the last day.
        case cache
        /// Past work (transcripts, checkpoints); only pruned by age.
        case history
    }

    var id: String
    var agent: Agent
    var kind: Kind
    var title: String
    var detail: String
    /// Folders shown by "Reveal in Finder".
    var roots: [URL]
    /// Only remove while this app isn't running (its files are in use).
    var requiresClosed: String?
    /// The removable units (session folders, transcript files, log files…).
    var items: @Sendable () -> [URL]

    static let recentGuard: TimeInterval = 24 * 3600
}

/// Measures and prunes Claude Code and Codex caches, logs and history.
enum AgentStorage {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    // Regex is immutable once built; it just isn't marked Sendable.
    nonisolated(unsafe) static let uuidPrefix = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

    static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func isSessionEntry(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().prefixMatch(of: uuidPrefix) != nil
    }

    // MARK: Categories

    static func categories(home: URL = AgentStorage.home) -> [StorageCategory] {
        let claude = home.appendingPathComponent(".claude")
        let codex = home.appendingPathComponent(".codex")
        let caches = home.appendingPathComponent("Library/Caches")
        return [
            StorageCategory(
                id: "claude-transcripts", agent: .claude, kind: .history, title: "Session transcripts",
                detail: "~/.claude/projects — conversation history used by --resume, --continue and /resume. Project memory is never touched.",
                roots: [claude.appendingPathComponent("projects")],
                items: {
                    children(claude.appendingPathComponent("projects")).flatMap { children($0).filter(isSessionEntry) }
                }),
            StorageCategory(
                id: "claude-checkpoints", agent: .claude, kind: .history, title: "File checkpoints",
                detail: "~/.claude/file-history — snapshots that let you rewind edits in a session.",
                roots: [claude.appendingPathComponent("file-history")],
                items: { children(claude.appendingPathComponent("file-history")) }),
            StorageCategory(
                id: "claude-scratch", agent: .claude, kind: .cache, title: "Session scratch & task output",
                detail: "~/Library/Caches/ClaudeCode — per-session scratchpads, background task output and sockets from Claude's apps.",
                roots: [caches.appendingPathComponent("ClaudeCode")],
                items: {
                    // cc-socks holds live IPC sockets; never touch it.
                    children(caches.appendingPathComponent("ClaudeCode")).filter { $0.lastPathComponent != "cc-socks" }.flatMap { user in
                        children(user).flatMap { project in
                            let sessions = children(project).filter(isSessionEntry)
                            return sessions.isEmpty ? [project] : sessions
                        }
                    }
                }),
            StorageCategory(
                id: "claude-logs", agent: .claude, kind: .cache, title: "MCP & debug logs",
                detail: "~/Library/Caches/claude-cli-nodejs — logs from MCP servers and the CLI, per project.",
                roots: [caches.appendingPathComponent("claude-cli-nodejs")],
                items: {
                    children(caches.appendingPathComponent("claude-cli-nodejs")).flatMap { project in
                        children(project).flatMap { log in (try? log.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? children(log) : [log] }
                    }
                }),
            StorageCategory(
                id: "claude-misc", agent: .claude, kind: .cache, title: "Shell snapshots, telemetry & temp",
                detail: "~/.claude/shell-snapshots, session-env, telemetry, paste-cache and cache.",
                roots: ["shell-snapshots", "session-env", "telemetry", "paste-cache", "cache"].map { claude.appendingPathComponent($0) },
                items: {
                    ["shell-snapshots", "session-env", "telemetry", "paste-cache", "cache"].flatMap { children(claude.appendingPathComponent($0)) }
                }),
            StorageCategory(
                id: "claude-versions", agent: .claude, kind: .cache, title: "Old CLI versions",
                detail: "~/.local/share/claude/versions — earlier native installs. The newest is always kept.",
                roots: [home.appendingPathComponent(".local/share/claude/versions")],
                items: {
                    let versions = children(home.appendingPathComponent(".local/share/claude/versions"))
                        .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
                    return Array(versions.dropLast())
                }),
            StorageCategory(
                id: "codex-sessions", agent: .codex, kind: .history, title: "Sessions",
                detail: "~/.codex/sessions and archived_sessions — conversation history used by codex resume.",
                roots: [codex.appendingPathComponent("sessions"), codex.appendingPathComponent("archived_sessions")],
                items: {
                    var files: [URL] = []
                    for root in [codex.appendingPathComponent("sessions"), codex.appendingPathComponent("archived_sessions")] {
                        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                        while let u = e.nextObject() as? URL {
                            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(u) }
                        }
                    }
                    return files
                }),
            StorageCategory(
                id: "codex-caches", agent: .codex, kind: .cache, title: "Temp & plugin caches",
                detail: "~/.codex/.tmp, ~/.codex/cache and ~/Library/Caches/*codex* — rebuilt when Codex starts.",
                roots: [codex.appendingPathComponent(".tmp"), codex.appendingPathComponent("cache"),
                        caches.appendingPathComponent("com.openai.codex"), caches.appendingPathComponent("codex")],
                requiresClosed: "codex",
                items: {
                    [codex.appendingPathComponent(".tmp"), codex.appendingPathComponent("cache"),
                     caches.appendingPathComponent("com.openai.codex"), caches.appendingPathComponent("codex")].flatMap(children)
                }),
            StorageCategory(
                id: "codex-logs", agent: .codex, kind: .cache, title: "Logs",
                detail: "~/.codex/logs_*.sqlite — Codex's log database; recreated on next launch.",
                roots: [codex],
                requiresClosed: "codex",
                items: {
                    children(codex).filter { $0.lastPathComponent.hasPrefix("logs_") && $0.lastPathComponent.contains(".sqlite") }
                }),
        ]
    }

    // MARK: Measuring

    struct Item {
        var url: URL
        var bytes: Int64
        var lastModified: Date
    }

    /// Size and newest modification time of a file or folder tree.
    static func measure(_ url: URL) -> Item {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var bytes: Int64 = 0
        var newest = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true {
            return Item(url: url, bytes: Int64(v.totalFileAllocatedSize ?? 0), lastModified: newest)
        }
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) {
            while let u = e.nextObject() as? URL {
                guard let v = try? u.resourceValues(forKeys: keys) else { continue }
                bytes += Int64(v.totalFileAllocatedSize ?? 0)
                if let d = v.contentModificationDate, d > newest { newest = d }
            }
        }
        return Item(url: url, bytes: bytes, lastModified: newest)
    }

    static func isRunning(_ process: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { ($0.localizedName ?? "").lowercased().contains(process) }
            || ProcessRunnerLite.pgrep(process)
    }

    /// Deletes items; returns bytes freed and failures.
    static func remove(_ items: [Item]) -> (freed: Int64, failures: [String]) {
        var freed: Int64 = 0
        var failures: [String] = []
        for item in items {
            do {
                try FileManager.default.removeItem(at: item.url)
                freed += item.bytes
            } catch {
                failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (freed, failures)
    }

    /// Claude Code's own retention (`cleanupPeriodDays`, default 30).
    static func claudeCleanupDays(home: URL = AgentStorage.home) -> Int {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = obj["cleanupPeriodDays"] as? Int, days > 0 else { return 30 }
        return days
    }
}

enum ProcessRunnerLite {
    /// True when a process whose command line starts with `name` is running (e.g. the codex CLI).
    static func pgrep(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", name]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// State for Settings › Agent Storage.
@MainActor
@Observable
final class AgentStorageModel {
    struct Measured {
        var items: [AgentStorage.Item]
        var total: Int64 { items.map(\.bytes).reduce(0, +) }
        func older(than cutoff: Date) -> [AgentStorage.Item] { items.filter { $0.lastModified < cutoff } }
    }

    static let shared = AgentStorageModel()

    let categories = AgentStorage.categories()
    private(set) var measured: [String: Measured] = [:]
    private(set) var isMeasuring = false
    private(set) var busy: Set<String> = []
    private(set) var lastResult: String?

    var total: Int64 { measured.values.map(\.total).reduce(0, +) }
    func total(for agent: StorageCategory.Agent) -> Int64 {
        categories.filter { $0.agent == agent }.compactMap { measured[$0.id]?.total }.reduce(0, +)
    }

    var historyDays: Int { max(1, SettingsStore.shared.settings.agentHistoryDays) }

    /// What pruning removes for a category right now.
    func removable(_ c: StorageCategory) -> [AgentStorage.Item] {
        guard let m = measured[c.id] else { return [] }
        switch c.kind {
        case .cache: return m.older(than: Date().addingTimeInterval(-StorageCategory.recentGuard))
        case .history: return m.older(than: Date().addingTimeInterval(-Double(historyDays) * 86400))
        }
    }

    func measure() {
        guard !isMeasuring else { return }
        isMeasuring = true
        let cats = categories
        Task {
            await withTaskGroup(of: (String, Measured).self) { group in
                for c in cats {
                    group.addTask {
                        let items = c.items().map(AgentStorage.measure)
                        return (c.id, Measured(items: items))
                    }
                }
                for await (id, m) in group { measured[id] = m }
            }
            isMeasuring = false
        }
    }

    /// Removes a category's removable items. Returns a message.
    @discardableResult
    func clean(_ c: StorageCategory) async -> String {
        if let app = c.requiresClosed, AgentStorage.isRunning(app) {
            let msg = "Quit \(c.agent.rawValue) first — \(c.title.lowercased()) are in use while it runs."
            lastResult = msg
            return msg
        }
        busy.insert(c.id)
        defer { busy.remove(c.id) }
        let items = removable(c)
        let result = await Task.detached { AgentStorage.remove(items) }.value
        let msg = "\(c.agent.rawValue) \(c.title.lowercased()): freed \(WorktreeService.formatBytes(result.freed))"
            + (result.failures.isEmpty ? "" : " (\(result.failures.count) couldn't be removed)")
        lastResult = msg
        let fresh = await Task.detached { c.items().map(AgentStorage.measure) }.value
        measured[c.id] = Measured(items: fresh)
        return msg
    }
}

// MARK: - Scheduled cleanup

/// Clears agent caches and prunes history older than the configured days.
@MainActor
final class AgentStorageCleanupJob: MaintenanceJob {
    let id = "agentStorage"
    let title = "Claude & Codex storage"
    let summary = "Clears Claude Code and Codex caches and logs, and prunes history older than the configured days"
    var isAvailable: Bool { true }
    var schedule: AutoUpdateSchedule { SettingsStore.shared.settings.agentStorageSchedule }

    func perform(_ run: MaintenanceRun) async -> MaintenanceOutcome {
        var out = MaintenanceOutcome()
        let includeHistory = SettingsStore.shared.settings.agentPruneHistory
        let days = max(1, SettingsStore.shared.settings.agentHistoryDays)
        var freed: Int64 = 0
        for c in AgentStorage.categories() {
            guard !run.cancelled else { break }
            if c.kind == .history && !includeHistory { continue }
            if let app = c.requiresClosed, AgentStorage.isRunning(app) {
                run.note("skip \(c.id): \(app) is running")
                continue
            }
            run.onStep?(c.title)
            let cutoff = Date().addingTimeInterval(c.kind == .cache ? -StorageCategory.recentGuard : -Double(days) * 86400)
            let items = await Task.detached { c.items().map(AgentStorage.measure).filter { $0.lastModified < cutoff } }.value
            if MaintenanceRun.dryRun {
                run.note("[dry run] \(c.id): \(items.count) items, \(WorktreeService.formatBytes(items.map(\.bytes).reduce(0, +)))")
                continue
            }
            let r = await Task.detached { AgentStorage.remove(items) }.value
            run.note("\(c.id): removed \(items.count - r.failures.count) items, \(WorktreeService.formatBytes(r.freed))")
            for f in r.failures { run.note("  ✗ \(f)") }
            freed += r.freed
            if r.freed > 0 { out.changes.append("\(c.agent.rawValue) \(c.title.lowercased())") }
            out.warnings += r.failures
        }
        out.summary = "freed \(WorktreeService.formatBytes(freed))"
        await MainActor.run { AgentStorageModel.shared.measure() }
        return out
    }

    func notification(for r: MaintenanceRecord) -> (title: String, body: String)? {
        guard r.outcome == .success, !r.changes.isEmpty else { return nil }
        return ("Cleaned up Claude & Codex storage", (r.summary.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "") + " · " + r.changes.joined(separator: ", "))
    }

    func didFinish() async {}
}
