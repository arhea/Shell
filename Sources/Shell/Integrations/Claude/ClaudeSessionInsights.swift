import Foundation

// Data the native Claude view derives from the stream beyond the transcript
// itself: to-dos, background work, changed files, the context window, the
// status line's activity label, and what a turn accomplished. Everything here
// is plain value logic so it can be unit tested without a `claude` process.

// MARK: - To-dos

/// One entry of Claude's latest TodoWrite list.
struct ClaudeTodo: Hashable, Sendable {
    enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    var content: String
    var activeForm: String
    var status: Status

    static func parse(_ input: [String: Any]) -> [ClaudeTodo] {
        (input["todos"] as? [[String: Any]] ?? []).map {
            ClaudeTodo(content: $0["content"] as? String ?? "", activeForm: $0["activeForm"] as? String ?? "",
                       status: Status(rawValue: $0["status"] as? String ?? "") ?? .pending)
        }
    }
}

// MARK: - Background work

/// A subagent (Task/Agent tool) or a `run_in_background` Bash command, for the
/// inspector's "Running in background" list.
struct ClaudeBackgroundTask: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case subagent, backgroundTask }
    enum Status: Sendable { case running, completed, failed, stopped }

    /// The tool_use id that started it.
    var id: String
    /// "code-reviewer", or the command's description.
    var title: String
    var kind: Kind
    var status: Status
    var startedAt: Date
    var endedAt: Date?
    /// The latest activity: "Reading StreamWriter.swift", a line of output.
    var detail: String?
    /// The shell command of a background task.
    var command: String?
    /// The id Claude Code reports for it (`bash_1`, an agent id), for matching
    /// BashOutput, KillShell and task notifications.
    var taskID: String?
    /// Tool calls a subagent made, by tool name.
    var toolCounts: [String: Int] = [:]
    /// Started with `run_in_background`: its tool result only says it launched.
    var isAsync = false

    var isRunning: Bool { status == .running }
    var toolCallCount: Int { toolCounts.values.reduce(0, +) }
    /// "Read 4 · Grep 2", most used first.
    var toolSummary: String { ClaudeWork.breakdown(toolCounts) }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }

    func matches(_ reference: String) -> Bool { id == reference || taskID == reference }
}

// MARK: - Changed files

/// Line counts of a file edit.
struct ClaudeDiffStats: Hashable, Sendable {
    var added: Int
    var removed: Int

    static func + (a: Self, b: Self) -> Self { .init(added: a.added + b.added, removed: a.removed + b.removed) }
}

/// A file Claude changed with Edit, MultiEdit, Write or NotebookEdit this session.
struct ClaudeChangedFile: Identifiable, Hashable, Sendable {
    var path: String
    var added: Int
    var removed: Int
    /// Created by a Write, not changed.
    var isNew: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

// MARK: - Context window

/// The model's context window, for the composer's meter. Kept simple:
///
/// - 1M when the model ID has the `[1m]` suffix, the model picker describes it
///   "with 1M context", or it's Opus 5 or later;
/// - 1M when the context in use is already past 200k (it can't be smaller);
/// - otherwise 200k.
enum ClaudeContextWindow {
    static let standard = 200_000
    static let extended = 1_000_000

    static func size(model: String?, description: String? = nil, inUse: Int? = nil) -> Int {
        if let inUse, inUse > standard { return extended }
        if let description, description.localizedCaseInsensitiveContains("1M context") { return extended }
        guard let model = model?.lowercased() else { return standard }
        if model.contains("[1m]") || model.hasSuffix("-1m") { return extended }
        let parts = model.split(separator: "-")
        if let i = parts.firstIndex(of: "opus"), i + 1 < parts.count, let major = Int(parts[i + 1]), major >= 5 { return extended }
        return standard
    }
}

// MARK: - Formatting

enum ClaudeFormat {
    /// "6s", "2m 41s", "1h 4m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// "41.2s" for short, precise durations (a command); `duration` otherwise.
    static func preciseDuration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1fs", max(0, seconds)) : duration(seconds)
    }

