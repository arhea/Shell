import Darwin
import Foundation
import Observation

/// A live Claude Code session that isn't running in Shell, from
/// `claude agents --json`.
struct ClaudeRunningSession: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A `claude --bg` session; `claude attach <jobID>` opens it anywhere.
        case background(jobID: String)
        /// Held by another terminal or app. Claude Code won't open it elsewhere.
        case interactive
    }

    /// Where an interactive session runs, from its `~/.claude/sessions` record.
    enum Host: Equatable, Sendable {
        case claudeDesktop, terminal
    }

    var kind: Kind
    var pid: Int32?
    var sessionID: String?
    var directory: String
    var name: String?
    /// "busy", "waiting" or "idle" while the process runs.
    var status: String?
    /// What a waiting session waits for ("permission prompt").
    var waitingFor: String?
    /// A background job's state: "working", "blocked", "done", "failed", "stopped".
    var state: String?
    var startedAt: Date
    var host: Host = .terminal

    var id: String {
        if case .background(let job) = kind { return "job:" + job }
        return sessionID ?? "pid:\(pid ?? 0)"
    }

    var jobID: String? {
        if case .background(let job) = kind { return job }
        return nil
    }

    /// Only background sessions can be opened from Shell.
    var canAttach: Bool { jobID != nil }

    /// `claude attach <job>`, typed at the prompt of a new tab.
    var attachCommand: String? {
        guard let jobID, jobID.wholeMatch(of: Self.jobIDPattern) != nil else { return nil }
        return "claude attach " + ShellQuote.quote(jobID)
    }

    /// Claude Code's own check for job IDs.
    nonisolated(unsafe) static let jobIDPattern = /^[0-9A-Za-z.+_-]{1,100}$/

    // MARK: Parsing

    /// Parses `claude agents --json`: background jobs carry a short `id`,
    /// interactive sessions a `pid`.
    static func parse(_ data: Data) -> [ClaudeRunningSession] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { obj in
            guard let cwd = obj["cwd"] as? String, !cwd.isEmpty else { return nil }
            let kind: Kind
            switch obj["kind"] as? String {
            case "background":
                // Background sessions without a job aren't attachable; skip them.
                guard let job = obj["id"] as? String, !job.isEmpty else { return nil }
                kind = .background(jobID: job)
            case "interactive":
                kind = .interactive
            default:
                return nil
            }
            let started = (obj["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
            return ClaudeRunningSession(
                kind: kind,
                pid: (obj["pid"] as? NSNumber)?.int32Value,
                sessionID: nonEmpty(obj["sessionId"]),
                directory: cwd,
                name: nonEmpty(obj["name"]),
                status: nonEmpty(obj["status"]),
                waitingFor: nonEmpty(obj["waitingFor"]),
                state: nonEmpty(obj["state"]),
                startedAt: started)
        }
    }

    /// The job a command line attaches to (`claude attach <job>`), so a job
    /// already open in a Shell tab isn't listed again.
    static func attachedJob(in command: String) -> String? {
        let words = (command.split(separator: "\n", maxSplits: 1).first ?? "").split(whereSeparator: \.isWhitespace)
        guard let i = words.firstIndex(of: "attach"), i > 0, i + 1 < words.count else { return nil }
        let bin = words[i - 1].split(separator: "/").last ?? words[i - 1]
        guard bin == "claude" else { return nil }
        return String(words[i + 1]).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}

/// Claude Code sessions running outside Shell: in Claude desktop, another
/// terminal, or in the background. Polled while the Claude Sessions page is
/// on screen; nothing runs otherwise.
@MainActor
@Observable
final class ClaudeRunningSessions {
    static let shared = ClaudeRunningSessions()

    /// Everything Claude Code reports, minus sessions inside Shell's own process tree.
    private(set) var all: [ClaudeRunningSession] = []
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var loadedAt: Date?

    /// Sessions to show: drops native sessions and background jobs attached
    /// in a Shell tab (those already have a tile).
    var sessions: [ClaudeRunningSession] {
        // Track panes opening and closing, and commands starting.
        let local = SessionRegistry.shared.all
        let native = Set(local.compactMap { $0.nativeClaude?.sessionID })
        let attached = Set(local.compactMap { $0.runningCommand.flatMap(ClaudeRunningSession.attachedJob) })
        return all.filter { s in
            if let id = s.sessionID, native.contains(id) { return false }
            if let job = s.jobID, attached.contains(job) { return false }
            return true
        }
    }

    /// Asks Claude Code again, at most every 4 seconds unless forced.
    func refresh(force: Bool = false) {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 4 { return }
        guard !isLoading else { return }
        isLoading = true
        loadedAt = Date()
        Task.detached(priority: .utility) {
            let found = await Self.load()
            await MainActor.run {
                let model = ClaudeRunningSessions.shared
                model.isLoading = false
                if let found, model.all != found { model.all = found }
            }
        }
    }

    /// nil when Claude Code couldn't be asked (not installed, too old for
    /// `agents --json`, timed out): keep what's showing.
    private nonisolated static func load() async -> [ClaudeRunningSession]? {
        guard let binary = claudeBinary() else { return [] }
        let r = await ProcessRunner.run(binary, ["agents", "--json"], directory: NSHomeDirectory(), timeout: 10)
        guard r.succeeded else {
            if !r.timedOut { Log.claude.debug("claude agents --json failed: \(r.stderr, privacy: .public)") }
            return r.timedOut ? nil : []
        }
        let me = getpid()
        return ClaudeRunningSession.parse(r.stdout).compactMap { session in
            var session = session
            if let pid = session.pid {
                if ProcessTree.isDescendant(pid, of: me) { return nil }
                session.host = host(of: pid)
            }
            return session
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private nonisolated static func claudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":" + home.appendingPathComponent(".local/bin").path + ":" + home.appendingPathComponent(".claude/local").path
        return GitRepository.findExecutable("claude", environment: env)
    }

    /// Claude desktop or a terminal, from the session's `entrypoint`. Best
    /// effort: the record is Claude Code's, not a public format.
    private nonisolated static func host(of pid: Int32) -> ClaudeRunningSession.Host {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = obj["entrypoint"] as? String else { return .terminal }
        return entry == "claude-desktop" ? .claudeDesktop : .terminal
    }
}

enum ProcessTree {
    /// Whether `pid` is `ancestor` or runs under it (Shell's tabs and native
    /// view are children of the app; background jobs and other apps aren't).
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if current == ancestor { return true }
            guard current > 1, let parent = parent(of: current) else { return false }
            current = parent
        }
        return false
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
