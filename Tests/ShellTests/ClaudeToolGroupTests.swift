import XCTest
@testable import Shell

@MainActor
final class ClaudeToolGroupTests: XCTestCase {
    private func tool(_ name: String) -> ClaudeItem {
        let i = ClaudeItem(kind: .tool)
        i.toolName = name
        return i
    }

    private func shape(_ rows: [ClaudeTranscript.Row]) -> [String] {
        rows.map {
            switch $0 {
            case .item(let i): "\(i.kind)"
            case .tools(let items): "tools(\(items.count))"
            case .run(let items): "run(\(items.count))"
            case .summary: "summary"
            }
        }
    }

    private var transcript: [ClaudeItem] {
        [ClaudeItem(kind: .user), tool("Read"), ClaudeItem(kind: .thinking), tool("Edit"), ClaudeItem(kind: .assistant),
         ClaudeItem(kind: .user), tool("Bash"), tool("TodoWrite"), tool("Grep"), ClaudeItem(kind: .assistant)]
    }

    func testCollapsePreviousKeepsTheCurrentTurn() {
        XCTAssertEqual(shape(ClaudeTranscript.rows(transcript, mode: .collapsePrevious)),
                       ["user", "tools(3)", "assistant", "user", "tool", "tool", "tool", "assistant"])
    }

    func testCollapseAllFoldsEveryRunButKeepsCards() {
        XCTAssertEqual(shape(ClaudeTranscript.rows(transcript, mode: .collapseAll)),
                       ["user", "tools(3)", "assistant", "user", "tools(1)", "tool", "tools(1)", "assistant"])
    }

    func testShowAllAndThinkingOnlyRuns() {
        XCTAssertEqual(ClaudeTranscript.rows(transcript, mode: .showAll).count, transcript.count)
        let thinkingOnly = [ClaudeItem(kind: .user), ClaudeItem(kind: .thinking), ClaudeItem(kind: .assistant)]
        XCTAssertEqual(shape(ClaudeTranscript.rows(thinkingOnly, mode: .collapseAll)), ["user", "thinking", "assistant"])
    }

    func testBreakdown() {
        XCTAssertEqual(ToolGroupView.breakdown([tool("Bash"), tool("Read"), tool("Read")]).hasPrefix(ClaudeToolFormat.displayName("Read") + " 2"), true)
    }
}
