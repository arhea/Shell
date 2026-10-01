import XCTest
@testable import Shell

/// Answers requests to `mcp-inspector.test` with canned MCP responses, so the
/// Streamable HTTP client runs without a network. The handler sees each
/// request (with its body) and returns status, headers and body.
private final class StubMCPProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = ["Content-Type": "application/json"]; var body = Data() }
    // Accessed only from URL loading threads one request at a time; guarded by the lock.
    nonisolated(unsafe) static var handler: ((URLRequest, [String: Any]) -> Reply)?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp-inspector.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let reply: Reply = Self.lock.withLock {
            Self.seen.append(request)
            return Self.handler?(request, json) ?? Reply(status: 500)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func json(_ obj: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }
}

final class MCPToolInfoTests: XCTestCase {
    func testParsesNameDescriptionAnnotationsAndParameters() {
        let t = MCPToolInfo.parse([
            "name": "search", "description": "Finds things",
            "annotations": ["title": "Search", "readOnlyHint": true, "destructiveHint": false, "openWorldHint": true],
            "inputSchema": [
                "required": ["query", "a_required"],
                "properties": [
                    "query": ["type": "string", "description": "What to find"],
                    "a_required": ["type": "number"],
                    "tags": ["type": "array", "items": ["type": "string"]],
                    "mode": ["type": "string", "enum": ["fast", "slow"]],
                    "maybe": ["type": ["string", "null"]],
                    "any": [String: Any](),
                    "bare": "not a dict",
                ],
            ],
        ])
        XCTAssertEqual(t.id, "search")
        XCTAssertEqual(t.title, "Search")
        XCTAssertEqual(t.description, "Finds things")
        XCTAssertEqual(t.readOnly, true)
        XCTAssertEqual(t.destructive, false)
        XCTAssertEqual(t.openWorld, true)
        // Required first, then alphabetical.
        XCTAssertEqual(t.parameters.map(\.name), ["a_required", "query", "any", "bare", "maybe", "mode", "tags"])
        let byName = Dictionary(uniqueKeysWithValues: t.parameters.map { ($0.name, $0) })
        XCTAssertEqual(byName["query"], .init(name: "query", type: "string", required: true, description: "What to find"))
        XCTAssertEqual(byName["tags"]?.type, "[string]")
        XCTAssertEqual(byName["mode"]?.type, "fast | slow")
        XCTAssertEqual(byName["maybe"]?.type, "string | null")
        XCTAssertEqual(byName["any"]?.type, "")
        XCTAssertEqual(byName["bare"]?.required, false)
    }

    func testDefaultsAndFallbacks() {
        let empty = MCPToolInfo.parse([:])
        XCTAssertEqual(empty.name, "")
        XCTAssertNil(empty.title)
        XCTAssertNil(empty.readOnly)
        XCTAssertTrue(empty.parameters.isEmpty)
        let t = MCPToolInfo.parse(["name": "x", "title": "Own title", "annotations": ["title": "Ann", "readOnly": false]])
        XCTAssertEqual(t.title, "Own title")
        XCTAssertEqual(t.readOnly, false)
        let arrayWithoutItems = MCPToolInfo.parse(["inputSchema": ["properties": ["list": ["type": "array"]]]])
        XCTAssertEqual(arrayWithoutItems.parameters.first?.type, "array")
    }
}

final class MCPToolInspectorTests: XCTestCase {
    private let env = ["HOME": "/Users/me", "TOKEN": "abc", "PATH": "/usr/bin:/bin"]

    override func tearDown() {
        URLProtocol.unregisterClass(StubMCPProtocol.self)
        StubMCPProtocol.lock.withLock {
            StubMCPProtocol.handler = nil
            StubMCPProtocol.seen = []
        }
        super.tearDown()
    }

    // MARK: Expansion

