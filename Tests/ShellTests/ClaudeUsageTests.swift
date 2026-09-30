import XCTest
@testable import Shell

final class ClaudeUsageTests: XCTestCase {
    private func line(id: String, request: String = "req_1", at stamp: String, model: String = "claude-opus-5-5",
                      input: Int = 10, output: Int = 20, cacheWrite: Int = 30, cacheRead: Int = 40, session: String = "s1") -> String {
        #"{"type":"assistant","sessionId":"\#(session)","requestId":"\#(request)","timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead)}}}"#
    }

    func testScannerReadsIncrementallyAndDedupes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("-Users-me-repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = dir.appendingPathComponent("s1.jsonl")
        let now = ISO8601DateFormatter().string(from: Date())
        let first = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            line(id: "msg_1", at: now),
            line(id: "msg_1", at: now), // second content block, same message
        ].joined(separator: "\n") + "\n"
        try first.write(to: file, atomically: true, encoding: .utf8)

        let scanner = TranscriptScanner(root: root)
        XCTAssertEqual(scanner.scan().count, 1)

        // Appended lines are picked up; a partial trailing line waits for its newline.
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((line(id: "msg_2", at: now, output: 5) + "\n" + #"{"type":"assist"#).utf8))
        try handle.close()
        let records = scanner.scan()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.output).sorted(), [5, 20])
        XCTAssertEqual(records.first?.total, records.first.map { $0.input + $0.output + $0.cacheWrite + $0.cacheRead })
    }

    func testStatsBucketsByDayAndWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-09-29T18:00:00Z")!
        func record(_ hoursAgo: Double, _ tokens: Int, model: String = "claude-opus-5-5", session: String = "a") -> UsageRecord {
            UsageRecord(timestamp: now.addingTimeInterval(-hoursAgo * 3600), model: model, sessionID: session,
                        input: 0, output: tokens, cacheWrite: 0, cacheRead: 0)
        }
        let stats = ClaudeUsage.stats(from: [
            record(1, 100), record(4, 50, model: "claude-sonnet-5-5", session: "b"),
            record(8, 25), record(30, 1000),
        ], now: now, calendar: calendar)
        XCTAssertEqual(stats.today.total, 175)
        XCTAssertEqual(stats.lastFiveHours.total, 150)
        XCTAssertEqual(stats.sessionsToday, 2)
        XCTAssertEqual(stats.days.count, 7)
        XCTAssertEqual(stats.days.last?.tokens, 175)
        XCTAssertEqual(stats.days.dropLast().last?.tokens, 1000)
        XCTAssertEqual(stats.modelsToday.first?.0, "claude-opus-5-5")
    }

    @MainActor
    func testRateLimitEventUpdatesWindows() {
        let suite = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = ClaudeUsage(defaults: defaults)
        let now = Date()
        let reset = now.addingTimeInterval(3600).timeIntervalSince1970
        usage.record(rateLimitInfo: [
            "status": "allowed", "rateLimitType": "five_hour", "utilization": 0.42, "resetsAt": Int(reset),
            "unifiedWindows": ["seven_day": ["utilization": 0.1, "resetsAt": Int(reset + 86400)]],
        ], at: now)
        XCTAssertEqual(usage.limits?.fiveHour?.utilization ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(usage.limits?.sevenDay?.utilization ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(usage.limits?.status, "allowed")
    }

    @MainActor
    func testFormatting() {
        XCTAssertEqual(ClaudeUsageTile.compact(999), "999")
        XCTAssertEqual(ClaudeUsageTile.compact(12_345), "12.3K")
        XCTAssertEqual(ClaudeUsageTile.compact(4_200_000), "4.2M")
        XCTAssertEqual(ClaudeUsageTile.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ClaudeUsageTile.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }
}