    /// "999", "18.2k", "1.2M".
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: n % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return n >= 100_000 ? "\(n / 1000)k" : String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

// MARK: - Activity

enum ClaudeActivity {
    /// What a tool call is doing, for the status line and subagent rows:
    /// "Reading AppDelegate.swift", "Running tests".
    static func label(tool: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let file = (s("file_path") ?? s("notebook_path")).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Read": return "Reading " + (file ?? "a file")
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing " + (file ?? "a file")
        case "Write": return "Writing " + (file ?? "a file")
        case "Bash":
            if let d = s("description") { return d }
            let command = (s("command") ?? "").components(separatedBy: "\n").first ?? ""
            return "Running " + (command.count > 48 ? String(command.prefix(47)) + "…" : command)
        case "Grep", "Glob": return "Searching " + (s("pattern") ?? "the code")
        case "WebFetch": return "Fetching " + (s("url").flatMap { URL(string: $0)?.host } ?? "a page")
        case "WebSearch": return "Searching the web"
        case "Task", "Agent": return "Running " + (s("subagent_type") ?? s("description") ?? "a subagent")
        case "TodoWrite": return "Updating the to-dos"
        case "Skill": return "Using " + (s("skill") ?? s("command") ?? "a skill")
        default: return "Using " + ClaudeToolFormat.displayName(tool)
        }
    }
}

// MARK: - Tool output

enum ClaudeOutput {
    /// Output without terminal escape sequences (colors, cursor moves, titles).
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()][A-Za-z0-9]", with: "", options: .regularExpression)
    }

    /// Lines of text, without a trailing empty line.
    static func lines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var n = 1
        for c in text.utf8 where c == 0x0A { n += 1 }
        return text.utf8.last == 0x0A ? n - 1 : n
    }

    /// A failed Bash call's exit code ("Exit code 1" leads its result).
    static func exitCode(_ result: String) -> Int? {
        guard let m = result.prefix(80).firstMatch(of: /Exit code (\d+)/) else { return nil }
        return Int(m.output.1)
    }

    /// The commit a `git commit` printed: "[main 74c838f] fix: …".
    static func commit(command: String, output: String) -> String? {
        guard command.contains("git commit") || command.contains("git merge") else { return nil }
        let m = output.firstMatch(of: /(?m)^\[[^\]\s]+(?: \([^)]*\))? ([0-9a-f]{7,40})\]/)
        return m.map { String($0.output.1.prefix(7)) }
    }

    /// A pull request URL from `gh pr create` (or any command printing one it created).
    static func pullRequest(command: String, output: String) -> (number: Int, url: URL)? {
        guard command.contains("gh pr create") || command.contains("hub pull-request") else { return nil }
        guard let m = output.firstMatch(of: /https:\/\/github\.com\/[^\/\s]+\/[^\/\s]+\/pull\/(\d+)/),
              let n = Int(m.output.1), let url = URL(string: String(m.output.0)) else { return nil }
        return (n, url)
    }

    /// A test run's outcome: "210 passed", "1 of 211 failed". XCTest / swift
    /// test, Jest / Vitest and pytest summaries; nil for anything else.
    static func testSummary(_ output: String) -> String? {
        if let m = output.matches(of: /Executed (\d+) tests?, with (\d+) failures?/).last,
           let total = Int(m.output.1), let failed = Int(m.output.2) {
            return failed == 0 ? "\(total) passed" : "\(failed) of \(total) failed"
        }
        if let m = output.matches(of: /Tests:\s+(?:(\d+) failed, )?(?:\d+ skipped, )?(\d+) passed, (\d+) total/).last,
           let total = Int(m.output.3) {
            let failed = m.output.1.flatMap { Int($0) } ?? 0
            return failed == 0 ? "\(m.output.2) passed" : "\(failed) of \(total) failed"
        }
        if let m = output.matches(of: /=+ (?:(\d+) failed, )?(\d+) passed(?:, (\d+) failed)?/).last, let passed = Int(m.output.2) {
            let failed = (m.output.1.flatMap { Int($0) } ?? 0) + (m.output.3.flatMap { Int($0) } ?? 0)
            return failed == 0 ? "\(passed) passed" : "\(failed) of \(passed + failed) failed"
        }
        return nil
    }

    /// Lines that look like errors, to tint in logs and output.
    static func isErrorLine(_ line: Substring) -> Bool {
        line.contains("error:") || line.contains("Error:") || line.contains("FAILED") || line.contains(" failed")
            || line.hasPrefix("FAIL") || line.contains("panic:") || line.contains("✗") || line.contains("is not equal to")
    }

    /// The part of a CI log worth showing: around the first error, else the
    /// end. `gh run view --log` prefixes ("job\tstep\ttimestamp ") are dropped.
    static func logExcerpt(_ log: String, maxLines: Int = 12) -> [(text: String, isError: Bool)] {
        let lines = lines(stripANSI(log)).map { line -> Substring in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return line }
            let rest = parts[2]
            // "2024-05-01T10:00:00.1234567Z text"
            if let space = rest.firstIndex(of: " "), rest[..<space].contains("T"), rest[..<space].hasSuffix("Z") {
                return rest[rest.index(after: space)...]
            }
            return rest
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return [] }
        let start: Int
        if let first = lines.firstIndex(where: isErrorLine) {
            start = max(0, min(first - 1, lines.count - maxLines))
        } else {
            start = max(0, lines.count - maxLines)
        }
        return lines[start..<min(lines.count, start + maxLines)].map { (String($0), isErrorLine($0)) }
    }
}

