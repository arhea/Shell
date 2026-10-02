import AppKit
import SwiftUI
import XCTest
@testable import Shell

private typealias F = ClaudeViewFixtures

final class ClaudeInsightsFormattingTests: XCTestCase {
    func testDurationsAndTokens() {
        XCTAssertEqual(ClaudeFormat.duration(6.4), "6s")
        XCTAssertEqual(ClaudeFormat.duration(161), "2m 41s")
        XCTAssertEqual(ClaudeFormat.duration(242), "4m 02s")
        XCTAssertEqual(ClaudeFormat.duration(3900), "1h 5m")
        XCTAssertEqual(ClaudeFormat.preciseDuration(41.23), "41.2s")
        XCTAssertEqual(ClaudeFormat.preciseDuration(90), "1m 30s")
        XCTAssertEqual(ClaudeFormat.tokens(999), "999")
        XCTAssertEqual(ClaudeFormat.tokens(18_200), "18.2k")
        XCTAssertEqual(ClaudeFormat.tokens(143_000), "143k")
        XCTAssertEqual(ClaudeFormat.tokens(1_000_000), "1M")
        XCTAssertEqual(ClaudeFormat.tokens(1_500_000), "1.5M")
    }

    func testContextWindow() {
        XCTAssertEqual(ClaudeContextWindow.size(model: nil), 200_000)
        XCTAssertEqual(ClaudeContextWindow.size(model: "claude-sonnet-4-5"), 200_000)
        XCTAssertEqual(ClaudeContextWindow.size(model: "claude-sonnet-4-5[1m]"), 1_000_000)
        XCTAssertEqual(ClaudeContextWindow.size(model: "claude-opus-5"), 1_000_000)
        XCTAssertEqual(ClaudeContextWindow.size(model: "claude-opus-4-1"), 200_000)
        XCTAssertEqual(ClaudeContextWindow.size(model: "default", description: "Opus 5 with 1M context · Best for…"), 1_000_000)
        XCTAssertEqual(ClaudeContextWindow.size(model: "sonnet", inUse: 250_000), 1_000_000, "it can't be smaller than what's in use")
    }

    func testActivityLabels() {
        XCTAssertEqual(ClaudeActivity.label(tool: "Read", input: ["file_path": "/a/StreamWriter.swift"]), "Reading StreamWriter.swift")
        XCTAssertEqual(ClaudeActivity.label(tool: "Bash", input: ["command": "make", "description": "Run the tests"]), "Run the tests")
        XCTAssertEqual(ClaudeActivity.label(tool: "Bash", input: ["command": "swift build\nswift test"]), "Running swift build")
        XCTAssertEqual(ClaudeActivity.label(tool: "Grep", input: ["pattern": "TODO"]), "Searching TODO")
        XCTAssertEqual(ClaudeActivity.label(tool: "Task", input: ["subagent_type": "code-reviewer"]), "Running code-reviewer")
        XCTAssertEqual(ClaudeActivity.label(tool: "mcp__github__get_pr", input: [:]), "Using github · get_pr")
    }
}

final class ClaudeOutputTests: XCTestCase {
    func testStripsANSIAndCountsLines() {
        XCTAssertEqual(ClaudeOutput.stripANSI("\u{1B}[32m** TEST SUCCEEDED **\u{1B}[0m\u{1B}]0;title\u{07}"), "** TEST SUCCEEDED **")
        XCTAssertEqual(ClaudeOutput.lineCount(""), 0)
        XCTAssertEqual(ClaudeOutput.lineCount("a\nb\n"), 2)
        XCTAssertEqual(ClaudeOutput.lineCount("a\nb"), 2)
        XCTAssertEqual(ClaudeOutput.lines("a\n\nb\n\n").count, 3)
    }

