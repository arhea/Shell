import XCTest
@testable import Shell

final class ClaudeDashboardTests: XCTestCase {
    @MainActor
    func testRecognizesClaudeCommands() {
        XCTAssertTrue(TerminalSession.isClaudeCommand("claude"))
        XCTAssertTrue(TerminalSession.isClaudeCommand("claude --resume 7bcc953c"))
        XCTAssertTrue(TerminalSession.isClaudeCommand("command claude -c"))
        XCTAssertTrue(TerminalSession.isClaudeCommand("ANTHROPIC_MODEL=opus claude"))
        XCTAssertTrue(TerminalSession.isClaudeCommand("~/.local/bin/claude"))
        XCTAssertTrue(TerminalSession.isClaudeCommand("npx -y @anthropic-ai/claude-code"))
        XCTAssertFalse(TerminalSession.isClaudeCommand("git commit -m claude"))
        XCTAssertFalse(TerminalSession.isClaudeCommand("cd claude"))
        XCTAssertFalse(TerminalSession.isClaudeCommand("claudette"))
        XCTAssertFalse(TerminalSession.isClaudeCommand(""))
    }

    @MainActor
    func testPreviewDropsInputBoxAndFooter() {
        let viewport = """
        ⏺ Read(Sources/Shell/App/main.swift)
          ⎿  Read 42 lines

        ⏺ The entry point sets up the app delegate.

        ────────────────────────────────────────────
        > fix the build
        ────────────────────────────────────────────
          ? for shortcuts
        """
        XCTAssertEqual(ClaudeDashboard.previewLines(fromViewport: viewport), [
            "⏺ Read(Sources/Shell/App/main.swift)",
            "⎿  Read 42 lines",
            "⏺ The entry point sets up the app delegate.",
        ])
    }

    @MainActor
    func testPreviewStripsBoxBordersAndLimits() {
        let viewport = (1...10).map { "│ line \($0) │" }.joined(separator: "\n")
        XCTAssertEqual(ClaudeDashboard.previewLines(fromViewport: viewport, limit: 2), ["line 9", "line 10"])
    }

    @MainActor
    func testFindsTerminalPermissionPrompt() {
        let viewport = """
        ⏺ I'll check the status.

        ╭──────────────────────────────────────────────────╮
        │ Bash command                                     │
        │                                                  │
        │   git status                                     │
        │   Show working tree status                       │
        │                                                  │
        │ Do you want to proceed?                          │
        │ ❯ 1. Yes                                         │
        │   2. Yes, and don't ask again for git status     │
        │   3. No, and tell Claude what to do differently (esc) │
        ╰──────────────────────────────────────────────────╯
        """
        let prompt = ClaudeDashboard.terminalPrompt(fromViewport: viewport)
        XCTAssertEqual(prompt?.question, "Do you want to proceed?")
        XCTAssertEqual(prompt?.context, ["Bash command", "git status", "Show working tree status"])
        XCTAssertEqual(prompt?.options.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(prompt?.options.last?.label, "No, and tell Claude what to do differently")
    }

    @MainActor
    func testIgnoresNumberedListsInReplies() {
        let reply = """
        ⏺ Which approach do you prefer?
          1. Refactor the parser
          2. Patch the call site
        ────────────────────────
        > 
        ────────────────────────
        """
        XCTAssertNil(ClaudeDashboard.terminalPrompt(fromViewport: reply)) // no ❯ selector
    }
}