// MARK: - Step meta

enum ClaudeStepMeta {
    /// The right-hand detail of a tool step: "L1–184", "5 lines", "0 matches".
    /// Edit stats are separate (`diffStats`).
    static func meta(tool: String, input: [String: Any], result: String?, isError: Bool) -> String? {
        guard let result, !isError || tool == "Bash" else { return nil }
        let visible = ClaudeToolFormat.visibleResult(result)
        switch tool {
        case "Read":
            let offset = input["offset"] as? Int ?? 1
            if let limit = input["limit"] as? Int { return "L\(offset)–\(offset + limit - 1)" }
            let n = ClaudeOutput.lineCount(visible)
            return n > 0 ? "L\(offset)–\(offset + n - 1)" : nil
        case "Grep":
            if visible.hasPrefix("No matches") || visible.isEmpty { return "0 matches" }
            if let m = visible.firstMatch(of: /^Found (\d+) (files?|matches|lines?)/) { return "\(m.output.1) \(m.output.2)" }
            let n = ClaudeOutput.lineCount(visible)
            return "\(n) \(n == 1 ? "match" : "matches")"
        case "Glob":
            if visible.hasPrefix("No files") || visible.isEmpty { return "0 files" }
            let n = ClaudeOutput.lineCount(visible)
            return "\(n) \(n == 1 ? "file" : "files")"
        case "Bash":
            if isError, let code = ClaudeOutput.exitCode(visible) { return "exit \(code)" }
            if input["run_in_background"] as? Bool == true { return "background" }
            let n = ClaudeOutput.lineCount(visible)
            return n == 0 ? nil : "\(n) \(n == 1 ? "line" : "lines")"
        default:
            return nil
        }
    }

    /// Added and removed lines of an edit: the CLI's structured patch when it
    /// sent one, else a diff of the edit's own text.
    static func diffStats(tool: String, input: [String: Any], structured: Any?) -> ClaudeDiffStats? {
        guard ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool) else { return nil }
        if let result = structured as? [String: Any], let hunks = result["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            var stats = ClaudeDiffStats(added: 0, removed: 0)
            for line in hunks.flatMap({ $0["lines"] as? [String] ?? [] }) {
                if line.hasPrefix("+") { stats.added += 1 } else if line.hasPrefix("-") { stats.removed += 1 }
            }
            return stats
        }
        func count(_ old: String, _ new: String) -> ClaudeDiffStats {
            let lines = ClaudeDiff.diff(old: old, new: new)
            return .init(added: lines.filter { $0.kind == .added }.count, removed: lines.filter { $0.kind == .removed }.count)
        }
        switch tool {
        case "Edit":
            return count(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")
        case "MultiEdit":
            return (input["edits"] as? [[String: Any]] ?? []).reduce(ClaudeDiffStats(added: 0, removed: 0)) {
                $0 + count($1["old_string"] as? String ?? "", $1["new_string"] as? String ?? "")
            }
        case "Write":
            return .init(added: ClaudeOutput.lineCount(input["content"] as? String ?? ""), removed: 0)
        default:
            return nil
        }
    }
}

