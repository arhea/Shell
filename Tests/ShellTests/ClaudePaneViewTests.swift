import AppKit
import SwiftUI
import XCTest
@testable import Shell

private typealias F = ClaudeViewFixtures

/// Callbacks a pane reports, counted.
@MainActor
private final class PaneEvents {
    var closed = 0, continued = 0, explorer = 0, focused = 0
}

@MainActor
private func pane(_ claude: ClaudeCodeSession, _ composer: ClaudeComposerModel = ClaudeComposerModel(), events: PaneEvents = PaneEvents()) -> ClaudePaneView {
    ClaudePaneView(claude: claude, composer: composer, onClose: { events.closed += 1 }, onContinueInTerminal: { events.continued += 1 },
                   onToggleExplorer: { events.explorer += 1 }, onFocus: { events.focused += 1 })
}

/// A session that has a transcript with one of everything.
@MainActor
private func busySession() -> ClaudeCodeSession {
    let claude = F.session()
    F.systemInit(claude, skills: ["deploy"], agents: ["reviewer"], mcp: [("github", "connected"), ("linear", "needs-auth")], slash: ["deploy", "help"])
    F.assistantText(claude, "Here's the **plan** with `code` and /deploy", usage: ["input_tokens": 1200, "cache_read_input_tokens": 3400], model: "claude-opus-5-5")
    F.thinking(claude, "Considering the options", finished: true)
    F.tool(claude, id: "t-bash", name: "Bash", input: ["command": "swift build"])
    F.toolResult(claude, id: "t-bash", content: "Build complete")
    F.tool(claude, id: "t-edit", name: "Edit", input: ["file_path": "/tmp/a.swift", "old_string": "a\n", "new_string": "b\n"])
    F.toolResult(claude, id: "t-edit", content: "ok")
    F.tool(claude, id: "t-write", name: "Write", input: ["file_path": "/tmp/new.swift", "content": "let x = 1\nlet y = 2"])
    F.tool(claude, id: "t-todo", name: "TodoWrite", input: ["todos": [["content": "Write tests", "activeForm": "Writing tests", "status": "in_progress"],
                                                                     ["content": "Ship", "activeForm": "", "status": "pending"],
                                                                     ["content": "Plan", "activeForm": "", "status": "completed"]]])
    let question = F.questionInput([("Which DB?", "Storage", [("Postgres", "SQL", nil), ("Redis", "", nil)], false)])
    F.tool(claude, id: "t-ask", name: "AskUserQuestion", input: question)
    F.toolResult(claude, id: "t-ask", content: "User has answered: \"Which DB?\"=\"Postgres\"")
    F.tool(claude, id: "t-plan", name: "ExitPlanMode", input: ["plan": "# Ship it\n\n- step one"])
    F.toolResult(claude, id: "t-plan", content: "approved")
    F.tool(claude, id: "t-mcp", name: "mcp__github__create_pr", input: ["title": "Add tests"])
    F.toolResult(claude, id: "t-mcp", content: "failed: 401", isError: true)
    claude.handle(["type": "system", "subtype": "compact_boundary"])
    claude.handle(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": "", "total_cost_usd": 0.42])
    claude.handle(["type": "result", "subtype": "success", "is_error": true, "result": "API Error: 529 Overloaded"])
    return claude
}

@MainActor
final class ClaudePaneViewTests: XCTestCase {
    private var savedTabBarStyle: TabBarStyle?

    /// These tests count and press the pane's own header controls, which only
    /// show with horizontal tabs (vertical tabs move them to the window toolbar).
    override func setUp() async throws {
        try await super.setUp()
        savedTabBarStyle = SettingsStore.shared.settings.tabBarStyle
        SettingsStore.shared.settings.tabBarStyle = .horizontal
    }

    override func tearDown() async throws {
        if let savedTabBarStyle { SettingsStore.shared.settings.tabBarStyle = savedTabBarStyle }
        try await super.tearDown()
    }

    func testEmptyStateShowsTheWelcomeAndComposer() {
        let claude = F.session()
        XCTAssertFalse(claude.hasStarted)
        let composer = ClaudeComposerModel()
        for width in [ChatComposerWidth.centered, .full] {
            withSettings({ $0.chatComposerWidth = width; $0.chatMaxWidth = width == .full ? 0 : 700 }) {
                let host = render(pane(claude, composer), size: CGSize(width: 1000, height: 800))
                XCTAssertGreaterThan(host.fittingSize.height, 100)
            }
        }
        XCTAssertNotNil(composer.textView, "the composer's text view is created")
    }

    func testTranscriptShowsEveryKindOfItemInEveryToolCallMode() {
        let claude = busySession()
        XCTAssertTrue(claude.hasStarted)
        XCTAssertEqual(claude.items.last?.kind, .error)
        XCTAssertEqual(claude.totalCost, 0.42)
        for mode in ToolCallDisplay.allCases {
            withSettings({ $0.claudeToolCalls = mode }) {
                render(pane(claude), size: CGSize(width: 900, height: 2400))
            }
        }
        // A thinking block still streaming, and a fresh session with no items yet but docked.
        F.thinking(claude, "Still thinking", finished: false)
        render(pane(claude), size: CGSize(width: 900, height: 2400))
        let resumed = F.session(arguments: ClaudeArguments(model: "default", effort: "", permissionMode: "default", passthrough: ["-c"]))
        XCTAssertTrue(resumed.hasStarted, "continuing a conversation docks the composer")
        render(pane(resumed), size: CGSize(width: 900, height: 700))
    }

    func testTrustGateShowsBeforeStartingInAnUntrustedFolder() throws {
        let dir = try makeTemporaryDirectory()
        for docked in [false, true] {
            let args = ClaudeArguments(model: "default", effort: "", permissionMode: "default", passthrough: docked ? ["-c"] : [])
            let claude = F.session(directory: dir.path, arguments: args)
            claude.start()
            try XCTSkipUnless(claude.needsTrust, "this folder is trusted in ~/.claude.json")
            XCTAssertTrue(claude.hasExited)
            XCTAssertFalse(claude.canSend)
            let events = PaneEvents()
            let w = claudeWindow(pane(claude, events: events), width: 900, height: 700)
            XCTAssertGreaterThan(w.controls().count, 3)
            render(ClaudeHeader(claude: claude, palette: F.palette, onClose: {}, onContinueInTerminal: {}, onToggleExplorer: {}))
        }
    }

    func testSignInGateShowsWhenSignedOut() {
        let fresh = F.session()
        F.signOut(fresh)
        XCTAssertEqual(fresh.login?.expired, false)
        render(pane(fresh), size: CGSize(width: 900, height: 800))

        let expired = F.session()
        F.assistantText(expired, "Hi")
        expired.handle(["type": "result", "subtype": "success", "is_error": false, "result": "Hi"])
        F.signOut(expired)
        XCTAssertEqual(expired.login?.expired, true, "a session that worked before has an expired sign-in")
        render(pane(expired), size: CGSize(width: 900, height: 800))
    }

    func testComposerBoxStatesAndPermissionModeBorders() throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        let png = dir.appendingPathComponent("shot.png")
        try F.writePNG(to: png)
        let claude = F.session(arguments: ClaudeArguments(model: "default", effort: "", permissionMode: "default",
                                                          passthrough: ["--dangerously-skip-permissions"]))
        claude.draftAttachments = [try XCTUnwrap(ClaudeAttachment.load(file)), try XCTUnwrap(ClaudeAttachment.load(png))]
        let composer = ClaudeComposerModel()
        composer.dropTargeted = true
        composer.suggestions = [.init(kind: .command, title: "/help", insert: "/help ", detail: "Help", badge: nil)]
        for mode in ClaudePermissionMode.allCases {
            claude.setPermissionMode(mode)
            XCTAssertEqual(claude.permissionMode, mode)
            render(pane(claude, composer), size: CGSize(width: 900, height: 700))
        }
        composer.dropTargeted = false
        composer.isEmpty = false
        render(pane(claude, composer), size: CGSize(width: 900, height: 700))
    }

    func testRemovingADraftAttachmentFromTheStrip() throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        let claude = F.session()
        claude.draftAttachments = [try XCTUnwrap(ClaudeAttachment.load(file))]
        let w = claudeWindow(pane(claude), width: 900, height: 600)
        // The remove button's key-view stand-in sits at the very top (it's an
        // offset overlay), ahead of the header's buttons.
        let controls = w.controls()
        XCTAssertEqual(controls.count, 5, "remove, the header's MCP button, +, @ Context, / Skills")
        w.press(0)
        XCTAssertTrue(claude.draftAttachments.isEmpty)
    }

    // MARK: Prompts in the pane

    /// Presses the `n`th control below the header (the prompt card's buttons
    /// come first, before the composer's).
    private func pressBelowHeader(_ w: ClaudeViewWindow<ClaudePaneView>, _ n: Int) throws {
        let controls = w.controls()
        let below = controls.filter { $0.frame.minY > 80 }
        XCTAssertGreaterThan(below.count, n)
        let index = try XCTUnwrap(controls.firstIndex { $0 === below[n] })
        w.press(index)
    }

    func testPermissionCardAllowsAndDenies() throws {
        let claude = F.session()
        F.permission(claude, id: "a", tool: "Bash", input: ["command": "ls"], description: "List files")
        let w = claudeWindow(pane(claude), width: 900, height: 700)
        try pressBelowHeader(w, 0) // Allow
        XCTAssertTrue(claude.pending.isEmpty)

        F.permission(claude, id: "b", tool: "Bash", input: ["command": "rm -rf build"])
        w.layout(settle: 0.05)
        try pressBelowHeader(w, 1) // Deny
        XCTAssertTrue(claude.pending.isEmpty)
    }

    func testPlanCardApprovesOrKeepsPlanning() throws {
        let claude = F.session()
        F.permission(claude, id: "p1", tool: "ExitPlanMode", input: ["plan": "# Plan\n\nDo it"])
        let w = claudeWindow(pane(claude), width: 1000, height: 800)
        try pressBelowHeader(w, 0)
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertEqual(claude.permissionMode, .acceptEdits)

        F.permission(claude, id: "p2", tool: "ExitPlanMode", input: ["plan": "Again"])
        w.layout(settle: 0.05)
        try pressBelowHeader(w, 2) // Keep planning
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertEqual(claude.permissionMode, .acceptEdits, "keeping the plan doesn't change the mode")
    }

    func testQuestionCardAnswersOrSkips() throws {
        let claude = F.session()
        F.tool(claude, id: "t-ask", name: "AskUserQuestion", input: F.questionInput([("Which?", "", [("A", "", nil), ("B", "", nil)], false)]))
        F.permission(claude, id: "q1", tool: "AskUserQuestion", input: F.questionInput([("Which?", "", [("A", "", nil), ("B", "", nil)], false)]),
                     toolUseID: "t-ask")
        let w = claudeWindow(pane(claude), width: 900, height: 1200)
        // Below the header: A, B, Skip (Submit is disabled), then the composer's +, @ Context and / Skills.
        XCTAssertEqual(w.controls().filter { $0.frame.minY > 80 }.count, 6)
        try pressBelowHeader(w, 1) // B
        try pressBelowHeader(w, 2) // Submit, now enabled, before Skip
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertEqual(claude.items.first { $0.toolName == "AskUserQuestion" }?.answers, ["Which?": "B"])

        F.permission(claude, id: "q2", tool: "AskUserQuestion", input: F.questionInput([("Again?", "", [("A", "", nil)], false)]))
        w.layout(settle: 0.05)
        let now = w.controls().filter { $0.frame.minY > 80 }
        try pressBelowHeader(w, now.count - 4) // Skip, before the composer's three buttons
        XCTAssertTrue(claude.pending.isEmpty)
    }
}

