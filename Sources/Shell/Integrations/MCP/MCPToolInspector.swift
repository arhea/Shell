import Foundation

/// A tool as the MCP server describes it (`tools/list`).
struct MCPToolInfo: Identifiable, Hashable {
    struct Parameter: Hashable {
        var name: String
        var type: String
        var required: Bool
        var description: String
    }

    var name: String
    var title: String?
    var description: String
    var readOnly: Bool?
    var destructive: Bool?
    var openWorld: Bool?
    var parameters: [Parameter]
    var id: String { name }

    static func parse(_ t: [String: Any]) -> MCPToolInfo {
        let ann = t["annotations"] as? [String: Any] ?? [:]
        let schema = t["inputSchema"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        let props = schema["properties"] as? [String: Any] ?? [:]
        let params = props.keys.sorted { a, b in
            let ra = required.contains(a), rb = required.contains(b)
            return ra != rb ? ra : a < b
        }.map { key -> Parameter in
            let p = props[key] as? [String: Any] ?? [:]
            var type = p["type"] as? String ?? (p["type"] as? [String])?.joined(separator: " | ") ?? ""
            if type == "array", let items = p["items"] as? [String: Any], let it = items["type"] as? String { type = "[\(it)]" }
            if let e = p["enum"] as? [Any] { type = e.map { "\($0)" }.joined(separator: " | ") }
            return Parameter(name: key, type: type, required: required.contains(key), description: p["description"] as? String ?? "")
        }
        return MCPToolInfo(
            name: t["name"] as? String ?? "", title: (t["title"] as? String) ?? (ann["title"] as? String),
            description: t["description"] as? String ?? "",
            readOnly: ann["readOnlyHint"] as? Bool ?? ann["readOnly"] as? Bool,
            destructive: ann["destructiveHint"] as? Bool,
            openWorld: ann["openWorldHint"] as? Bool,
            parameters: params)
    }
}

/// Connects to an MCP server just long enough to call `tools/list`.
/// Supports stdio servers and Streamable HTTP servers that don't need OAuth;
/// OAuth tokens belong to Claude Code, so those servers aren't queried.
enum MCPToolInspector {
    enum InspectError: LocalizedError {
        case unsupported(String)
        case needsAuth
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let s): s
            case .needsAuth: "This server requires sign-in; Shell can't read its tool descriptions with Claude Code's credentials."
            case .failed(let s): s
            }
        }
    }

    static let protocolVersion = "2025-06-18"

    /// Same as `listTools(config:…)`, from the server's JSON (Sendable across actors).
    static func listTools(configJSON: Data, environment: [String: String], directory: String) async throws -> [MCPToolInfo] {
        let config = (try? JSONSerialization.jsonObject(with: configJSON) as? [String: Any]) ?? [:]
        return try await listTools(config: config, environment: environment, directory: directory)
    }

    static func listTools(config: [String: Any], environment: [String: String], directory: String) async throws -> [MCPToolInfo] {
        let type = config["type"] as? String ?? (config["command"] != nil ? "stdio" : "http")
        switch type {
        case "stdio":
            return try await stdio(config: config, environment: environment, directory: directory)
        case "http":
            guard let s = config["url"] as? String, let url = URL(string: expand(s, environment)), url.scheme?.hasPrefix("http") == true else {
                throw InspectError.failed("No URL configured")
            }
            let headers = (config["headers"] as? [String: String] ?? [:]).mapValues { expand($0, environment) }
            return try await http(url: url, headers: headers)
        default:
            throw InspectError.unsupported("Tool descriptions aren't available for \(type) servers.")
        }
    }

    /// `${VAR}` and `${VAR:-default}` expansion, as Claude Code does for MCP configs.
    static func expand(_ s: String, _ env: [String: String]) -> String {
        guard s.contains("${") else { return s }
        var out = ""
        var rest = Substring(s)
        while let start = rest.range(of: "${"), let end = rest[start.upperBound...].firstIndex(of: "}") {
            out += rest[..<start.lowerBound]
            let body = rest[start.upperBound..<end]
            let parts = body.components(separatedBy: ":-")
            out += env[parts[0]] ?? (parts.count > 1 ? parts.dropFirst().joined(separator: ":-") : "")
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    private static func initializeParams() -> [String: Any] {
        ["protocolVersion": protocolVersion, "capabilities": [String: Any](),
         "clientInfo": ["name": "Shell", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"]]
    }

    // MARK: stdio

    private static func stdio(config: [String: Any], environment: [String: String], directory: String) async throws -> [MCPToolInfo] {
        guard let command = config["command"] as? String else { throw InspectError.failed("No command configured") }
        var env = environment
        for (k, v) in config["env"] as? [String: String] ?? [:] { env[k] = expand(v, environment) }
        let args = (config["args"] as? [String] ?? []).map { expand($0, environment) }
        let exe = expand(command, environment)
        let resolved = exe.contains("/") ? exe : (GitRepository.findExecutable(exe, environment: env) ?? exe)

        let finalEnv = env
        return try await withThrowingTaskGroup(of: [MCPToolInfo].self) { group in
            let session = StdioSession()
            group.addTask {
                try await session.run(executable: resolved, args: args, env: finalEnv, directory: directory)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw InspectError.failed("The server didn't answer within 25 seconds")
            }
            defer { session.stop(); group.cancelAll() }
            guard let result = try await group.next() else { return [] }
            return result
        }
    }

    /// One JSON-RPC conversation over a child process's stdin/stdout.
    ///
    /// Output arrives through a `readabilityHandler` rather than a blocking
    /// read, so `stop()` can end the conversation even when a grandchild (the
    /// real server behind `npx`/`uvx`) keeps the pipe open. A blocking read
    /// there would pin a cooperative thread and the task group forever.
    final class StdioSession: @unchecked Sendable {
        private let process = Process()
        private let lock = NSLock()
        private var output: FileHandle?
        private var input: FileHandle?
        private var chunks: AsyncStream<Data>.Continuation?

        func stop() {
            lock.lock(); defer { lock.unlock() }
            output?.readabilityHandler = nil
            chunks?.finish()
            // Stdio MCP servers exit when stdin closes, which also reaches the
            // server behind an npx/uvx wrapper that SIGTERM alone would miss.
            try? input?.close()
            input = nil
            if process.isRunning { process.terminate() }
        }

        func run(executable: String, args: [String], env: [String: String], directory: String) async throws -> [MCPToolInfo] {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = env
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let inPipe = Pipe(), outPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            let output = outPipe.fileHandleForReading
            output.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            lock.withLock {
                self.output = output
                self.input = inPipe.fileHandleForWriting
                self.chunks = continuation
            }
            do { try process.run() } catch {
                stop()
                throw InspectError.failed("Couldn't start \(executable): \(error.localizedDescription)")
            }
            let input = inPipe.fileHandleForWriting
            var chunkIterator = stream.makeAsyncIterator()

            func send(_ obj: [String: Any]) throws {
                var d = try JSONSerialization.data(withJSONObject: obj)
                d.append(0x0A)
                try input.write(contentsOf: d)
            }
            var pending = Data()
            func response(id: Int) async throws -> [String: Any] {
                while true {
                    while let nl = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["id"] as? Int == id {
                            if let err = obj["error"] as? [String: Any] { throw InspectError.failed(err["message"] as? String ?? "MCP error") }
                            return obj["result"] as? [String: Any] ?? [:]
                        }
                    }
                    // Nil on EOF, on stop(), or when the task is cancelled (timeout).
                    guard let chunk = await chunkIterator.next() else {
                        try Task.checkCancellation()
                        throw InspectError.failed("The server exited before answering")
                    }
                    pending.append(chunk)
                }
            }
            defer { stop() }
            try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": MCPToolInspector.initializeParams()])
            _ = try await response(id: 1)
            try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            var tools: [MCPToolInfo] = []
            var cursor: String?
            var id = 2
            repeat {
                var params: [String: Any] = [:]
                if let cursor { params["cursor"] = cursor }
                try send(["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": params])
                let r = try await response(id: id)
                tools += (r["tools"] as? [[String: Any]] ?? []).map(MCPToolInfo.parse)
                cursor = r["nextCursor"] as? String
                id += 1
            } while cursor != nil && id < 20
            return tools
        }
    }

    // MARK: Streamable HTTP

    private static func http(url: URL, headers: [String: String]) async throws -> [MCPToolInfo] {
        var sessionID: String?
        func call(_ body: [String: Any], id: Int?) async throws -> [String: Any]? {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw InspectError.failed("No response") }
            if http.statusCode == 401 || http.statusCode == 403 { throw InspectError.needsAuth }
            guard (200..<300).contains(http.statusCode) else { throw InspectError.failed("HTTP \(http.statusCode)") }
            if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
            guard let id else { return nil }
            // JSON body, or an SSE stream of "data:" lines.
            var candidates: [Data] = [data]
            if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("event-stream"), let text = String(data: data, encoding: .utf8) {
                candidates = text.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                    .compactMap { $0.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8) }
            }
            for c in candidates {
                guard let obj = try? JSONSerialization.jsonObject(with: c) as? [String: Any], obj["id"] as? Int == id else { continue }
                if let err = obj["error"] as? [String: Any] { throw InspectError.failed(err["message"] as? String ?? "MCP error") }
                return obj["result"] as? [String: Any] ?? [:]
            }
            throw InspectError.failed("Unexpected response from the server")
        }
        _ = try await call(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": initializeParams()], id: 1)
        _ = try? await call(["jsonrpc": "2.0", "method": "notifications/initialized"], id: nil)
        var tools: [MCPToolInfo] = []
        var cursor: String?
        var id = 2
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let r = try await call(["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": params], id: id) ?? [:]
            tools += (r["tools"] as? [[String: Any]] ?? []).map(MCPToolInfo.parse)
            cursor = r["nextCursor"] as? String
            id += 1
        } while cursor != nil && id < 20
        return tools
    }
}