    func testExitCodeCommitAndPullRequest() {
        XCTAssertEqual(ClaudeOutput.exitCode("Exit code 2\nmake: *** [all] Error 2"), 2)
        XCTAssertNil(ClaudeOutput.exitCode("fine"))
        XCTAssertEqual(ClaudeOutput.commit(command: "git commit -m x", output: "[bug/38-sigpipe 74c838fa] fix: x\n 3 files changed"), "74c838f")
        XCTAssertEqual(ClaudeOutput.commit(command: "git add . && git commit -m x", output: "[main (root-commit) abcdef1] init"), "abcdef1")
        XCTAssertNil(ClaudeOutput.commit(command: "cat log", output: "[main 74c838f] x"), "only commands that commit")
        let pr = ClaudeOutput.pullRequest(command: "gh pr create --fill", output: "Creating pull request\nhttps://github.com/arhea/Shell/pull/39\n")
        XCTAssertEqual(pr?.number, 39)
        XCTAssertEqual(pr?.url.absoluteString, "https://github.com/arhea/Shell/pull/39")
        XCTAssertNil(ClaudeOutput.pullRequest(command: "gh pr view 39", output: "https://github.com/arhea/Shell/pull/39"))
    }

    func testTestSummaries() {
        XCTAssertEqual(ClaudeOutput.testSummary("Executed 210 tests, with 0 failures (0 unexpected) in 38.6 s"), "210 passed")
        XCTAssertEqual(ClaudeOutput.testSummary("Executed 5 tests\nExecuted 211 tests, with 1 failure (0 unexpected)"), "1 of 211 failed")
        XCTAssertEqual(ClaudeOutput.testSummary("Tests:       2 failed, 40 passed, 42 total"), "2 of 42 failed")
        XCTAssertEqual(ClaudeOutput.testSummary("Tests:       40 passed, 40 total"), "40 passed")
        XCTAssertEqual(ClaudeOutput.testSummary("===== 12 passed in 0.3s ====="), "12 passed")
        XCTAssertEqual(ClaudeOutput.testSummary("===== 1 failed, 12 passed in 0.3s ====="), "1 of 13 failed")
        XCTAssertNil(ClaudeOutput.testSummary("Build complete"))
    }

    func testLogExcerptCentersOnTheFirstErrorAndDropsGitHubPrefixes() {
        var log = (1...40).map { "build\tRun tests\t2026-01-01T00:00:00.0000000Z noise \($0)" }
        log.insert("build\tRun tests\t2026-01-01T00:00:00.0000000Z Foo.swift:48: error: XCTAssertEqual failed", at: 20)
        let excerpt = ClaudeOutput.logExcerpt(log.joined(separator: "\n"), maxLines: 5)
        XCTAssertEqual(excerpt.count, 5)
        XCTAssertEqual(excerpt[0].text, "noise 20")
        XCTAssertTrue(excerpt[1].isError)
        XCTAssertEqual(excerpt[1].text, "Foo.swift:48: error: XCTAssertEqual failed")
        let tail = ClaudeOutput.logExcerpt((1...30).map { "line \($0)" }.joined(separator: "\n"), maxLines: 3)
        XCTAssertEqual(tail.map(\.text), ["line 28", "line 29", "line 30"], "without errors, the end")
        XCTAssertTrue(ClaudeOutput.logExcerpt("\n \n").isEmpty)
    }

    func testStepMeta() {
        XCTAssertEqual(ClaudeStepMeta.meta(tool: "Read", input: [:], result: "1\ta\n2\tb\n3\tc", isError: false), "L1–3")
        XCTAssertEqual(ClaudeStepMeta.meta(tool: "Read", input: ["offset": 10, "limit": 20], result: "x", isError: false), "L10–29")
        XCTAssertEqual(ClaudeStepMeta.meta(tool: "Grep", input: [:], result: "No matches found", isError: false), "0 matches")
        XCTAssertEqual(ClaudeStepMeta.meta(tool: "Grep", input: [:], result: "Found 3 files\na\nb\nc", isError: false), "3 files")
        XCTAssertEqual(ClaudeStepMeta.meta(tool: "Glob", input: [:], result: "a\nb", isError: false), "2 files")
        XCTAssertEqual(ClaudeStepMeta.meta(tool: "Bash", input: [:], result: "a\nb\nc\nd\ne", isError: false), "5 lines")
        XCTAssertEqual(ClaudeStepMeta.meta(tool: "Bash", input: [:], result: "Exit code 1\nboom", isError: true), "exit 1")
        XCTAssertEqual(ClaudeStepMeta.meta(tool: "Bash", input: ["run_in_background": true], result: "started", isError: false), "background")
        XCTAssertNil(ClaudeStepMeta.meta(tool: "Read", input: [:], result: "denied", isError: true))
        XCTAssertNil(ClaudeStepMeta.meta(tool: "WebFetch", input: [:], result: "page", isError: false))
    }

