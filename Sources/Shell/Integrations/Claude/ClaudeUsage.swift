import Foundation
import Observation

/// Claude Code usage for the dashboard: plan limits (from the `rate_limit_event`
/// messages native sessions receive) and token totals (from the local
/// transcripts in ~/.claude/projects). Nothing leaves the machine.
@MainActor
@Observable
final class ClaudeUsage {
    /// Unit tests keep plan limits out of the app's real defaults.
    static let shared = ClaudeUsage(defaults: AppEnvironment.isRunningTests
        ? UserDefaults(suiteName: "app.bethesdalabs.Shell.tests") ?? .standard : .standard)

    struct LimitWindow: Codable, Equatable {
        /// 0…1 of the window used.
        var utilization: Double
        var resetsAt: Date?

        enum Level: Equatable { case normal, warning, critical }

        /// Green up to 70%, yellow above, red above 90%.
        var level: Level {
            utilization > 0.9 ? .critical : utilization > 0.7 ? .warning : .normal
        }

        /// Whole percent used, clamped to 0…100.
        var percent: Int { Int((min(max(utilization, 0), 1) * 100).rounded()) }
    }

    struct Limits: Codable, Equatable {
        var fiveHour: LimitWindow?
        var sevenDay: LimitWindow?
        var status: String?
        var updatedAt: Date
    }

    struct DayTotal: Identifiable, Equatable {
        var day: Date
        var tokens: Int
        var id: Date { day }
    }

    struct TokenStats: Equatable {
        var today = TokenBreakdown()
        var lastFiveHours = TokenBreakdown()
        var days: [DayTotal] = []
        var sessionsToday = 0
        /// Model → tokens today, largest first.
        var modelsToday: [(String, Int)] = []

        static func == (a: TokenStats, b: TokenStats) -> Bool {
            a.today == b.today && a.lastFiveHours == b.lastFiveHours && a.days == b.days && a.sessionsToday == b.sessionsToday
                && a.modelsToday.map(\.0) == b.modelsToday.map(\.0) && a.modelsToday.map(\.1) == b.modelsToday.map(\.1)
        }
    }

    struct TokenBreakdown: Equatable {
        var input = 0
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0
        var total: Int { input + output + cacheWrite + cacheRead }

        /// The share of input-side tokens served from the prompt cache (0…1),
        /// nil before any input.
        var cacheShare: Double? {
            let inputSide = input + cacheWrite + cacheRead
            return inputSide > 0 ? Double(cacheRead) / Double(inputSide) : nil
        }

        mutating func add(_ r: UsageRecord) {
            input += r.input
            output += r.output
            cacheWrite += r.cacheWrite
            cacheRead += r.cacheRead
        }
    }

    private(set) var limits: Limits?
    private(set) var tokens: TokenStats?
    private(set) var isScanning = false

    @ObservationIgnored private let scanner: TranscriptScanner
    @ObservationIgnored private var lastScan: Date?
    @ObservationIgnored private let defaults: UserDefaults
    private static let limitsKey = "ClaudeUsageLimits"

    init(defaults: UserDefaults = .standard, scanner: TranscriptScanner = TranscriptScanner()) {
        self.defaults = defaults
        self.scanner = scanner
        if let data = defaults.data(forKey: Self.limitsKey) {
            limits = try? JSONDecoder().decode(Limits.self, from: data)
        }
    }

    // MARK: Plan limits

    /// Records a stream-json `rate_limit_info` object.
    func record(rateLimitInfo info: [String: Any], at date: Date = Date()) {
        var next = limits ?? Limits(updatedAt: date)
        next.updatedAt = date
        next.status = info["status"] as? String ?? next.status
        func window(_ obj: Any?) -> LimitWindow? {
            guard let obj = obj as? [String: Any], let u = Self.double(obj["utilization"]) else { return nil }
            return LimitWindow(utilization: u, resetsAt: Self.double(obj["resetsAt"] ?? obj["resets_at"]).map { Date(timeIntervalSince1970: $0) })
        }
        if let windows = info["unifiedWindows"] as? [String: Any] {
            if let w = window(windows["five_hour"]) { next.fiveHour = w }
            if let w = window(windows["seven_day"]) { next.sevenDay = w }
        }
        if let w = window(info) {
            switch info["rateLimitType"] as? String {
            case "five_hour": next.fiveHour = w
            case "seven_day": next.sevenDay = w
            default: break
            }
        }
        // Drop windows that have already reset.
        if let r = next.fiveHour?.resetsAt, r < date { next.fiveHour = nil }
        if let r = next.sevenDay?.resetsAt, r < date { next.sevenDay = nil }
        limits = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.limitsKey) }
    }

    private static func double(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    // MARK: Tokens

    /// Rescans transcripts in the background, at most once a minute.
    func refreshIfNeeded() {
        if let lastScan, Date().timeIntervalSince(lastScan) < 60 { return }
        guard !isScanning else { return }
        isScanning = true
        lastScan = Date()
        let scanner = scanner
        Task.detached(priority: .utility) { [weak self] in
            let records = scanner.scan()
            let stats = ClaudeUsage.stats(from: records, now: Date(), calendar: .current)
            await MainActor.run {
                guard let usage = self else { return }
                usage.isScanning = false
                if usage.tokens != stats { usage.tokens = stats }
            }
        }
    }

    /// One bar of the dashboard's 7-day sparkline.
    struct SparkBar: Equatable, Identifiable {
        var day: Date
        var tokens: Int
        /// Height relative to the busiest day, 0…1.
        var fraction: Double
        var isToday: Bool
        var id: Date { day }
    }

    /// Bars for `days`, scaled to the busiest one (all zero when nothing ran).
    nonisolated static func sparkline(_ days: [DayTotal], now: Date = Date(), calendar: Calendar = .current) -> [SparkBar] {
        let peak = days.map(\.tokens).max() ?? 0
        return days.map { d in
            SparkBar(day: d.day, tokens: d.tokens, fraction: peak > 0 ? Double(d.tokens) / Double(peak) : 0,
                     isToday: calendar.isDate(d.day, inSameDayAs: now))
        }
    }

    nonisolated static func stats(from records: [UsageRecord], now: Date, calendar: Calendar, days: Int = 7) -> TokenStats {
        var stats = TokenStats()
        let startOfToday = calendar.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        var perDay: [Date: Int] = [:]
        var sessions = Set<String>()
        var models: [String: Int] = [:]
        for r in records {
            if r.timestamp >= startOfToday {
                stats.today.add(r)
                sessions.insert(r.sessionID)
                models[r.model, default: 0] += r.total
            }
            if r.timestamp >= fiveHoursAgo { stats.lastFiveHours.add(r) }
            perDay[calendar.startOfDay(for: r.timestamp), default: 0] += r.total
        }
        stats.days = (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: startOfToday).map { DayTotal(day: $0, tokens: perDay[$0] ?? 0) }
        }
        stats.sessionsToday = sessions.count
        stats.modelsToday = models.sorted { $0.value > $1.value }
        return stats
    }
}

