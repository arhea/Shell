import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// A real (never shown) window with tabs of terminal and native Claude
/// sessions, registered with the app delegate so the dashboard lists them.
/// Native sessions run `/usr/bin/false` in an untrusted temp folder, so no
/// process starts. Rendering never scans transcripts under tests
/// (`ClaudeUsageTile.refreshesUsage`). `close()` tears everything down.
@MainActor
private final class DashboardFixture {
    let controller: TerminalWindowController
    let dir: URL
    private var extra: [TerminalWindowController] = []

    init(dir: URL) {
        self.dir = dir
        controller = AppDelegate.shared.newWindowController()
    }

    func secondWindow() -> TerminalWindowController {
        let c = AppDelegate.shared.newWindowController()
        extra.append(c)
        return c
    }

    /// A terminal tab running `command` (nil: an idle shell).
    @discardableResult
    func terminal(_ command: String? = "claude", in controller: TerminalWindowController? = nil) -> (TerminalTab, TerminalSession) {
        let tab = (controller ?? self.controller).newTab(directory: dir.path)
        let session = tab.focusedSession!
        if let command { session.commandStarted(command, directory: nil) }
        return (tab, session)
    }

    @discardableResult
    func native() -> (TerminalTab, TerminalSession, ClaudeCodeSession) {
        let tab = controller.newTab(directory: dir.path)
        let session = tab.focusedSession!
        session.startNativeClaude(ClaudeLaunchRequest(directory: dir.path, binary: "/usr/bin/false", arguments: ClaudeArguments(), environment: [:]))
        let claude = session.nativeClaude!
        claude.onEvent = nil // no notifications from the events fed below
        return (tab, session, claude)
    }

    func close() {
        for c in [controller] + extra { c.close() }
        DashboardRepos.shared.releaseAll()
        XCTAssertFalse(AppDelegate.shared.controllers.contains { c in ([controller] + extra).contains { $0 === c } },
                       "closed windows leave the app delegate")
    }
}

/// Stream-json messages for a native session.
@MainActor
private enum Feed {
    static func assistant(_ claude: ClaudeCodeSession, _ text: String) {
        claude.handle(["type": "assistant", "parent_tool_use_id": NSNull(),
                       "message": ["id": UUID().uuidString, "model": "claude-opus-5-5", "content": [["type": "text", "text": text]]]])
    }

    static func tool(_ claude: ClaudeCodeSession, _ name: String, _ input: [String: Any]) {
        claude.handle(["type": "assistant", "parent_tool_use_id": NSNull(),
                       "message": ["id": UUID().uuidString, "content": [["type": "tool_use", "id": UUID().uuidString, "name": name, "input": input]]]])
    }

    static func request(_ claude: ClaudeCodeSession, id: String, tool: String, input: [String: Any]) {
        claude.handle(["type": "control_request", "request_id": id,
                       "request": ["subtype": "can_use_tool", "tool_name": tool, "input": input, "description": "Run it"]])
    }

    static func cancel(_ claude: ClaudeCodeSession, id: String) {
        claude.handle(["type": "control_cancel_request", "request_id": id])
    }

    static let question: [String: Any] = ["questions": [["question": "Which approach?", "header": "Approach", "multiSelect": false,
                                                         "options": [["label": "A", "description": "First"], ["label": "B", "description": "Second"]]]]]
}

@MainActor
final class ClaudeDashboardModelTests: XCTestCase {
    func testRenderingNeverScansTranscriptsUnderTests() {
        XCTAssertFalse(ClaudeUsageTile.refreshesUsage)
        XCTAssertFalse(PastSessionsDrawer.refreshesHistory)
        XCTAssertFalse(RunningElsewhereSection.refreshesSessions, "never runs the user's claude")
    }