    func testDiffStatsPreferTheStructuredPatch() {
        let structured: [String: Any] = ["structuredPatch": [["lines": [" a", "-b", "+c", "+d"]], ["lines": ["+e"]]]]
        XCTAssertEqual(ClaudeStepMeta.diffStats(tool: "Edit", input: [:], structured: structured), ClaudeDiffStats(added: 3, removed: 1))
        XCTAssertEqual(ClaudeStepMeta.diffStats(tool: "Edit", input: ["old_string": "a\nb", "new_string": "a\nc\nd"], structured: nil),
                       ClaudeDiffStats(added: 2, removed: 1))
        XCTAssertEqual(ClaudeStepMeta.diffStats(tool: "MultiEdit", input: ["edits": [["old_string": "x", "new_string": "y"],
                                                                                   ["old_string": "", "new_string": "z"]]], structured: nil)?.added, 2)
        XCTAssertEqual(ClaudeStepMeta.diffStats(tool: "Write", input: ["content": "1\n2\n3\n"], structured: nil), ClaudeDiffStats(added: 3, removed: 0))
        XCTAssertNil(ClaudeStepMeta.diffStats(tool: "Read", input: [:], structured: nil))
    }

    func testCheckFailureNaming() {
        let job = CheckJob(id: "1", name: "Build and test", workflow: "Test · test.yml", state: .failed, duration: 242,
                           steps: [.init(name: "Checkout", state: .passed), .init(name: "Run tests", state: .failed)])
        let f = ClaudeCheckFailure(job: job, log: "Executed 211 tests, with 1 failure (0 unexpected)", headSHA: "74c838f")
        XCTAssertEqual(f.workflowName, "Test")
        XCTAssertEqual(f.title, "Test / Build and test")
        XCTAssertEqual(f.failedStep, "Run tests")
        XCTAssertEqual(f.slug, "build-and-test")
        XCTAssertEqual(CheckFailureCard.subtitle(f), "Test workflow · 74c838f · 4m 02s")
        XCTAssertEqual(CheckFailureCard.failureLine(f), "Failed at step Run tests · 1 of 211 tests failed")
        let bare = ClaudeCheckFailure(job: CheckJob(id: "2", name: "lint", state: .failed, detail: "3 warnings"), log: "")
        XCTAssertEqual(bare.title, "lint")
        XCTAssertEqual(CheckFailureCard.failureLine(bare), "3 warnings")
        XCTAssertEqual(CheckFailureCard.subtitle(bare), "")
    }
}

@MainActor
final class ClaudeSessionDataTests: XCTestCase {
    private func event(_ claude: ClaudeCodeSession, _ event: [String: Any], parent: Any = NSNull()) {
        claude.handle(["type": "stream_event", "parent_tool_use_id": parent, "event": event])
    }

    func testThinkingAndToolsAreTimed() {
        let claude = F.session()
        F.thinking(claude, "hmm", finished: true)
        let thinking = try? XCTUnwrap(claude.items.last)
        XCTAssertNotNil(thinking?.endedAt)
        XCTAssertNotNil(thinking?.duration)
        F.tool(claude, id: "t1", name: "Bash", input: ["command": "ls"])
        let tool = claude.items.last
        XCTAssertNil(tool?.endedAt)
        F.toolResult(claude, id: "t1", content: "a\nb")
        XCTAssertNotNil(tool?.endedAt)
        XCTAssertEqual(tool?.meta, "2 lines")
        XCTAssertGreaterThanOrEqual(tool?.duration ?? -1, 0)
    }