/// One assistant message's token usage from a transcript.
struct UsageRecord: Equatable, Sendable {
    var timestamp: Date
    var model: String
    var sessionID: String
    var input: Int
    var output: Int
    var cacheWrite: Int
    var cacheRead: Int
    /// "messageID:requestID", for de-duplicating across transcript lines and files.
    var key: String = ""
    var total: Int { input + output + cacheWrite + cacheRead }
}

/// Reads token usage from ~/.claude/projects/**/*.jsonl. Transcripts are
/// append-only, so each file is read from where the last scan stopped.
final class TranscriptScanner: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64
        var records: [UsageRecord]
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private var seen = Set<String>()
    private let root: URL
    private let window: TimeInterval

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
         window: TimeInterval = 8 * 86400) {
        self.root = root
        self.window = window
    }

    func scan(now: Date = Date()) -> [UsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        let fm = FileManager.default
        var live = Set<String>()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= cutoff else { continue }
                let path = url.path
                live.insert(path)
                let size = UInt64(values.fileSize ?? 0)
                var state = files[path] ?? FileState(offset: 0, records: [])
                if size < state.offset { // rewritten: forget what it held so it's counted again
                    forget(state.records)
                    state = FileState(offset: 0, records: [])
                }
                if size > state.offset, let (records, consumed) = read(url, from: state.offset) {
                    state.records += records
                    state.offset += consumed
                }
                let expired = state.records.filter { $0.timestamp < cutoff }
                if !expired.isEmpty {
                    forget(expired)
                    state.records.removeAll { $0.timestamp < cutoff }
                }
                files[path] = state
            }
        }
        for (path, state) in files where !live.contains(path) {
            forget(state.records)
            files[path] = nil
        }
        return files.values.flatMap(\.records)
    }

    /// Drops keys for records we no longer hold, so `seen` stays bounded.
    private func forget(_ records: [UsageRecord]) {
        for r in records { seen.remove(r.key) }
    }

    /// Parses complete lines after `offset`; returns the records and bytes consumed.
    /// Reads complete lines after `offset` in 1 MB chunks (transcripts reach
    /// hundreds of MB; reading one whole doubled peak memory).
    private func read(_ url: URL, from offset: UInt64) -> ([UsageRecord], UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var records: [UsageRecord] = []
        var consumed: UInt64 = 0
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            let complete = carry[carry.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A) {
                if let r = parse(line) { records.append(r) }
            }
            consumed += UInt64(complete.count)
            carry = Data(carry[carry.index(after: lastNewline)...])
        }
        return consumed > 0 ? (records, consumed) : nil
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let usageMarker = Data(#""usage""#.utf8)
    nonisolated(unsafe) private static let fractionalDates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let wholeSecondDates = ISO8601DateFormatter()

    private static func date(_ stamp: String) -> Date? {
        fractionalDates.date(from: stamp) ?? wholeSecondDates.date(from: stamp)
    }

    /// Parses one transcript line, skipping duplicates (Claude Code writes a
    /// line per content block, each carrying the same message usage).
    private func parse(_ line: Data) -> UsageRecord? {
        guard line.range(of: Self.assistantMarker) != nil, line.range(of: Self.usageMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String, let timestamp = Self.date(stamp) else { return nil }
        let key = "\(message["id"] as? String ?? UUID().uuidString):\(obj["requestId"] as? String ?? "")"
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>", seen.insert(key).inserted else { return nil }
        return UsageRecord(
            timestamp: timestamp, model: model, sessionID: obj["sessionId"] as? String ?? "",
            input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0, cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            key: key)
    }
}