    func testSummaryDetail() {
        XCTAssertEqual(ClaudeDashboard.Summary().detail, "")
        XCTAssertEqual(ClaudeDashboard.Summary(total: 5, working: 1, needsInput: 1, finished: 1).detail, "1 needs input · 1 working · 1 done · 2 idle")
        XCTAssertEqual(ClaudeDashboard.Summary(total: 2, needsInput: 2).detail, "2 need input")
    }

    func testActivityTitlesAndMessages() {
        let all: [ClaudeDashboard.Activity] = [.needsInput("q"), .working, .finished("done"), .starting, .idle, .exited]
        XCTAssertEqual(all.map(\.title), ["Needs input", "Working", "Done", "Starting", "Idle", "Exited"])
        XCTAssertEqual(all.map(\.message), ["q", nil, "done", nil, nil, nil])
    }

    func testVisibilityFollowsTheSetting() {
        XCTAssertTrue(DashboardVisibility.shows(mode: .never, sessions: 0, claudeInstalled: false, dashboardOpen: true))
        XCTAssertTrue(DashboardVisibility.shows(mode: .always, sessions: 0, claudeInstalled: true, dashboardOpen: false))
        XCTAssertTrue(DashboardVisibility.shows(mode: .always, sessions: 1, claudeInstalled: false, dashboardOpen: false))
        XCTAssertFalse(DashboardVisibility.shows(mode: .always, sessions: 0, claudeInstalled: false, dashboardOpen: false))
        XCTAssertTrue(DashboardVisibility.shows(mode: .whenActive, sessions: 2, claudeInstalled: true, dashboardOpen: false))
        XCTAssertFalse(DashboardVisibility.shows(mode: .whenActive, sessions: 0, claudeInstalled: true, dashboardOpen: false))
        XCTAssertFalse(DashboardVisibility.shows(mode: .never, sessions: 3, claudeInstalled: true, dashboardOpen: false))

        let workspace = Workspace()
        withSettings({ $0.claudeSessionsButton = .never }) {
            XCTAssertNil(DashboardVisibility(workspace: workspace).summary)
            workspace.showsDashboard = true
            XCTAssertEqual(DashboardVisibility(workspace: workspace).summary?.total, 0)
        }
        workspace.showsDashboard = false
        withSettings({ $0.claudeSessionsButton = .whenActive }) {
            XCTAssertNil(DashboardVisibility(workspace: workspace).summary)
        }
    }

    func testDirectoriesAreHomeRelative() {
        let inHome = TerminalSession(workingDirectory: NSHomeDirectory() + "/code/project")
        let outside = TerminalSession(workingDirectory: "/opt/project")
        let none = TerminalSession(workingDirectory: nil)
        defer { [inHome, outside, none].forEach { $0.close() } }
        XCTAssertEqual(ClaudeDashboard.directory(for: inHome), "~/code/project")
        XCTAssertEqual(ClaudeDashboard.directory(for: outside), "/opt/project")
        XCTAssertEqual(ClaudeDashboard.fullDirectory(for: none), NSHomeDirectory())
        XCTAssertNil(ClaudeDashboard.branch(for: outside))
    }

    func testTerminalSessionActivityFollowsAgentHooks() {
        let session = TerminalSession(workingDirectory: "/tmp")
        defer { session.close() }
        XCTAssertEqual(ClaudeDashboard.activity(for: session), .idle)
        session.agent = .working(.claude)
        XCTAssertEqual(ClaudeDashboard.activity(for: session), .working)
        session.agent = .needsInput(.claude, "Allow Bash?")
        XCTAssertEqual(ClaudeDashboard.activity(for: session), .needsInput("Allow Bash?"))
        session.agent = .finished(.claude, "All done")
        XCTAssertEqual(ClaudeDashboard.activity(for: session), .finished("All done"))
        XCTAssertEqual(SessionSummaries.transcript(for: session), "", "no terminal engine in tests: empty viewport")
        XCTAssertNil(SessionSummaries.shared.line(for: session))
    }

