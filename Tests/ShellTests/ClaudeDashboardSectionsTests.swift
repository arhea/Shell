import SwiftUI
import XCTest
@testable import Shell

/// The Claude Sessions page's model: sections, timers, request text, the
/// usage strip's data, the Running elsewhere table and the Recent drawer.
@MainActor
final class ClaudeDashboardSectionsTests: XCTestCase {
    typealias Activity = ClaudeDashboard.Activity

    // MARK: Sections

    func testActivitiesMapToSections() {
        XCTAssertEqual(ClaudeDashboard.section(for: .needsInput("Allow Bash?")), .needsYou)
        XCTAssertEqual(ClaudeDashboard.section(for: .working), .working)
        XCTAssertEqual(ClaudeDashboard.section(for: .starting), .working)
        for a: Activity in [.finished("Done"), .idle, .exited] { XCTAssertEqual(ClaudeDashboard.section(for: a), .idle) }
        XCTAssertEqual(ClaudeDashboard.Section.allCases.map(\.title), ["Needs you", "Working", "Idle"])
        XCTAssertEqual(ClaudeDashboard.Section.allCases.map(\.status), [.needsYou, .working, .idle])
    }

    func testGroupingKeepsTabOrderAndPutsFinishedFirstInIdle() {
        let items: [(String, Activity)] = [
            ("idle-1", .idle), ("work-1", .working), ("ask-1", .needsInput("?")), ("exit", .exited),
            ("done", .finished("ok")), ("start", .starting), ("ask-2", .needsInput("!")), ("idle-2", .idle),
        ]
        let g = ClaudeDashboard.grouped(items) { $0.1 }
        XCTAssertEqual(g.needsYou.map(\.0), ["ask-1", "ask-2"])
        XCTAssertEqual(g.working.map(\.0), ["work-1", "start"])
        XCTAssertEqual(g.idle.map(\.0), ["done", "idle-1", "idle-2", "exit"])
        XCTAssertEqual(g.items(in: .working).map(\.0), g.working.map(\.0))
        XCTAssertFalse(g.isEmpty)
        XCTAssertTrue(ClaudeDashboard.grouped([(String, Activity)]()) { $0.1 }.isEmpty)
    }

    func testFilterMatchesTitleFolderAndBranch() {
        XCTAssertTrue(ClaudeDashboard.matches("  ", title: "x", directory: "/y", branch: nil))
        XCTAssertTrue(ClaudeDashboard.matches("TAB", title: "Editor tabs", directory: "/code/shell", branch: nil))
        XCTAssertTrue(ClaudeDashboard.matches("shell", title: "Editor tabs", directory: "/code/Shell", branch: nil))
        XCTAssertTrue(ClaudeDashboard.matches("feature/", title: "x", directory: "/y", branch: "feature/editor-tabs"))
        XCTAssertFalse(ClaudeDashboard.matches("nope", title: "x", directory: "/y", branch: "main"))
    }

    // MARK: Time

    func testElapsedAndWaitingText() {
        XCTAssertEqual(ClaudeDashboard.elapsed(-5), "0s")
        XCTAssertEqual(ClaudeDashboard.elapsed(42), "42s")
        XCTAssertEqual(ClaudeDashboard.elapsed(161), "2m 41s")
        XCTAssertEqual(ClaudeDashboard.elapsed(14 * 60 + 5), "14m")
        XCTAssertEqual(ClaudeDashboard.elapsed(3600), "1h")
        XCTAssertEqual(ClaudeDashboard.elapsed(3900), "1h 5m")
        XCTAssertEqual(ClaudeDashboard.waiting(20), "waiting <1 min")
        XCTAssertEqual(ClaudeDashboard.waiting(4 * 60 + 30), "waiting 4 min")
        XCTAssertEqual(ClaudeDashboard.waiting(2 * 3600 + 10), "waiting 2 h")
    }

    func testActivityClockRestartsOnlyWhenTheSectionChanges() {
        let clock = ActivityClock()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(clock.note(id, section: .working, now: t0), t0)
        XCTAssertEqual(clock.since(id, section: .working, now: t0.addingTimeInterval(60)), t0, "still working: same start")
        XCTAssertEqual(clock.since(id, section: .needsYou, now: t0.addingTimeInterval(90)), t0.addingTimeInterval(90))
        clock.note(UUID(), section: .idle, now: t0)
        XCTAssertEqual(clock.count, 2)
        clock.prune(keeping: [id])
        XCTAssertEqual(clock.count, 1)
    }