@MainActor
final class ClaudeHeaderTests: XCTestCase {
    private func header(_ claude: ClaudeCodeSession) -> ClaudeHeader {
        ClaudeHeader(claude: claude, palette: F.palette, onClose: {}, onContinueInTerminal: {}, onToggleExplorer: {})
    }

    func testStateBadgeForEachSessionState() throws {
        let starting = F.session()
        XCTAssertTrue(starting.isStarting)
        render(header(starting))

        let ready = F.session()
        F.systemInit(ready)
        XCTAssertFalse(ready.isStarting)
        render(header(ready))

        let waiting = F.session()
        F.permission(waiting, tool: "Bash", input: ["command": "ls"])
        render(header(waiting))

        let signedOut = F.session()
        F.signOut(signedOut)
        render(header(signedOut))

        let ended = F.session(directory: try makeTemporaryDirectory().path)
        ended.start()
        try XCTSkipUnless(ended.hasExited, "this folder is trusted in ~/.claude.json")
        render(header(ended))
    }

    func testVerticalTabsLeaveTheHeaderToTheWindowToolbar() {
        let claude = F.session()
        withSettings({ $0.tabBarStyle = .horizontal }) {
            XCTAssertGreaterThan(render(header(claude), size: CGSize(width: 900, height: 60)).fittingSize.height, 30)
        }
        withSettings({ $0.tabBarStyle = .vertical }) {
            XCTAssertEqual(render(header(claude), size: CGSize(width: 900, height: 60)).fittingSize.height, 0)
        }
    }