    func testEditsAreCountedPerFile() {
        let claude = F.session()
        F.tool(claude, id: "e1", name: "Edit", input: ["file_path": "/r/a.swift", "old_string": "a", "new_string": "b\nc"])
        F.toolResult(claude, id: "e1", content: "ok")
        F.tool(claude, id: "e2", name: "Edit", input: ["file_path": "/r/a.swift", "old_string": "x", "new_string": "y"])
        F.toolResult(claude, id: "e2", content: "ok")
        F.tool(claude, id: "w1", name: "Write", input: ["file_path": "/r/new.swift", "content": "1\n2"])
        F.toolResult(claude, id: "w1", content: "ok", structured: ["type": "create"])
        F.tool(claude, id: "e3", name: "Edit", input: ["file_path": "/r/b.swift", "old_string": "x", "new_string": "y"])
        F.toolResult(claude, id: "e3", content: "String not found", isError: true)
        XCTAssertEqual(claude.changedFiles.map(\.path), ["/r/a.swift", "/r/new.swift"], "failed edits don't count")
        XCTAssertEqual(claude.changedFiles[0].added, 3)
        XCTAssertEqual(claude.changedFiles[0].removed, 2)
        XCTAssertTrue(claude.changedFiles[1].isNew)
        XCTAssertEqual(claude.changedFiles[1].name, "new.swift")
    }

    func testTodosAndActivityLabel() {
        let claude = F.session()
        XCTAssertEqual(claude.activityLabel, "Working")
        F.tool(claude, id: "r", name: "Read", input: ["file_path": "/a/b.swift"])
        XCTAssertEqual(claude.activityLabel, "Reading b.swift")
        F.tool(claude, id: "todo", name: "TodoWrite", input: ["todos": [["content": "Write it", "activeForm": "Writing it", "status": "in_progress"],
                                                                     ["content": "Ship", "activeForm": "", "status": "pending"]]])
        XCTAssertEqual(claude.todos.count, 2)
        XCTAssertEqual(claude.todos[0].status, .inProgress)
        XCTAssertEqual(claude.activityLabel, "Updating the to-dos", "to-dos from outside a running turn don't name it")
        claude.handle(["type": "system", "subtype": "status", "status": "compacting"])
        XCTAssertEqual(claude.activityLabel, "Compacting conversation…")
    }

    func testSubagentProgressAndCompletion() {
        let claude = F.session()
        F.tool(claude, id: "a1", name: "Task", input: ["subagent_type": "code-reviewer", "description": "Review the fix"])
        XCTAssertEqual(claude.backgroundTasks.count, 1)
        var task = claude.backgroundTasks[0]
        XCTAssertEqual(task.title, "code-reviewer")
        XCTAssertEqual(task.kind, .subagent)
        XCTAssertEqual(task.detail, "Review the fix")
        claude.handle(["type": "assistant", "parent_tool_use_id": "a1", "message": ["id": "s1", "content": [
            ["type": "tool_use", "id": "x1", "name": "Read", "input": ["file_path": "/r/StreamWriter.swift"]],
            ["type": "tool_use", "id": "x2", "name": "Read", "input": ["file_path": "/r/A.swift"]],
        ]]])
        task = claude.backgroundTasks[0]
        XCTAssertEqual(task.detail, "Reading A.swift")
        XCTAssertEqual(task.toolSummary, "Read 2")
        XCTAssertEqual(task.toolCallCount, 2)
        XCTAssertTrue(claude.items.allSatisfy { $0.toolID != "x1" }, "a subagent's own tools stay out of the transcript")
        XCTAssertEqual(claude.runningBackgroundTasks.count, 1)
        F.toolResult(claude, id: "a1", content: "Looks good")
        XCTAssertEqual(claude.backgroundTasks[0].status, .completed)
        XCTAssertNotNil(claude.backgroundTasks[0].endedAt)
        XCTAssertGreaterThanOrEqual(claude.backgroundTasks[0].elapsed(), 0)
    }

