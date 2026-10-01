import XCTest
@testable import Shell

/// Drives `ClaudeCodeSession.handle(_:)` with stream-json fixtures, without a
/// `claude` process, and checks the transcript and session state.
@MainActor
final class ClaudeCodeSessionTests: XCTestCase {
    private var events: [(String, String?)] = []

    private func makeSession(_ arguments: ClaudeArguments = ClaudeArguments()) -> ClaudeCodeSession {
        let session = ClaudeCodeSession(request: ClaudeLaunchRequest(directory: NSTemporaryDirectory(), binary: "/usr/bin/false",
                                                                     arguments: arguments, environment: [:]))
        events = []
        session.onEvent = { [weak self] event, message in self?.events.append((event, message)) }
        return session
    }

    private func stream(_ session: ClaudeCodeSession, _ event: [String: Any], parent: Any = NSNull()) {
        session.handle(["type": "stream_event", "parent_tool_use_id": parent, "event": event])
    }

    private func controlResponse(_ session: ClaudeCodeSession, id: String, response: [String: Any]? = nil, error: String? = nil) {
        var body: [String: Any] = ["subtype": error == nil ? "success" : "error", "request_id": id]
        if let response { body["response"] = response }
        if let error { body["error"] = error }
        session.handle(["type": "control_response", "response": body])
    }

    // MARK: Streaming

    func testStreamedBlocksBuildTheTranscriptOnce() {
        let claude = makeSession()
        stream(claude, ["type": "message_start", "message": ["id": "m1"]])
        stream(claude, ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking"]])
        XCTAssertEqual(claude.items.last?.isRunning, true, "thinking shows as running while it streams")
        stream(claude, ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Let me "]])
        stream(claude, ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "look."]])
        stream(claude, ["type": "content_block_stop", "index": 0])
        // An empty thinking block disappears when it ends.
        stream(claude, ["type": "content_block_start", "index": 1, "content_block": ["type": "thinking"]])
        stream(claude, ["type": "content_block_stop", "index": 1])
        stream(claude, ["type": "content_block_start", "index": 2, "content_block": ["type": "text"]])
        stream(claude, ["type": "content_block_delta", "index": 2, "delta": ["type": "text_delta", "text": "Hello "]])
        stream(claude, ["type": "content_block_delta", "index": 2, "delta": ["type": "text_delta", "text": "world"]])
        stream(claude, ["type": "content_block_delta", "index": 2, "delta": ["type": "signature_delta", "signature": "x"]])
        stream(claude, ["type": "content_block_stop", "index": 2])
        stream(claude, ["type": "content_block_start", "index": 3, "content_block": ["type": "tool_use", "id": "t1", "name": "Bash"]])
        stream(claude, ["type": "content_block_start", "index": 4, "content_block": ["type": "redacted_thinking"]])
        // Malformed or unknown events are ignored.
        stream(claude, ["type": "content_block_delta", "index": 9, "delta": ["type": "text_delta", "text": "lost"]])
        stream(claude, ["type": "content_block_start", "content_block": ["type": "text"]])
        stream(claude, ["type": "content_block_stop", "index": 9])
        stream(claude, ["type": "message_delta"])

        XCTAssertEqual(claude.items.map(\.kind), [.thinking, .assistant, .tool])
        XCTAssertEqual(claude.items[0].text, "Let me look.")
        XCTAssertFalse(claude.items[0].isRunning)
        XCTAssertEqual(claude.items[1].text, "Hello world")
        XCTAssertEqual(claude.items[2].toolName, "Bash")
        XCTAssertTrue(claude.items[2].isRunning)
        XCTAssertTrue(claude.hasStarted)

        // The full message repeats the streamed text: only the tool input and usage are new.
        claude.handle(["type": "assistant", "parent_tool_use_id": NSNull(), "message": [
            "id": "m1", "model": "claude-opus-5-5",
            "usage": ["input_tokens": 10, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 3000, "output_tokens": 7],
            "content": [
                ["type": "thinking", "thinking": "Let me look."],
                ["type": "text", "text": "Hello world"],
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls -la\n| wc -l"]],
            ],
        ]])
        XCTAssertEqual(claude.items.count, 3)
        XCTAssertEqual(claude.items[2].summary, "ls -la | wc -l")
        XCTAssertEqual(claude.items[2].input["command"] as? String, "ls -la\n| wc -l")
        XCTAssertEqual(claude.contextTokens, 3210)
        XCTAssertEqual(claude.resolvedModel, "claude-opus-5-5")
        XCTAssertEqual(claude.modelTitle, "Opus 5.5")
    }