    func testToolbarControlsForModelEffortModeAndMCP() {
        withSettings({ _ in }) {
            let claude = F.session(arguments: ClaudeArguments(model: "claude-sonnet-5", effort: "", permissionMode: "default",
                                                              passthrough: ["--allow-dangerously-skip-permissions"]))
            XCTAssertEqual(claude.modelTitle, "Sonnet 5")
            XCTAssertTrue(claude.availableModes.contains(.bypassPermissions))
            func controls() -> ClaudeToolbarControls<EmptyView> {
                ClaudeToolbarControls(claude: claude, inspectorOn: false, onToggleInspector: {}, onClose: {}, onContinueInTerminal: {}) { EmptyView() }
            }
            XCTAssertGreaterThan(render(controls(), size: CGSize(width: 700, height: 30)).fittingSize.width, 100)
            claude.setEffort("xhigh")
            XCTAssertEqual(claude.effort, "xhigh")
            XCTAssertEqual(ClaudeToolbarControls<EmptyView>.effortTitle("xhigh"), "Extra high")
            XCTAssertEqual(ClaudeToolbarControls<EmptyView>.effortTitle("high"), "High")
            claude.setModel("default")
            XCTAssertEqual(claude.modelTitle, "Default")
            render(controls(), size: CGSize(width: 700, height: 30))
            F.systemInit(claude, mcp: [("github", "connected"), ("linear", "needs-auth")])
            XCTAssertEqual(claude.mcpNeedsAuth.map(\.name), ["linear"])
            render(controls(), size: CGSize(width: 700, height: 30))
        }
    }