    func testBackgroundCommandsFollowBashOutputAndKill() {
        let claude = F.session()
        F.tool(claude, id: "b1", name: "Bash", input: ["command": "gh pr checks 39 --watch", "run_in_background": true, "description": "CI · PR #39"])
        XCTAssertEqual(claude.backgroundTasks.first?.kind, .backgroundTask)
        XCTAssertEqual(claude.backgroundTasks.first?.title, "CI · PR #39")
        XCTAssertEqual(claude.backgroundTasks.first?.command, "gh pr checks 39 --watch")
        F.toolResult(claude, id: "b1", content: "Command running in background with ID: bash_1")
        XCTAssertEqual(claude.backgroundTasks[0].status, .running, "launching isn't finishing")
        XCTAssertEqual(claude.backgroundTasks[0].taskID, "bash_1")
        F.tool(claude, id: "o1", name: "BashOutput", input: ["bash_id": "bash_1"])
        F.toolResult(claude, id: "o1", content: "<status>running</status>\n<stdout>lint\tpass\nBuild and test\tpending\n</stdout>")
        XCTAssertEqual(claude.backgroundTasks[0].detail, "Build and test\tpending")
        XCTAssertTrue(claude.backgroundTasks[0].isRunning)
        F.tool(claude, id: "o2", name: "BashOutput", input: ["bash_id": "bash_1"])
        F.toolResult(claude, id: "o2", content: "<status>completed</status><exit_code>1</exit_code>")
        XCTAssertEqual(claude.backgroundTasks[0].status, .failed)

        F.tool(claude, id: "b2", name: "Bash", input: ["command": "npm run dev", "run_in_background": true])
        F.toolResult(claude, id: "b2", content: "Command running in background with ID: bash_2")
        F.tool(claude, id: "k", name: "KillShell", input: ["shell_id": "bash_2"])
        F.toolResult(claude, id: "k", content: "Killed")
        XCTAssertEqual(claude.backgroundTasks[1].title, "npm run dev")
        XCTAssertEqual(claude.backgroundTasks[1].status, .stopped)
    }

    func testTaskNotificationsFinishAsyncAgents() {
        let claude = F.session()
        F.tool(claude, id: "a2", name: "Agent", input: ["description": "Watch CI", "run_in_background": true])
        F.toolResult(claude, id: "a2", content: "Async agent launched", structured: ["agentId": "agent-7"])
        XCTAssertEqual(claude.backgroundTasks[0].taskID, "agent-7")
        claude.handle(["type": "system", "subtype": "task_progress", "task_id": "agent-7", "description": "Checking lint"])
        XCTAssertEqual(claude.backgroundTasks[0].detail, "Checking lint")
        claude.handle(["type": "system", "subtype": "task_notification", "task_id": "agent-7", "status": "completed", "summary": "CI is green"])
        XCTAssertEqual(claude.backgroundTasks[0].status, .completed)
        XCTAssertEqual(claude.backgroundTasks[0].detail, "CI is green")
        claude.handle(["type": "system", "subtype": "task_notification", "task_id": "unknown", "status": "failed"])
    }

    func testResultFinishesForegroundSubagentsAndExitStopsTheRest() {
        let claude = F.session()
        F.tool(claude, id: "a1", name: "Task", input: ["description": "x"])
        F.tool(claude, id: "b1", name: "Bash", input: ["command": "sleep 100", "run_in_background": true])
        claude.handle(["type": "result", "subtype": "success", "is_error": false, "result": "ok"])
        XCTAssertEqual(claude.backgroundTasks.map(\.status), [.completed, .running])
    }

    func testCheckFailureItemAndFixNeedsARunningClaude() {
        let claude = F.session()
        let job = CheckJob(id: "j", name: "Build and test", state: .failed)
        claude.appendCheckFailure(job, log: "error: boom")
        let item = claude.items.last
        XCTAssertEqual(item?.kind, .checkFailure)
        XCTAssertEqual(item?.checkFailure?.job.id, "j")
        XCTAssertEqual(item?.checkFailure?.log, "error: boom")
        XCTAssertFalse(claude.fixCheckFailure(job, log: "error: boom"), "nothing to send to")
        XCTAssertFalse(item?.checkFixRequested ?? true)
        render(ClaudeItemView(item: item!, palette: F.palette, mentions: .init(skills: [], commands: [], mcpServers: [], agents: []),
                              fontSize: 13, session: claude), size: CGSize(width: 700, height: 300))
    }