    func testTabShortcutsAndRepoNames() {
        XCTAssertEqual(ClaudeDashboard.tabShortcut(0), ShortcutAction.tab1.shortcut?.displayString)
        XCTAssertEqual(ClaudeDashboard.tabShortcut(7), ShortcutAction.tab8.shortcut?.displayString)
        XCTAssertNil(ClaudeDashboard.tabShortcut(8))
        XCTAssertNil(ClaudeDashboard.tabShortcut(-1))
        XCTAssertEqual(ClaudeDashboard.repoName(slug: "arhea/Shell", folder: "swift-tests-cadf19"), "Shell")
        XCTAssertEqual(ClaudeDashboard.repoName(slug: nil, folder: "backend"), "backend")
    }

    // MARK: Requests

    func testRequestHeadlinesAndChips() {
        typealias T = DashboardRequestText
        XCTAssertEqual(T.headline(toolName: "Edit", input: ["file_path": "/r/Sources/TabStore.swift"]), "Claude wants to edit TabStore.swift")
        XCTAssertEqual(T.headline(toolName: "Write", input: [:]), "Claude wants to write a file")
        XCTAssertEqual(T.headline(toolName: "NotebookEdit", input: ["notebook_path": "/r/a.ipynb"]), "Claude wants to edit a.ipynb")
        XCTAssertEqual(T.headline(toolName: "Bash", input: ["command": "make"]), "Claude wants to run a command")
        XCTAssertEqual(T.headline(toolName: "WebFetch", input: ["url": "https://example.com/x"]), "Claude wants to fetch example.com")
        XCTAssertEqual(T.headline(toolName: "WebSearch", input: [:]), "Claude wants to search the web")
        XCTAssertEqual(T.headline(toolName: "mcp__github__create_issue", input: [:]), "Claude wants to use github’s create_issue")
        XCTAssertEqual(T.headline(toolName: "Task", input: [:]), "Claude wants to use Task")

        XCTAssertEqual(T.chips(toolName: "Bash", input: ["command": "git status\ngit diff"]), ["git status"])
        XCTAssertEqual(T.chips(toolName: "Bash", input: ["command": String(repeating: "x", count: 100)]).first?.count, 80)
        XCTAssertEqual(T.chips(toolName: "Grep", input: ["pattern": "TODO"]), ["TODO"])
        XCTAssertEqual(T.chips(toolName: "Task", input: [:]), [])
        XCTAssertEqual(T.chips(toolName: "Edit", input: ["file_path": "/tmp/a.swift"]).count, 1)
    }

    func testAlwaysAllowLabelSaysWhatItDoes() {
        typealias T = DashboardRequestText
        XCTAssertNil(T.alwaysLabel(suggestions: []))
        XCTAssertEqual(T.alwaysLabel(suggestions: [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]), "Allow edits this session")
        XCTAssertEqual(T.alwaysLabel(suggestions: [["type": "setMode", "mode": "acceptEdits", "destination": "localSettings"]]), "Always allow edits")
        XCTAssertEqual(T.alwaysLabel(suggestions: [["type": "addDirectories", "directories": ["/x"], "destination": "session"]]), "Allow this folder")
        XCTAssertEqual(T.alwaysLabel(suggestions: [["type": "addRules", "destination": "session"]]), "Allow this session")
        XCTAssertEqual(T.alwaysLabel(suggestions: [["type": "addRules", "destination": "localSettings"]]), "Always allow")
        XCTAssertEqual(T.alwaysLabel(suggestions: ["opaque"]), "Always allow")
    }

    // MARK: Usage strip

    func testLimitLevelsAndPercent() {
        XCTAssertEqual(ClaudeUsage.LimitWindow(utilization: 0.25).level, .normal)
        XCTAssertEqual(ClaudeUsage.LimitWindow(utilization: 0.70).level, .normal)
        XCTAssertEqual(ClaudeUsage.LimitWindow(utilization: 0.71).level, .warning)
        XCTAssertEqual(ClaudeUsage.LimitWindow(utilization: 0.91).level, .critical)
        XCTAssertEqual(ClaudeUsage.LimitWindow(utilization: 0.474).percent, 47)
        XCTAssertEqual(ClaudeUsage.LimitWindow(utilization: 1.4).percent, 100)
        XCTAssertEqual(ClaudeUsage.LimitWindow(utilization: -1).percent, 0)
    }