    func testInspectorToggleCallsBack() throws {
        var toggled = 0
        let claude = F.session()
        let w = claudeWindow(ClaudeToolbarControls(claude: claude, inspectorOn: true, onToggleInspector: { toggled += 1 },
                                                   onClose: {}, onContinueInTerminal: {}) { EmptyView() }, width: 700)
        // The inspector toggle is the rightmost control (never press a menu: it would open and block).
        let controls = w.controls()
        let index = try XCTUnwrap(controls.indices.max { controls[$0].frame.maxX < controls[$1].frame.maxX })
        w.press(index)
        XCTAssertEqual(toggled, 1)
    }

    func testHeaderButtonStyleRenders() {
        render(Button("x") {}.buttonStyle(HeaderButtonStyle(palette: F.palette, active: true)))
    }
}

@MainActor
final class ClaudeRemoteControlTests: XCTestCase {
    func testButtonAndPopoverInEveryState() {
        let claude = F.session()
        render(RemoteControlButton(claude: claude, palette: F.palette))
        render(RemoteControlPopover(claude: claude, palette: F.palette))

        claude.setRemoteControl(true)
        XCTAssertTrue(claude.remoteControlBusy)
        render(RemoteControlButton(claude: claude, palette: F.palette))
        render(RemoteControlPopover(claude: claude, palette: F.palette))

        F.controlResponse(claude, id: "shell-1", response: ["session_url": "https://claude.ai/code/session_123"])
        XCTAssertEqual(claude.remoteControlURL?.absoluteString, "https://claude.ai/code/session_123")
        XCTAssertFalse(claude.remoteControlBusy)
        render(RemoteControlButton(claude: claude, palette: F.palette))
        let host = render(RemoteControlPopover(claude: claude, palette: F.palette))
        XCTAssertGreaterThan(host.fittingSize.height, 150, "the QR code shows")

        claude.setRemoteControl(false)
        F.controlResponse(claude, id: "shell-2", error: "Remote Control isn't available for this account")
        XCTAssertEqual(claude.remoteControlError, "Remote Control isn't available for this account")
        render(RemoteControlPopover(claude: claude, palette: F.palette))
    }