    func testReviewChangesIsANotification() {
        let claude = F.session()
        let expectation = expectation(forNotification: .shellReviewChanges, object: claude) { note in
            note.userInfo?["path"] as? String == "/r/a.swift"
        }
        claude.requestReviewChanges(path: "/r/a.swift")
        wait(for: [expectation], timeout: 1)
    }

    func testDenyingWithInstructionsShowsThemAndClearsThePrompt() {
        let claude = F.session()
        F.permission(claude, id: "p", tool: "Bash", input: ["command": "rm -rf /"])
        claude.denyWithInstructions(claude.pending[0], "  use trash instead ")
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertEqual(claude.items.last?.kind, .user)
        XCTAssertEqual(claude.items.last?.text, "use trash instead")
        F.permission(claude, id: "q", tool: "Bash", input: ["command": "ls"])
        claude.denyWithInstructions(claude.pending[0], " ")
        XCTAssertTrue(claude.pending.isEmpty)
    }

    func testContextWindowFollowsTheModel() {
        let claude = F.session(arguments: ClaudeArguments(model: "sonnet[1m]", effort: "", permissionMode: "default"))
        XCTAssertEqual(claude.contextWindow, 1_000_000)
        let plain = F.session()
        F.systemInit(plain, model: "claude-haiku-4-5")
        XCTAssertEqual(plain.contextWindow, 200_000)
    }

    func testOutputTokensOnlyCountDuringATurn() {
        let claude = F.session()
        event(claude, ["type": "message_start", "message": ["id": "m1", "usage": ["output_tokens": 5]]])
        event(claude, ["type": "message_delta", "usage": ["output_tokens": 900]])
        XCTAssertEqual(claude.turnOutputTokens, 0, "no turn is running")
        XCTAssertNil(claude.turnStartedAt)
    }
}

@MainActor
final class ClaudeTranscriptRowTests: XCTestCase {
    private func tool(_ name: String, _ input: [String: Any] = [:], result: String? = "ok", error: Bool = false) -> ClaudeItem {
        let i = F.item(.tool, tool: name, input: input, result: result, isError: error)
        if let result, !error { i.diffStats = ClaudeStepMeta.diffStats(tool: name, input: input, structured: nil); _ = result }
        return i
    }

    private func shape(_ rows: [ClaudeTranscript.Row]) -> [String] {
        rows.map {
            switch $0 {
            case .item(let i): i.kind == .tool ? i.toolName : "\(i.kind)"
            case .tools(let items): "tools(\(items.count))"
            case .run(let items): "run(\(items.filter { $0.kind == .tool }.count))"
            case .summary: "summary"
            }
        }
    }

    func testLightStepsRunTogetherWhileEditsAndBuildsStandAlone() {
        let items = [F.item(.user, text: "go"), tool("Grep"), tool("Read"), F.item(.thinking, text: "t"), tool("Bash", ["command": "git log"]),
                     tool("Edit", ["file_path": "/a", "old_string": "a", "new_string": "b"]),
                     tool("Bash", ["command": "xcodebuild test"]),
                     tool("Edit", ["file_path": "/b", "old_string": "a", "new_string": "b"]), tool("Write", ["file_path": "/c", "content": "x"]),
                     F.item(.assistant, text: "done")]
        XCTAssertEqual(shape(ClaudeTranscript.rows(items, mode: .collapsePrevious)),
                       ["user", "run(3)", "Edit", "Bash", "run(2)", "assistant", "summary"])
        XCTAssertEqual(shape(ClaudeTranscript.rows(items, mode: .collapsePrevious, turnRunning: true)).last, "assistant",
                       "the summary waits for the turn to end")
        XCTAssertFalse(shape(ClaudeTranscript.rows(items, mode: .showAll)).contains { $0.hasPrefix("run") })
    }

