import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// Borderless windows can't become key unless they say so.
private final class EditorKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// A real (never-launched) session and its input editor in an offscreen
/// window. libghostty isn't running, so writes to the terminal are dropped;
/// completion requests only write a file in the temp runtime folder.
@MainActor
final class EditorFixture {
    let dir: String
    let session: TerminalSession
    let editor: InputEditorView
    let window: NSWindow
    var submitted: [String] = []
    var heightChanges = 0
    var visibilityChanges = 0
    var focusEvents = 0

    init(dir: String, idle: Bool = true) {
        self.dir = dir
        session = TerminalSession(workingDirectory: dir)
        editor = InputEditorView(session: session)
        window = EditorKeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 200),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
        window.contentView = container
        editor.frame = container.bounds
        container.addSubview(editor)
        editor.onSubmit = { [unowned self] in submitted.append($0) }
        editor.onHeightChange = { [unowned self] in heightChanges += 1 }
        editor.onCompletionVisibilityChange = { [unowned self] in visibilityChanges += 1 }
        editor.onFocus = { [unowned self] in focusEvents += 1 }
        editor.layoutSubtreeIfNeeded()
        window.makeFirstResponder(editor.textView)
        if idle { makeIdle() }
    }

    var tv: CommandTextView { editor.textView }
    var text: String { tv.string }
    var completion: CompletionModel { editor.completion }

    func makeIdle(exitCode: Int? = nil, branch: String? = nil, duration: TimeInterval? = nil) {
        session.promptReady(exitCode: exitCode, directory: dir, branch: branch, duration: duration)
    }

    /// Types at the cursor the way the input system does.
    func type(_ s: String) {
        tv.insertText(s, replacementRange: tv.selectedRange())
    }

    func command(_ selector: Selector) {
        tv.doCommand(by: selector)
    }

    func event(_ chars: String, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: keyCode)!
    }

    func key(_ chars: String, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) {
        tv.keyDown(with: event(chars, flags: flags, keyCode: keyCode))
    }

    static func item(_ insertion: String, display: String? = nil, description: String = "", tag: String = "files",
                     dir: Bool = false, file: Bool = false) -> CompletionItem {
        CompletionItem(id: 0, insertion: insertion, display: display ?? insertion, description: description, tag: tag,
                       isDirectory: dir, isFile: file)
    }

    func close() {
        editor.hideCompletions()
        window.makeFirstResponder(nil)
        session.close()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

@MainActor
final class InputEditorTests: XCTestCase {
    private func fixture(idle: Bool = true) throws -> EditorFixture {
        // Restore any settings a test changes.
        let original = SettingsStore.shared.settings
        addTeardownBlock { @MainActor in SettingsStore.shared.settings = original }
        let fx = EditorFixture(dir: try makeTemporaryDirectory().path, idle: idle)
        addTeardownBlock { @MainActor in fx.close() }
        return fx
    }

    private func uniquePrefix() -> String {
        "ied" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
    }

    private func color(_ fx: EditorFixture, at location: Int) -> NSColor? {
        fx.tv.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    // MARK: Highlighting

    func testHighlightsEachTokenKind() throws {
        let fx = try fixture()
        let t = ConfigController.shared.theme
        let line = #"echo -n "hi" $HOME | zzqnotacommand > out # note"#
        fx.type(line)
        let ns = line as NSString
        func at(_ s: String) -> NSColor? { color(fx, at: ns.range(of: s).location) }
        XCTAssertEqual(at("echo"), t.palette[2].nsColor, "known command")
        XCTAssertEqual(at("-n"), t.palette[6].nsColor)
        XCTAssertEqual(at("\"hi\""), t.palette[3].nsColor)
        XCTAssertEqual(at("$HOME"), t.palette[5].nsColor)
        XCTAssertEqual(at("|"), t.accent.nsColor)
        XCTAssertEqual(at("zzqnotacommand"), t.palette[1].nsColor, "unknown command")
        XCTAssertEqual(at(">"), t.accent.nsColor)
        XCTAssertEqual(at("out"), t.foreground.nsColor, "plain argument")
        XCTAssertEqual(at("# note"), t.background.mixed(with: t.foreground, 0.45).nsColor)
        fx.editor.text = "A=1 echo"
        XCTAssertEqual(color(fx, at: 0), t.palette[5].nsColor, "assignment")
    }

    func testSyntaxHighlightingOffUsesTheForegroundOnly() throws {
        let fx = try fixture()
        SettingsStore.shared.settings.syntaxHighlighting = false
        fx.type("echo -n hi")
        let t = ConfigController.shared.theme
        for i in 0..<fx.text.count { XCTAssertEqual(color(fx, at: i), t.foreground.nsColor) }
    }

    // MARK: Ghost text

    func testGhostTextSuggestsFromHistoryAndArrowAcceptsIt() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        HistoryStore.shared.add("\(p) git status --short")
        fx.type("\(p) git s")
        XCTAssertEqual(fx.tv.ghostText, "tatus --short")
        fx.tv.display() // draws the ghost after the text
        fx.command(#selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(fx.text, "\(p) git status --short")
        XCTAssertNil(fx.tv.ghostText)
        // With nothing to accept, → is the text view's.
        fx.tv.setSelectedRange(NSRange(location: 0, length: 0))
        fx.command(#selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(fx.tv.selectedRange().location, 1)
    }

    func testOptionArrowAcceptsOneWordAtATime() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        HistoryStore.shared.add("\(p) cd ~/code/project now")
        fx.type("\(p) cd")
        XCTAssertEqual(fx.tv.ghostText, " ~/code/project now")
        fx.key("\u{F703}", flags: [.option, .numericPad, .function], keyCode: 0x7C)
        XCTAssertEqual(fx.text, "\(p) cd ~/", "stops after a slash")
        fx.key("\u{F703}", flags: [.option, .numericPad, .function], keyCode: 0x7C)
        XCTAssertEqual(fx.text, "\(p) cd ~/code/")
        fx.key("\u{F703}", flags: [.option, .numericPad, .function], keyCode: 0x7C)
        fx.key("\u{F703}", flags: [.option, .numericPad, .function], keyCode: 0x7C)
        XCTAssertEqual(fx.text, "\(p) cd ~/code/project now")
    }

    func testCommandArrowEndAndEndOfLineAcceptTheWholeSuggestion() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        HistoryStore.shared.add("\(p) make test")
        fx.type("\(p) ma")
        fx.key("\u{F703}", flags: [.command, .numericPad, .function], keyCode: 0x7C)
        XCTAssertEqual(fx.text, "\(p) make test")

        fx.editor.text = "\(p) m"
        XCTAssertEqual(fx.tv.ghostText, "ake test")
        fx.key("\u{F72B}", flags: [.function], keyCode: 0x77)
        XCTAssertEqual(fx.text, "\(p) make test")

        fx.editor.text = "\(p) mak"
        fx.command(#selector(NSResponder.moveToEndOfLine(_:)))
        XCTAssertEqual(fx.text, "\(p) make test")
        // Nothing to accept: the text view moves the cursor itself.
        fx.command(#selector(NSResponder.moveToEndOfParagraph(_:)))
        XCTAssertEqual(fx.text, "\(p) make test")
    }

    func testEscapeDismissesTheGhost() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        HistoryStore.shared.add("\(p) uptime")
        fx.type("\(p) up")
        XCTAssertNotNil(fx.tv.ghostText)
        fx.command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(fx.tv.ghostText)
        fx.command(#selector(NSResponder.cancelOperation(_:))) // nothing left to dismiss
        XCTAssertEqual(fx.text, "\(p) up")
    }

    func testNoGhostWhenSuggestionsAreOffOrTheCursorIsntAtTheEnd() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        HistoryStore.shared.add("\(p) whoami")
        fx.type("\(p) who")
        XCTAssertNotNil(fx.tv.ghostText)
        fx.tv.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertNil(fx.tv.ghostText)
        fx.tv.display()
        SettingsStore.shared.settings.historySuggestions = false
        fx.editor.text = "\(p) who"
        XCTAssertNil(fx.tv.ghostText)
    }

    func testGhostDrawsAfterAnEmptyBufferAndANewline() throws {
        let fx = try fixture()
        func draw() {
            guard let rep = fx.tv.bitmapImageRepForCachingDisplay(in: fx.tv.bounds) else { return XCTFail("no bitmap") }
            fx.tv.cacheDisplay(in: fx.tv.bounds, to: rep)
        }
        fx.tv.ghostText = "suggested\nsecond line"
        draw()
        fx.editor.text = "first\n"
        fx.tv.ghostText = "next"
        draw()
        fx.editor.text = "first"
        fx.tv.ghostText = " line"
        draw()
        XCTAssertEqual(fx.tv.ghostText, " line")
    }

    func testPlainKeysAreTypedByTheTextView() throws {
        let fx = try fixture()
        fx.key("a", keyCode: 0)
        XCTAssertEqual(fx.text, "a")
    }

    func testShiftEnterInsertsANewline() throws {
        let fx = try fixture()
        fx.type("echo")
        // Dequeuing an event makes it the app's current event, which is
        // where the editor looks for ⇧.
        NSApp.postEvent(fx.event("\r", flags: .shift, keyCode: 36), atStart: true)
        let current = NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true)
        XCTAssertEqual(current?.modifierFlags.contains(.shift), true)
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.text, "echo\n")
        XCTAssertTrue(fx.submitted.isEmpty)
    }

    func testIdleWithoutAQueuedCommandOnlyChecksForAFix() throws {
        let fx = try fixture()
        fx.session.commandStarted("false", directory: nil)
        fx.makeIdle(exitCode: 1)
        fx.editor.shellBecameIdle()
        XCTAssertNil(fx.tv.ghostText)
        XCTAssertFalse(fx.editor.barState.suggestedFix)
    }

    // MARK: Control keys

    func testControlCClearsTheLineOrInterruptsWhenEmpty() throws {
        let fx = try fixture()
        fx.type("some text")
        fx.key("c", flags: .control, keyCode: 8)
        XCTAssertEqual(fx.text, "")
        fx.key("c", flags: .control, keyCode: 8) // empty: sent to the shell
        XCTAssertEqual(fx.text, "")
    }

    func testControlDLAndUnknownControlKeys() throws {
        let fx = try fixture()
        XCTAssertTrue(fx.editor.handleKeyDown(fx.event("d", flags: .control)))
        XCTAssertTrue(fx.editor.handleKeyDown(fx.event("l", flags: .control)))
        fx.type("abc")
        XCTAssertFalse(fx.editor.handleKeyDown(fx.event("d", flags: .control)), "⌃D with text is the text view's")
        XCTAssertFalse(fx.editor.handleKeyDown(fx.event("k", flags: .control)))
        XCTAssertFalse(fx.editor.handleKeyDown(fx.event("x")))
        XCTAssertFalse(fx.editor.handleKeyDown(fx.event("\u{F703}", flags: .option, keyCode: 0x7C)), "no ghost to accept")
    }

    func testControlUDeletesToLineStartAndControlWDeletesAWord() throws {
        let fx = try fixture()
        fx.type("first line\nsecond word")
        fx.key("w", flags: .control, keyCode: 13)
        XCTAssertEqual(fx.text, "first line\nsecond ")
        fx.key("u", flags: .control, keyCode: 32)
        XCTAssertEqual(fx.text, "first line\n")
    }

    // MARK: History navigation

    func testUpAndDownWalkHistoryMatchingWhatWasTyped() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        for c in ["build one", "other", "build two"] { HistoryStore.shared.add("\(p) \(c)") }
        fx.type("\(p) build")
        fx.command(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(fx.text, "\(p) build two")
        XCTAssertNil(fx.tv.ghostText)
        fx.command(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(fx.text, "\(p) build one")
        fx.command(#selector(NSResponder.moveUp(_:))) // no older match: stays
        XCTAssertEqual(fx.text, "\(p) build one")
        fx.command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(fx.text, "\(p) build two")
        fx.command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(fx.text, "\(p) build", "past the newest: back to the draft")
        // ↓ without a history walk is the text view's.
        XCTAssertFalse(fx.editor.handleCommand(#selector(NSResponder.moveDown(_:))))
    }

    func testUpAndDownOnlyTakeOverOnTheFirstAndLastLine() throws {
        let fx = try fixture()
        fx.type("line one\nline two")
        XCTAssertFalse(fx.editor.handleCommand(#selector(NSResponder.moveUp(_:))), "↑ on the last line moves the cursor")
        fx.tv.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(fx.editor.handleCommand(#selector(NSResponder.moveDown(_:))), "↓ on the first line moves the cursor")
    }

    // MARK: Submitting

    func testEnterSubmitsAtThePromptAndClearsTheEditor() throws {
        let fx = try fixture()
        let cmd = "\(uniquePrefix()) run"
        fx.type(cmd)
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.submitted, [cmd])
        XCTAssertEqual(fx.text, "")
        XCTAssertEqual(fx.session.state, .running)
        XCTAssertEqual(HistoryStore.shared.entries.last, cmd)
        // While it runs, Enter types into the terminal instead.
        fx.type("y")
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.submitted, [cmd, "y"])
    }

    func testEnterContinuesAnUnterminatedQuoteOrTrailingBackslash() throws {
        let fx = try fixture()
        fx.type("echo \"open")
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.text, "echo \"open\n")
        fx.editor.text = "ls \\"
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.text, "ls \\\n")
        fx.command(#selector(NSResponder.insertLineBreak(_:)))
        fx.command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(fx.text, "ls \\\n\n\n")
        XCTAssertTrue(fx.submitted.isEmpty)
    }

    func testCommandsTypedBeforeThePromptRunOnceItsReady() throws {
        let original = SettingsStore.shared.settings
        addTeardownBlock { @MainActor in SettingsStore.shared.settings = original }
        SettingsStore.shared.settings.shellIntegration = true
        SettingsStore.shared.settings.shellPath = "/bin/zsh"
        let fx = try fixture(idle: false)
        XCTAssertEqual(fx.session.state, .starting)
        let cmd = "\(uniquePrefix()) early"
        fx.type(cmd)
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.submitted, [cmd])
        XCTAssertNotEqual(HistoryStore.shared.entries.last, cmd, "not run yet")
        fx.makeIdle()
        fx.editor.shellBecameIdle()
        XCTAssertEqual(fx.session.state, .running)
        XCTAssertEqual(HistoryStore.shared.entries.last, cmd)
    }

    func testUnterminatedQuoteDetection() {
        XCTAssertTrue(InputEditorView.hasUnterminatedQuote("echo \"hi"))
        XCTAssertTrue(InputEditorView.hasUnterminatedQuote("echo 'it"))
        XCTAssertFalse(InputEditorView.hasUnterminatedQuote("echo \"a \\\" b\""))
        XCTAssertFalse(InputEditorView.hasUnterminatedQuote("echo 'a \"b' c"))
        XCTAssertFalse(InputEditorView.hasUnterminatedQuote("echo 'a\\'"), "no escapes inside single quotes")
        XCTAssertFalse(InputEditorView.hasUnterminatedQuote("echo \\\"x"))
        XCTAssertFalse(InputEditorView.hasUnterminatedQuote(""))
    }

    func testCommonPrefix() {
        XCTAssertEqual(InputEditorView.commonPrefix(["src/app", "src/api", "src/assets"]), "src/a")
        XCTAssertEqual(InputEditorView.commonPrefix(["one"]), "one")
        XCTAssertNil(InputEditorView.commonPrefix(["abc", "xyz"]))
        XCTAssertNil(InputEditorView.commonPrefix([]))
    }

    // MARK: Completions

    func testCompletionsWhileTypingShowAndTabAcceptsTheSelection() throws {
        let fx = try fixture()
        fx.type("git ch")
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: [
            EditorFixture.item("checkout", tag: "git-commands"), EditorFixture.item("cherry-pick", tag: "git-commands"),
        ]))
        XCTAssertTrue(fx.completion.isVisible)
        XCTAssertEqual(fx.completion.mode, .completions)
        XCTAssertEqual(fx.completion.items.map(\.id), [0, 1])
        XCTAssertEqual(fx.completion.workingDirectory, fx.dir)
        XCTAssertNil(fx.tv.ghostText)
        fx.command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(fx.completion.selected?.insertion, "cherry-pick")
        fx.command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(fx.text, "git cherry-pick ")
        XCTAssertFalse(fx.completion.isVisible)
    }

    func testSelectionMovesWithArrowsPagesAndBacktab() throws {
        let fx = try fixture()
        fx.type("x")
        let items = (0..<20).map { EditorFixture.item("x\($0)") }
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: items))
        XCTAssertTrue(fx.completion.isVisible)
        fx.command(#selector(NSResponder.pageDown(_:)))
        XCTAssertEqual(fx.completion.selectedIndex, 8)
        fx.command(#selector(NSResponder.scrollPageDown(_:)))
        XCTAssertEqual(fx.completion.selectedIndex, 16)
        fx.command(#selector(NSResponder.pageUp(_:)))
        XCTAssertEqual(fx.completion.selectedIndex, 8)
        fx.command(#selector(NSResponder.scrollPageUp(_:)))
        XCTAssertEqual(fx.completion.selectedIndex, 0)
        fx.command(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(fx.completion.selectedIndex, 19, "wraps around")
        fx.command(#selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(fx.completion.selectedIndex, 18)
        XCTAssertTrue(fx.completion.userNavigated)
        // Enter accepts once the user has moved the selection.
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.text, "x18 ")
        XCTAssertTrue(fx.submitted.isEmpty)
        // Without a menu, page keys and backtab do nothing special.
        XCTAssertFalse(fx.editor.handleCommand(#selector(NSResponder.pageDown(_:))))
        XCTAssertFalse(fx.editor.handleCommand(#selector(NSResponder.pageUp(_:))))
        XCTAssertTrue(fx.editor.handleCommand(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertFalse(fx.editor.handleCommand(#selector(NSResponder.selectAll(_:))))
    }

    func testEscapeHidesTheMenuAndEnterWithoutNavigatingSubmits() throws {
        let fx = try fixture()
        fx.type("ls a")
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: [EditorFixture.item("a1"), EditorFixture.item("a2")]))
        fx.command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(fx.completion.isVisible)
        fx.editor.completionsReceived(CompletionResult(requestID: 2, items: [EditorFixture.item("a1"), EditorFixture.item("a2")]))
        XCTAssertTrue(fx.completion.isVisible)
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.submitted, ["ls a"])
        XCTAssertFalse(fx.completion.isVisible)
    }

    func testAcceptingADirectoryAddsNoSpaceAndKeepsDrilling() throws {
        let fx = try fixture()
        fx.type("cd sr")
        fx.editor.accept(EditorFixture.item("src/", dir: true))
        XCTAssertEqual(fx.text, "cd src/")
        fx.type(" --x")
        fx.tv.setSelectedRange(NSRange(location: 3, length: 0))
        fx.editor.accept(EditorFixture.item("lib"))
        XCTAssertEqual(fx.text, "cd lib src/ --x", "inserted at the (empty) word under the cursor")
        for suffix in ["KEY=", "host:"] {
            fx.editor.text = "x"
            fx.editor.accept(EditorFixture.item(suffix))
            XCTAssertEqual(fx.text, suffix, "no space after \(suffix)")
        }
    }

    func testOnlyMatchIsHiddenWhenItsWhatWasTyped() throws {
        let fx = try fixture()
        fx.type("ls src")
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: [EditorFixture.item("a1"), EditorFixture.item("a2")]))
        XCTAssertTrue(fx.completion.isVisible)
        fx.editor.completionsReceived(CompletionResult(requestID: 2, items: [EditorFixture.item("src")]))
        XCTAssertFalse(fx.completion.isVisible)
    }

    func testEmptyWordShowsOnlyAfterASpaceAndForShortLists() throws {
        let fx = try fixture()
        fx.type("git")
        fx.tv.setSelectedRange(NSRange(location: 0, length: 0))
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: [EditorFixture.item("a"), EditorFixture.item("b")]))
        XCTAssertFalse(fx.completion.isVisible, "no word and no space before the cursor")
        fx.editor.text = "git "
        fx.editor.completionsReceived(CompletionResult(requestID: 2, items: (0..<81).map { EditorFixture.item("c\($0)") }))
        XCTAssertFalse(fx.completion.isVisible, "too many to list for an empty word")
        fx.editor.completionsReceived(CompletionResult(requestID: 3, items: [EditorFixture.item("add"), EditorFixture.item("am")]))
        XCTAssertTrue(fx.completion.isVisible)
    }

    func testTypingWhileTheMenuIsUpFiltersIt() throws {
        let fx = try fixture()
        fx.type("git c")
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: [
            EditorFixture.item("checkout"), EditorFixture.item("cherry-pick"), EditorFixture.item("commit"),
        ]))
        fx.type("h")
        XCTAssertEqual(fx.completion.items.map(\.insertion), ["checkout", "cherry-pick"])
        XCTAssertEqual(fx.completion.items.map(\.id), [0, 1])
        fx.type("zz") // nothing matches: keep the last list
        XCTAssertEqual(fx.completion.items.count, 2)
    }

    func testWhileTypingOffOnlyTabShowsCompletions() throws {
        let fx = try fixture()
        SettingsStore.shared.settings.completionsWhileTyping = false
        fx.type("git ch")
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: [EditorFixture.item("checkout"), EditorFixture.item("cherry-pick")]))
        XCTAssertFalse(fx.completion.isVisible)
        // ⇥ asks zsh, then inserts the common prefix and lists the rest.
        fx.command(#selector(NSResponder.insertTab(_:)))
        fx.editor.completionsReceived(CompletionResult(requestID: 2, items: [EditorFixture.item("checkout"), EditorFixture.item("cherry-pick")]))
        XCTAssertEqual(fx.text, "git che")
        XCTAssertTrue(fx.completion.isVisible)
    }

    func testTabWithASingleCompletionAcceptsIt() throws {
        let fx = try fixture()
        fx.type("git sta")
        fx.key(" ", flags: .control, keyCode: 49) // ⌃Space is ⇥
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: [EditorFixture.item("status", tag: "git-commands")]))
        XCTAssertEqual(fx.text, "git status ")
        XCTAssertFalse(fx.completion.isVisible)
    }

    func testCompletionsAreOnlyRequestedAtAnIdlePrompt() throws {
        let fx = try fixture()
        SettingsStore.shared.settings.completions = false
        fx.type("ls ")
        fx.editor.requestCompletionsNow(fromTab: true) // ignored
        SettingsStore.shared.settings.completions = true
        fx.editor.text = ""
        fx.editor.requestCompletionsNow(fromTab: false) // an empty line never pops up
        fx.editor.text = "ls\n"
        fx.editor.requestCompletionsNow(fromTab: false)
        fx.editor.text = "ls -"
        fx.editor.requestCompletionsNow(fromTab: false)
        fx.session.commandStarted("sleep 1", directory: nil)
        fx.editor.requestCompletionsNow(fromTab: true)
        XCTAssertFalse(fx.completion.isVisible)
        // Typing schedules a request after a short pause.
        fx.makeIdle()
        fx.type("x")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(fx.completion.isVisible, "nothing answers without a shell")
    }

    // MARK: History search

    func testControlRSearchesHistoryAndEnterRunsTheMatch() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        HistoryStore.shared.add("\(p) deploy staging")
        HistoryStore.shared.add("\(p) deploy\nproduction")
        fx.type("\(p) deploy")
        fx.key("r", flags: .control, keyCode: 15)
        XCTAssertTrue(fx.completion.isVisible)
        XCTAssertEqual(fx.completion.mode, .history)
        XCTAssertEqual(fx.completion.query, "\(p) deploy")
        XCTAssertEqual(fx.completion.items.first?.display, "\(p) deploy ⏎ production")
        XCTAssertEqual(fx.completion.items.first?.tag, "history")
        fx.command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(fx.completion.selected?.insertion, "\(p) deploy staging")
        fx.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fx.submitted, ["\(p) deploy staging"])
        XCTAssertFalse(fx.completion.isVisible)
    }

    func testHistorySearchTabEditsTheMatchAndNarrowsAsYouType() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        HistoryStore.shared.add("\(p) alpha")
        HistoryStore.shared.add("\(p) beta")
        fx.type(p)
        fx.key("r", flags: .control, keyCode: 15)
        XCTAssertEqual(fx.completion.items.count, 2)
        fx.type(" alp")
        XCTAssertEqual(fx.completion.items.map(\.insertion), ["\(p) alpha"])
        fx.command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(fx.text, "\(p) alpha")
        XCTAssertFalse(fx.completion.isVisible)
        // No matches hides the menu.
        fx.key("r", flags: .control, keyCode: 15)
        fx.type("qqqqqq")
        XCTAssertFalse(fx.completion.isVisible)
    }

    func testAcceptingAHistoryItemReplacesTheLine() throws {
        let fx = try fixture()
        let p = uniquePrefix()
        HistoryStore.shared.add("\(p) one")
        fx.type(p)
        fx.key("r", flags: .control, keyCode: 15)
        let item = try XCTUnwrap(fx.completion.selected)
        fx.editor.accept(item)
        XCTAssertEqual(fx.text, "\(p) one")
        XCTAssertFalse(fx.completion.isVisible)
    }

    // MARK: Focus, layout and appearance

    func testFocusAndBlur() throws {
        let fx = try fixture()
        fx.window.makeFirstResponder(nil)
        fx.editor.focus()
        XCTAssertTrue(fx.window.firstResponder === fx.tv)
        XCTAssertGreaterThan(fx.focusEvents, 0)
        fx.type("ls a")
        fx.editor.completionsReceived(CompletionResult(requestID: 1, items: [EditorFixture.item("a1"), EditorFixture.item("a2")]))
        fx.window.makeFirstResponder(nil)
        XCTAssertFalse(fx.completion.isVisible, "losing focus hides the menu")
        fx.editor.insert("b")
        XCTAssertEqual(fx.text, "ls ab")
    }

    func testPreferredHeightGrowsWithLinesUpToALimit() throws {
        let fx = try fixture()
        let one = fx.editor.preferredHeight
        fx.editor.text = "1\n2\n3"
        let three = fx.editor.preferredHeight
        XCTAssertGreaterThan(three, one)
        fx.editor.text = (1...30).map(String.init).joined(separator: "\n")
        let many = fx.editor.preferredHeight
        fx.editor.text = (1...40).map(String.init).joined(separator: "\n")
        XCTAssertEqual(fx.editor.preferredHeight, many, "capped at ten lines")
        XCTAssertGreaterThan(fx.heightChanges, 0)
    }

    func testLaysOutForATopOrBottomPrompt() throws {
        let fx = try fixture()
        render(fx.editor, size: CGSize(width: 600, height: 120))
        XCTAssertFalse(fx.editor.isAtTop)
        SettingsStore.shared.settings.inputPosition = .top
        XCTAssertTrue(fx.editor.isAtTop)
        render(fx.editor, size: CGSize(width: 600, height: 120))
        XCTAssertEqual(fx.tv.frame.width, fx.tv.enclosingScrollView?.contentSize.width)
    }

    func testThemeFollowsEditorFontSettings() throws {
        let fx = try fixture()
        SettingsStore.shared.settings.editorFontSize = 17
        SettingsStore.shared.settings.fontFamily = "Menlo"
        fx.editor.applyTheme()
        XCTAssertEqual(fx.editor.editorFont.pointSize, 17)
        XCTAssertEqual(fx.editor.editorFont.familyName, "Menlo")
        XCTAssertEqual(fx.tv.font, fx.editor.editorFont)
        SettingsStore.shared.settings.editorFontSize = 0
        SettingsStore.shared.settings.fontSize = 12
        fx.editor.applyTheme()
        XCTAssertEqual(fx.editor.editorFont.pointSize, 12)
        fx.editor.refreshContext()
    }

    func testFontFallsBackToTheSystemMonospacedFont() {
        let f = InputEditorView.font(family: "No Such Font \(UUID().uuidString)", size: 14)
        XCTAssertEqual(f.pointSize, 14)
        XCTAssertTrue(f.isFixedPitch)
        XCTAssertEqual(InputEditorView.font(family: "", size: 11).pointSize, 11)
    }

    // MARK: Context bar and copy

    func testCopyingOutputThatScrolledAwayFlashesAMessage() throws {
        let fx = try fixture()
        fx.editor.copy(.lastOutput)
        XCTAssertEqual(fx.editor.barState.flashMessage, "Output no longer on screen")
        XCTAssertFalse(fx.editor.barState.flashSuccess)
    }

    func testBarStateFlashClearsItself() {
        let bar = EditorBarState()
        bar.flash("Copied", success: true)
        bar.flash("Copied again", success: true)
        XCTAssertEqual(bar.flashMessage, "Copied again")
        XCTAssertTrue(waitUntil(timeout: 3) { bar.flashMessage == nil })
    }

    func testRendersTheContextBarInEachState() throws {
        let fx = try fixture()
        let bar = EditorBarState()
        render(EditorContextBar(session: fx.session, bar: bar, onCopy: { _ in }), size: CGSize(width: 700, height: 30))
        fx.session.commandStarted("false", directory: nil)
        fx.makeIdle(exitCode: 1, branch: "main", duration: 2.5)
        bar.suggestedFix = true
        render(EditorContextBar(session: fx.session, bar: bar, onCopy: { _ in }), size: CGSize(width: 700, height: 30))
        fx.session.commandStarted("true", directory: nil)
        fx.makeIdle(exitCode: 0, branch: "main", duration: 0.2)
        bar.flash("Copied command", success: true)
        render(EditorContextBar(session: fx.session, bar: bar, onCopy: { _ in }), size: CGSize(width: 700, height: 30))
        bar.flash("Nothing to copy", success: false)
        SettingsStore.shared.settings.showContextBar = false
        render(EditorContextBar(session: fx.session, bar: bar, onCopy: { _ in }), size: CGSize(width: 700, height: 30))
        render(CopyMenuButton(palette: .current, copied: true, onCopy: { _ in }), size: CGSize(width: 120, height: 24))
        fx.editor.refreshContext()
        render(fx.editor, size: CGSize(width: 700, height: 120))
    }

    func testContextBarShowsAStartingSpinner() throws {
        let original = SettingsStore.shared.settings
        addTeardownBlock { @MainActor in SettingsStore.shared.settings = original }
        SettingsStore.shared.settings.shellIntegration = true
        SettingsStore.shared.settings.shellPath = "/bin/zsh"
        let fx = try fixture(idle: false)
        XCTAssertEqual(fx.session.state, .starting)
        render(EditorContextBar(session: fx.session, bar: EditorBarState(), onCopy: { _ in }), size: CGSize(width: 700, height: 30))
    }

    func testCopyButtonReportsWhichKindWasPicked() throws {
        var picked: [InputEditorView.CopyKind] = []
        let w = claudeWindow(CopyMenuButton(palette: .current, copied: false, onCopy: { picked.append($0) }), width: 140, height: 24)
        w.press(0)
        XCTAssertEqual(picked.first, .lastOutput, "the main action copies the last output")
    }
}
