import AppKit
import XCTest
@testable import Shell

/// A stand-in for the `claude` binary: a small shell script in a temporary
/// folder. `auth status` and `auth login` answer from files; a session prints
/// `stdout.jsonl`, records its arguments and appends everything it reads on
/// stdin to `stdin.jsonl`.
private struct FakeClaude {
    let dir: URL
    var binary: String { dir.appendingPathComponent("claude").path }
    var environment: [String: String] {
        ["FAKE_CLAUDE_DIR": dir.path, "PATH": "/usr/bin:/bin", "SHELL_APP_CTL": "/should/not/leak", "SHELL_APP_SESSION": "x"]
    }

    static let script = #"""
    #!/bin/sh
    D="$FAKE_CLAUDE_DIR"
    if [ "$1" = auth ] && [ "$2" = status ]; then
      if [ -f "$D/auth-status.json" ]; then /bin/cat "$D/auth-status.json"; else echo '{"loggedIn":true}'; fi
      exit 0
    fi
    if [ "$1" = auth ] && [ "$2" = login ]; then
      echo "$*" >> "$D/login-args"
      echo "Opening your browser to sign in."
      echo "If it didn't open, visit: https://claude.ai/oauth/authorize?code=true"
      printf 'Paste code here if prompted > '
      read code
      echo "$code" > "$D/login-code"
      if [ -f "$D/login-fail" ]; then echo; echo "Invalid code"; /bin/sleep 0.2; exit 1; fi
      [ -f "$D/login-noop" ] || echo '{"loggedIn":true}' > "$D/auth-status.json"
      exit 0
    fi
    echo "$*" >> "$D/args"
    /bin/pwd -P > "$D/cwd"
    echo "ctl=${SHELL_APP_CTL-unset} session=${SHELL_APP_SESSION-unset} term=$TERM" > "$D/env"
    [ -f "$D/stdout.jsonl" ] && /bin/cat "$D/stdout.jsonl"
    if [ -f "$D/exit-code" ]; then
      [ -f "$D/stderr.txt" ] && /bin/cat "$D/stderr.txt" >&2
      read first; echo "$first" >> "$D/stdin.jsonl"
      read second; echo "$second" >> "$D/stdin.jsonl"
      exit "$(/bin/cat "$D/exit-code")"
    fi
    exec /bin/cat >> "$D/stdin.jsonl"
    """#

    init(dir: URL) throws {
        self.dir = dir
        try Self.script.write(to: dir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    /// Everything the session wrote to the process's stdin, decoded.
    func messages() -> [[String: Any]] {
        read("stdin.jsonl").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func controlRequests(_ subtype: String) -> [[String: Any]] {
        messages().compactMap { msg in
            guard msg["type"] as? String == "control_request", let req = msg["request"] as? [String: Any],
                  req["subtype"] as? String == subtype else { return nil }
            return req
        }
    }

    func controlResponses() -> [[String: Any]] {
        messages().compactMap { $0["type"] as? String == "control_response" ? $0["response"] as? [String: Any] : nil }
    }
}

@MainActor
final class ClaudeCodeSessionProcessTests: XCTestCase {
    private var fake: FakeClaude!
    private var project: URL!
    private var sessions: [ClaudeCodeSession] = []
    private var events: [(String, String?)] = []

    override func setUp() async throws {
        fake = try FakeClaude(dir: try makeTemporaryDirectory())
        project = try makeTemporaryDirectory().appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let config = try makeTemporaryDirectory().appendingPathComponent("claude.json")
        try trustConfig([project.path, project.resolvingSymlinksInPath().path]).write(to: config)
        ClaudeTrust.configURLOverride = config
        ClaudeCodeSession.projectsDirectoryOverride = try makeTemporaryDirectory()
        try fake.write("stdout.jsonl", #"{"type":"system","subtype":"init","session_id":"S1","model":"claude-opus-5"}"# + "\n")
    }

    override func tearDown() async throws {
        for s in sessions { s.terminate() }
        sessions = []
        ClaudeTrust.configURLOverride = nil
        ClaudeCodeSession.projectsDirectoryOverride = nil
    }

    private func trustConfig(_ paths: [String]) throws -> Data {
        let projects = Dictionary(paths.map { ($0, ["hasTrustDialogAccepted": true] as [String: Any]) }, uniquingKeysWith: { a, _ in a })
        return try JSONSerialization.data(withJSONObject: ["projects": projects])
    }

    private func makeSession(_ arguments: ClaudeArguments = ClaudeArguments(), binary: String? = nil) -> ClaudeCodeSession {
        let session = ClaudeCodeSession(request: ClaudeLaunchRequest(directory: project.path, binary: binary ?? fake.binary,
                                                                     arguments: arguments, environment: fake.environment))
        session.onEvent = { [weak self] event, message in self?.events.append((event, message)) }
        sessions.append(session)
        return session
    }

    /// Starts a session and waits for the fake's `init` to arrive through the pipe.
    private func started(_ arguments: ClaudeArguments = ClaudeArguments()) -> ClaudeCodeSession {
        let claude = makeSession(arguments)
        claude.start()
        XCTAssertTrue(waitUntil { claude.sessionID == "S1" }, "the session never started")
        XCTAssertTrue(waitUntil { !fake.controlRequests("initialize").isEmpty })
        return claude
    }

    private func respond(_ claude: ClaudeCodeSession, id: String, _ response: [String: Any]) {
        claude.handle(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
    }

    // MARK: Launching

    func testLaunchPassesFlagsAndAStrippedEnvironment() {
        withSettings({ $0.claudeRemoteControl = false }) {
            var args = ClaudeArguments()
            args.model = "claude-opus-5"
            args.effort = "high"
            args.permissionMode = "plan"
            args.passthrough = ["--add-dir", "../x"]
            let claude = started(args)
            XCTAssertTrue(claude.isLaunched)
            XCTAssertTrue(claude.canSend)
            XCTAssertEqual(claude.resolvedModel, "claude-opus-5")
            XCTAssertEqual(fake.read("args").trimmingCharacters(in: .newlines),
                           "-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages "
                               + "--permission-prompt-tool stdio --model claude-opus-5 --effort high --permission-mode plan --add-dir ../x")
            XCTAssertEqual(fake.read("env").trimmingCharacters(in: .newlines), "ctl=unset session=unset term=xterm-256color",
                           "Shell's hook variables never reach the native session")
            XCTAssertTrue(fake.read("cwd").trimmingCharacters(in: .newlines).hasSuffix(project.path), "runs in the session's folder")
            XCTAssertEqual(fake.messages().first?["request_id"] as? String, "shell-1")

            respond(claude, id: "shell-1", [
                "models": [
                    ["value": "default", "displayName": "Default", "description": "Opus 5 · Most capable", "supportsEffort": true,
                     "supportedEffortLevels": ["low", "high"], "supportsAutoMode": true],
                    ["value": "claude-opus-5", "displayName": "Opus", "description": "Opus 5 · Pinned", "supportsEffort": false],
                ],
                "commands": [["name": "review", "description": "Review", "argumentHint": "<pr>"]],
                "account": ["email": "a@b.c", "subscriptionType": "max"],
                "current_permission_mode": "acceptEdits",
            ])
            XCTAssertFalse(claude.isStarting)
            XCTAssertEqual(claude.models.map(\.value), ["default", "claude-opus-5"])
            XCTAssertEqual(claude.models.first?.effortLevels, ["low", "high"])
            XCTAssertEqual(claude.currentModel?.value, "claude-opus-5")
            XCTAssertEqual(claude.modelTitle, "Opus 5")
            XCTAssertEqual(claude.effortLevels, [], "a model without effort support offers no levels")
            XCTAssertFalse(claude.autoModeAvailable)
            XCTAssertFalse(claude.availableModes.contains(.auto))
            XCTAssertEqual(claude.commands.map(\.name), ["review"])
            XCTAssertEqual(claude.accountLabel, "a@b.c · max")
            XCTAssertEqual(claude.permissionMode, .acceptEdits)
            XCTAssertTrue(fake.controlRequests("remote_control").isEmpty, "Remote Control stays off unless enabled")
        }
    }

    func testDefaultModelAndModeAddNoFlagsAndRemoteControlStartsWhenEnabled() {
        withSettings({ $0.claudeRemoteControl = true; $0.claudeModel = ""; $0.claudeEffort = ""; $0.claudePermissionMode = "" }) {
            let claude = started()
            XCTAssertFalse(fake.read("args").contains("--model"))
            XCTAssertFalse(fake.read("args").contains("--effort"))
            XCTAssertFalse(fake.read("args").contains("--permission-mode"))
            respond(claude, id: "shell-1", [:])
            XCTAssertTrue(waitUntil { fake.controlRequests("remote_control").first?["enabled"] as? Bool == true })
            XCTAssertTrue(claude.remoteControlBusy)
            respond(claude, id: "shell-2", ["session_url": "https://claude.ai/code/abc"])
            XCTAssertEqual(claude.remoteControlURL?.absoluteString, "https://claude.ai/code/abc")
        }
    }

    func testAPromptOnTheCommandLineIsSentRightAway() {
        var args = ClaudeArguments()
        args.prompt = "explain this repo"
        let claude = started(args)
        XCTAssertTrue(waitUntil { fake.messages().contains { $0["type"] as? String == "user" } })
        XCTAssertEqual(claude.items.first?.text, "explain this repo")
        XCTAssertTrue(claude.isRunning)
    }

    // MARK: Sending and answering

    func testSendingWritesUserMessagesAndAnswersPrompts() throws {
        let claude = started()
        let file = project.appendingPathComponent("notes.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let attachment = try XCTUnwrap(ClaudeAttachment.load(file))
        claude.send("  look at this  ", attachments: [attachment])
        claude.send("   ")
        XCTAssertEqual(claude.items.map(\.text), ["look at this"])
        XCTAssertEqual(claude.items.first?.attachments.map(\.name), ["notes.md"])
        XCTAssertTrue(claude.isRunning)
        XCTAssertEqual(events.last?.0, "working")
        XCTAssertTrue(waitUntil { fake.messages().contains { $0["type"] as? String == "user" } })
        let user = try XCTUnwrap(fake.messages().first { $0["type"] as? String == "user" })
        XCTAssertEqual(user["session_id"] as? String, "S1")
        let content = try XCTUnwrap((user["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.last?["text"] as? String, "look at this\n\nAttached: @notes.md")

        // Prompts are answered on stdin.
        func ask(_ id: String, _ tool: String, _ input: [String: Any] = ["command": "make"]) -> ClaudePermissionRequest {
            claude.handle(["type": "control_request", "request_id": id, "request": [
                "subtype": "can_use_tool", "tool_name": tool, "input": input, "permission_suggestions": [["type": "addRules"]],
            ]])
            return claude.pending.first { $0.id == id }!
        }
        claude.respond(ask("r1", "Bash"), allow: true, always: true)
        claude.respond(ask("r2", "Bash"), allow: false)
        claude.answer(ask("r3", "AskUserQuestion", [:]), answers: ["Q": "A"])
        claude.approvePlan(ask("r4", "ExitPlanMode", ["plan": "p"]), mode: .acceptEdits)
        claude.keepPlanning(ask("r5", "ExitPlanMode", ["plan": "p"]), feedback: " smaller steps ")
        claude.handle(["type": "control_request", "request_id": "r6", "request": ["subtype": "mcp_message"]])
        XCTAssertEqual(events.filter { $0.0 == "working" }.count, 6, "each answer reports work resuming")

        XCTAssertTrue(waitUntil { fake.controlResponses().count == 6 })
        let responses = Dictionary(fake.controlResponses().map { ($0["request_id"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        func body(_ id: String) -> [String: Any] { responses[id]?["response"] as? [String: Any] ?? [:] }
        XCTAssertEqual(body("r1")["behavior"] as? String, "allow")
        XCTAssertEqual((body("r1")["updatedPermissions"] as? [Any])?.count, 1)
        XCTAssertEqual((body("r1")["updatedInput"] as? [String: Any])?["command"] as? String, "make")
        XCTAssertEqual(body("r2")["behavior"] as? String, "deny")
        XCTAssertEqual(body("r2")["message"] as? String, "The user doesn't want to proceed with this tool use.")
        XCTAssertEqual((body("r3")["updatedInput"] as? [String: Any])?["answers"] as? [String: String], ["Q": "A"])
        XCTAssertEqual((body("r4")["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String, "acceptEdits")
        XCTAssertEqual(body("r5")["message"] as? String, "The user wants to keep planning. Their feedback on the plan:\n\nsmaller steps")
        XCTAssertEqual(responses["r6"]?["subtype"] as? String, "error")
        XCTAssertEqual(responses["r6"]?["error"] as? String, "Not supported by Shell")
        XCTAssertEqual(claude.permissionMode, .acceptEdits)
    }

    func testInterruptDeniesWaitingPromptsAndAsksClaudeToStop() {
        let claude = started()
        claude.send("long task")
        claude.handle(["type": "control_request", "request_id": "r1", "request": ["subtype": "can_use_tool", "tool_name": "Bash"]])
        claude.interrupt()
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertEqual(claude.statusText, "Interrupting…")
        XCTAssertTrue(waitUntil { !fake.controlRequests("interrupt").isEmpty })
        let deny = fake.controlResponses().first { $0["request_id"] as? String == "r1" }?["response"] as? [String: Any]
        XCTAssertEqual(deny?["message"] as? String, "The user interrupted.")
        claude.handle(["type": "result", "subtype": "error_during_execution", "is_error": true])
        XCTAssertNil(claude.statusText)
        XCTAssertEqual(claude.items.last?.text, "Interrupted")
    }

    // MARK: Exiting

    func testAnUnexpectedExitShowsTheStatusAndStderr() throws {
        try fake.write("exit-code", "3")
        try fake.write("stderr.txt", "Error: something broke\nat main.js:1\n")
        let claude = makeSession()
        claude.start()
        XCTAssertTrue(waitUntil { claude.isLaunched })
        XCTAssertTrue(waitUntil { fake.messages().count == 1 }, "initialize was written")
        claude.handle(["type": "control_request", "request_id": "r1", "request": ["subtype": "can_use_tool", "tool_name": "Bash"]])
        claude.handle(["type": "assistant", "message": ["id": "m", "content": [["type": "tool_use", "id": "t1", "name": "Bash"]]]])
        claude.setPermissionMode(.plan) // the second line; the fake exits after reading it
        XCTAssertTrue(waitUntil { claude.hasExited })
        XCTAssertFalse(claude.canSend)
        XCTAssertFalse(claude.isStarting)
        XCTAssertTrue(claude.pending.isEmpty)
        XCTAssertFalse(claude.items.contains { $0.kind == .tool && $0.isRunning })
        XCTAssertNotEqual(claude.permissionMode, .plan, "an unanswered mode switch reverts")
        XCTAssertTrue(claude.items.contains { $0.text.hasPrefix("Couldn't switch to Plan mode: Claude Code exited") })
        let error = try XCTUnwrap(claude.items.last { $0.kind == .error && $0.text.contains("exited with status") })
        XCTAssertTrue(error.text.hasPrefix("Claude Code exited with status 3."))
        XCTAssertTrue(error.text.contains("Error: something broke"))
        XCTAssertEqual(events.last?.0, "ended")

        // Nothing more is sent to a process that's gone.
        let written = fake.messages().count
        claude.send("anyone?")
        claude.setRemoteControl(true)
        claude.reconnectMCP("github")
        XCTAssertEqual(fake.messages().count, written)
        XCTAssertFalse(claude.remoteControlBusy)
    }

    func testExitingFromSIGTERMIsQuiet() throws {
        try fake.write("exit-code", "15")
        withSettings({ $0.claudeEffort = "" }) {
            let claude = makeSession()
            claude.start()
            XCTAssertTrue(waitUntil { fake.messages().count == 1 })
            claude.setEffort("low")
            XCTAssertTrue(waitUntil { claude.hasExited })
            XCTAssertFalse(claude.items.contains { $0.text.contains("exited with status") })
            XCTAssertEqual(claude.items.last?.text, "Couldn't change effort: Claude Code exited")
            XCTAssertEqual(events.last?.0, "ended")
        }
    }

    func testTerminateStopsTheProcess() {
        let claude = started()
        claude.terminate()
        // The fake is stopped with SIGTERM: reported as ended, without an error.
        XCTAssertTrue(waitUntil { claude.hasExited })
        XCTAssertFalse(claude.canSend)
        XCTAssertFalse(claude.items.contains { $0.kind == .error })
        claude.send("after close")
        XCTAssertFalse(claude.items.contains { $0.text == "after close" })
    }

    func testAMissingBinaryIsReported() {
        let claude = makeSession(binary: fake.dir.appendingPathComponent("missing/claude").path)
        claude.start()
        XCTAssertTrue(waitUntil { claude.hasExited })
        XCTAssertFalse(claude.isLaunched)
        XCTAssertFalse(claude.isStarting)
        XCTAssertTrue(claude.items.last?.text.hasPrefix("Couldn't start ") == true)
    }

    // MARK: Trust

    func testAnUntrustedFolderWaitsForTrustThenStarts() throws {
        let config = try XCTUnwrap(ClaudeTrust.configURLOverride)
        try Data(#"{"numStartups": 3}"#.utf8).write(to: config)
        let claude = makeSession()
        claude.start()
        XCTAssertTrue(claude.needsTrust)
        XCTAssertTrue(claude.hasExited)
        XCTAssertFalse(claude.isStarting)
        XCTAssertFalse(claude.isLaunched)

        claude.trustAndStart()
        XCTAssertFalse(claude.needsTrust)
        XCTAssertTrue(waitUntil { claude.sessionID == "S1" })
        XCTAssertTrue(ClaudeTrust.isTrusted(project.path))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        XCTAssertEqual(saved?["numStartups"] as? Int, 3, "the rest of the config is kept")
    }

    func testTrustingWithAnUnreadableConfigShowsAnError() throws {
        let config = try XCTUnwrap(ClaudeTrust.configURLOverride)
        try Data("{ not json".utf8).write(to: config)
        let claude = makeSession()
        claude.start()
        XCTAssertTrue(claude.needsTrust)
        claude.trustAndStart()
        XCTAssertTrue(claude.needsTrust)
        XCTAssertFalse(claude.isLaunched)
        XCTAssertTrue(claude.items.last?.text.hasPrefix("Couldn't update \(config.path)") == true)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{ not json", "an unreadable config is never overwritten")
    }

    func testAWorktreeOfATrustedRepositoryIsTrustedAutomatically() throws {
        let main = try makeTemporaryDirectory().appendingPathComponent("repo")
        let worktree = try makeTemporaryDirectory().appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(ClaudeTrust.configURLOverride)
        try trustConfig([main.path]).write(to: config)
        let nested = worktree.appendingPathComponent("Sources").path

        withSettings({ $0.claudeTrustWorktrees = false }) {
            XCTAssertFalse(ClaudeTrust.ensureTrusted(nested))
        }
        withSettings({ $0.claudeTrustWorktrees = true }) {
            XCTAssertFalse(ClaudeTrust.ensureTrusted(project.path), "a folder outside any worktree isn't trusted")
            XCTAssertTrue(ClaudeTrust.ensureTrusted(nested))
            XCTAssertTrue(ClaudeTrust.isTrusted(worktree.path), "the worktree is recorded so the terminal UI agrees")
            XCTAssertTrue(ClaudeTrust.ensureTrusted(nested))
        }
    }

    // MARK: Signing in

    func testSigningInFromTheCardStartsTheSession() throws {
        try fake.write("auth-status.json", #"{"loggedIn": false, "apiProvider": "firstParty"}"#)
        let claude = makeSession()
        claude.start()
        XCTAssertTrue(waitUntil { claude.login != nil })
        XCTAssertFalse(claude.isLaunched)
        XCTAssertFalse(claude.isStarting)
        let login = try XCTUnwrap(claude.login)
        XCTAssertEqual(login.phase, .choosing)
        XCTAssertFalse(login.expired)

        login.begin(.claudeAI)
        XCTAssertEqual(login.phase, .signingIn)
        XCTAssertTrue(waitUntil { login.url != nil })
        XCTAssertEqual(login.url?.absoluteString, "https://claude.ai/oauth/authorize?code=true")
        login.submit(code: "   ")
        login.submit(code: " abc123 ")
        XCTAssertTrue(waitUntil(timeout: 5) { claude.login == nil && claude.sessionID == "S1" })
        XCTAssertEqual(fake.read("login-code").trimmingCharacters(in: .newlines), "abc123")
        XCTAssertEqual(fake.read("login-args").trimmingCharacters(in: .newlines), "auth login --claudeai")
        XCTAssertTrue(claude.isLaunched)
    }

    func testAnExpiredSignInRestartsTheConversationAndResendsTheMessage() throws {
        var args = ClaudeArguments()
        args.passthrough = ["-c", "--verbose"]
        let claude = started(args)
        claude.send("first")
        claude.handle(["type": "result", "subtype": "success", "result": "ok"])
        claude.send("fix the build")
        claude.handle(["type": "assistant", "error": "authentication_failed", "message": ["id": "x", "content": []]])
        claude.handle(["type": "result", "subtype": "success", "result": "done anyway"])
        let login = try XCTUnwrap(claude.login)
        XCTAssertTrue(login.expired)
        XCTAssertFalse(claude.canSend)
        XCTAssertEqual(claude.items.map(\.text), ["first", "ok", "fix the build"])

        login.useSSO = true
        login.begin(.console)
        XCTAssertTrue(waitUntil { login.url != nil })
        login.submit(code: "code")
        XCTAssertTrue(waitUntil(timeout: 5) { claude.login == nil && fake.read("args").split(separator: "\n").count == 2 })
        XCTAssertEqual(fake.read("login-args").trimmingCharacters(in: .newlines), "auth login --console --sso")
        let relaunch = String(fake.read("args").split(separator: "\n")[1])
        XCTAssertTrue(relaunch.hasSuffix("--verbose --resume S1"), relaunch)
        XCTAssertFalse(relaunch.contains(" -c"), "the restarted process resumes this conversation instead")
        XCTAssertEqual(claude.items.map(\.text), ["first", "ok", "fix the build"], "the failed message is sent again, once")
        XCTAssertTrue(waitUntil { fake.messages().filter { ($0["message"] as? [String: Any])?["content"] as? String == "fix the build" }.count == 2 })
        XCTAssertTrue(claude.isRunning)
    }

    func testLoginFailuresCancellationAndVerification() throws {
        func login() -> ClaudeLogin {
            ClaudeLogin(binary: fake.binary, environment: fake.environment, directory: project.path, expired: false)
        }
        XCTAssertEqual(ClaudeLogin.Method.claudeAI.arguments, ["--claudeai"])
        XCTAssertEqual(ClaudeLogin.Method.console.id, "console")
        for method in ClaudeLogin.Method.allCases {
            XCTAssertFalse(method.title.isEmpty)
            XCTAssertFalse(method.detail.isEmpty)
        }

        // A wrong code: the reason is the last line, without the prompt.
        try fake.write("login-fail", "")
        let failing = login()
        failing.openSignInPage() // no page yet: nothing to open
        failing.submit(code: "too early")
        failing.begin(.claudeAI)
        failing.submit(code: "nope")
        XCTAssertTrue(waitUntil { failing.phase != .signingIn })
        XCTAssertEqual(failing.phase, .failed("Invalid code"))
        try FileManager.default.removeItem(at: fake.dir.appendingPathComponent("login-fail"))

        // Signed in according to `auth login`, but `auth status` disagrees.
        try fake.write("login-noop", "")
        try fake.write("auth-status.json", #"{"loggedIn": false}"#)
        let unverified = login()
        var signedIn = false
        unverified.onSignedIn = { signedIn = true }
        unverified.begin(.claudeAI)
        unverified.submit(code: "ok")
        XCTAssertTrue(waitUntil(timeout: 5) { if case .failed = unverified.phase { true } else { false } })
        XCTAssertEqual(unverified.phase, .failed("Claude Code still isn't signed in. Try again."))
        XCTAssertFalse(signedIn)

        // Cancelling stops the login; cancelling again changes nothing.
        let cancelled = login()
        cancelled.begin(.console)
        XCTAssertTrue(waitUntil { cancelled.url != nil })
        cancelled.cancel()
        XCTAssertEqual(cancelled.phase, .failed("Sign-in was cancelled."))
        cancelled.cancel()
        XCTAssertEqual(cancelled.phase, .failed("Sign-in was cancelled."))

        // A binary that can't run.
        let broken = ClaudeLogin(binary: fake.dir.appendingPathComponent("nope").path, environment: [:], directory: project.path, expired: true)
        broken.begin(.claudeAI)
        guard case .failed(let message) = broken.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.hasPrefix("Couldn't start "))
    }

    func testAuthStatusRunsTheBinary() async throws {
        let status = await ClaudeAuth.status(binary: fake.binary, environment: fake.environment, directory: project.path)
        XCTAssertEqual(status, .loggedIn)
        try fake.write("auth-status.json", #"{"loggedIn": false, "apiProvider": "bedrock"}"#)
        let bedrock = await ClaudeAuth.status(binary: fake.binary, environment: fake.environment, directory: project.path)
        XCTAssertEqual(bedrock, .unknown)
    }

    // MARK: History

    private func pngBase64() -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    private func transcript() -> String {
        let lines: [[String: Any]] = [
            ["type": "user", "message": ["role": "user", "content": "first prompt"]],
            ["type": "user", "isMeta": true, "message": ["content": "meta context"]],
            ["type": "user", "isSidechain": true, "message": ["content": "subagent prompt"]],
            ["type": "user", "message": ["content": "<system-reminder>hidden</system-reminder>"]],
            ["type": "user", "message": ["content": "<command-name>/review</command-name><command-args>12</command-args>"]],
            ["type": "assistant", "message": ["id": "h1", "model": "claude-opus-5", "content": [
                ["type": "text", "text": "Looking."],
                ["type": "tool_use", "id": "ht1", "name": "Bash", "input": ["command": "ls"]],
            ]]],
            ["type": "user", "toolUseResult": ["stdout": "a"], "message": ["content": [
                ["type": "tool_result", "tool_use_id": "ht1", "content": "README.md"],
            ]]],
            ["type": "user", "message": ["content": [
                ["type": "text", "text": "what is this?"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": pngBase64()]],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "!!not base64"]],
            ]]],
            ["type": "summary", "summary": "x", "message": [:]],
            ["type": "user"],
        ]
        let json = lines.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        return (json + ["{ broken"]).joined(separator: "\n") + "\n"
    }

    func testContinuingShowsTheMostRecentTranscriptFirst() throws {
        let projects = try XCTUnwrap(ClaudeCodeSession.projectsDirectoryOverride)
        let folder = projects.appendingPathComponent(ClaudeCodeSession.projectDirectoryName(for: project.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let older = folder.appendingPathComponent("old.jsonl"), newer = folder.appendingPathComponent("new.jsonl")
        try #"{"type":"user","message":{"content":"stale"}}"#.write(to: older, atomically: true, encoding: .utf8)
        try transcript().write(to: newer, atomically: true, encoding: .utf8)
        try "ignored".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: older.path)

        var args = ClaudeArguments()
        args.passthrough = ["-c"]
        let claude = started(args)
        XCTAssertTrue(waitUntil { claude.items.last?.kind == .notice })
        XCTAssertEqual(claude.items.map(\.kind), [.user, .user, .assistant, .tool, .user, .notice])
        XCTAssertEqual(claude.items.map(\.text).prefix(3), ["first prompt", "/review 12", "Looking."])
        XCTAssertEqual(claude.items[3].result, "README.md")
        XCTAssertFalse(claude.items[3].isRunning)
        XCTAssertEqual(claude.items[4].text, "what is this?")
        XCTAssertEqual(claude.items[4].attachments.count, 1, "undecodable images are skipped")
        XCTAssertEqual(claude.items.last?.text, "Continuing the conversation above")
        XCTAssertEqual(claude.resolvedModel, "claude-opus-5")
    }

    func testResumingFindsTheTranscriptByID() throws {
        let id = "7bcc953c-5abd-4120-82da-148001c196cb"
        let projects = try XCTUnwrap(ClaudeCodeSession.projectsDirectoryOverride)
        let folder = projects.appendingPathComponent("-somewhere-else")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"type":"user","message":{"content":"resumed prompt"}}"#.write(to: folder.appendingPathComponent("\(id).jsonl"),
                                                                              atomically: true, encoding: .utf8)
        var args = ClaudeArguments()
        args.passthrough = ["--resume", id]
        let claude = started(args)
        // Something live arrives before the history is read: it stays below it.
        claude.handle(["type": "system", "subtype": "compact_boundary"])
        XCTAssertTrue(waitUntil { claude.items.contains { $0.text == "resumed prompt" } })
        XCTAssertEqual(claude.items.map(\.text), ["resumed prompt", "Continuing the conversation above", "Conversation compacted"])
    }

    func testAMissingTranscriptShowsNothing() {
        var args = ClaudeArguments()
        args.passthrough = ["--resume", "00000000-0000-0000-0000-000000000000"]
        let claude = started(args)
        XCTAssertTrue(waitUntil { claude.repositoryChecked })
        XCTAssertTrue(claude.items.isEmpty)
    }

    // MARK: Repository and MCP

    private func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                       "-c", "init.defaultBranch=main"] + args
        p.currentDirectoryURL = dir
        p.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin", "HOME": dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    func testTheSessionIsNamedAfterItsRepositoryAndBranch() throws {
        try git(["init", "-q"], in: project)
        try git(["checkout", "-q", "-b", "feature/login"], in: project)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: project)
        let claude = started()
        XCTAssertTrue(waitUntil(timeout: 5) { claude.repository != nil })
        XCTAssertEqual(claude.sessionName, "proj · feature/login")
        XCTAssertEqual(claude.tabTitle, "proj · feature/login")
        XCTAssertTrue(waitUntil { fake.controlRequests("rename_session").first?["title"] as? String == "proj · feature/login" })

        // Edits refresh git status; a result refreshes it too.
        claude.handle(["type": "assistant", "message": ["id": "m", "content": [["type": "tool_use", "id": "e1", "name": "Edit", "input": [:]]]]])
        claude.handle(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "e1", "content": "ok"]]]])
        claude.handle(["type": "result", "subtype": "success"])
        XCTAssertEqual(fake.controlRequests("rename_session").count, 1, "the same name isn't sent twice")
    }

    func testANameFromTheCommandLineIsKept() throws {
        try git(["init", "-q"], in: project)
        var args = ClaudeArguments()
        args.passthrough = ["-n", "my-session"]
        withSettings({ $0.claudeRemoteControl = false }) {
            let claude = started(args)
            XCTAssertTrue(waitUntil(timeout: 5) { claude.repositoryChecked })
            XCTAssertNotNil(claude.repository)
            respond(claude, id: "shell-1", [:])
            claude.refreshMCPStatus()
            XCTAssertTrue(waitUntil { !fake.controlRequests("mcp_status").isEmpty })
            XCTAssertTrue(fake.controlRequests("rename_session").isEmpty)
        }
    }

    func testSignInsInTheMCPManagerReconnectTheServer() {
        let claude = started()
        claude.handle(["type": "system", "subtype": "init", "session_id": "S1", "mcp_servers": [["name": "linear", "status": "needs-auth"]]])
        NotificationCenter.default.post(name: .mcpServerDidChange, object: nil, userInfo: [:])
        NotificationCenter.default.post(name: .mcpServerDidChange, object: nil, userInfo: ["name": "linear"])
        XCTAssertTrue(waitUntil { fake.controlRequests("mcp_reconnect").first?["serverName"] as? String == "linear" })
        XCTAssertEqual(fake.controlRequests("mcp_reconnect").count, 1)
    }
}