    func testFinishedTurnsFoldTheirInBetweenText() {
        let items = [F.item(.user, text: "a"), tool("Read"), F.item(.assistant, text: "found it"), tool("Read"), F.item(.assistant, text: "done"),
                     F.item(.user, text: "b"), F.item(.assistant, text: "ok")]
        XCTAssertEqual(shape(ClaudeTranscript.rows(items, mode: .collapsePrevious)), ["user", "tools(3)", "assistant", "user", "assistant"])
        XCTAssertTrue(ClaudeTranscript.isProminentCommand(tool("Bash", ["command": "ls"], result: "x", error: true)))
        XCTAssertFalse(ClaudeTranscript.isProminentCommand(tool("Bash", ["command": "ls -la"])))
    }

    func testFoldSummariesNameCommitsAndPullRequests() {
        let commit = tool("Bash", ["command": "git commit -m x"], result: "[main 74c838f] x")
        let pr = tool("Bash", ["command": "gh pr create"], result: "https://github.com/o/r/pull/39")
        let work = ClaudeWork([commit, pr, tool("Task", ["description": "review"])])
        XCTAssertEqual(work.commits, ["74c838f"])
        XCTAssertEqual(work.pullRequests.first?.number, 39)
        XCTAssertEqual(ToolGroupView.details(work), "3 tool calls · Bash 2 · Task · 1 subagent · committed 74c838f · opened PR #39")
        XCTAssertEqual(TurnSummaryCard.title(work), "Opened PR #39")
        XCTAssertTrue(ClaudeTranscript.hasChanges(commit))
        XCTAssertEqual(ToolGroupView.headline(ClaudeWork([])), "Worked")
        XCTAssertEqual(ToolRunCard.title([tool("Read"), tool("Grep")]), "Explored the code")
        XCTAssertEqual(ToolRunCard.title([tool("Edit", ["file_path": "/a"]), tool("Write", ["file_path": "/b"])]), "Edited 2 files")
        XCTAssertEqual(ToolRunCard.title([tool("Bash"), tool("Bash")]), "Ran 2 commands")
        XCTAssertEqual(ToolRunCard.title([tool("WebSearch"), tool("WebFetch")]), "Searched the web")
    }

    func testCardsRender() {
        let p = F.palette
        let edit = tool("Edit", ["file_path": "/tmp/a.swift", "old_string": "a\nb", "new_string": "a\nc"])
        let bash = tool("Bash", ["command": "make test"], result: "Exit code 2\nerror: boom", error: true)
        let items = [F.item(.user, text: "go"), edit, bash, tool("Bash", ["command": "git commit -m x"], result: "[main 74c838f] x")]
        for view in [AnyView(ToolRunCard(items: [tool("Read", ["file_path": "/tmp/a.swift"]), F.item(.thinking, text: "hm"), tool("Grep", ["pattern": "x", "path": "/tmp"])],
                                         palette: p, fontSize: 13, directory: "/tmp")),
                     AnyView(EditCard(item: edit, palette: p, fontSize: 13, directory: "/tmp")),
                     AnyView(BashCard(item: bash, palette: p, fontSize: 13, directory: "/tmp")),
                     AnyView(TurnSummaryCard(items: items, palette: p, fontSize: 13)),
                     AnyView(ToolGroupView(items: Array(items.dropFirst()), palette: p, mentions: .init(skills: [], commands: [], mcpServers: [], agents: []),
                                           fontSize: 13, expanded: true))] {
            XCTAssertGreaterThan(render(view, size: CGSize(width: 800, height: 600)).fittingSize.height, 20)
        }
        XCTAssertEqual(EditCard.unifiedText(ClaudeDiff.diff(old: "a\nb", new: "a\nc")), " a\n-b\n+c")
    }
}