    func testSubagentStreamAndMessagesStayOutOfTheTranscript() {
        let claude = makeSession()
        stream(claude, ["type": "content_block_start", "index": 0, "content_block": ["type": "text"]], parent: "toolu_parent")
        claude.handle(["type": "assistant", "parent_tool_use_id": "toolu_parent",
                       "message": ["id": "sub", "content": [["type": "text", "text": "subagent text"]]]])
        XCTAssertTrue(claude.items.isEmpty)
        XCTAssertFalse(claude.hasStarted)
    }

    func testUnstreamedAssistantMessagesAppendTextAndThinking() {
        let claude = makeSession()
        claude.handle(["type": "assistant", "message": [
            "id": "m2", "model": "<synthetic>",
            "usage": ["input_tokens": 0],
            "content": [
                ["type": "thinking", "thinking": "Considering"],
                ["type": "thinking", "thinking": ""],
                ["type": "text", "text": ""],
                ["type": "text", "text": "Answer"],
                ["type": "server_tool_use", "name": "WebSearch", "input": ["query": "swift 6"]],
                ["type": "tool_use"],
                ["type": "image"],
            ],
        ]])
        XCTAssertEqual(claude.items.map(\.kind), [.thinking, .assistant, .tool, .tool])
        XCTAssertEqual(claude.items[1].text, "Answer")
        XCTAssertEqual(claude.items[2].summary, "swift 6")
        XCTAssertEqual(claude.items[3].toolName, "Tool", "a tool block without a name still shows")
        XCTAssertNil(claude.resolvedModel, "synthetic messages don't change the model")
        XCTAssertNil(claude.contextTokens, "zero usage is ignored")

        // The result repeats the turn's text, so it isn't shown again…
        claude.handle(["type": "result", "subtype": "success", "result": "Answer"])
        XCTAssertEqual(claude.items.count, 4)
    }

    func testLocalCommandResultIsShownWhenTheTurnHadNoText() {
        // …but a local slash command (/cost, /context) only answers with a result.
        let claude = makeSession()
        claude.handle(["type": "result", "subtype": "success", "result": "Total cost: $0.01"])
        XCTAssertEqual(claude.items.map(\.kind), [.assistant])
        XCTAssertEqual(claude.items.last?.text, "Total cost: $0.01")
    }

    // MARK: Tool results