    func testNativePreviewShowsTheLatestReplyOrTool() {
        let claude = ClaudeCodeSession(request: ClaudeLaunchRequest(directory: NSTemporaryDirectory(), binary: "/usr/bin/false",
                                                                    arguments: ClaudeArguments(), environment: [:]))
        XCTAssertEqual(ClaudeDashboard.nativePreview(claude), [])
        Feed.assistant(claude, "line one\n\n  line two  \nline three")
        XCTAssertEqual(ClaudeDashboard.nativePreview(claude, limit: 2), ["line two", "line three"])
        Feed.tool(claude, "Bash", ["command": "ls -la"])
        XCTAssertEqual(ClaudeDashboard.nativePreview(claude).count, 1)
        XCTAssertTrue(ClaudeDashboard.nativePreview(claude)[0].hasPrefix("Bash"))
        Feed.tool(claude, "Unknown", [:])
        XCTAssertEqual(ClaudeDashboard.nativePreview(claude), ["Unknown"])
    }

    func testChooseTypesTheOptionKey() {
        let session = TerminalSession(workingDirectory: "/tmp")
        defer { session.close() }
        // No terminal engine in tests: this exercises the path without effect.
        ClaudeDashboard.choose(.init(key: "1", label: "Yes"), in: session)
        _ = waitUntil(timeout: 0.6) { false }
    }

    func testSummaryRefreshIsOffWithoutAppleIntelligence() async {
        let session = TerminalSession(workingDirectory: "/tmp")
        defer { session.close() }
        let original = SettingsStore.shared.settings
        defer { SettingsStore.shared.settings = original }
        SettingsStore.shared.settings.intelligenceSessionSummaries = false
        await SessionSummaries.shared.refresh(session)
        XCTAssertNil(SessionSummaries.shared.line(for: session))
    }
}

@MainActor
final class ClaudeDashboardViewTests: XCTestCase {
    private var chrome: ChromePalette { ChromePalette.current }

    func testEntriesLocationsTitlesAndSummary() throws {
        let fx = DashboardFixture(dir: try makeTemporaryDirectory())
        defer { fx.close() }
        let (tab1, terminal) = fx.terminal("claude --resume 7bcc953c")
        tab1.customTitle = "Refactor"
        fx.terminal(nil) // not Claude: not listed
        let (_, native, _) = fx.native()
        fx.controller.split(.horizontal) // second pane in the native tab, not Claude

        var entries = ClaudeDashboard.entries()
        XCTAssertEqual(entries.map(\.session.id), [terminal.id, native.id])
        XCTAssertEqual(entries[0].location, "Tab 1")
        XCTAssertEqual(entries[1].location, "Tab 3 · Pane 1")
        XCTAssertEqual(ClaudeDashboard.title(for: entries[0]), "Refactor")
        XCTAssertEqual(ClaudeDashboard.title(for: entries[1]), fx.dir.lastPathComponent, "outside git the native tab title is the folder")
        XCTAssertEqual(ClaudeDashboard.entries { _ in true }.count, 4)

        terminal.agent = .working(.claude)
        let summary = ClaudeDashboard.summary(of: entries)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.working, 1)
        XCTAssertEqual(summary.needsInput, 1, "the native session waits for the folder to be trusted")