    func testCacheShare() {
        XCTAssertNil(ClaudeUsage.TokenBreakdown().cacheShare)
        let b = ClaudeUsage.TokenBreakdown(input: 5, output: 1_000, cacheWrite: 5, cacheRead: 990)
        XCTAssertEqual(b.cacheShare ?? 0, 0.99, accuracy: 0.0001)
    }

    func testSparklineScalesToTheBusiestDayAndMarksToday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let today = cal.startOfDay(for: now)
        let days = (0..<7).reversed().map { offset in
            ClaudeUsage.DayTotal(day: cal.date(byAdding: .day, value: -offset, to: today)!, tokens: offset == 3 ? 400 : offset == 0 ? 100 : 0)
        }
        let bars = ClaudeUsage.sparkline(days, now: now, calendar: cal)
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars.map(\.isToday), [false, false, false, false, false, false, true])
        XCTAssertEqual(bars[3].fraction, 1)
        XCTAssertEqual(bars[6].fraction, 0.25)
        XCTAssertEqual(bars[0].fraction, 0)
        XCTAssertTrue(ClaudeUsage.sparkline([ClaudeUsage.DayTotal(day: today, tokens: 0)], now: now, calendar: cal).allSatisfy { $0.fraction == 0 })
    }

    // MARK: Running elsewhere

    private func running(_ name: String, status: String? = nil, state: String? = nil, waitingFor: String? = nil,
                         job: String? = nil, age: TimeInterval = 0, host: ClaudeRunningSession.Host = .terminal) -> ClaudeRunningSession {
        ClaudeRunningSession(kind: job.map { .background(jobID: $0) } ?? .interactive, pid: 1, sessionID: name, directory: "/Users/me/takt-corp/backend",
                             name: name, status: status, waitingFor: waitingFor, state: state,
                             startedAt: Date(timeIntervalSince1970: 1_000_000 - age), host: host)
    }

    func testElsewhereStatusLabels() {
        XCTAssertEqual(running("a", status: "waiting", waitingFor: "permission prompt").statusLabel, "Needs permission")
        XCTAssertEqual(running("a", status: "waiting", waitingFor: "your answer").statusLabel, "Waiting on your answer")
        XCTAssertEqual(running("a", state: "blocked").statusLabel, "Needs input")
        XCTAssertEqual(running("a", status: "busy").statusLabel, "Working")
        XCTAssertEqual(running("a", state: "working", job: "j").dashboardStatus, .working)
        XCTAssertEqual(running("a", state: "done", job: "j").statusLabel, "Done")
        XCTAssertEqual(running("a", state: "failed", job: "j").statusLabel, "Failed")
        XCTAssertEqual(running("a", state: "stopped", job: "j").statusLabel, "Stopped · Background")
        XCTAssertEqual(running("a", status: "idle", job: "j").statusLabel, "Idle · Background")
        XCTAssertEqual(running("a", status: "idle").statusLabel, "Idle")
        XCTAssertEqual(running("a", host: .claudeDesktop).hostLabel, "Claude desktop")
        XCTAssertEqual(running("a").hostLabel, "Other terminal")
        XCTAssertEqual(running("a").folderLabel, "takt-corp/backend")
        XCTAssertTrue(running("backend-bug-watch").matches("BUG"))
        XCTAssertTrue(running("x").matches("takt-corp"))
        XCTAssertFalse(running("x").matches("frontend"))
    }

    func testElsewhereSortsNeedsYouFirstAndFoldsIdleRows() {
        let sessions = [
            running("idle-old", status: "idle", age: 500), running("busy", status: "busy", age: 100),
            running("ask", status: "waiting", age: 300), running("idle-new", status: "idle", age: 10),
        ] + (0..<6).map { running("bg-\($0)", status: "idle", job: "j\($0)", age: 1_000 + Double($0)) }
        let sorted = ClaudeRunningSession.sortedForDashboard(sessions)
        XCTAssertEqual(Array(sorted.prefix(4).map { $0.name! }), ["ask", "busy", "idle-new", "idle-old"])
        XCTAssertEqual(ClaudeRunningSession.visibleCount(sorted, limit: 5), 5)
        XCTAssertEqual(ClaudeRunningSession.moreLabel(sorted.suffix(5)), "Show 5 more idle sessions")
        XCTAssertEqual(ClaudeRunningSession.moreLabel([running("w", status: "busy")]), "Show 1 more session")
        // Every session that isn't idle stays visible, even past the limit.
        let busy = (0..<7).map { running("b\($0)", status: "busy") } + [running("i", status: "idle")]
        XCTAssertEqual(ClaudeRunningSession.visibleCount(ClaudeRunningSession.sortedForDashboard(busy), limit: 5), 7)
        XCTAssertEqual(ClaudeRunningSession.visibleCount([running("i")], limit: 5), 1)
    }

    // MARK: Recent drawer

    private func past(_ id: String, _ when: Date, dir: String = "/code/a") -> ClaudePastSession {
        ClaudePastSession(id: id, directory: dir, title: id, prompt: nil, branch: nil, lastActive: when)
    }

    func testRecentDrawerGroupsByDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        cal.locale = Locale(identifier: "en_US")
        // Thursday, 1 Oct 2026, 15:00 UTC.
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 15)))
        let hour: TimeInterval = 3600
        let sessions = [
            past("yesterday", now - 20 * hour), past("today-old", now - 5 * hour), past("today-new", now - hour),
            past("monday", now - 3 * 24 * hour), past("old", now - 20 * 24 * hour), past("last-year", now - 400 * 24 * hour),
        ]
        let groups = PastSessionsDrawer.dayGroups(sessions, now: now, calendar: cal)
        XCTAssertEqual(groups.map { $0.sessions.map(\.id) }, [["today-new", "today-old"], ["yesterday"], ["monday"], ["old"], ["last-year"]])
        XCTAssertEqual(groups[0].title, "Today")
        XCTAssertEqual(groups[1].title, "Yesterday")
        XCTAssertFalse(groups[2].title.isEmpty)
        XCTAssertNotEqual(groups[3].title, groups[4].title)
        XCTAssertTrue(PastSessionsDrawer.dayGroups([], now: now, calendar: cal).isEmpty)
    }

    func testRecentFoldersAndPullRequestLabels() {
        let now = Date()
        let folders = DashboardActions.recentFolders([
            past("1", now - 30, dir: "/a"), past("2", now - 10, dir: "/b"), past("3", now - 20, dir: "/a"), past("4", now - 40, dir: "/c"),
        ], limit: 2)
        XCTAssertEqual(folders, ["/b", "/a"])

        let url = URL(string: "https://github.com/o/r/pull/7")!
        XCTAssertEqual(PastSessionCard.pullRequestLabel(PullRequestInfo(number: 7, title: "t", url: url, state: .open, isDraft: false)).0, "#7 open")
        XCTAssertEqual(PastSessionCard.pullRequestLabel(PullRequestInfo(number: 7, title: "t", url: url, state: .open, isDraft: true)).0, "#7 draft")
        XCTAssertEqual(PastSessionCard.pullRequestLabel(PullRequestInfo(number: 7, title: "t", url: url, state: .merged, isDraft: false)).0, "#7 merged")
        XCTAssertEqual(PastSessionCard.pullRequestLabel(PullRequestInfo(number: 7, title: "t", url: url, state: .closed, isDraft: false)).0, "#7 closed")
    }

    // MARK: Views

    func testPermissionRowRendersEachKindOfRequest() {
        var decisions: [String] = []
        for (tool, input, suggestions) in [
            ("Edit", ["file_path": "/r/TabStore.swift"], [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]),
            ("Bash", ["command": "make test"], []),
        ] as [(String, [String: Any], [Any])] {
            let req = ClaudePermissionRequest(id: tool, toolName: tool, displayName: tool, input: input, description: "Move tab state",
                                              suggestions: suggestions, reason: "Outside the project")
            let host = render(DashboardPermissionRow(request: req) { allow, always in decisions.append("\(allow)\(always)") },
                              size: CGSize(width: 900, height: 120))
            XCTAssertGreaterThan(host.fittingSize.height, 0)
            render(DashboardPermissionRow(request: req) { _, _ in }, size: CGSize(width: 320, height: 200))
        }
        XCTAssertTrue(decisions.isEmpty, "rendering decides nothing")
    }

    func testRunningElsewhereRowsRender() {
        for s in [running("a", status: "waiting", waitingFor: "permission prompt"), running("b", status: "idle", job: "j1"),
                  running("c", status: "busy", host: .claudeDesktop), running("d", state: "failed", job: "j2")] {
            let host = render(RunningElsewhereRow(session: s) {}, size: CGSize(width: 900, height: 40))
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }
}
