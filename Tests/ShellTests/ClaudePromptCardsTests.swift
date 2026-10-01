import AppKit
import SwiftUI
import XCTest
@testable import Shell

private struct Decision: Equatable {
    var allow: Bool
    var always: Bool
}

@MainActor
final class ClaudePermissionCardTests: XCTestCase {
    private let p = ClaudeViewFixtures.palette

    func testRendersEditWithDiffAndFilePath() {
        let req = ClaudeViewFixtures.request(tool: "Edit", input: ["file_path": "/tmp/project/main.swift", "old_string": "let a = 1\n", "new_string": "let a = 2\n"],
                                             description: "Edit main.swift", reason: "Not in the allow list")
        let host = render(PermissionCard(request: req, palette: p, fontSize: 13) { _, _ in }, size: CGSize(width: 600, height: 500))
        XCTAssertGreaterThan(host.fittingSize.height, 80)
    }

    func testRendersBashCommandHighlightedWithoutKeyHint() {
        let req = ClaudeViewFixtures.request(tool: "Bash", input: ["command": "ls -la | grep swift"], description: "List files",
                                             suggestions: [["type": "addRules"]])
        let host = render(PermissionCard(request: req, palette: p, fontSize: 13, showsKeyHint: false) { _, _ in }, size: CGSize(width: 600, height: 400))
        XCTAssertGreaterThan(host.fittingSize.height, 60)
    }

    func testRendersOtherToolsWithTheirSummaryOrNothing() {
        for (tool, input) in [("WebFetch", ["url": "https://example.com"]), ("mcp__github__list", [String: Any]()), ("Bash", [:])] {
            let req = ClaudeViewFixtures.request(tool: tool, input: input, description: "")
            let host = render(PermissionCard(request: req, palette: p, fontSize: 13) { _, _ in }, size: CGSize(width: 600, height: 300))
            XCTAssertGreaterThan(host.fittingSize.height, 30, tool)
        }
    }

    func testHidesADescriptionThatOnlyRepeatsTheFilePath() {
        let path = NSHomeDirectory() + "/project/a.swift"
        for description in ["Read ~/project/a.swift", "Read \(path)", "Something else"] {
            let req = ClaudeViewFixtures.request(tool: "Read", input: ["file_path": path], description: description)
            render(PermissionCard(request: req, palette: p, fontSize: 13) { _, _ in }, size: CGSize(width: 600, height: 300))
        }
    }

    func testButtonsAllowAlwaysAllowAndDenyInOrder() {
        var decisions: [Decision] = []
        let req = ClaudeViewFixtures.request(tool: "Bash", input: ["command": "make test"], suggestions: [["type": "addRules"]])
        let w = claudeWindow(PermissionCard(request: req, palette: p, fontSize: 13) { decisions.append(Decision(allow: $0, always: $1)) })
        w.pressAll()
        XCTAssertEqual(decisions, [Decision(allow: true, always: false), Decision(allow: true, always: true), Decision(allow: false, always: false)])
    }

    func testWithoutSuggestionsThereIsNoAlwaysAllow() {
        var decisions: [Decision] = []
        let req = ClaudeViewFixtures.request(tool: "Bash", input: ["command": "make test"])
        let w = claudeWindow(PermissionCard(request: req, palette: p, fontSize: 13) { decisions.append(Decision(allow: $0, always: $1)) })
        w.pressAll()
        XCTAssertEqual(decisions, [Decision(allow: true, always: false), Decision(allow: false, always: false)])
    }
}

@MainActor
final class ClaudePlanCardTests: XCTestCase {
    private let p = ClaudeViewFixtures.palette

    func testRendersThePlanAsMarkdown() {
        let req = ClaudeViewFixtures.request(tool: "ExitPlanMode", input: ["plan": "# Plan\n\n1. Add tests\n2. Ship it\n\n```swift\nlet x = 1\n```"])
        XCTAssertTrue(req.isPlan)
        let host = render(PlanCard(request: req, palette: p, fontSize: 13, directory: "/tmp") { _ in }, size: CGSize(width: 700, height: 600))
        XCTAssertGreaterThan(host.fittingSize.height, 100)
    }

    func testButtonsChooseAcceptEditsDefaultOrKeepPlanning() {
        var modes: [ClaudePermissionMode?] = []
        let req = ClaudeViewFixtures.request(tool: "ExitPlanMode", input: ["plan": "Do the thing"])
        let w = claudeWindow(PlanCard(request: req, palette: p, fontSize: 13) { modes.append($0) }, width: 760)
        w.pressAll()
        XCTAssertEqual(modes, [.acceptEdits, .default, nil])
    }
}

@MainActor
final class ClaudeQuestionCardTests: XCTestCase {
    private let p = ClaudeViewFixtures.palette