        // With two windows, entries name the window.
        let second = fx.secondWindow()
        fx.terminal("claude", in: second)
        entries = ClaudeDashboard.entries()
        XCTAssertTrue(ClaudeDashboard.controllers.contains { $0 === second })
        XCTAssertEqual(entries.last?.location, "Window \(ClaudeDashboard.controllers.firstIndex { $0 === second }! + 1) · Tab 1")
        XCTAssertTrue(entries.first?.location.hasPrefix("Window ") == true)
    }

    func testNativeSessionStateAndTranscript() throws {
        let fx = DashboardFixture(dir: try makeTemporaryDirectory())
        defer { fx.close() }
        let (_, session, claude) = fx.native()
        XCTAssertTrue(claude.needsTrust)
        XCTAssertEqual(ClaudeDashboard.activity(for: session), .needsInput("Trust this folder to start Claude Code"))
        claude.handle(["type": "user", "message": ["content": [["type": "text", "text": "hi"]]]])
        Feed.assistant(claude, "Hello there")
        Feed.tool(claude, "Read", ["file_path": "/tmp/a.swift"])
        claude.handle(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": "boom"])
        claude.handle(["type": "result", "subtype": "success", "is_error": true, "result": "API Error"])
        let transcript = SessionSummaries.transcript(for: session)
        XCTAssertTrue(transcript.contains("Claude: Hello there"))
        XCTAssertTrue(transcript.contains("Tool: Read"))
        XCTAssertTrue(transcript.contains("Error: API Error"))
    }

    func testRendersTheDashboardInEveryState() throws {
        let fx = DashboardFixture(dir: try makeTemporaryDirectory())
        defer { fx.close() }
        // Empty, with and without the past sessions drawer.
        for history in [true, false] {
            withSettings({ $0.claudeSessionsHistory = history }) {
                let host = render(ClaudeDashboardView(controller: fx.controller), size: CGSize(width: 1200, height: 900))
                XCTAssertGreaterThan(host.fittingSize.height, 0)
            }
        }
        // Populated: terminal sessions in each hook state, in a group, and native sessions.
        let group = TabGroup(name: "", color: .teal)
        fx.controller.workspace.groups.append(group)
        let (tab, working) = fx.terminal("claude\n--verbose")
        tab.groupID = group.id
        working.agent = .working(.claude)
        let (named, waiting) = fx.terminal("claude")
        let namedGroup = TabGroup(name: "Agents", color: .purple)
        fx.controller.workspace.groups.append(namedGroup)
        named.groupID = namedGroup.id
        waiting.agent = .needsInput(.claude, "Allow Bash?")
        fx.terminal("claude").1.agent = .finished(.claude, "Done")
        fx.terminal("claude")
        let (_, _, claude) = fx.native()
        Feed.assistant(claude, "Working on it")
        claude.handle(["type": "result", "subtype": "success", "is_error": false, "result": "Done", "total_cost_usd": 1.25])
        let (_, _, asking) = fx.native()
        Feed.request(asking, id: "q1", tool: "AskUserQuestion", input: Feed.question)
        for history in [true, false] {
            withSettings({ $0.claudeSessionsHistory = history }) {
                let host = render(ClaudeDashboardView(controller: fx.controller), size: CGSize(width: 1400, height: 1600))
                XCTAssertGreaterThan(host.fittingSize.height, 0)
            }
        }
    }

    func testSessionTilesForEachKind() throws {
        let fx = DashboardFixture(dir: try makeTemporaryDirectory())
        defer { fx.close() }
        let (_, terminal) = fx.terminal("claude")
        let (_, _, claude) = fx.native()
        var opened = 0
        for agent in [nil, AgentStatus.working(.claude), .needsInput(.claude, "?"), .finished(.claude, "ok")] {
            terminal.agent = agent
            for entry in ClaudeDashboard.entries() {
                render(ClaudeSessionTile(entry: entry, palette: chrome) { opened += 1 }, size: CGSize(width: 420, height: 300))
            }
        }
        // Native: a preview, then each kind of pending request.
        Feed.assistant(claude, "Reply")
        let native = try XCTUnwrap(ClaudeDashboard.entries().first { $0.session.nativeClaude != nil })
        render(ClaudeSessionTile(entry: native, palette: chrome) {}, size: CGSize(width: 420, height: 400))
        for (id, tool, input) in [("q", "AskUserQuestion", Feed.question), ("p", "ExitPlanMode", ["plan": "# Plan\n\n1. Do it"]),
                                  ("b", "Bash", ["command": "rm -rf build", "description": "Clean"])] as [(String, String, [String: Any])] {
            Feed.request(claude, id: id, tool: tool, input: input)
            XCTAssertEqual(claude.pending.first?.id, id)
            render(ClaudeSessionTile(entry: native, palette: chrome) {}, size: CGSize(width: 420, height: 600))
            render(DashboardApproval(session: native.session, palette: chrome), size: CGSize(width: 420, height: 400))
            Feed.cancel(claude, id: id)
        }
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertEqual(opened, 0, "rendering doesn't open sessions")
    }

    func testTerminalPromptApproval() throws {
        let fx = DashboardFixture(dir: try makeTemporaryDirectory())
        defer { fx.close() }
        let (_, session) = fx.terminal("claude")
        let prompt = ClaudeDashboard.TerminalPrompt(question: "Do you want to proceed?", context: ["Bash command", "git status"],
                                                    options: [.init(key: "1", label: "Yes"), .init(key: "2", label: "No")])
        render(DashboardApproval(session: session, palette: chrome, terminalPrompt: prompt), size: CGSize(width: 420, height: 300))
        let bare = ClaudeDashboard.TerminalPrompt(question: "Continue?", context: [], options: [.init(key: "1", label: "Yes")])
        render(DashboardApproval(session: session, palette: chrome, terminalPrompt: bare), size: CGSize(width: 420, height: 200))
        // Nothing to show without a prompt.
        let host = render(DashboardApproval(session: session, palette: chrome), size: CGSize(width: 420, height: 200))
        XCTAssertEqual(host.fittingSize.height, 0)
    }

    func testTabStripEntries() throws {
        let fx = DashboardFixture(dir: try makeTemporaryDirectory())
        defer { fx.close() }
        let summaries = [ClaudeDashboard.Summary(), ClaudeDashboard.Summary(total: 3, working: 1, needsInput: 1, finished: 1)]
        for selected in [false, true] {
            fx.controller.workspace.showsDashboard = selected
            for summary in summaries {
                render(DashboardTabChip(controller: fx.controller, workspace: fx.controller.workspace, summary: summary, palette: chrome),
                       size: CGSize(width: 140, height: 30))
                render(DashboardSidebarRow(controller: fx.controller, workspace: fx.controller.workspace, summary: summary, palette: chrome),
                       size: CGSize(width: 240, height: 50))
                render(DashboardStatusIcon(summary: summary, palette: chrome, active: selected), size: CGSize(width: 20, height: 20))
                let badge = render(DashboardCountBadge(summary: summary, palette: chrome), size: CGSize(width: 30, height: 20))
                XCTAssertEqual(badge.fittingSize.width > 0, summary.total > 0)
            }
        }
        fx.controller.workspace.showsDashboard = false
    }

    func testLogoStates() {
        render(ClaudeLogo(), size: CGSize(width: 20, height: 20))
        render(ClaudeLogo(size: 28, spinning: true, alert: .yellow), size: CGSize(width: 40, height: 40))
        XCTAssertEqual(ClaudeLogoShape().path(in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty, false)
    }

    func testPullRequestLinks() {
        let url = URL(string: "https://github.com/o/r/pull/7")!
        for (state, draft) in [(PullRequestInfo.State.open, false), (.open, true), (.merged, false), (.closed, false)] {
            let pr = PullRequestInfo(number: 7, title: "Fix it", url: url, state: state, isDraft: draft)
            let host = render(PullRequestLink(pr: pr, palette: chrome), size: CGSize(width: 200, height: 24))
            XCTAssertGreaterThan(host.fittingSize.width, 0)
        }
    }
}

// MARK: - Usage tile

@MainActor
final class ClaudeUsageTileTests: XCTestCase {
    private var chrome: ChromePalette { ChromePalette.current }

    private func usage() -> ClaudeUsage {
        let suite = "ShellTests-usage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return ClaudeUsage(defaults: defaults)
    }

    func testFormatting() {
        XCTAssertEqual(ClaudeUsageTile.compact(999), "999")
        XCTAssertEqual(ClaudeUsageTile.compact(1_500), "1.5K")
        XCTAssertEqual(ClaudeUsageTile.compact(2_300_000), "2.3M")
        XCTAssertEqual(ClaudeUsageTile.compact(4_000_000_000), "4.0B")
        XCTAssertEqual(ClaudeUsageTile.modelName("claude-opus-5-5"), ClaudeModelName.format("claude-opus-5-5"))
        XCTAssertFalse(ClaudeUsageTile.weekday(Date()).isEmpty)
    }

    func testRendersWithoutAndWithPlanLimits() {
        let empty = usage()
        render(ClaudeUsageTile(palette: chrome, usage: empty), size: CGSize(width: 420, height: 300))

        let now = Date()
        let limited = usage()
        limited.record(rateLimitInfo: ["unifiedWindows": [
            "five_hour": ["utilization": 0.95, "resetsAt": now.addingTimeInterval(3600).timeIntervalSince1970],
            "seven_day": ["utilization": 0.75, "resetsAt": now.addingTimeInterval(3 * 86400).timeIntervalSince1970],
        ]], at: now.addingTimeInterval(-600))
        XCTAssertNotNil(limited.limits?.fiveHour)
        render(ClaudeUsageTile(palette: chrome, usage: limited), size: CGSize(width: 420, height: 300))

        let fresh = usage()
        fresh.record(rateLimitInfo: ["rateLimitType": "seven_day", "utilization": 0.2, "resetsAt": now.addingTimeInterval(1800).timeIntervalSince1970])
        fresh.record(rateLimitInfo: ["rateLimitType": "five_hour", "utilization": 0.1])
        render(ClaudeUsageTile(palette: chrome, usage: fresh), size: CGSize(width: 420, height: 300))
    }

    func testRendersTokenTotals() {
        render(ClaudeUsageTokens(stats: nil, palette: chrome), size: CGSize(width: 420, height: 100))
        let now = Date()
        func record(_ ago: TimeInterval, _ model: String, _ output: Int) -> UsageRecord {
            UsageRecord(timestamp: now.addingTimeInterval(-ago), model: model, sessionID: "s\(model)", input: 1_000, output: output,
                        cacheWrite: 500, cacheRead: 20_000)
        }
        let stats = ClaudeUsage.stats(from: [record(60, "claude-opus-5-5", 3_000), record(120, "claude-sonnet-5", 100), record(3 * 86400, "claude-opus-5-5", 9_000)],
                                      now: now, calendar: .current)
        XCTAssertEqual(stats.sessionsToday, 2)
        render(ClaudeUsageTokens(stats: stats, palette: chrome), size: CGSize(width: 420, height: 120))
        // One session, nothing today.
        let quiet = ClaudeUsage.stats(from: [record(3 * 86400, "claude-opus-5-5", 9)], now: now, calendar: .current)
        render(ClaudeUsageTokens(stats: quiet, palette: chrome), size: CGSize(width: 420, height: 120))
    }
}

// MARK: - Past sessions

@MainActor
final class PastSessionsDrawerTests: XCTestCase {
    private func session(_ dir: String, id: String = UUID().uuidString.lowercased(), prompt: String? = "Fix the login redirect",
                         branch: String? = "fix/login") -> ClaudePastSession {
        ClaudePastSession(id: id, directory: dir, title: "brisk-wren", prompt: prompt, branch: branch, lastActive: Date().addingTimeInterval(-3600))
    }

    func testFilterMatchesTitlePromptFolderAndBranch() {
        let a = session("/code/shell", prompt: "Fix the login redirect", branch: "fix/login")
        let b = session("/code/api", prompt: nil, branch: nil)
        let all = [a, b]
        XCTAssertEqual(PastSessionsDrawer.filter(all, query: "  "), all)
        XCTAssertEqual(PastSessionsDrawer.filter(all, query: "LOGIN"), [a])
        XCTAssertEqual(PastSessionsDrawer.filter(all, query: "api"), [b])
        XCTAssertEqual(PastSessionsDrawer.filter(all, query: "brisk"), all)
        XCTAssertEqual(PastSessionsDrawer.filter(all, query: "fix/"), [a])
        XCTAssertEqual(PastSessionsDrawer.filter(all, query: "nothing"), [])
    }

    func testCommands() {
        let id = "7bcc953c-5abd-4120-82da-148001c196cb"
        XCTAssertEqual(PastSessionAction.command(for: .resume, session: session("/x", id: id)), "claude --resume \(id)")
        XCTAssertNil(PastSessionAction.command(for: .resume, session: session("/x", id: "not-a-uuid; rm -rf ~")))
        XCTAssertEqual(PastSessionAction.command(for: .newSession, session: session("/x")), "claude")
        XCTAssertNil(PastSessionAction.command(for: .terminal, session: session("/x")))
    }

    func testPerformOpensATabInTheSessionFolder() throws {
        let dir = try makeTemporaryDirectory()
        let fx = DashboardFixture(dir: dir)
        defer { fx.close() }
        let id = "7bcc953c-5abd-4120-82da-148001c196cb"
        let tabs = { fx.controller.workspace.tabs }
        PastSessionAction.perform(.resume, session: session(dir.path + "/missing"), controller: fx.controller)
        XCTAssertTrue(tabs().isEmpty, "nothing opens for a folder that's gone")

        PastSessionAction.perform(.resume, session: session(dir.path, id: id), controller: fx.controller)
        XCTAssertEqual(tabs().last?.focusedSession?.pendingCommand, "claude --resume \(id)")
        PastSessionAction.perform(.newSession, session: session(dir.path), controller: fx.controller)
        XCTAssertEqual(tabs().last?.focusedSession?.pendingCommand, "claude")
        PastSessionAction.perform(.terminal, session: session(dir.path), controller: fx.controller)
        XCTAssertNil(tabs().last?.focusedSession?.pendingCommand)
        XCTAssertEqual(tabs().count, 3)
    }

    func testRendersTheDrawer() throws {
        let fx = DashboardFixture(dir: try makeTemporaryDirectory())
        defer { fx.close() }
        fx.native()
        let host = render(PastSessionsDrawer(controller: fx.controller, live: ClaudeDashboard.entries()), size: CGSize(width: 340, height: 700))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testCardsForMissingPlainAndUncheckedFolders() async throws {
        let base = try makeTemporaryDirectory()
        let plain = base.appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let missing = base.appendingPathComponent("missing-\(UUID().uuidString)").path
        await DirectoryWorktreeStatus.shared.refresh(plain.path)
        await DirectoryWorktreeStatus.shared.refresh(missing)
        XCTAssertEqual(DirectoryWorktreeStatus.shared.state(for: plain.path), .notRepository)
        XCTAssertEqual(DirectoryWorktreeStatus.shared.state(for: missing), .missing)

        let fx = DashboardFixture(dir: base)
        defer { fx.close() }
        fx.native()
        let live = try XCTUnwrap(ClaudeDashboard.entries().first)
        let p = ClaudePalette.current
        var performed: [String] = []
        let unchecked = base.appendingPathComponent("unchecked-\(UUID().uuidString)").path
        for dir in [plain.path, missing, unchecked] {
            for hovering in [false, true] {
                for entry in [nil, live] {
                    for prompt in [nil, "Prompt"] as [String?] {
                        let card = PastSessionCard(session: session(dir, prompt: prompt, branch: prompt == nil ? nil : "main"), liveEntry: entry,
                                                   palette: p, perform: { performed.append("\($0)") }, hovering: hovering)
                        let host = render(card, size: CGSize(width: 320, height: 160))
                        XCTAssertGreaterThan(host.fittingSize.height, 0)
                    }
                }
            }
        }
        XCTAssertTrue(performed.isEmpty)
        XCTAssertEqual(PastSessionCard.homeRelative(NSHomeDirectory() + "/code"), "~/code")
        XCTAssertEqual(PastSessionCard.homeRelative("/opt/x"), "/opt/x")
    }
}