    func testExpandsVariablesAndDefaults() {
        XCTAssertEqual(MCPToolInspector.expand("plain", env), "plain")
        XCTAssertEqual(MCPToolInspector.expand("${HOME}/x", env), "/Users/me/x")
        XCTAssertEqual(MCPToolInspector.expand("Bearer ${TOKEN}", env), "Bearer abc")
        XCTAssertEqual(MCPToolInspector.expand("${MISSING}", env), "")
        XCTAssertEqual(MCPToolInspector.expand("${MISSING:-fallback}", env), "fallback")
        XCTAssertEqual(MCPToolInspector.expand("${MISSING:-a:-b}", env), "a:-b")
        XCTAssertEqual(MCPToolInspector.expand("${TOKEN:-unused}", env), "abc")
        XCTAssertEqual(MCPToolInspector.expand("${HOME}-${TOKEN}!", env), "/Users/me-abc!")
        XCTAssertEqual(MCPToolInspector.expand("open ${HOME", env), "open ${HOME", "unterminated stays literal")
    }

    func testErrorDescriptions() {
        XCTAssertEqual(MCPToolInspector.InspectError.unsupported("u").errorDescription, "u")
        XCTAssertEqual(MCPToolInspector.InspectError.failed("f").errorDescription, "f")
        XCTAssertTrue(MCPToolInspector.InspectError.needsAuth.errorDescription?.contains("sign-in") == true)
    }

    // MARK: Config validation

    private func expectError(_ config: [String: Any], _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await MCPToolInspector.listTools(config: config, environment: env, directory: NSTemporaryDirectory())
            XCTFail("expected \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, message, file: file, line: line)
        }
    }

    func testUnsupportedTransport() async {
        await expectError(["type": "sse", "url": "https://x"], "Tool descriptions aren't available for sse servers.")
    }

    func testHTTPNeedsAnHTTPURL() async {
        await expectError([:], "No URL configured")
        await expectError(["type": "http", "url": "ftp://x/y"], "No URL configured")
    }

    func testStdioNeedsACommand() async {
        await expectError(["type": "stdio"], "No command configured")
    }

    // MARK: stdio

    func testStdioListsToolsAcrossPagesWithExpandedEnvAndArgs() async throws {
        let dir = try makeTemporaryDirectory()
        let server = try FakeMCPServer.write(in: dir)
        let config: [String: Any] = ["command": server, "args": ["ok", "${TOKEN}"], "env": ["GREETING": "${HOME}"]]
        let data = try JSONSerialization.data(withJSONObject: config)
        let tools = try await MCPToolInspector.listTools(configJSON: data, environment: env, directory: dir.path)
        XCTAssertEqual(tools.map(\.name), ["first", "second"])
        XCTAssertEqual(tools[0].description, "hello /Users/me")
        XCTAssertEqual(tools[0].readOnly, true)
        XCTAssertEqual(tools[0].parameters.map(\.name), ["q", "limit"])
        XCTAssertEqual(tools[1].description, "arg abc")
    }

    func testStdioResolvesABareCommandOnThePath() async throws {
        let dir = try makeTemporaryDirectory()
        _ = try FakeMCPServer.write(in: dir, name: "fake-mcp-on-path")
        let tools = try await MCPToolInspector.listTools(config: ["type": "stdio", "command": "fake-mcp-on-path"],
                                                         environment: ["PATH": dir.path + ":/usr/bin:/bin"], directory: dir.path)
        XCTAssertEqual(tools.count, 2)
    }

    private func expectStdioError(_ mode: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let dir = try makeTemporaryDirectory()
        let server = try FakeMCPServer.write(in: dir)
        await expectError(["command": server, "args": [mode]], message, file: file, line: line)
    }

    func testStdioInitializeError() async throws {
        try await expectStdioError("initerror", "bad init")
    }

    func testStdioListErrorWithoutMessage() async throws {
        try await expectStdioError("listerror", "MCP error")
    }

    func testStdioServerExitingBeforeAnswering() async throws {
        try await expectStdioError("exit", "The server exited before answering")
    }

