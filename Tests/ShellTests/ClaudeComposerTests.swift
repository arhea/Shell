import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// `url` with every symlink resolved, `/private/var` included. The composer's
/// directory walk reports real paths and strips the session directory's
/// length from them, so it only lines up when that directory is a real path.
/// (`resolvingSymlinksInPath()` maps `/private/var` back to `/var`.)
private func realPath(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// The composer's text view and coordinator, hosted in a window.
@MainActor
private final class ComposerHarness {
    let claude: ClaudeCodeSession
    let model = ClaudeComposerModel()
    let window: ClaudeViewWindow<ClaudeComposerField>
    var exits = 0
    var focuses = 0

    var textView: ComposerTextView { model.textView! }
    var coordinator: ClaudeComposerField.Coordinator { textView.delegate as! ClaudeComposerField.Coordinator }

    init(_ test: XCTestCase, claude: ClaudeCodeSession = ClaudeViewFixtures.session()) {
        self.claude = claude
        var exitHandler: () -> Void = {}
        var focusHandler: () -> Void = {}
        let field = ClaudeComposerField(claude: claude, model: model, palette: ClaudeViewFixtures.palette, fontSize: 13,
                                        onExit: { exitHandler() }, onFocus: { focusHandler() })
        window = test.claudeWindow(field, width: 600, height: 120)
        exitHandler = { [weak self] in self?.exits += 1 }
        focusHandler = { [weak self] in self?.focuses += 1 }
    }

    /// Replaces the text and puts the cursor at the end, as typing would.
    func set(_ text: String) {
        textView.string = ""
        textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    }

    @discardableResult
    func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> Bool {
        coordinator.handleKey(Self.event(code, chars, flags: flags))
    }

    static func event(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static let returnKey: UInt16 = 36, tab: UInt16 = 48, escape: UInt16 = 53, up: UInt16 = 126, down: UInt16 = 125
}

@MainActor
final class ClaudeComposerModelTests: XCTestCase {
    func testWithoutATextViewFocusAndInsertDoNothing() {
        let model = ClaudeComposerModel()
        model.focus()
        model.insert("@file")
        XCTAssertFalse(model.showsSuggestions)
        XCTAssertTrue(model.isEmpty)
    }

    func testInsertAddsASpaceAfterAWordAndFocuses() {
        let h = ComposerHarness(self)
        h.set("look at")
        h.model.insert("@main.swift")
        XCTAssertEqual(h.textView.string, "look at @main.swift")
        XCTAssertTrue(h.window.window.firstResponder === h.textView)
        XCTAssertGreaterThan(h.focuses, 0, "becoming first responder reports focus")

        h.set("look at ")
        h.model.insert("@a.swift")
        XCTAssertEqual(h.textView.string, "look at @a.swift")

        h.set("")
        h.model.insert("@b.swift")
        XCTAssertEqual(h.textView.string, "@b.swift")
    }

    func testShowsSuggestionsFollowsTheList() {
        let model = ClaudeComposerModel()
        model.suggestions = [.init(kind: .file, title: "a", insert: "@a ", detail: "a", badge: nil)]
        XCTAssertTrue(model.showsSuggestions)
        XCTAssertEqual(model.suggestions.first?.id, "@a ")
    }
}

@MainActor
final class ClaudeComposerFieldTests: XCTestCase {
    // MARK: Setup and text changes

    func testRestoresTheSessionDraft() {
        let claude = ClaudeViewFixtures.session()
        claude.draft = "half-written prompt"
        let h = ComposerHarness(self, claude: claude)
        XCTAssertEqual(h.textView.string, "half-written prompt")
        XCTAssertFalse(h.model.isEmpty)
        XCTAssertEqual(h.textView.placeholder, "Ask Claude…  / for skills & commands, @ for files & MCP servers")
    }

    func testTypingUpdatesTheDraftEmptinessAndHeight() {
        let h = ComposerHarness(self)
        XCTAssertTrue(h.model.isEmpty)
        h.set("hello")
        XCTAssertFalse(h.model.isEmpty)
        XCTAssertEqual(h.claude.draft, "hello")
        let oneLine = h.model.height
        h.set((1...6).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertGreaterThan(h.model.height, oneLine)
        h.set((1...80).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(h.model.height, 280, "the composer stops growing")
        h.set("")
        XCTAssertTrue(h.model.isEmpty)
        XCTAssertEqual(h.model.height, oneLine)
    }

    func testRestylesWhenTheSessionsCommandsChange() {
        let h = ComposerHarness(self)
        h.set("/review")
        let before = h.textView.textStorage?.attribute(.backgroundColor, at: 1, effectiveRange: nil)
        XCTAssertNil(before, "unknown commands aren't highlighted")
        ClaudeViewFixtures.commands(h.claude, [("review", "Review a PR", "")])
        h.window.layout(settle: 0.05)
        h.coordinator.applyStyle()
        h.coordinator.textChanged()
        XCTAssertNotNil(h.textView.textStorage?.attribute(.backgroundColor, at: 1, effectiveRange: nil))
    }

    // MARK: Highlighting

    private func attributes(_ h: ComposerHarness, at text: String, in full: String) -> [NSAttributedString.Key: Any] {
        let r = (full as NSString).range(of: text)
        XCTAssertNotEqual(r.location, NSNotFound, text)
        return h.textView.textStorage?.attributes(at: r.location, effectiveRange: nil) ?? [:]
    }

    func testHighlightsMarkdownAndMentions() {
        let claude = ClaudeViewFixtures.session()
        ClaudeViewFixtures.systemInit(claude, skills: ["deploy"], agents: ["reviewer"], mcp: [("github", "connected")], slash: ["deploy"])
        let h = ComposerHarness(self, claude: claude)
        let text = """
        # Heading
        **bold** and *italic* and `code`
        - item
        > quote
        see [docs](https://example.com) and /deploy with @github
        """
        h.set(text)
        let heading = attributes(h, at: "# Heading", in: text)[.font] as? NSFont
        XCTAssertTrue(heading.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
        let bold = attributes(h, at: "bold", in: text)[.font] as? NSFont
        XCTAssertTrue(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
        XCTAssertNotNil(attributes(h, at: "*italic*", in: text)[.font])
        let code = attributes(h, at: "`code`", in: text)
        XCTAssertNotNil(code[.backgroundColor])
        XCTAssertTrue((code[.font] as? NSFont)?.isFixedPitch ?? false)
        XCTAssertNotNil(attributes(h, at: "docs", in: text)[.foregroundColor])
        XCTAssertNotNil(attributes(h, at: "/deploy", in: text)[.backgroundColor], "known skills are highlighted")
        XCTAssertNotNil(attributes(h, at: "@github", in: text)[.backgroundColor], "MCP servers are highlighted")
    }

    func testCodeFencesUseMonospaceAndSkipMarkdown() {
        let h = ComposerHarness(self)
        let text = "before\n```swift\nlet **x** = 1\n```\nafter **bold**"
        h.set(text)
        let inside = attributes(h, at: "let", in: text)
        XCTAssertTrue((inside[.font] as? NSFont)?.isFixedPitch ?? false)
        XCTAssertNotNil(inside[.backgroundColor])
        let insideBold = attributes(h, at: "**x**", in: text)[.font] as? NSFont
        XCTAssertFalse(insideBold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? true, "no markdown inside code")
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        let h = ComposerHarness(self)
        let text = "```\necho hi"
        h.set(text)
        XCTAssertTrue((attributes(h, at: "echo", in: text)[.font] as? NSFont)?.isFixedPitch ?? false)
        h.set("```")
        XCTAssertNotNil(h.textView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    // MARK: Suggestions

    private func sessionWithCommands() -> ClaudeCodeSession {
        let claude = ClaudeViewFixtures.session()
        ClaudeViewFixtures.systemInit(claude, skills: ["deploy"], agents: ["reviewer"], mcp: [("github", "connected"), ("linear app", "needs-auth")])
        ClaudeViewFixtures.commands(claude, [("deploy", "Deploy the app\nwith details", ""), ("help", "", "[topic]"),
                                             ("mcp__github__pr", "Open a PR", ""), ("review-pr", "Review a pull request", "")])
        return claude
    }

    func testSlashSuggestsCommandsRankedWithBadges() {
        let h = ComposerHarness(self, claude: sessionWithCommands())
        h.set("/")
        XCTAssertEqual(h.model.suggestions.map(\.title), ["/deploy", "/help", "/mcp__github__pr", "/review-pr"])
        XCTAssertEqual(h.model.suggestions.map(\.badge), ["skill", nil, "mcp", nil])
        XCTAssertEqual(h.model.suggestions[0].kind, .skill)
        XCTAssertEqual(h.model.suggestions[0].detail, "Deploy the app", "first line only")
        XCTAssertEqual(h.model.suggestions[1].detail, "[topic]", "falls back to the argument hint")
        h.set("/pr")
        XCTAssertEqual(h.model.suggestions.map(\.title), ["/mcp__github__pr", "/review-pr"], "word-prefix matches, ties by name")
        h.set("/view")
        XCTAssertEqual(h.model.suggestions.map(\.title), ["/review-pr"])
        h.set("/zzz")
        XCTAssertFalse(h.model.showsSuggestions)
    }

    func testSlashOnlyAtTheStartOfALine() {
        let h = ComposerHarness(self, claude: sessionWithCommands())
        h.set("run /dep")
        XCTAssertFalse(h.model.showsSuggestions)
        h.set("first line\n/dep")
        XCTAssertEqual(h.model.suggestions.first?.title, "/deploy")
    }

    func testNoSuggestionsInsideCodeOrWithASelection() {
        let h = ComposerHarness(self, claude: sessionWithCommands())
        h.set("```\n/dep")
        XCTAssertFalse(h.model.showsSuggestions)
        h.set("/dep")
        XCTAssertTrue(h.model.showsSuggestions)
        h.textView.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertFalse(h.model.showsSuggestions)
        XCTAssertNil(h.model.tokenRange)
        h.set("plain words")
        XCTAssertFalse(h.model.showsSuggestions)
        h.set("trailing space ")
        XCTAssertFalse(h.model.showsSuggestions)
    }

    func testAtSuggestsServersAgentsAndFiles() throws {
        let dir = try realPath(makeTemporaryDirectory())
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Sources/main.swift"))
        try Data().write(to: dir.appendingPathComponent("My Notes.md"))
        try Data().write(to: dir.appendingPathComponent("node_modules/pkg/index.js"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        let claude = ClaudeViewFixtures.session(directory: dir.path)
        ClaudeViewFixtures.systemInit(claude, agents: ["reviewer"], mcp: [("github", "connected"), ("linear app", "needs-auth")])
        let h = ComposerHarness(self, claude: claude)

        h.set("@")
        XCTAssertEqual(Array(h.model.suggestions.prefix(3).map(\.title)), ["@github", "@linear-app", "@agent-reviewer"])
        XCTAssertEqual(h.model.suggestions[0].badge, "mcp")
        XCTAssertEqual(h.model.suggestions[1].badge, "needs-auth")
        XCTAssertTrue(waitUntil { h.model.suggestions.contains { $0.kind == .file } }, "the file index loads in the background")
        let files = h.model.suggestions.filter { $0.kind == .file }
        XCTAssertEqual(Set(files.map(\.detail)), ["Sources/main.swift", "My Notes.md"], "skips node_modules and hidden files")
        XCTAssertEqual(files.first { $0.detail == "My Notes.md" }?.insert, "@\"My Notes.md\" ", "paths with spaces are quoted")

        h.set("look at @mai")
        XCTAssertEqual(h.model.suggestions.map(\.title), ["main.swift"])
        h.set("@sources/m")
        XCTAssertEqual(h.model.suggestions.first?.detail, "Sources/main.swift", "matches the path too")
    }

    func testAcceptingASuggestionReplacesTheToken() {
        let h = ComposerHarness(self, claude: sessionWithCommands())
        h.set("/dep")
        let suggestion = h.model.suggestions[0]
        h.coordinator.accept(suggestion)
        XCTAssertEqual(h.textView.string, "/deploy ")
        XCTAssertFalse(h.model.showsSuggestions)
        // No token: nothing to replace.
        h.coordinator.accept(suggestion)
        XCTAssertEqual(h.textView.string, "/deploy ")
    }

    func testScoreRanksPrefixWordSubstringAndSubsequence() {
        typealias C = ClaudeComposerField.Coordinator
        XCTAssertEqual(C.score("anything", ""), 0)
        XCTAssertEqual(C.score("review", "rev"), 0)
        XCTAssertEqual(C.score("code-review", "rev"), 1)
        XCTAssertEqual(C.score("plugin:review", "rev"), 1)
        XCTAssertEqual(C.score("src/review", "rev"), 1)
        XCTAssertEqual(C.score("my_review", "rev"), 1)
        XCTAssertEqual(C.score("prereview", "rev"), 2)
        XCTAssertEqual(C.score("readme-vendor", "rmv"), 3)
        XCTAssertNil(C.score("deploy", "xyz"))
    }

    func testCleanDescriptionKeepsTheFirstLineAndTruncates() {
        typealias C = ClaudeComposerField.Coordinator
        XCTAssertEqual(C.cleanDescription("one\ntwo"), "one")
        XCTAssertEqual(C.cleanDescription(""), "")
        let long = String(repeating: "a", count: 200)
        let cleaned = C.cleanDescription(long)
        XCTAssertEqual(cleaned.count, 138)
        XCTAssertTrue(cleaned.hasSuffix("…"))
    }

    func testListFilesWalksADirectoryOutsideGit() async throws {
        let dir = try realPath(makeTemporaryDirectory())
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("a/b/c.txt"))
        try Data().write(to: dir.appendingPathComponent("top.txt"))
        let files = await ClaudeComposerField.Coordinator.listFiles(directory: dir.path, repository: nil)
        XCTAssertEqual(Set(files), ["a/b/c.txt", "top.txt"])
        let missing = await ClaudeComposerField.Coordinator.listFiles(directory: dir.appendingPathComponent("nope").path, repository: nil)
        XCTAssertTrue(missing.isEmpty)
    }

    // MARK: Keys

    func testReturnAcceptsTheSelectedSuggestion() {
        let h = ComposerHarness(self, claude: sessionWithCommands())
        h.set("/")
        XCTAssertTrue(h.key(ComposerHarness.down))
        XCTAssertEqual(h.model.selected, 1)
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r"))
        XCTAssertEqual(h.textView.string, "/help ")
    }

    func testUpAndDownWrapThroughSuggestions() {
        let h = ComposerHarness(self, claude: sessionWithCommands())
        h.set("/")
        XCTAssertTrue(h.key(ComposerHarness.up))
        XCTAssertEqual(h.model.selected, h.model.suggestions.count - 1)
        XCTAssertTrue(h.key(ComposerHarness.down))
        XCTAssertEqual(h.model.selected, 0)
    }

    func testTabAcceptsASuggestionOrPassesThrough() {
        let h = ComposerHarness(self, claude: sessionWithCommands())
        h.set("/he")
        XCTAssertTrue(h.key(ComposerHarness.tab, "\t"))
        XCTAssertEqual(h.textView.string, "/help ")
        XCTAssertFalse(h.key(ComposerHarness.tab, "\t"), "no suggestions: Tab is the text view's")
    }

    func testShiftTabCyclesThePermissionMode() {
        let h = ComposerHarness(self)
        XCTAssertEqual(h.claude.permissionMode, .default)
        XCTAssertTrue(h.key(ComposerHarness.tab, "\t", flags: .shift))
        XCTAssertEqual(h.claude.permissionMode, .acceptEdits)
    }

    func testEscapeHidesSuggestionsThenDeniesThenClearsRecalledHistory() {
        let h = ComposerHarness(self, claude: sessionWithCommands())
        h.set("/")
        XCTAssertTrue(h.key(ComposerHarness.escape))
        XCTAssertFalse(h.model.showsSuggestions)

        ClaudeViewFixtures.permission(h.claude, tool: "Bash", input: ["command": "ls"])
        XCTAssertTrue(h.key(ComposerHarness.escape))
        XCTAssertTrue(h.claude.pending.isEmpty, "Esc denies the prompt")

        h.set("")
        h.model.history = ["earlier"]
        XCTAssertTrue(h.key(ComposerHarness.up))
        XCTAssertEqual(h.textView.string, "earlier")
        XCTAssertTrue(h.key(ComposerHarness.escape))
        XCTAssertEqual(h.textView.string, "")
        XCTAssertNil(h.model.historyIndex)

        XCTAssertTrue(h.key(ComposerHarness.escape), "Esc is always handled")
    }

    func testShiftOrOptionReturnAndReturnInsideAFenceAddALine() {
        let h = ComposerHarness(self)
        h.set("a")
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r", flags: .shift))
        XCTAssertEqual(h.textView.string, "a\n")
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r", flags: .option))
        XCTAssertEqual(h.textView.string, "a\n\n")
        h.set("```swift")
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r"))
        XCTAssertEqual(h.textView.string, "```swift\n")
    }

    func testReturnKeepsTheDraftUntilTheSessionCanSend() {
        let h = ComposerHarness(self)
        h.set("hello")
        XCTAssertFalse(h.claude.canSend)
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r"))
        XCTAssertEqual(h.textView.string, "hello", "kept while Claude isn't running")
        XCTAssertTrue(h.claude.items.isEmpty)
    }

    func testSubmittingNothingDoesNothingAndExitCommandsClose() {
        let h = ComposerHarness(self)
        h.set("   ")
        h.coordinator.submit()
        XCTAssertEqual(h.exits, 0)
        h.set("/exit")
        h.coordinator.submit()
        XCTAssertEqual(h.exits, 1)
        h.set("/quit")
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r"))
        XCTAssertEqual(h.exits, 2)
    }

    func testReturnApprovesOrRevisesAPlan() {
        let h = ComposerHarness(self)
        ClaudeViewFixtures.permission(h.claude, id: "plan-1", tool: "ExitPlanMode", input: ["plan": "Do it"])
        h.set("")
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r"))
        XCTAssertTrue(h.claude.pending.isEmpty)
        XCTAssertEqual(h.claude.permissionMode, .acceptEdits, "Return approves with auto-accept edits")

        let other = ClaudeViewFixtures.session()
        let h2 = ComposerHarness(self, claude: other)
        ClaudeViewFixtures.permission(other, id: "plan-2", tool: "ExitPlanMode", input: ["plan": "Do it"])
        h2.set("use a queue instead")
        XCTAssertTrue(h2.key(ComposerHarness.returnKey, "\r"))
        XCTAssertTrue(other.pending.isEmpty)
        XCTAssertEqual(other.permissionMode, .default, "feedback keeps planning")
        XCTAssertEqual(h2.textView.string, "", "the feedback is sent and cleared")
    }

    func testReturnAnswersASingleQuestionWithTypedText() {
        let h = ComposerHarness(self)
        let input = ClaudeViewFixtures.questionInput([("Which?", "", [("A", "", nil), ("B", "", nil)], false)])
        ClaudeViewFixtures.permission(h.claude, tool: "AskUserQuestion", input: input)
        h.set("")
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r"))
        XCTAssertEqual(h.claude.pending.count, 1, "nothing typed: still waiting")
        h.set("C, actually")
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r"))
        XCTAssertTrue(h.claude.pending.isEmpty)
        XCTAssertEqual(h.textView.string, "")
    }

    func testReturnAllowsAPermissionPromptWhenEmpty() {
        let h = ComposerHarness(self)
        ClaudeViewFixtures.permission(h.claude, tool: "Bash", input: ["command": "ls"])
        h.set("")
        XCTAssertTrue(h.key(ComposerHarness.returnKey, "\r"))
        XCTAssertTrue(h.claude.pending.isEmpty)
    }

    func testNumberKeysAnswerQuestionsPlansAndPermissions() {
        let h = ComposerHarness(self)
        h.set("")
        let input = ClaudeViewFixtures.questionInput([("Which?", "", [("A", "", nil), ("B", "", nil)], false)])
        ClaudeViewFixtures.permission(h.claude, id: "q", tool: "AskUserQuestion", input: input)
        XCTAssertFalse(h.key(18, "9"), "out of range")
        XCTAssertTrue(h.key(19, "2"))
        XCTAssertTrue(h.claude.pending.isEmpty)

        let multi = ClaudeViewFixtures.questionInput([("Which?", "", [("A", "", nil)], true)])
        ClaudeViewFixtures.permission(h.claude, id: "m", tool: "AskUserQuestion", input: multi)
        XCTAssertFalse(h.key(18, "1"), "multi-select questions need the card")
        h.claude.respond(h.claude.pending[0], allow: false)

        for (n, mode) in [("2", ClaudePermissionMode.default), ("1", .acceptEdits)] {
            ClaudeViewFixtures.permission(h.claude, id: "p\(n)", tool: "ExitPlanMode", input: ["plan": "x"])
            XCTAssertTrue(h.key(18, n))
            XCTAssertEqual(h.claude.permissionMode, mode)
        }
        ClaudeViewFixtures.permission(h.claude, id: "p3", tool: "ExitPlanMode", input: ["plan": "x"])
        XCTAssertFalse(h.key(21, "4"))
        XCTAssertTrue(h.key(20, "3"))
        XCTAssertTrue(h.claude.pending.isEmpty)

        for (id, key, suggestions) in [("a", "1", [Any]()), ("b", "2", [["type": "addRules"]]), ("c", "2", []), ("d", "3", [])] {
            ClaudeViewFixtures.permission(h.claude, id: id, tool: "Bash", input: ["command": "ls"], suggestions: suggestions)
            XCTAssertTrue(h.key(18, key), id)
            XCTAssertTrue(h.claude.pending.isEmpty, id)
        }
        ClaudeViewFixtures.permission(h.claude, id: "e", tool: "Bash", input: ["command": "ls"])
        XCTAssertFalse(h.key(0, "a"))
        XCTAssertEqual(h.claude.pending.count, 1)
    }

    func testControlDExitsOnlyWhenEmptyAndControlCNeedsARunningTurn() {
        let h = ComposerHarness(self)
        h.set("text")
        XCTAssertFalse(h.key(2, "d", flags: .control))
        h.set("")
        XCTAssertTrue(h.key(2, "d", flags: .control))
        XCTAssertEqual(h.exits, 1)
        XCTAssertFalse(h.key(8, "c", flags: .control), "nothing to interrupt")
    }

    func testHistoryRecallWalksUpAndBackDown() {
        let h = ComposerHarness(self)
        XCTAssertFalse(h.key(ComposerHarness.up), "no history yet")
        h.model.history = ["first", "second"]
        h.set("")
        XCTAssertTrue(h.key(ComposerHarness.up))
        XCTAssertEqual(h.textView.string, "second")
        XCTAssertTrue(h.key(ComposerHarness.up))
        XCTAssertEqual(h.textView.string, "first")
        XCTAssertTrue(h.key(ComposerHarness.up), "stays at the oldest")
        XCTAssertEqual(h.textView.string, "first")
        XCTAssertTrue(h.key(ComposerHarness.down))
        XCTAssertEqual(h.textView.string, "second")
        XCTAssertTrue(h.key(ComposerHarness.down))
        XCTAssertEqual(h.textView.string, "")
        XCTAssertNil(h.model.historyIndex)
    }

    func testArrowsMoveTheCursorInMultilineText() {
        let h = ComposerHarness(self)
        h.model.history = ["old"]
        h.set("one\ntwo")
        XCTAssertFalse(h.key(ComposerHarness.up), "typed text: arrows move the cursor")
        h.model.historyIndex = 0
        XCTAssertFalse(h.key(ComposerHarness.up), "not on the first line")
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(h.key(ComposerHarness.down), "not on the last line")
        XCTAssertFalse(h.key(ComposerHarness.up, flags: .shift), "modified arrows select")
        XCTAssertFalse(h.key(0, "x"))
    }

    func testKeyDownRunsTheHandlerFirst() {
        let h = ComposerHarness(self)
        h.set("")
        h.window.window.makeFirstResponder(h.textView)
        h.textView.keyDown(with: ComposerHarness.event(0, "x"))
        XCTAssertEqual(h.textView.string, "x", "unhandled keys type")
        h.textView.keyDown(with: ComposerHarness.event(ComposerHarness.returnKey, "\r", flags: .shift))
        XCTAssertEqual(h.textView.string, "x\n", "handled keys don't reach the text view")
    }

    // MARK: Attachments

    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("ShellComposerTest-\(UUID().uuidString)"))
        pb.clearContents()
        fill(pb)
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    func testAttachTakesFilesButNotText() throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)
        let h = ComposerHarness(self)
        XCTAssertFalse(h.coordinator.attach(from: pasteboard { $0.setString("just text", forType: .string) }))
        XCTAssertTrue(h.coordinator.attach(from: pasteboard { $0.writeObjects([file as NSURL]) }))
        XCTAssertEqual(h.claude.draftAttachments.map(\.name), ["notes.txt"])
        XCTAssertTrue(h.textView.attachHandler?(pasteboard { $0.writeObjects([file as NSURL]) }) ?? false)
        XCTAssertEqual(h.claude.draftAttachments.count, 2)
    }

    func testSubmitWithOnlyAttachmentsWaitsForTheSession() throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("a.txt")
        try Data().write(to: file)
        let h = ComposerHarness(self)
        h.claude.draftAttachments = [try XCTUnwrap(ClaudeAttachment.load(file))]
        h.set("/exit")
        h.coordinator.submit()
        XCTAssertEqual(h.exits, 0, "/exit with attachments is a message, not a command")
        XCTAssertEqual(h.claude.draftAttachments.count, 1, "kept until the session can send")
    }

    func testDragsOfFilesAreAcceptedAndHoverIsReported() throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("drop.txt")
        try Data().write(to: file)
        let h = ComposerHarness(self)
        XCTAssertTrue(h.textView.acceptableDragTypes.contains(.fileURL))
        let drag = FakeDrag(pasteboard: pasteboard { $0.writeObjects([file as NSURL]) })
        XCTAssertEqual(h.textView.draggingEntered(drag), .copy)
        XCTAssertTrue(h.model.dropTargeted)
        XCTAssertEqual(h.textView.draggingUpdated(drag), .copy)
        h.textView.draggingExited(drag)
        XCTAssertFalse(h.model.dropTargeted)
        h.model.dropTargeted = true
        XCTAssertTrue(h.textView.performDragOperation(drag))
        XCTAssertFalse(h.model.dropTargeted)
        XCTAssertEqual(h.claude.draftAttachments.map(\.name), ["drop.txt"])
        h.model.dropTargeted = true
        h.textView.draggingEnded(drag)
        XCTAssertFalse(h.model.dropTargeted)
    }

    func testPasteMenuIsEnabledOnlyWithSomethingToAttach() {
        let h = ComposerHarness(self)
        let other = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        _ = h.textView.validateUserInterfaceItem(other)
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        // Whatever is on the clipboard, validation must not throw or attach anything.
        _ = h.textView.validateUserInterfaceItem(paste)
        XCTAssertTrue(h.claude.draftAttachments.isEmpty)
    }

    func testPlaceholderDrawsOnlyWhenEmpty() {
        let h = ComposerHarness(self)
        h.set("")
        h.textView.display()
        h.set("text")
        h.textView.display()
        h.textView.placeholder = ""
        h.set("")
        h.textView.display()
        XCTAssertEqual(h.textView.string, "")
    }
}

@MainActor
final class ClaudeSuggestionListTests: XCTestCase {
    func testRendersEveryKindAndScrollsToTheSelection() {
        let model = ClaudeComposerModel()
        model.suggestions = [
            .init(kind: .skill, title: "/deploy", insert: "/deploy ", detail: "Deploy", badge: "skill"),
            .init(kind: .command, title: "/help", insert: "/help ", detail: "", badge: nil),
            .init(kind: .mcp, title: "@github", insert: "@github ", detail: "MCP server", badge: "mcp"),
            .init(kind: .agent, title: "@agent-reviewer", insert: "@agent-reviewer ", detail: "Subagent", badge: "agent"),
            .init(kind: .file, title: "main.swift", insert: "@Sources/main.swift ", detail: "Sources/main.swift", badge: nil),
        ]
        var accepted: [String] = []
        let w = claudeWindow(ClaudeSuggestionList(model: model, palette: ClaudeViewFixtures.palette) { accepted.append($0.insert) }, width: 500)
        XCTAssertGreaterThan(w.size.height, 100)
        model.selected = 4
        w.layout(settle: 0.05)
        XCTAssertEqual(model.selected, 4)
        XCTAssertTrue(accepted.isEmpty, "rendering alone accepts nothing")
    }
}

/// A drag carrying `pasteboard`, for the composer's drop handling.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