@MainActor
final class ClaudeComposerAndCardHelperTests: XCTestCase {
    func testAlwaysAllowLabels() {
        let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "gh pr merge:*"]], "destination": "localSettings"]
        XCTAssertTrue(PermissionCard.alwaysParts([rule]) == ("Always allow", "gh pr merge", "in this repo"))
        let mode: [String: Any] = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        XCTAssertTrue(PermissionCard.alwaysParts([mode]) == ("Allow all edits", nil, "during this session"))
        XCTAssertTrue(PermissionCard.alwaysParts([["type": "addRules"]]) == ("Always allow", nil, ""))
        XCTAssertEqual(PermissionCard.title(F.request(tool: "Bash", input: [:])), "Claude wants to run a command")
        XCTAssertEqual(PermissionCard.title(F.request(tool: "Edit", input: ["file_path": "/a/b.swift"])), "Claude wants to edit b.swift")
        XCTAssertEqual(PermissionCard.title(F.request(tool: "mcp__github__merge", input: [:])), "Claude wants to use github · merge")
    }

    func testWaitingHints() {
        XCTAssertEqual(ClaudeActivityLine.waitingHint(F.request(tool: "Bash", input: [:], suggestions: [["type": "addRules"]])),
                       "Press 1, 2 or 3, or type different instructions")
        XCTAssertEqual(ClaudeActivityLine.waitingTitle(F.request(tool: "ExitPlanMode", input: ["plan": "p"])), "Review Claude's plan")
        XCTAssertEqual(ClaudeActivityLine.progress(elapsed: 161, tokens: 18_200), "2m 41s · ↓ 18.2k tokens")
        XCTAssertEqual(ClaudeActivityLine.progress(elapsed: 3, tokens: 0), "3s")
    }

    func testCodeBlockFileNamesAndSnippets() throws {
        XCTAssertTrue(CodeBlockView.split("bash:repro.sh") == ("bash", "repro.sh"))
        XCTAssertTrue(CodeBlockView.split("swift") == ("swift", nil))
        XCTAssertEqual(MarkdownBlock.parse("```bash repro-sigpipe.sh\necho hi\n```"), [.code(language: "bash:repro-sigpipe.sh", code: "echo hi", closed: true)])
        XCTAssertEqual(MarkdownBlock.parse("```ts title=\"a.ts\"\nx\n```"), [.code(language: "ts:a.ts", code: "x", closed: true)])
        XCTAssertEqual(MarkdownBlock.parse("```ts {1,2}\nx\n```"), [.code(language: "ts", code: "x", closed: true)])
        XCTAssertEqual(CodeBlockView.fileExtension("python"), "py")
        XCTAssertEqual(CodeBlockView.fileExtension(""), "txt")
        XCTAssertTrue(ClaudeTerminalLauncher.isShell("Bash"))
        XCTAssertFalse(ClaudeTerminalLauncher.isShell("swift"))
        XCTAssertEqual(ClaudeTerminalLauncher.command(for: "  ls -la \n", language: "sh"), "ls -la")
        XCTAssertNil(ClaudeTerminalLauncher.command(for: " ", language: "sh"))
        let script = try XCTUnwrap(ClaudeTerminalLauncher.command(for: "cd /tmp\nls", language: "zsh"))
        XCTAssertTrue(script.hasPrefix("zsh "))
        let path = String(script.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "cd /tmp\nls\n")
        render(CodeBlockView(language: "bash:run.sh", code: "echo 1\necho 2", palette: F.palette, directory: "/tmp"))
    }

    func testBeginTokenStartsMentionsAndCommands() {
        let claude = F.session()
        let model = ClaudeComposerModel()
        let w = claudeWindow(ClaudeComposerField(claude: claude, model: model, palette: F.palette, fontSize: 13, onExit: {}, onFocus: {}), width: 500, height: 60)
        _ = w
        let tv = model.textView!
        model.beginToken("@")
        XCTAssertEqual(tv.string, "@")
        tv.string = "fix"
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        model.beginToken("@")
        XCTAssertEqual(tv.string, "fix @")
        model.beginToken("/")
        XCTAssertEqual(tv.string, "fix @\n/", "a command starts its own line")
        XCTAssertEqual(ClaudeComposerField.placeholder(started: true), "Reply to Claude…")
    }
}
