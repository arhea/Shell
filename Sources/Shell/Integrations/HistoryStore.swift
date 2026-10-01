import Foundation

/// Command history for the input editor: zsh's HISTFILE plus commands run
/// through the editor. Powers ghost-text suggestions, ↑/↓ and ⌃R search.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    /// Unique commands, oldest first.
    private(set) var entries: [String] = [] {
        didSet { lastSuggestion = nil; loweredEntries = nil }
    }
    /// Memo for `suggestion(for:)`, which runs on every keystroke.
    private var lastSuggestion: (prefix: String, result: String?)?
    /// `entries` lowercased, for ⌃R search; built lazily.
    private var loweredEntries: [String]?
    private var index: [String: Int] = [:]
    private var loadedPath: String?
    private var loadedMTime: Date?
    /// Bytes of `loadedPath` already read: after each command only the new tail is parsed.
    private var loadedSize: UInt64 = 0
    /// Oldest entries are dropped past this.
    static let maxEntries = 50_000
    private let ownFile = SettingsStore.supportDirectory.appendingPathComponent("history")

    private init() {
        let own = Self.parse(data: (try? Data(contentsOf: ownFile)) ?? Data())
        merge(own)
        // Unit tests never read the user's real zsh history.
        guard !AppEnvironment.isRunningTests else { return }
        // Seed from the default zsh history before any shell reports its HISTFILE.
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zsh_history").path
        load(path: fallback)
    }

    func load(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded != loadedPath else { return reloadIfChanged(path: expanded) }
        loadedPath = expanded
        loadedSize = 0
        read(path: expanded)
    }

    func reloadIfChanged(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              let mtime = attrs[.modificationDate] as? Date else { return }
        if loadedPath == expanded, let loadedMTime, mtime <= loadedMTime { return }
        if loadedPath != expanded { loadedSize = 0 }
        loadedPath = expanded
        read(path: expanded)
    }

    private func read(path: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        loadedMTime = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        // Appended since the last read (INC_APPEND_HISTORY / SHARE_HISTORY): read
        // only the tail. Shrunk (zsh trimmed it) or a new file: read it all.
        let from: UInt64 = size >= loadedSize && loadedSize > 0 ? loadedSize : 0
        loadedSize = size
        guard size > from else { return }
        Task.detached(priority: .utility) {
            guard let handle = FileHandle(forReadingAtPath: path) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: from)
            guard let data = try? handle.read(upToCount: Int(size - from)), !data.isEmpty else { return }
            let parsed = Self.parse(data: data)
            await MainActor.run { HistoryStore.shared.merge(parsed, incremental: from > 0) }
        }
    }

    /// Merges a batch in O(n): later occurrences win, so recency is preserved.
    /// A few new commands (the usual case after each prompt) are appended in
    /// place instead of rebuilding everything.
    private func merge(_ commands: [String], incremental: Bool = false) {
        guard !commands.isEmpty else { return }
        if incremental, commands.count < 64 {
            for cmd in commands { append(cmd) }
            return
        }
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(entries.count + commands.count)
        for cmd in (entries + commands).reversed() {
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        entries = Array(result.prefix(Self.maxEntries).reversed())
        index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element, $0.offset) })
    }

    private func append(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let old = index[trimmed] {
            // Move to the end; only indices after `old` shift, and repeats are
            // usually recent commands near the end.
            entries.remove(at: old)
            entries.append(trimmed)
            for i in old..<entries.count { index[entries[i]] = i }
            return
        }
        entries.append(trimmed)
        index[trimmed] = entries.count - 1
    }

    func add(_ command: String) {
        append(command)
        let line = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: ownFile) {
            // Throwing APIs: the legacy ones raise uncatchable exceptions on I/O errors.
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: ownFile, atomically: true, encoding: .utf8)
        }
    }

    /// Most recent command that starts with `prefix` (zsh-autosuggestions style).
    func suggestion(for prefix: String) -> String? {
        guard !prefix.isEmpty, !prefix.hasSuffix("\n") else { return nil }
        // Typing usually extends the previous prefix. The previous answer is
        // then still the newest match if it matches, and no match stays no match.
        if let last = lastSuggestion {
            if last.prefix == prefix { return last.result }
            if prefix.hasPrefix(last.prefix) {
                guard let r = last.result else { return nil }
                if r.hasPrefix(prefix), r != prefix {
                    lastSuggestion = (prefix, r)
                    return r
                }
            }
        }
        let result = entries.last { $0 != prefix && $0.hasPrefix(prefix) }
        lastSuggestion = (prefix, result)
        return result
    }

    /// Previous/next history entry matching a prefix, walking from `position`
    /// (an index into `entries`, or nil for "after the newest").
    func step(from position: Int?, prefix: String, backwards: Bool) -> (Int, String)? {
        if backwards {
            var i = (position ?? entries.count) - 1
            while i >= 0 {
                if prefix.isEmpty || entries[i].hasPrefix(prefix) { return (i, entries[i]) }
                i -= 1
            }
        } else {
            guard let position else { return nil }
            var i = position + 1
            while i < entries.count {
                if prefix.isEmpty || entries[i].hasPrefix(prefix) { return (i, entries[i]) }
                i += 1
            }
        }
        return nil
    }

    /// Fuzzy search, newest first.
    func search(_ query: String, limit: Int = 200) -> [String] {
        let q = query.lowercased()
        let lowered: [String]
        if let cached = loweredEntries {
            lowered = cached
        } else {
            lowered = entries.map { $0.lowercased() }
            loweredEntries = lowered
        }
        var results: [(String, Int)] = []
        for (age, i) in entries.indices.reversed().enumerated() {
            let cmd = entries[i]
            if q.isEmpty {
                results.append((cmd, age))
            } else if let score = FuzzyMatch.score(q, in: lowered[i]) {
                results.append((cmd, score * 4 + min(age, 4000) / 10))
            }
            if q.isEmpty && results.count >= limit { break }
        }
        if !q.isEmpty { results.sort { $0.1 < $1.1 } }
        return results.prefix(limit).map(\.0)
    }

    // MARK: Parsing

    /// Parses zsh history (plain or EXTENDED_HISTORY, metafied, with
    /// backslash-continued multiline entries) and Shell's own history file.
    nonisolated static func parse(data: Data) -> [String] {
        // Unmetafy: 0x83 marks the next byte as XOR 0x20.
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count)
        var meta = false
        for b in data {
            if meta { bytes.append(b ^ 0x20); meta = false; continue }
            if b == 0x83 { meta = true; continue }
            bytes.append(b)
        }
        let text = String(decoding: bytes, as: UTF8.self)
        var out: [String] = []
        var current: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if current == nil, line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                // ": <start>:<elapsed>;<command>"
                line = String(line[line.index(after: semi)...])
            }
            if line.hasSuffix("\\") && !line.hasSuffix("\\\\") {
                current = (current.map { $0 + "\n" } ?? "") + line.dropLast()
                continue
            }
            let full = (current.map { $0 + "\n" } ?? "") + line
            current = nil
            if !full.isEmpty { out.append(full.replacingOccurrences(of: "\\n", with: "\n")) }
        }
        return out
    }
}

enum FuzzyMatch {
    /// Lower is better; nil when `needle` isn't a subsequence of `haystack`.
    static func score(_ needle: String, in haystack: String) -> Int? {
        if needle.isEmpty { return 0 }
        if let r = haystack.range(of: needle) {
            return haystack.distance(from: haystack.startIndex, to: r.lowerBound) / 4
        }
        var score = 0
        var last: String.Index?
        var hi = haystack.startIndex
        for ch in needle {
            guard let found = haystack[hi...].firstIndex(of: ch) else { return nil }
            if let last { score += haystack.distance(from: last, to: found) }
            last = found
            hi = haystack.index(after: found)
        }
        return 20 + score
    }
}