    func testPopoverTogglesRemoteControlAndTheDefault() throws {
        let claude = F.session()
        try withSettings({ $0.claudeRemoteControl = false }) {
            let w = claudeWindow(RemoteControlPopover(claude: claude, palette: F.palette), width: 380)
            // The Remote Control switch, then "Turn on for every session".
            let toggles = w.toggles()
            XCTAssertEqual(toggles.count, 2)
            w.flip(try XCTUnwrap(toggles.first))
            XCTAssertTrue(claude.remoteControlBusy, "turning it on asks Claude Code")
            w.flip(try XCTUnwrap(toggles.last))
            XCTAssertTrue(SettingsStore.shared.settings.claudeRemoteControl)
        }
    }

    func testQRCodeImageIsTheRequestedSize() throws {
        let image = try XCTUnwrap(QRCode.image(for: "https://claude.ai/code/abc", size: 132))
        XCTAssertEqual(image.size.width, 132, accuracy: 1)
        XCTAssertEqual(image.size.height, 132, accuracy: 1)
    }
}

@MainActor
final class ClaudeStatusLineTests: XCTestCase {
    func testModeColorsAndCompactNumbers() {
        let p = F.palette
        XCTAssertEqual(ClaudeStatusLine.modeColor(.default, p), p.dim)
        XCTAssertEqual(ClaudeStatusLine.modeColor(.acceptEdits, p), p.magenta)
        XCTAssertEqual(ClaudeStatusLine.modeColor(.plan, p), p.cyan)
        XCTAssertEqual(ClaudeStatusLine.modeColor(.auto, p), p.yellow)
        XCTAssertEqual(ClaudeStatusLine.modeColor(.dontAsk, p), p.dim)
        XCTAssertEqual(ClaudeStatusLine.modeColor(.bypassPermissions, p), p.red)
        XCTAssertEqual(ClaudeStatusLine.compact(999), "999")
        XCTAssertEqual(ClaudeStatusLine.compact(1000), "1.0k")
        XCTAssertEqual(ClaudeStatusLine.compact(45_600), "45.6k")
    }

    func testRendersEveryModeWithContextCostAndModel() {
        let claude = F.session()
        render(ClaudeStatusLine(claude: claude, palette: F.palette), size: CGSize(width: 700, height: 30))
        F.assistantText(claude, "hi", usage: ["input_tokens": 10, "cache_creation_input_tokens": 2000], model: "claude-fable-5-1")
        claude.handle(["type": "result", "subtype": "success", "is_error": false, "result": "hi", "total_cost_usd": 1.25])
        XCTAssertEqual(claude.contextTokens, 2010)
        XCTAssertEqual(claude.resolvedModel, "claude-fable-5-1")
        for mode in ClaudePermissionMode.allCases {
            claude.setPermissionMode(mode)
            render(ClaudeStatusLine(claude: claude, palette: F.palette), size: CGSize(width: 700, height: 30))
        }
    }

    func testClickingTheModeCyclesIt() {
        let claude = F.session()
        let w = claudeWindow(ClaudeStatusLine(claude: claude, palette: F.palette), width: 700)
        w.press(0)
        XCTAssertEqual(claude.permissionMode, .acceptEdits)
        w.press(0)
        XCTAssertEqual(claude.permissionMode, .plan)
    }
}

@MainActor
final class ClaudeGateTests: XCTestCase {
    func testWelcomeRenders() {
        XCTAssertGreaterThan(render(ClaudeWelcome(claude: F.session(), palette: F.palette)).fittingSize.height, 30)
    }