    func testStdioCommandThatCannotStart() async throws {
        let dir = try makeTemporaryDirectory()
        let missing = dir.appendingPathComponent("missing").path
        do {
            _ = try await MCPToolInspector.listTools(config: ["command": missing], environment: env, directory: dir.path)
            XCTFail("expected a launch failure")
        } catch {
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.hasPrefix("Couldn't start \(missing)") == true, "\(error)")
        }
    }

    func testStdioSessionStopBeforeRunIsHarmless() {
        let session = MCPToolInspector.StdioSession()
        session.stop()
        session.stop()
    }

    // MARK: Streamable HTTP

    private func stub(_ handler: @escaping (URLRequest, [String: Any]) -> StubMCPProtocol.Reply) {
        StubMCPProtocol.lock.withLock { StubMCPProtocol.handler = handler }
        URLProtocol.registerClass(StubMCPProtocol.self)
    }

    private var seen: [URLRequest] { StubMCPProtocol.lock.withLock { StubMCPProtocol.seen } }

    func testHTTPListsToolsFromJSONAndEventStreamReplies() async throws {
        stub { req, body in
            let id = body["id"] as? Int
            switch body["method"] as? String {
            case "initialize":
                return .init(headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
                             body: StubMCPProtocol.json(["jsonrpc": "2.0", "id": id!, "result": ["protocolVersion": "2025-06-18"]]))
            case "notifications/initialized":
                return .init(status: 202, body: Data())
            case "tools/list" where (body["params"] as? [String: Any])?["cursor"] == nil:
                return .init(body: StubMCPProtocol.json(["jsonrpc": "2.0", "id": id!, "result": ["tools": [["name": "a"]], "nextCursor": "c2"]]))
            default:
                let other = String(decoding: StubMCPProtocol.json(["jsonrpc": "2.0", "id": 99, "result": [:]]), as: UTF8.self)
                let mine = String(decoding: StubMCPProtocol.json(["jsonrpc": "2.0", "id": id!, "result": ["tools": [["name": "b"]]]]), as: UTF8.self)
                return .init(headers: ["Content-Type": "text/event-stream"],
                             body: Data("event: message\ndata: \(other)\n\ndata: \(mine)\n\n".utf8))
            }
        }
        let tools = try await MCPToolInspector.listTools(
            config: ["type": "http", "url": "https://mcp-inspector.test/${PATHPART:-mcp}", "headers": ["Authorization": "Bearer ${TOKEN}"]],
            environment: env, directory: NSTemporaryDirectory())
        XCTAssertEqual(tools.map(\.name), ["a", "b"])
        let requests = seen
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.first?.url?.path, "/mcp")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "MCP-Protocol-Version"), MCPToolInspector.protocolVersion)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1", "the session id is sent back")
    }

    private func expectHTTPError(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                                 _ handler: @escaping (URLRequest, [String: Any]) -> StubMCPProtocol.Reply) async {
        stub(handler)
        await expectError(["type": "http", "url": "https://mcp-inspector.test/mcp"], message, file: file, line: line)
    }

    func testHTTPUnauthorizedNeedsAuth() async {
        await expectHTTPError(MCPToolInspector.InspectError.needsAuth.errorDescription!) { _, _ in .init(status: 401) }
        await expectHTTPError(MCPToolInspector.InspectError.needsAuth.errorDescription!) { _, _ in .init(status: 403) }
    }

    func testHTTPServerError() async {
        await expectHTTPError("HTTP 500") { _, _ in .init(status: 500) }
    }

    func testHTTPJSONRPCError() async {
        await expectHTTPError("denied") { _, body in
            .init(body: StubMCPProtocol.json(["jsonrpc": "2.0", "id": body["id"] as? Int ?? 0, "error": ["message": "denied"]]))
        }
        await expectHTTPError("MCP error") { _, body in
            .init(body: StubMCPProtocol.json(["jsonrpc": "2.0", "id": body["id"] as? Int ?? 0, "error": [:]]))
        }
    }

    func testHTTPUnexpectedResponse() async {
        await expectHTTPError("Unexpected response from the server") { _, _ in .init(body: Data("<html>".utf8)) }
    }
}
