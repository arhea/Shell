import XCTest
@testable import Shell

/// `ClaudeControlClient` against a fake `claude` speaking stream-json control messages.
@MainActor
final class ClaudeControlClientTests: XCTestCase {
    private var dir: URL!
    private var fake: FakeMCPClaude!

    override func setUp() async throws {
        dir = try makeTemporaryDirectory()
        fake = try FakeMCPClaude(in: dir)
    }

    private func makeClient(environment: [String: String]? = nil) -> ClaudeControlClient {
        let client = ClaudeControlClient(binary: fake.binary, directory: dir.path, environment: environment ?? fake.environment)
        addTeardownBlock { @MainActor in client.stop() }
        return client
    }

    func testRequestBeforeStartThrowsNotRunning() async {
        let client = makeClient()
        XCTAssertFalse(client.isRunning)
        do {
            try await client.request(["subtype": "initialize"])
            XCTFail("expected notRunning")
        } catch ClaudeControlClient.ClientError.notRunning {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStartFailsForMissingBinary() {
        let client = ClaudeControlClient(binary: dir.appendingPathComponent("nope").path, directory: dir.path, environment: [:])
        XCTAssertThrowsError(try client.start())
        XCTAssertFalse(client.isRunning)
    }

    func testRequestRoundTripsTheResponseBody() async throws {
        try fake.set("mcp_status.json", #"{"mcpServers":[{"name":"a"}],"n":7}"#)
        let client = makeClient()
        try client.start()
        XCTAssertTrue(client.isRunning)
        let r = try await client.request(["subtype": "mcp_status"])
        XCTAssertEqual(r["n"] as? Int, 7)
        XCTAssertEqual((r["mcpServers"] as? [[String: Any]])?.first?["name"] as? String, "a")
        // Requests are numbered and wrapped as control_request messages.
        let second = try await client.request(["subtype": "other"])
        XCTAssertTrue(second.isEmpty)
        let sent = fake.requests
        XCTAssertEqual(sent.map { $0["request_id"] as? String }, ["shell-mcp-1", "shell-mcp-2"])
        XCTAssertEqual(sent.first?["type"] as? String, "control_request")
    }

    func testLaunchesHeadlessStreamJSONInTheDirectoryWithoutShellVariables() async throws {
        var env = fake.environment
        env["SHELL_APP_SOCKET"] = "/tmp/sock"
        env["SHELL_APP_CTL"] = "/tmp/ctl"
        env["SHELL_APP_SESSION"] = "abc"
        env["KEEP_ME"] = "yes"
        let client = makeClient(environment: env)
        try client.start()
        XCTAssertEqual(client.directory, dir.path)
        _ = try await client.request(["subtype": "initialize"])
        let launch = fake.log("launch.log")
        XCTAssertTrue(launch.contains("args: -p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio"), launch)
        let pwd = launch.split(separator: "\n").first { $0.hasPrefix("pwd: ") }.map { String($0.dropFirst(5)) }
        XCTAssertEqual(pwd.map { URL(fileURLWithPath: $0).standardizedFileURL.lastPathComponent }, dir.lastPathComponent, launch)
        XCTAssertTrue(pwd?.hasSuffix(dir.path.replacingOccurrences(of: "/private", with: "")) == true, launch)
        XCTAssertTrue(launch.contains("KEEP_ME=yes"))
        XCTAssertFalse(launch.contains("SHELL_APP_"))
    }

    func testErrorResponseThrowsFailedWithItsMessage() async throws {
        try fake.set("mcp_toggle.error", "no such server")
        let client = makeClient()
        try client.start()
        do {
            try await client.request(["subtype": "mcp_toggle"])
            XCTFail("expected an error")
        } catch let error as ClaudeControlClient.ClientError {
            XCTAssertEqual(error.errorDescription, "no such server")
        }
    }

    func testUnansweredRequestTimesOut() async throws {
        try fake.set("mcp_reconnect.silent", "")
        let client = makeClient()
        try client.start()
        do {
            try await client.request(["subtype": "mcp_reconnect"], timeout: 0.2)
            XCTFail("expected a timeout")
        } catch let error as ClaudeControlClient.ClientError {
            XCTAssertEqual(error.errorDescription, "mcp_reconnect timed out")
        }
        // Still usable afterwards.
        let r = try await client.request(["subtype": "initialize"])
        XCTAssertTrue(r.isEmpty)
    }

    func testExitFailsPendingRequestsAndCallsOnExit() async throws {
        try fake.set("initialize.exit", "")
        let client = makeClient()
        var exited = false
        client.onExit = { exited = true }
        try client.start()
        do {
            try await client.request(["subtype": "initialize"])
            XCTFail("expected notRunning")
        } catch let error as ClaudeControlClient.ClientError {
            XCTAssertEqual(error.errorDescription, "Claude Code isn't running")
        }
        await assertEventually { exited }
        XCTAssertFalse(client.isRunning)
    }

    func testKeepsTheLastTwentyStderrLines() async throws {
        try fake.set("stderr.txt", (1...25).map { "line \($0)" }.joined(separator: "\n"))
        let client = makeClient()
        try client.start()
        await assertEventually { client.stderrTail.last == "line 25" }
        XCTAssertEqual(client.stderrTail.count, 20)
        XCTAssertEqual(client.stderrTail.first, "line 6")
    }

    func testRefusesPermissionRequestsAndIgnoresNoise() async throws {
        try fake.set("preamble.txt", [
            "this is not json",
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"control_response","response":{"request_id":"unknown-id","subtype":"success"}}"#,
            #"{"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool"}}"#,
        ].joined(separator: "\n"))
        let client = makeClient()
        try client.start()
        let r = try await client.request(["subtype": "initialize"])
        XCTAssertTrue(r.isEmpty)
        await assertEventually { self.fake.log("requests.log").contains("perm-1") }
        let refusal = fake.requests.first { ($0["response"] as? [String: Any])?["request_id"] as? String == "perm-1" }
        let response = refusal?["response"] as? [String: Any]
        XCTAssertEqual(refusal?["type"] as? String, "control_response")
        XCTAssertEqual(response?["subtype"] as? String, "error")
        XCTAssertEqual(response?["error"] as? String, "Not supported")
    }

    func testStopEndsTheProcess() async throws {
        let client = makeClient()
        try client.start()
        _ = try await client.request(["subtype": "initialize"])
        client.stop()
        XCTAssertFalse(client.isRunning)
        client.stop() // idempotent
        do {
            try await client.request(["subtype": "initialize"])
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Claude Code isn't running")
        }
    }
}