    func testTrustGateButtons() {
        var trusted = 0, opened = 0, closed = 0
        let w = claudeWindow(TrustGate(directory: NSHomeDirectory() + "/code/app", palette: F.palette, onTrust: { trusted += 1 },
                                       onOpenTerminal: { opened += 1 }, onClose: { closed += 1 }), width: 700)
        w.pressAll()
        XCTAssertEqual([trusted, opened, closed], [1, 1, 1])
    }

    private func login(binary: String = "/nonexistent/claude", expired: Bool = false) -> ClaudeLogin {
        ClaudeLogin(binary: binary, environment: [:], directory: NSTemporaryDirectory(), expired: expired)
    }

    func testLoginGateChoosingTogglesSSOAndCloses() throws {
        let login = login()
        var closed = 0
        let w = claudeWindow(LoginGate(login: login, palette: F.palette, onClose: { closed += 1 }), width: 600)
        // Two account types, the SSO checkbox, Close.
        XCTAssertEqual(w.controls().count, 4)
        w.flip(try XCTUnwrap(w.toggles().first))
        XCTAssertTrue(login.useSSO)
        // Close is the rightmost control.
        let controls = w.controls()
        w.press(try XCTUnwrap(controls.indices.max { controls[$0].frame.maxX < controls[$1].frame.maxX }))
        XCTAssertEqual(closed, 1)
    }

    func testLoginGateShowsWhySignInFailed() {
        let login = login(expired: true)
        let w = claudeWindow(LoginGate(login: login, palette: F.palette, onClose: {}), width: 600)
        w.press(0) // Claude account: the binary doesn't exist
        guard case .failed(let message) = login.phase else { return XCTFail("expected a failure, got \(login.phase)") }
        XCTAssertTrue(message.contains("/nonexistent/claude"))
        w.layout(settle: 0.05)
        XCTAssertGreaterThan(w.host.fittingSize.height, 150)
    }

    func testLoginGateSignsInWithAPastedCode() throws {
        let dir = try makeTemporaryDirectory()
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then echo '{"loggedIn": true}'; exit 0; fi
        echo "Opening https://claude.ai/oauth/authorize?code=test in your browser"
        echo "Paste code here if prompted >"
        read code
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let login = login(binary: script.path)
        var signedIn = false
        login.onSignedIn = { signedIn = true }
        login.begin(.claudeAI)
        XCTAssertEqual(login.phase, .signingIn)
        XCTAssertTrue(waitUntil(timeout: 5) { login.url != nil }, "the sign-in page is read from the output")
        let w = claudeWindow(LoginGate(login: login, palette: F.palette, onClose: {}), width: 600)
        let field = try XCTUnwrap(w.subview(NSTextField.self))
        w.type("abc123", into: field)
        // Submit, Open Sign-in Page, Cancel: Submit is first once a code is typed.
        w.press(0)
        XCTAssertTrue(waitUntil(timeout: 5) { signedIn }, "the code goes to claude auth login, then the status check passes")
        XCTAssertEqual(login.phase, .verifying)
        w.layout(settle: 0.05)
        XCTAssertGreaterThan(w.host.fittingSize.height, 80)
    }

    func testLoginGateCancelsSigningIn() throws {
        let dir = try makeTemporaryDirectory()
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/sh\nread code\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let login = login(binary: script.path)
        login.begin(.console)
        let w = claudeWindow(LoginGate(login: login, palette: F.palette, onClose: {}), width: 600)
        let controls = w.controls()
        XCTAssertGreaterThanOrEqual(controls.count, 1)
        w.press(controls.count - 1) // Cancel
        XCTAssertEqual(login.phase, .failed("Sign-in was cancelled."))
    }

    func testActivityLineShowsWorkOrWaiting() {
        let claude = F.session()
        XCTAssertLessThan(render(ClaudeActivityLine(claude: claude, palette: F.palette)).fittingSize.height, 5, "nothing between turns")
        claude.handle(["type": "system", "subtype": "status", "status": "compacting"])
        F.tool(claude, id: "t", name: "Read", input: ["file_path": "/tmp/a.swift"])
        let w = claudeWindow(ClaudeActivityLine(claude: claude, palette: F.palette), width: 600)
        _ = w
        F.permission(claude, id: "r", tool: "Bash", input: ["command": "ls"])
        XCTAssertGreaterThan(render(ClaudeActivityLine(claude: claude, palette: F.palette), size: CGSize(width: 600, height: 30)).fittingSize.height, 10)
    }
}