// MARK: - Work summaries

/// What a run of transcript items did: for the folded "Worked for…" row and
/// the end-of-turn summary card. Only facts that can be read from the
/// transcript; nothing is guessed.
@MainActor
struct ClaudeWork {
    var toolCount = 0
    var toolCounts: [String: Int] = [:]
    var subagents = 0
    var failures = 0
    var running = false
    var startedAt: Date?
    var endedAt: Date?
    /// Short SHAs of commits made, in order.
    var commits: [String] = []
    var pullRequests: [(number: Int, url: URL)] = []
    var tests: String?
    /// Files changed, in first-touched order, with summed stats.
    var files: [ClaudeChangedFile] = []

    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    var breakdown: String { ClaudeWork.breakdown(toolCounts) }
    var stats: ClaudeDiffStats { files.reduce(.init(added: 0, removed: 0)) { $0 + .init(added: $1.added, removed: $1.removed) } }
    var hasChanges: Bool { !files.isEmpty || !commits.isEmpty }

    init(_ items: [ClaudeItem]) {
        for item in items {
            if item.kind != .user {
                startedAt = min(startedAt ?? item.startedAt, item.startedAt)
                endedAt = max(endedAt ?? .distantPast, item.endedAt ?? item.startedAt)
            }
            guard item.kind == .tool else { continue }
            toolCount += 1
            toolCounts[ClaudeToolFormat.displayName(item.toolName), default: 0] += 1
            if item.toolName == "Task" || item.toolName == "Agent" { subagents += 1 }
            if item.isError { failures += 1 }
            if item.isRunning { running = true }
            guard let result = item.result, !item.isError else { continue }
            if item.toolName == "Bash" {
                let command = item.input["command"] as? String ?? ""
                if let sha = ClaudeOutput.commit(command: command, output: result) { commits.append(sha) }
                if let pr = ClaudeOutput.pullRequest(command: command, output: result),
                   !pullRequests.contains(where: { $0.number == pr.number }) { pullRequests.append(pr) }
                if let t = ClaudeOutput.testSummary(result) { tests = t }
            } else if let stats = item.diffStats, let path = (item.input["file_path"] ?? item.input["notebook_path"]) as? String {
                if let i = files.firstIndex(where: { $0.path == path }) {
                    files[i].added += stats.added
                    files[i].removed += stats.removed
                } else {
                    files.append(ClaudeChangedFile(path: path, added: stats.added, removed: stats.removed, isNew: item.createdFile))
                }
            }
        }
    }

    /// "Read 3 · Edit 2 · Bash", most used first.
    nonisolated static func breakdown(_ counts: [String: Int]) -> String {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key) \($0.value)" : $0.key }
            .joined(separator: " · ")
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Asks the window to show Review Changes for a Claude session. The object
    /// is the `ClaudeCodeSession`; `userInfo["path"]` optionally names a file.
    static let shellReviewChanges = Notification.Name("ShellReviewChanges")
}

// MARK: - CI failures

/// A failed CI check shown in the transcript (`ClaudeItem.Kind.checkFailure`).
struct ClaudeCheckFailure: Sendable {
    var job: CheckJob
    /// The failing log lines (`gh run view --log-failed`), trimmed.
    var log: String
    /// The commit the check ran on, when known.
    var headSHA: String?

    /// "Test" from "Test · test.yml".
    var workflowName: String? {
        job.workflow?.components(separatedBy: " · ").first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "Test / Build and test".
    var title: String { [workflowName, job.name].compactMap { $0 }.joined(separator: " / ") }

    /// The first failed step's name.
    var failedStep: String? { job.steps.first { $0.state == .failed }?.name }

    /// "build-and-test", for the log attachment.
    var slug: String {
        let s = job.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-")
    }
}
