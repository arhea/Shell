import AppKit
import SwiftUI
import XCTest
@testable import Shell

// MARK: - Fix bar and prompt chips

@MainActor
final class PromptBarTests: XCTestCase {
    func testClaudeFixPromptNamesTheCommandOutputAndSuggestion() {
        var fix = CommandFixState(command: "make test", exitCode: 65, duration: 18.4, directory: "/tmp/x")
        let plain = InputEditorView.claudeFixPrompt(fix, outputPath: nil)
        XCTAssertTrue(plain.contains("`make test` failed with exit status 65 in /tmp/x"))
        XCTAssertFalse(plain.contains("output is in"))
        fix.suggestion = "make bootstrap"
        let full = InputEditorView.claudeFixPrompt(fix, outputPath: "/tmp/out.log")
        XCTAssertTrue(full.contains("Its output is in /tmp/out.log."))
        XCTAssertTrue(full.contains("`make bootstrap`"))
    }

    func testRendersTheFixBarAndChips() {
        var fix = CommandFixState(command: "make test", exitCode: 65, duration: 18.4, directory: "/tmp")
        render(CommandFixBar(fix: fix, onRun: { _ in }, onClaude: {}, onDismiss: {}), size: CGSize(width: 700, height: 38))
        fix.suggestion = "make bootstrap"
        render(CommandFixBar(fix: fix, onRun: { _ in }, onClaude: {}, onDismiss: {}), size: CGSize(width: 700, height: 38))
        render(PromptChip(color: DS.Status.info) { Text("~/code") }, size: CGSize(width: 100, height: 20))
        render(PromptChip(color: nil) { Text("node 22.9") }, size: CGSize(width: 100, height: 20))
    }
}

@MainActor
final class EditorFixBarTests: XCTestCase {
    private func fixture() throws -> EditorFixture {
        let original = SettingsStore.shared.settings
        addTeardownBlock { @MainActor in SettingsStore.shared.settings = original }
        let fx = EditorFixture(dir: try makeTemporaryDirectory().path)
        addTeardownBlock { @MainActor in fx.close() }
        return fx
    }

    func testAFailureShowsTheFixBarAndEscDismissesIt() throws {
        let fx = try fixture()
        let before = fx.editor.preferredHeight
        fx.session.commandStarted("make test", directory: nil)
        fx.makeIdle(exitCode: 2, duration: 1.5)
        fx.editor.shellBecameIdle()
        XCTAssertEqual(fx.editor.barState.fix?.command, "make test")
        XCTAssertEqual(fx.editor.barState.fix?.exitCode, 2)
        XCTAssertNil(fx.editor.barState.fix?.suggestion)
        XCTAssertGreaterThan(fx.editor.preferredHeight, before, "the bar takes room above the chips")
        render(fx.editor, size: CGSize(width: 700, height: fx.editor.preferredHeight))
        fx.command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(fx.editor.barState.fix)
        XCTAssertEqual(fx.editor.preferredHeight, before)
    }

    func testNoFixBarForSignalsSuccessOrWhenTurnedOff() throws {
        let fx = try fixture()
        fx.session.commandStarted("sleep 9", directory: nil)
        fx.makeIdle(exitCode: 130)
        fx.editor.shellBecameIdle()
        XCTAssertNil(fx.editor.barState.fix, "^C isn't a failure to fix")
        fx.session.commandStarted("true", directory: nil)
        fx.makeIdle(exitCode: 0)
        fx.editor.shellBecameIdle()
        XCTAssertNil(fx.editor.barState.fix)
        SettingsStore.shared.settings.showCommandBlocks = false
        fx.session.commandStarted("false", directory: nil)
        fx.makeIdle(exitCode: 1, duration: 0.1)
        fx.editor.shellBecameIdle()
        XCTAssertNil(fx.editor.barState.fix)
    }

    func testRunItSubmitsTheSuggestionAndClearsTheBar() throws {
        let fx = try fixture()
        fx.session.commandStarted("make", directory: nil)
        fx.makeIdle(exitCode: 2)
        fx.editor.shellBecameIdle()
        XCTAssertNotNil(fx.editor.barState.fix)
        fx.editor.runFix("make bootstrap")
        XCTAssertNil(fx.editor.barState.fix)
        XCTAssertEqual(fx.submitted.last, "make bootstrap")
    }

    func testRendersTheContextBarWithAPromptContext() throws {
        let fx = try fixture()
        fx.session.commandStarted("false", directory: nil)
        fx.makeIdle(exitCode: 1, branch: "main", duration: 2)
        render(EditorContextBar(session: fx.session, bar: EditorBarState(), context: fx.editor.promptContext, onCopy: { _ in }),
               size: CGSize(width: 900, height: 30))
    }
}