@MainActor
final class ClaudeItemViewTests: XCTestCase {
    private let p = F.palette
    private let mentions = InlineMarkdown.MentionStyle(skills: ["deploy"], commands: ["deploy"], mcpServers: ["github"], agents: ["reviewer"])

    private func itemView(_ item: ClaudeItem) -> ClaudeItemView {
        ClaudeItemView(item: item, palette: p, mentions: mentions, fontSize: 13, directory: "/tmp")
    }

    func testEveryKindRenders() throws {
        let dir = try makeTemporaryDirectory()
        let png = dir.appendingPathComponent("shot.png")
        try F.writePNG(to: png)
        let user = F.item(.user, text: "Fix /deploy for @github")
        user.attachments = [try XCTUnwrap(ClaudeAttachment.load(png))]
        let attachmentsOnly = F.item(.user)
        attachmentsOnly.attachments = user.attachments
        let items = [
            user, attachmentsOnly,
            F.item(.assistant, text: "Done. See `main.swift`."),
            F.item(.thinking, text: "Hmm", isRunning: true),
            F.item(.thinking, text: "Done thinking"),
            F.item(.tool, tool: "Bash", input: ["command": "ls"], result: "a\nb"),
            F.item(.tool, tool: "AskUserQuestion", input: F.questionInput([("Q?", "", [("A", "", nil)], false)])),
            F.item(.tool, tool: "ExitPlanMode", input: ["plan": "# Plan"]),
            F.item(.tool, tool: "TodoWrite", input: ["todos": [["content": "a", "status": "pending"]]]),
            F.item(.notice, text: "Conversation compacted"),
            F.item(.error, text: "Claude Code exited with status 1."),
        ]
        for item in items {
            let host = render(itemView(item), size: CGSize(width: 700, height: 400))
            XCTAssertGreaterThan(host.fittingSize.height, 5, "\(item.kind)")
        }
    }

    func testEqualityComparesTheItemAndInputs() {
        let item = F.item(.assistant, text: "x")
        XCTAssertTrue(itemView(item) == itemView(item))
        XCTAssertFalse(itemView(item) == itemView(F.item(.assistant, text: "x")), "a different item")
        XCTAssertFalse(itemView(item) == ClaudeItemView(item: item, palette: p, mentions: mentions, fontSize: 14, directory: "/tmp"))
        XCTAssertFalse(itemView(item) == ClaudeItemView(item: item, palette: p, mentions: mentions, fontSize: 13, directory: nil))
    }

    func testThinkingExpandsWhenClicked() {
        let item = F.item(.thinking, text: String(repeating: "A long thought. ", count: 40))
        let w = claudeWindow(ThinkingView(item: item, palette: p, fontSize: 13), width: 500)
        let collapsed = w.host.fittingSize.height
        w.press(0)
        XCTAssertGreaterThan(w.host.fittingSize.height, collapsed)
    }

    func testToolCallStates() {
        let cases = [
            F.item(.tool, tool: "Read", input: ["file_path": "/tmp/a.swift"], isRunning: true),
            F.item(.tool, tool: "Bash", input: ["command": "make"], result: "error: one\nerror: two\nerror: three\nfour", isError: true),
            F.item(.tool, tool: "Edit", input: ["file_path": "/tmp/a.swift", "old_string": "a", "new_string": "b"], result: "ok"),
            F.item(.tool, tool: "Write", input: ["file_path": "/tmp/b.swift", "content": "x"]),
            F.item(.tool, tool: "mcp__github__get_pr", input: ["number": "1"], result: ""),
        ]
        for item in cases {
            render(ToolCallView(item: item, palette: p, fontSize: 13), size: CGSize(width: 700, height: 300))
        }
    }