    func testToolResultsCompleteTheirToolCalls() {
        let claude = makeSession()
        claude.handle(["type": "assistant", "message": ["id": "m", "content": [
            ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "make"]],
            ["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": NSHomeDirectory() + "/notes.txt"]],
        ]]])
        XCTAssertEqual(claude.items[1].summary, "~/notes.txt")
        claude.handle(["type": "user", "parent_tool_use_id": NSNull(), "message": ["content": [
            ["type": "text", "text": "ignored"],
            ["type": "tool_result", "tool_use_id": "t1", "is_error": true,
             "content": [["type": "text", "text": "make: *** No rule"], ["type": "image"], ["type": "other"]]],
            ["type": "tool_result", "tool_use_id": "unknown", "content": "nobody asked"],
            ["type": "tool_result", "content": "no id"],
        ]]])
        XCTAssertEqual(claude.items[0].result, "make: *** No rule\n[image]")
        XCTAssertTrue(claude.items[0].isError)
        XCTAssertFalse(claude.items[0].isRunning)
        XCTAssertTrue(claude.items[1].isRunning, "only the answered call finishes")

        // Subagent results still complete the call; a message without blocks is ignored.
        claude.handle(["type": "user", "parent_tool_use_id": "t9", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t2", "content": String(repeating: "a", count: ClaudeCodeSession.maxStoredText + 10)],
        ]]])
        claude.handle(["type": "user", "message": ["content": "plain prompt"]])
        claude.handle(["type": "user"])
        XCTAssertFalse(claude.items[1].isRunning)
        XCTAssertFalse(claude.items[1].isError)
        XCTAssertTrue(claude.items[1].result?.hasSuffix("more not shown)") == true, "long output is capped")
        XCTAssertEqual(claude.items.count, 2)
    }

    func testAskUserQuestionResultsRecordAnswers() {
        let claude = makeSession()
        let questions: [String: Any] = ["questions": [["question": "Which DB?", "header": "DB", "options": [["label": "Spanner"]]],
                                                      ["question": "Why?", "header": "Why", "options": []]]]
        claude.handle(["type": "assistant", "message": ["id": "m", "content": [
            ["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": questions],
            ["type": "tool_use", "id": "q2", "name": "AskUserQuestion", "input": questions],
            ["type": "tool_use", "id": "q3", "name": "AskUserQuestion", "input": questions],
        ]]])
        XCTAssertEqual(claude.items[0].summary, "2 questions")
        claude.handle(["type": "user", "tool_use_result": ["answers": ["Which DB?": "Spanner"]],
                       "message": ["content": [["type": "tool_result", "tool_use_id": "q1", "content": "ok"]]]])
        claude.handle(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "q2", "content": #"User has answered your questions: "Why?"="Scale"."#],
            ["type": "tool_result", "tool_use_id": "q3", "is_error": true, "content": #""Why?"="ignored""#],
        ]]])
        XCTAssertEqual(claude.items[0].answers, ["Which DB?": "Spanner"])
        XCTAssertEqual(claude.items[1].answers, ["Why?": "Scale"])
        XCTAssertNil(claude.items[2].answers, "a rejected question has no answers")
    }

    // MARK: Results

    func testSuccessfulResultEndsTheTurn() {
        let claude = makeSession()
        stream(claude, ["type": "message_start", "message": ["id": "m1"]])
        stream(claude, ["type": "content_block_start", "index": 0, "content_block": ["type": "text"]])
        stream(claude, ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Done."]])
        stream(claude, ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "t1", "name": "Edit"]])
        let long = String(repeating: "x", count: 300)
        claude.handle(["type": "result", "subtype": "success", "is_error": false, "result": long,
                       "total_cost_usd": 0.42, "duration_ms": 1500.0])
        XCTAssertFalse(claude.isRunning)
        XCTAssertEqual(claude.totalCost, 0.42, accuracy: 0.0001)
        XCTAssertEqual(claude.lastTurnDuration ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertFalse(claude.items[1].isRunning, "running tools stop when the turn ends")
        XCTAssertEqual(claude.items.map(\.kind), [.assistant, .tool], "streamed text isn't repeated")
        XCTAssertEqual(events.last?.0, "finished")
        XCTAssertEqual(events.last?.1?.count, 240, "the notification text is capped")

        claude.handle(["type": "result", "subtype": "success"])
        XCTAssertEqual(events.last?.0, "finished")
        XCTAssertNil(events.last?.1)
    }

    func testFailedResultsShowAnErrorOrInterruption() {
        let claude = makeSession()
        claude.handle(["type": "result", "subtype": "error_during_execution", "is_error": true])
        XCTAssertEqual(claude.items.last?.kind, .notice)
        XCTAssertEqual(claude.items.last?.text, "Interrupted")

        claude.handle(["type": "result", "subtype": "success", "is_error": true, "result": "Request interrupted by user"])
        XCTAssertEqual(claude.items.last?.text, "Interrupted")

        claude.handle(["type": "result", "subtype": "error_max_turns", "errors": ["Reached max turns", "Stopping"]])
        XCTAssertEqual(claude.items.last?.kind, .error)
        XCTAssertEqual(claude.items.last?.text, "Reached max turns\nStopping")

        claude.handle(["type": "result", "subtype": "error_max_budget_usd"])
        XCTAssertEqual(claude.items.last?.text, "error_max_budget_usd")

        claude.handle(["type": "result", "is_error": true, "result": "API Error: 500"])
        XCTAssertEqual(claude.items.last?.text, "API Error: 500")
        XCTAssertNil(claude.login)
        XCTAssertEqual(events.filter { $0.0 == "finished" }.count, 5)
    }

    func testLosingTheSignInAfterATurnShowsAnExpiredSignInCard() {
        let claude = makeSession()
        claude.handle(["type": "result", "subtype": "success", "result": "ok"])
        claude.handle(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in · Please run /login"])
        XCTAssertEqual(claude.login?.expired, true)
        XCTAssertEqual(events.last?.0, "needs-input")
        XCTAssertEqual(events.last?.1, "Sign in to Claude Code to continue")
        XCTAssertFalse(claude.canSend)
        // A second failure doesn't replace the card.
        let card = claude.login
        claude.handle(["type": "result", "subtype": "success", "is_error": true, "result": "Please run /login"])
        XCTAssertTrue(claude.login === card)
        claude.terminate()
    }

    // MARK: System messages

    func testInitAndSystemMessagesUpdateTheSession() {
        let claude = makeSession()
        XCTAssertTrue(claude.isStarting)
        claude.handle(["type": "system", "subtype": "init", "session_id": "S1", "model": "claude-fable-5-1[1m]",
                       "permissionMode": "plan",
                       "mcp_servers": [["name": "github", "status": "connected"], ["name": "linear app", "status": "needs-auth"]],
                       "skills": ["deep-research"], "agents": ["reviewer"],
                       "slash_commands": ["compact", "deep-research"]])
        XCTAssertFalse(claude.isStarting)
        XCTAssertEqual(claude.sessionID, "S1")
        XCTAssertEqual(claude.resolvedModel, "claude-fable-5-1[1m]")
        XCTAssertEqual(claude.permissionMode, .plan)
        XCTAssertEqual(claude.mcpServers.map(\.name), ["github", "linear app"])
        XCTAssertEqual(claude.mcpNeedsAuth.map(\.mention), ["linear-app"])
        XCTAssertEqual(claude.agents, ["reviewer"])
        XCTAssertEqual(claude.commands.map(\.name), ["compact", "deep-research"])
        XCTAssertEqual(claude.skillCommands.map(\.name), ["deep-research"])

        // A later init keeps the session ID when it isn't sent and doesn't replace richer commands.
        claude.handle(["type": "system", "subtype": "commands_changed",
                       "commands": [["name": "review", "description": "Review a PR", "argumentHint": "<pr>"], ["description": "nameless"]]])
        XCTAssertEqual(claude.commands, [ClaudeCommandInfo(name: "review", description: "Review a PR", argumentHint: "<pr>")])
        claude.handle(["type": "system", "subtype": "init", "slash_commands": ["other"], "permissionMode": "bogus"])
        XCTAssertEqual(claude.sessionID, "S1")
        XCTAssertEqual(claude.commands.map(\.name), ["review"])
        XCTAssertEqual(claude.permissionMode, .plan)
        XCTAssertTrue(claude.mcpServers.isEmpty)

        claude.handle(["type": "system", "subtype": "status", "status": "compacting"])
        XCTAssertEqual(claude.statusText, "Compacting conversation…")
        claude.handle(["type": "system", "subtype": "status", "status": NSNull()])
        XCTAssertNil(claude.statusText)
        claude.handle(["type": "system", "subtype": "api_retry"])
        XCTAssertEqual(claude.statusText, "Retrying request…")
        stream(claude, ["type": "message_start"])
        XCTAssertNil(claude.statusText, "a new message clears the status")
        claude.handle(["type": "system", "subtype": "compact_boundary"])
        XCTAssertEqual(claude.items.last?.text, "Conversation compacted")
        claude.handle(["type": "system", "subtype": "hook_response"])
        claude.handle(["type": "keep_alive"])
        XCTAssertEqual(claude.items.count, 1)
    }

    func testRateLimitEventsUpdateUsage() {
        let claude = makeSession()
        let resets = Date().addingTimeInterval(3600).timeIntervalSince1970
        claude.handle(["type": "rate_limit_event",
                       "rate_limit_info": ["status": "allowed_warning", "rateLimitType": "five_hour", "utilization": 0.81, "resetsAt": resets]])
        XCTAssertEqual(ClaudeUsage.shared.limits?.status, "allowed_warning")
        XCTAssertEqual(ClaudeUsage.shared.limits?.fiveHour?.utilization ?? 0, 0.81, accuracy: 0.001)
        claude.handle(["type": "rate_limit_event"])
    }

    // MARK: Permission prompts

    func testControlRequestsQueuePrompts() {
        let claude = makeSession()
        claude.handle(["type": "control_request", "request_id": "r1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "display_name": "Run command",
            "input": ["command": "rm -rf build"], "description": "Clean", "permission_suggestions": [["type": "addRules"]],
            "decision_reason": "Not in allow list", "tool_use_id": "t1",
        ]])
        claude.handle(["type": "control_request", "request_id": "r2", "request": [
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": ["questions": [["question": "Q?", "options": []]]],
        ]])
        claude.handle(["type": "control_request", "request_id": "r3", "request": [
            "subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": ["plan": "# Fix it\n1. Do"],
        ]])
        claude.handle(["type": "control_request", "request_id": "r4", "request": ["subtype": "can_use_tool"]])
        // Requests Shell doesn't support, or that are malformed, never become prompts.
        claude.handle(["type": "control_request", "request_id": "r5", "request": ["subtype": "hook_callback"]])
        claude.handle(["type": "control_request", "request": ["subtype": "can_use_tool"]])

        XCTAssertEqual(claude.pending.map(\.id), ["r1", "r2", "r3", "r4"])
        let bash = claude.pending[0]
        XCTAssertEqual(bash.displayName, "Run command")
        XCTAssertEqual(bash.description, "Clean")
        XCTAssertEqual(bash.reason, "Not in allow list")
        XCTAssertEqual(bash.toolUseID, "t1")
        XCTAssertEqual(bash.suggestions.count, 1)
        XCTAssertFalse(bash.isQuestion || bash.isPlan)
        XCTAssertTrue(claude.pending[1].isQuestion)
        XCTAssertEqual(claude.pending[1].questions.map(\.question), ["Q?"])
        XCTAssertTrue(claude.pending[2].isPlan)
        XCTAssertEqual(claude.pending[2].plan, "# Fix it\n1. Do")
        XCTAssertEqual(claude.pending[3].toolName, "Tool")
        XCTAssertEqual(claude.pending[3].displayName, "Tool")
        XCTAssertEqual(claude.pending[3].plan, "")
        XCTAssertEqual(events.map(\.1), ["Claude wants to use Run command", "Claude has a question",
                                         "Claude has a plan for you to review", "Claude wants to use Tool"])

        claude.handle(["type": "control_cancel_request", "request_id": "r2"])
        claude.handle(["type": "control_cancel_request"])
        XCTAssertEqual(claude.pending.map(\.id), ["r1", "r3", "r4"])

        // Answering removes the prompt (nothing is written without a process).
        claude.respond(claude.pending[0], allow: true, always: true)
        claude.keepPlanning(claude.pending[0], feedback: "  ")
        claude.approvePlan(claude.pending[0], mode: .acceptEdits)
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertEqual(claude.permissionMode, .acceptEdits)

        // A result clears anything still waiting.
        claude.handle(["type": "control_request", "request_id": "r6", "request": ["subtype": "can_use_tool", "tool_name": "Write"]])
        claude.handle(["type": "result", "subtype": "success"])
        XCTAssertTrue(claude.pending.isEmpty)
    }

    func testAnsweringAQuestionRecordsTheAnswersOnItsToolCall() {
        let claude = makeSession()
        claude.handle(["type": "assistant", "message": ["id": "m", "content": [
            ["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": ["questions": [["question": "Which?"]]]],
        ]]])
        claude.handle(["type": "control_request", "request_id": "r1", "request": [
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "q1", "input": [:],
        ]])
        claude.answer(claude.pending[0], answers: ["Which?": "That one"])
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertEqual(claude.items[0].answers, ["Which?": "That one"])
        XCTAssertEqual(claude.items[0].summary, "Which?")
    }

    // MARK: Control responses

    func testControlResponsesRunTheirCallbacks() {
        withSettings({ $0.claudeEffort = "turbo"; $0.claudeModel = "" }) {
            let claude = makeSession()
            XCTAssertEqual(claude.model, "default")
            XCTAssertEqual(claude.effort, "turbo")
            claude.setModel("claude-sonnet-5")   // shell-1; "turbo" isn't a valid effort, so shell-2 clears it
            XCTAssertEqual(claude.model, "claude-sonnet-5")
            XCTAssertEqual(claude.effort, "")
            XCTAssertEqual(SettingsStore.shared.settings.claudeModel, "claude-sonnet-5")
            XCTAssertEqual(SettingsStore.shared.settings.claudeEffort, "")
            controlResponse(claude, id: "shell-1", error: "unknown model")
            XCTAssertEqual(claude.model, "default", "a rejected model switch reverts")
            XCTAssertEqual(claude.items.last?.text, "Couldn't switch model: unknown model")
            controlResponse(claude, id: "shell-2", error: "bad effort")
            XCTAssertEqual(claude.items.last?.text, "Couldn't change effort: bad effort")
            controlResponse(claude, id: "shell-2", error: "again")
            XCTAssertEqual(claude.items.count, 2, "each callback runs once")

            claude.setModel("default")           // shell-3
            XCTAssertEqual(SettingsStore.shared.settings.claudeModel, "")
            controlResponse(claude, id: "shell-3", response: [:])
            XCTAssertEqual(claude.model, "default")

            claude.setPermissionMode(.plan)      // shell-4
            controlResponse(claude, id: "shell-4", response: ["mode": "acceptEdits"])
            XCTAssertEqual(claude.permissionMode, .acceptEdits, "the mode Claude Code reports wins")
            claude.setPermissionMode(.bypassPermissions) // shell-5
            claude.handle(["type": "control_response", "response": ["subtype": "error", "request_id": "shell-5"]])
            XCTAssertEqual(claude.permissionMode, .acceptEdits)
            XCTAssertEqual(claude.items.last?.text, "Couldn't switch to Bypass permissions: error")
            claude.setPermissionMode(.plan)      // shell-6
            controlResponse(claude, id: "shell-6", response: ["other": 1])
            XCTAssertEqual(claude.permissionMode, .plan)
            claude.cyclePermissionMode()         // shell-7
            XCTAssertEqual(claude.permissionMode, .auto, "auto is offered until a model says otherwise")

            // Malformed responses are ignored.
            claude.handle(["type": "control_response"])
            claude.handle(["type": "control_response", "response": ["subtype": "success"]])
            claude.handle(["type": "control_response", "response": ["subtype": "success", "request_id": "shell-99"]])
            XCTAssertEqual(claude.items.count, 3)
            claude.setEffort("")
        }
    }

    func testRemoteControlAndMCPCallbacks() {
        let claude = makeSession()
        claude.setRemoteControl(true)            // shell-1
        XCTAssertTrue(claude.remoteControlBusy)
        claude.setRemoteControl(false)           // ignored while busy
        controlResponse(claude, id: "shell-1", response: ["session_url": "https://claude.ai/code/session_1"])
        XCTAssertFalse(claude.remoteControlBusy)
        XCTAssertEqual(claude.remoteControlURL?.absoluteString, "https://claude.ai/code/session_1")
        claude.setRemoteControl(false)           // shell-2
        controlResponse(claude, id: "shell-2", response: [:])
        XCTAssertNil(claude.remoteControlURL)
        claude.setRemoteControl(true)            // shell-3
        controlResponse(claude, id: "shell-3", error: "Remote Control isn't available")
        XCTAssertEqual(claude.remoteControlError, "Remote Control isn't available")
        XCTAssertNil(claude.remoteControlURL)

        claude.handle(["type": "system", "subtype": "init", "session_id": "S", "mcp_servers": [["name": "github", "status": "needs-auth"]]])
        claude.reconnectMCP("unknown")           // not a server of this session: nothing sent
        claude.reconnectMCP("github")            // shell-4
        controlResponse(claude, id: "shell-4", response: [:]) // then refreshes: shell-5
        controlResponse(claude, id: "shell-5", response: ["mcpServers": [["name": "github", "status": "connected"], ["status": "failed"]]])
        XCTAssertEqual(claude.mcpServers, [ClaudeMCPServer(name: "github", status: "connected"), ClaudeMCPServer(name: "", status: "failed")])
        claude.refreshMCPStatus()                // shell-6
        controlResponse(claude, id: "shell-6", response: [:])
        XCTAssertEqual(claude.mcpServers.count, 2, "a response without a list keeps the statuses")
    }

    // MARK: Derived state

    func testDefaultsComeFromArgumentsThenSettings() {
        withSettings({ $0.claudeModel = "claude-haiku-4-5"; $0.claudeEffort = "low"; $0.claudePermissionMode = "" }) {
            let fromSettings = makeSession()
            XCTAssertEqual(fromSettings.model, "claude-haiku-4-5")
            XCTAssertEqual(fromSettings.modelTitle, "Haiku 4.5")
            XCTAssertEqual(fromSettings.effort, "low")
            XCTAssertEqual(fromSettings.permissionMode, .default)
            XCTAssertEqual(fromSettings.effortLevels, ["low", "medium", "high", "xhigh", "max"])
            XCTAssertTrue(fromSettings.autoModeAvailable)
            XCTAssertEqual(fromSettings.availableModes, [.default, .acceptEdits, .plan, .auto, .dontAsk])

            var args = ClaudeArguments()
            args.model = "opus"
            args.effort = "max"
            args.permissionMode = "bypassPermissions"
            args.passthrough = ["--resume", "7bcc953c-5abd-4120-82da-148001c196cb"]
            let fromArgs = makeSession(args)
            XCTAssertEqual(fromArgs.modelTitle, "Opus")
            XCTAssertEqual(fromArgs.effort, "max")
            XCTAssertEqual(fromArgs.permissionMode, .bypassPermissions)
            XCTAssertTrue(fromArgs.availableModes.contains(.bypassPermissions))
            XCTAssertTrue(fromArgs.hasStarted, "resuming starts with the composer at the bottom")
        }
        withSettings({ $0.claudeModel = "" }) {
            var args = ClaudeArguments()
            args.passthrough = ["--dangerously-skip-permissions", "-c"]
            let claude = makeSession(args)
            XCTAssertEqual(claude.modelTitle, "Default")
            XCTAssertTrue(claude.availableModes.contains(.bypassPermissions))
            XCTAssertTrue(claude.hasStarted)
        }
    }

    func testIdleSessionCantSendOrInterrupt() {
        let claude = makeSession()
        XCTAssertFalse(claude.canSend)
        XCTAssertNil(claude.sessionName)
        XCTAssertEqual(claude.tabTitle, "Claude")
        claude.send("hello")
        claude.interrupt()
        XCTAssertTrue(claude.items.isEmpty)
        XCTAssertNil(claude.statusText)
        XCTAssertTrue(events.isEmpty)
        claude.terminate()
        claude.terminate()
    }

    // MARK: Helpers

    func testTextOfToolResultContent() {
        XCTAssertEqual(ClaudeCodeSession.text(of: "plain"), "plain")
        XCTAssertEqual(ClaudeCodeSession.text(of: [["type": "text", "text": "a"], ["type": "image"], ["type": "x"], ["text": "b"]]), "a\n[image]\nb")
        XCTAssertEqual(ClaudeCodeSession.text(of: 42), "")
        XCTAssertEqual(ClaudeCodeSession.text(of: nil), "")
        XCTAssertEqual(ClaudeCodeSession.capped("short"), "short")
    }

    func testHistoryPromptForBashInputAndEmptyText() {
        XCTAssertNil(ClaudeCodeSession.historyPrompt("   \n"))
        XCTAssertEqual(ClaudeCodeSession.historyPrompt("<bash-input>ls -la</bash-input>"), "! ls -la")
        XCTAssertEqual(ClaudeCodeSession.historyPrompt("<command-name>clear</command-name>"), "/clear")
        XCTAssertNil(ClaudeCodeSession.historyPrompt("<command-name></command-name><bash-input></bash-input>"))
        XCTAssertNil(ClaudeCodeSession.historyPrompt("</command-name>x<command-name>"), "a closing tag before the opening one isn't a command")
    }

    func testWriteInputsAreCappedInMemory() {
        let item = ClaudeItem(kind: .tool)
        item.toolName = "Write"
        item.setInput(["file_path": "/tmp/big.txt", "content": String(repeating: "z", count: ClaudeCodeSession.maxStoredText * 2)])
        XCTAssertEqual((item.input["content"] as? String)?.utf8.count, ClaudeCodeSession.maxStoredText)
        XCTAssertEqual(item.summary, "/tmp/big.txt")
    }
}