    private func request(multi: Bool = false, previews: Bool = false, count: Int = 1) -> ClaudePermissionRequest {
        let questions = (1...count).map { i in
            (question: count == 1 ? "Which database?" : "Question \(i)?", header: i == 1 ? "Storage" : "",
             options: [("Postgres", "Relational, **battle tested**", previews ? "CREATE TABLE t (id int);" : nil),
                       ("Spanner", "", previews ? "CREATE TABLE t (id INT64) PRIMARY KEY (id);" : nil),
                       ("Redis", "In memory", nil)],
             multi: multi)
        }
        return ClaudeViewFixtures.request(tool: "AskUserQuestion", input: ClaudeViewFixtures.questionInput(questions))
    }

    func testRendersSingleMultiPreviewAndSeveralQuestions() {
        for req in [request(), request(multi: true), request(previews: true), request(count: 2), request(multi: true, previews: true, count: 3)] {
            XCTAssertTrue(req.isQuestion)
            let host = render(QuestionCard(request: req, palette: p, fontSize: 13, directory: "/tmp") { _ in } onDeny: {},
                              size: CGSize(width: 800, height: 900))
            XCTAssertGreaterThan(host.fittingSize.height, 100)
        }
    }

    func testHeaderChipRenders() {
        let host = render(QuestionHeaderChip(text: "Auth", palette: p), size: CGSize(width: 100, height: 30))
        XCTAssertGreaterThan(host.fittingSize.width, 10)
    }

    func testSingleSelectSubmitsTheLastChosenOption() {
        var answers: [[String: String]] = []
        var skipped = 0
        let w = claudeWindow(QuestionCard(request: request(previews: true), palette: p, fontSize: 13) { answers.append($0) } onDeny: { skipped += 1 },
                             width: 700)
        // The options, then Submit (once enabled) and Skip; the Other field is an AppKit text field.
        XCTAssertEqual(w.controls().count, 4, "three options and Skip; Submit is disabled")
        w.press(0)
        w.press(3)
        w.press(2)
        w.press(3)
        w.press(4)
        XCTAssertEqual(answers, [["Which database?": "Postgres"], ["Which database?": "Redis"]])
        XCTAssertEqual(skipped, 1)
    }

    func testMultiSelectTogglesOptions() {
        var answers: [[String: String]] = []
        let w = claudeWindow(QuestionCard(request: request(multi: true, previews: true), palette: p, fontSize: 13) { answers.append($0) } onDeny: {},
                             width: 700)
        w.press(2)
        w.press(0)
        w.press(3)
        w.press(2) // deselects Redis
        w.press(3)
        XCTAssertEqual(answers, [["Which database?": "Postgres, Redis"], ["Which database?": "Postgres"]])
    }

    func testSubmitWaitsForEveryQuestion() {
        var answers: [[String: String]] = []
        let w = claudeWindow(QuestionCard(request: request(count: 2), palette: p, fontSize: 13) { answers.append($0) } onDeny: {}, width: 700)
        // Q1 options 0-2, Q2 options 3-5, then Submit (once enabled) and Skip.
        w.press(0)
        XCTAssertEqual(w.controls().count, 7, "Submit stays disabled until both are answered")
        XCTAssertTrue(answers.isEmpty, "Submit is disabled until both are answered")
        w.press(4)
        w.press(6)
        XCTAssertEqual(answers, [["Question 1?": "Postgres", "Question 2?": "Spanner"]])
    }

    func testTypedOtherAnswerReplacesTheChoice() throws {
        var answers: [[String: String]] = []
        let w = claudeWindow(QuestionCard(request: request(), palette: p, fontSize: 13) { answers.append($0) } onDeny: {}, width: 700)
        w.press(0)
        w.type("CockroachDB", into: try XCTUnwrap(w.subview(NSTextField.self)))
        w.press(3)
        XCTAssertEqual(answers, [["Which database?": "CockroachDB"]])
    }

    func testTypedOtherAnswerJoinsChoicesInMultiSelect() throws {
        var answers: [[String: String]] = []
        let w = claudeWindow(QuestionCard(request: request(multi: true), palette: p, fontSize: 13) { answers.append($0) } onDeny: {}, width: 700)
        w.press(1)
        w.type("SQLite", into: try XCTUnwrap(w.subview(NSTextField.self)))
        w.press(3)
        XCTAssertEqual(answers, [["Which database?": "Spanner, SQLite"]])
    }

    func testChoosingAnOptionAfterTypingClearsTheTypedAnswer() throws {
        var answers: [[String: String]] = []
        let w = claudeWindow(QuestionCard(request: request(), palette: p, fontSize: 13) { answers.append($0) } onDeny: {}, width: 700)
        w.type("Mongo", into: try XCTUnwrap(w.subview(NSTextField.self)))
        w.press(1)
        w.press(3)
        XCTAssertEqual(answers, [["Which database?": "Spanner"]])
    }

    func testHoveringAnOptionShowsItsPreview() {
        let w = claudeWindow(QuestionCard(request: request(previews: true), palette: p, fontSize: 13) { _ in } onDeny: {}, width: 700)
        w.window.acceptsMouseMovedEvents = true
        for y in stride(from: 20.0, to: w.size.height - 30, by: 6) { w.hover(x: 60, y: y) }
        w.hover(x: 600, y: 5)
        XCTAssertGreaterThan(w.host.fittingSize.height, 100)
    }
}
