import Foundation
import Observation

/// A Claude Code conversation from the local transcripts, for the Claude
/// Sessions page's past sessions drawer.
struct ClaudePastSession: Identifiable, Equatable, Sendable {
    /// Claude Code's session ID (the transcript's file name), for `--resume`.
    var id: String
    /// The directory Claude ran in; resuming has to start there.
    var directory: String
    /// The `/rename` title, else Claude's own title, else the first prompt.
    var title: String
    /// The first prompt, when the title is something else (a `/rename` name
    /// such as Shell's random `brisk-wren` doesn't say what the session was).
    var prompt: String?
    /// The branch the session last reported.
    var branch: String?
    var lastActive: Date
}

/// Past Claude Code sessions, newest first, read from ~/.claude/projects.
/// Nothing leaves the machine and nothing is written.
@MainActor
@Observable
final class ClaudeHistory {
    static let shared = ClaudeHistory()

    private(set) var sessions: [ClaudePastSession] = []
    private(set) var isLoading = false
    @ObservationIgnored private let index = ClaudeTranscriptIndex()
    @ObservationIgnored private var loadedAt: Date?

    /// True when Claude Code is on this Mac: its config folder exists or the
    /// `claude` binary is on the PATH. Checked once per launch.
    static let isClaudeAvailable: Bool = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        if fm.fileExists(atPath: home.appendingPathComponent(".claude/projects").path) { return true }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":" + home.appendingPathComponent(".local/bin").path + ":" + home.appendingPathComponent(".claude/local").path
        return GitRepository.findExecutable("claude", environment: env) != nil
    }()

    /// Rescans in the background, at most every 15 seconds unless forced.
    /// Unchanged transcripts are served from the index's cache.
    func refresh(force: Bool = false) {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 15 { return }
        guard !isLoading else { return }
        isLoading = true
        loadedAt = Date()
        let index = index
        Task.detached(priority: .utility) {
            let found = index.scan()
            await MainActor.run {
                let history = ClaudeHistory.shared
                history.isLoading = false
                if history.sessions != found { history.sessions = found }
            }
        }
    }
}

/// Summarizes transcripts by reading only their first and last 64 KB (they
/// reach hundreds of MB). Results are cached by file size and modification
/// date, so a rescan only reopens transcripts that changed. Locked: scans run
/// on a background task.
final class ClaudeTranscriptIndex: @unchecked Sendable {
    private struct Cached {
        var size: Int
        var modified: Date
        var session: ClaudePastSession?
    }

    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    private let root: URL
    private let limit: Int

    static let chunk = 64 * 1024

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"), limit: Int = 200) {
        self.root = root
        self.limit = limit
    }

    func scan() -> [ClaudePastSession] {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var files: [(url: URL, size: Int, modified: Date)] = []
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for project in projects {
            // Top level only: subagent transcripts live in subfolders.
            let items = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            for url in items where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, let modified = v.contentModificationDate else { continue }
                files.append((url, v.fileSize ?? 0, modified))
            }
        }
        files.sort { $0.modified > $1.modified }
        var result: [ClaudePastSession] = []
        var live = Set<String>()
        // Look past the limit a little: empty and temporary sessions are skipped.
        for file in files.prefix(limit * 2) where result.count < limit {
            let path = file.url.path
            live.insert(path)
            let session: ClaudePastSession?
            if let hit = cache[path], hit.size == file.size, hit.modified == file.modified {
                session = hit.session
            } else {
                session = Self.summarize(file.url, size: file.size, modified: file.modified)
                cache[path] = Cached(size: file.size, modified: file.modified, session: session)
            }
            if let session { result.append(session) }
        }
        for path in cache.keys where !live.contains(path) { cache[path] = nil }
        return result
    }

    static func summarize(_ url: URL, size: Int, modified: Date) -> ClaudePastSession? {
        let id = url.deletingPathExtension().lastPathComponent
        guard id.wholeMatch(of: ClaudeArguments.sessionIDPattern) != nil,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        var tail = Data()
        if size > chunk * 2 {
            try? handle.seek(toOffset: UInt64(size - chunk))
            tail = (try? handle.readToEnd()) ?? Data()
        } else if size > head.count {
            tail = (try? handle.readToEnd()) ?? Data()
        }
        return parse(id: id, head: head, tail: tail, tailIsContinuation: size <= chunk * 2, modified: modified)
    }

    /// Builds a session from the start and end of a transcript. `head` may end
    /// mid-line and `tail` may start mid-line (unless it continues `head`
    /// directly); partial lines are dropped.
    static func parse(id: String, head: Data, tail: Data, tailIsContinuation: Bool = false, modified: Date) -> ClaudePastSession? {
        var cwd: String?
        var branch: String?
        var firstPrompt: String?
        var customTitle: String?
        var aiTitle: String?
        var summary: String?

        func read(_ line: Data.SubSequence) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            switch obj["type"] as? String {
            case "custom-title": customTitle = nonEmpty(obj["customTitle"]) ?? customTitle
            case "ai-title": aiTitle = nonEmpty(obj["aiTitle"]) ?? aiTitle
            case "summary": summary = nonEmpty(obj["summary"]) ?? summary
            default: break
            }
            guard obj["isSidechain"] as? Bool != true else { return }
            if let c = nonEmpty(obj["cwd"]) { cwd = c }
            if let b = nonEmpty(obj["gitBranch"]) { branch = b == "HEAD" ? nil : b }
            if firstPrompt == nil, obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
               let message = obj["message"] as? [String: Any] {
                firstPrompt = prompt(in: message)
            }
        }

        var combined = head
        var tailLines = tail
        if tailIsContinuation {
            combined.append(tail)
            tailLines = Data()
        }
        // Head: every complete line.
        var headLines = combined.split(separator: 0x0A, omittingEmptySubsequences: true)
        if combined.last != 0x0A, !headLines.isEmpty { headLines.removeLast() }
        for line in headLines { read(line) }
        // Tail: skip the partial first line; later lines win (latest title, branch).
        if !tailLines.isEmpty {
            var lines = tailLines.split(separator: 0x0A, omittingEmptySubsequences: true)
            if !lines.isEmpty { lines.removeFirst() }
            if tailLines.last != 0x0A, !lines.isEmpty { lines.removeLast() }
            let headPrompt = firstPrompt
            for line in lines { read(line) }
            if headPrompt != nil { firstPrompt = headPrompt }
        }

        guard let cwd, !isTemporary(cwd) else { return nil }
        let shownPrompt = firstPrompt.map(oneLine)
        guard let title = customTitle ?? aiTitle ?? summary ?? shownPrompt else { return nil }
        return ClaudePastSession(id: id, directory: cwd, title: title, prompt: shownPrompt == title ? nil : shownPrompt,
                                 branch: branch, lastActive: modified)
    }

    private static func prompt(in message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return ClaudeCodeSession.historyPrompt(text) }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String, let shown = ClaudeCodeSession.historyPrompt(text) { return shown }
        }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// The first line, capped, for prompts used as titles.
    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 140 ? String(line.prefix(140)) + "…" : line
    }

    /// Sessions in temporary folders (SDK runs, scratch checkouts) aren't worth resuming.
    static func isTemporary(_ path: String) -> Bool {
        ["/private/var/folders/", "/var/folders/", "/tmp/", "/private/tmp/"].contains { path.hasPrefix($0) }
    }
}