/// Labels and formatting used by the native Claude view.
final class ClaudeSessionFormattingTests: XCTestCase {
    func testModelOptionLabelAndDetail() {
        let described = ClaudeModelOption(value: "default", displayName: "Default", description: "Opus 5 with 1M context · Best for complex work",
                                          effortLevels: [], supportsAutoMode: true)
        XCTAssertEqual(described.label, "Opus 5 (1M)")
        XCTAssertEqual(described.detail, "Default · Best for complex work")
        XCTAssertEqual(described.id, "default")

        let byID = ClaudeModelOption(value: "claude-haiku-4-5", displayName: "Haiku", description: "Fastest", effortLevels: [], supportsAutoMode: false)
        XCTAssertEqual(byID.label, "Haiku 4.5")
        XCTAssertEqual(byID.detail, "Fastest")

        let alias = ClaudeModelOption(value: "sonnet", displayName: "Sonnet", description: "Sonnet", effortLevels: [], supportsAutoMode: false)
        XCTAssertEqual(alias.label, "Sonnet")
        XCTAssertEqual(alias.detail, "", "a description that only repeats the label adds nothing")

        let bare = ClaudeModelOption(value: "default", displayName: "", description: "", effortLevels: [], supportsAutoMode: false)
        XCTAssertEqual(bare.label, "default")
        XCTAssertEqual(bare.detail, "Default")
    }