    func testToolCallExpandsToShowItsResult() {
        let long = (1...3000).map { "line \($0) of output" }.joined(separator: "\n")
        let write = (1...30).map { "let v\($0) = \($0)" }.joined(separator: "\n")
        // Bash: "Show all 3000 lines"; Write: "Show all 30 lines" (after Copy and Review);
        // any other tool: its step row opens to the result.
        for (item, control) in [
            (F.item(.tool, tool: "Bash", input: ["command": "cat big.log"], result: long + "<system-reminder>hidden</system-reminder>"), 0),
            (F.item(.tool, tool: "Write", input: ["file_path": "/tmp/c.swift", "content": write]), 2),
            (F.item(.tool, tool: "Grep", input: ["pattern": "x"], result: "a.swift\nb.swift"), 0),
        ] {
            let w = claudeWindow(ToolCallView(item: item, palette: p, fontSize: 13), width: 700)
            let collapsed = w.host.fittingSize.height
            w.press(control)
            XCTAssertGreaterThan(w.host.fittingSize.height, collapsed, item.toolName)
        }
    }

    func testQuestionSummaryShowsAnswersOrWhatHappened() {
        let one = F.questionInput([("Which DB?", "Storage", [("Postgres", "", nil)], false)])
        let two = F.questionInput([("First?", "", [("A", "", nil)], false), ("Second?", "H", [("B", "", nil)], true)])
        let answered = F.item(.tool, tool: "AskUserQuestion", input: one)
        answered.answers = ["Which DB?": "Postgres"]
        let fallback = F.item(.tool, tool: "AskUserQuestion", input: one)
        fallback.answers = ["question text differs": "Redis"]
        let partial = F.item(.tool, tool: "AskUserQuestion", input: two)
        partial.answers = ["First?": "A"]
        for item in [answered, fallback, partial,
                     F.item(.tool, tool: "AskUserQuestion", input: one, isRunning: true),
                     F.item(.tool, tool: "AskUserQuestion", input: one, isError: true),
                     F.item(.tool, tool: "AskUserQuestion", input: one),
                     F.item(.tool, tool: "AskUserQuestion")] {
            render(QuestionSummaryView(item: item, palette: p, fontSize: 13, directory: "/tmp"), size: CGSize(width: 600, height: 300))
        }
    }

    func testPlanSummaryStatusesAndCollapse() {
        let plan = ["plan": "# Ship\n\n1. Test\n2. Release"]
        for item in [F.item(.tool, tool: "ExitPlanMode", input: plan, isRunning: true),
                     F.item(.tool, tool: "ExitPlanMode", input: plan, isError: true),
                     F.item(.tool, tool: "ExitPlanMode", input: plan, result: "ok"),
                     F.item(.tool, tool: "ExitPlanMode", input: plan),
                     F.item(.tool, tool: "ExitPlanMode")] {
            render(PlanSummaryView(item: item, palette: p, fontSize: 13, directory: "/tmp"), size: CGSize(width: 600, height: 400))
        }
        let w = claudeWindow(PlanSummaryView(item: F.item(.tool, tool: "ExitPlanMode", input: plan, result: "ok"), palette: p, fontSize: 13), width: 600)
        let expanded = w.host.fittingSize.height
        w.press(0)
        XCTAssertLessThan(w.host.fittingSize.height, expanded, "collapses")
    }

    func testTodoListShowsProgress() {
        let todos = ["todos": [["content": "Write tests", "activeForm": "Writing tests", "status": "in_progress"],
                               ["content": "Review", "activeForm": "", "status": "in_progress"],
                               ["content": "Ship", "status": "pending"],
                               ["content": "Plan", "status": "completed"],
                               ["content": "Unknown", "status": "weird"]]]
        let host = render(TodoListView(item: F.item(.tool, tool: "TodoWrite", input: todos), palette: p, fontSize: 13), size: CGSize(width: 600, height: 300))
        XCTAssertGreaterThan(host.fittingSize.height, 60)
        render(TodoListView(item: F.item(.tool, tool: "TodoWrite"), palette: p, fontSize: 13), size: CGSize(width: 600, height: 100))
    }

    func testOptionalBoolIsTrue() {
        XCTAssertTrue(Optional(true).isTrue)
        XCTAssertFalse(Optional(false).isTrue)
        XCTAssertFalse(Bool?.none.isTrue)
    }
}
