import XCTest
@testable import Shell

final class WidgetSnapshotTests: XCTestCase {
    private func agent(_ title: String, _ activity: WidgetSnapshot.Activity, id: UUID = UUID()) -> WidgetSnapshot.Agent {
        WidgetSnapshot.Agent(id: id, kind: "Claude", title: title, directory: "~/code/\(title)", branch: "main",
                             activity: activity, message: nil, location: "Tab 1")
    }

    func testRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = WidgetSnapshot(
            generatedAt: now, appRunning: true, agents: [agent("shell", .needsInput)],
            fiveHour: .init(utilization: 0.4, resetsAt: now.addingTimeInterval(3600)), tokensToday: 1234,
            days: [.init(day: now, tokens: 5)], models: [.init(name: "Opus 5.5", tokens: 1000)])
        try snapshot.save(to: url)
        XCTAssertEqual(WidgetSnapshot.load(from: url), snapshot)
        XCTAssertNil(WidgetSnapshot.load(from: url.deletingLastPathComponent().appendingPathComponent("missing.json")))
    }

    func testSortsAttentionFirstThenTitle() {
        let sorted = WidgetSnapshot.sorted([agent("b", .idle), agent("z", .working), agent("a", .working), agent("m", .needsInput)])
        XCTAssertEqual(sorted.map(\.title), ["m", "a", "z", "b"])
    }

    func testLivenessAndStaleness() {
        let now = Date()
        XCTAssertTrue(WidgetSnapshot(generatedAt: now.addingTimeInterval(-60), appRunning: true).isLive(at: now))
        XCTAssertFalse(WidgetSnapshot(generatedAt: now.addingTimeInterval(-60), appRunning: false).isLive(at: now))
        XCTAssertFalse(WidgetSnapshot(generatedAt: now.addingTimeInterval(-WidgetSnapshot.staleAfter - 1), appRunning: true).isLive(at: now))
        XCTAssertFalse(WidgetSnapshot.empty.isLive(at: now))
    }

    func testResetLimitsReadAsNothingUsed() {
        let now = Date()
        XCTAssertNil(WidgetSnapshot.current(.init(utilization: 0.9, resetsAt: now.addingTimeInterval(-1)), at: now))
        XCTAssertNotNil(WidgetSnapshot.current(.init(utilization: 0.9, resetsAt: now.addingTimeInterval(60)), at: now))
        XCTAssertNotNil(WidgetSnapshot.current(.init(utilization: 0.9, resetsAt: nil), at: now))
    }

    func testStatusSignatureIgnoresMessageAndTokenChurn() {
        let id = UUID()
        var a = WidgetSnapshot(generatedAt: Date(), appRunning: true, agents: [agent("shell", .working, id: id)])
        var b = a
        b.agents[0].message = "different"
        b.tokensToday = 99
        XCTAssertEqual(a.statusSignature(), b.statusSignature())
        b.agents[0].activity = .needsInput
        XCTAssertNotEqual(a.statusSignature(), b.statusSignature())
        a.appRunning = false
        XCTAssertNotEqual(a.statusSignature(), WidgetSnapshot(generatedAt: Date(), appRunning: true, agents: a.agents).statusSignature())
    }

    func testCompactNumbers() {
        XCTAssertEqual(WidgetSnapshot.compact(999), "999")
        XCTAssertEqual(WidgetSnapshot.compact(1_250), "1.2K")
        XCTAssertEqual(WidgetSnapshot.compact(18_400_000), "18.4M")
    }

    func testShellAppURLs() throws {
        let id = UUID()
        XCTAssertEqual(ShellAppURL.session(id).url.absoluteString, "shellapp://session/\(id.uuidString)")
        XCTAssertEqual(ShellAppURL(ShellAppURL.session(id).url), .session(id))
        XCTAssertEqual(ShellAppURL(ShellAppURL.dashboard.url), .dashboard)
        XCTAssertEqual(ShellAppURL(try XCTUnwrap(URL(string: "SHELLAPP://Dashboard"))), .dashboard)
        XCTAssertNil(ShellAppURL(try XCTUnwrap(URL(string: "shellapp://session/not-a-uuid"))))
        XCTAssertNil(ShellAppURL(try XCTUnwrap(URL(string: "shellapp://elsewhere"))))
        XCTAssertNil(ShellAppURL(try XCTUnwrap(URL(string: "https://dashboard"))))
    }
}