    func testPermissionModeTextAndSymbols() {
        for mode in ClaudePermissionMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.detail.isEmpty)
            XCTAssertFalse(mode.symbol.isEmpty)
            XCTAssertEqual(mode.id, mode.rawValue)
        }
        XCTAssertEqual(ClaudePermissionMode.plan.title, "Plan mode")
        XCTAssertEqual(ClaudePermissionMode.bypassPermissions.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(ClaudePermissionMode.cycle(from: .auto, autoAvailable: true), .default)
        XCTAssertEqual(ClaudePermissionMode.cycle(from: .bypassPermissions, autoAvailable: true), .default, "modes outside the cycle restart it")
    }

    func testToolSummaries() {
        let home = NSHomeDirectory()
        func summary(_ name: String, _ input: [String: Any]) -> String { ClaudeToolFormat.summary(name: name, input: input) }
        XCTAssertEqual(summary("Bash", [:]), "")
        XCTAssertEqual(summary("Edit", ["file_path": home + "/a.swift"]), "~/a.swift")
        XCTAssertEqual(summary("NotebookEdit", ["notebook_path": "/n.ipynb"]), "/n.ipynb")
        XCTAssertEqual(summary("Write", ["file_path": ""]), "")
        XCTAssertEqual(summary("Glob", ["pattern": "**/*.swift"]), "**/*.swift")
        XCTAssertEqual(summary("Grep", ["pattern": "TODO", "path": home + "/src"]), "TODO  in ~/src")
        XCTAssertEqual(summary("Grep", ["pattern": "TODO"]), "TODO")
        XCTAssertEqual(summary("WebFetch", ["url": "https://x.io"]), "https://x.io")
        XCTAssertEqual(summary("WebSearch", ["query": "swift"]), "swift")
        XCTAssertEqual(summary("Task", ["prompt": "Find bugs"]), "Find bugs")
        XCTAssertEqual(summary("Agent", ["description": "Review", "prompt": "p"]), "Review")
        XCTAssertEqual(summary("Skill", ["command": "pdf"]), "pdf")
        XCTAssertEqual(summary("Skill", ["skill": "docx"]), "docx")
        XCTAssertEqual(summary("TodoWrite", ["todos": [1, 2, 3]]), "3 items")
        XCTAssertEqual(summary("TodoWrite", [:]), "0 items")
        XCTAssertEqual(summary("ExitPlanMode", ["plan": "\n## Ship the fix\nsteps"]), "Ship the fix")
        XCTAssertEqual(summary("ExitPlanMode", [:]), "Plan")
        XCTAssertEqual(summary("mcp__github__get_issue", ["owner": String(repeating: "o", count: 200)]).count, 120)
        XCTAssertEqual(summary("mcp__x__y", ["n": 1]), "")
    }

    func testToolNamesSymbolsAndTodos() {
        XCTAssertEqual(ClaudeToolFormat.displayName("mcp__github__get_issue"), "github · get_issue")
        XCTAssertEqual(ClaudeToolFormat.displayName("mcp__a__b__c"), "a · b__c")
        XCTAssertEqual(ClaudeToolFormat.displayName("mcp__solo"), "mcp__solo")
        XCTAssertEqual(ClaudeToolFormat.displayName("Bash"), "Bash")
        let expected = ["Bash": "terminal", "Read": "doc.text", "Write": "doc.badge.plus", "Edit": "pencil", "MultiEdit": "pencil",
                        "Glob": "doc.text.magnifyingglass", "Grep": "magnifyingglass", "WebFetch": "globe", "Task": "person.2",
                        "TodoWrite": "checklist", "Skill": "sparkles", "AskUserQuestion": "questionmark.bubble",
                        "ExitPlanMode": "list.bullet.clipboard", "mcp__x__y": "puzzlepiece.extension", "Custom": "wrench.and.screwdriver"]
        for (name, symbol) in expected { XCTAssertEqual(ClaudeToolFormat.symbol(name), symbol, name) }
        XCTAssertEqual(ClaudeToolFormat.visibleResult("plain"), "plain")
        let todos = ClaudeToolFormat.todos(["todos": [["content": "A", "status": "completed"], ["content": "B", "status": "weird"]]])
        XCTAssertEqual(todos.map(\.status), [.completed, .pending])
        XCTAssertEqual(ClaudeToolFormat.shortPath("/etc/hosts"), "/etc/hosts")
        XCTAssertEqual(ClaudeToolFormat.diff(name: "Write", input: ["content": "a\nb"])?.count, 2)
        XCTAssertNil(ClaudeToolFormat.diff(name: "Bash", input: [:]))
    }
}
