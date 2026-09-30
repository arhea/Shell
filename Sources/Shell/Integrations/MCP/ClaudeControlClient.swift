import Foundation

/// A headless `claude` process used only for control requests (MCP status,
/// sign-in, reconnect). It never receives a prompt, so it costs no tokens.
@MainActor
final class ClaudeControlClient {
    enum ClientError: LocalizedError {
        case notRunning
        case failed(String)
        case timedOut(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: "Claude Code isn't running"
            case .failed(let s): s
            case .timedOut(let s): "\(s) timed out"
            }
        }
    }

    let directory: String
    private let binary: String
    private let environment: [String: String]
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var counter = 0
    private var waiters: [String: CheckedContinuation<JSONResponse, Error>] = [:]

    /// A control response body. Plain JSON values, handed straight to the awaiting caller.
    struct JSONResponse: @unchecked Sendable { let value: [String: Any] }
    private(set) var stderrTail: [String] = []
    var onExit: (() -> Void)?

    init(binary: String, directory: String, environment: [String: String]) {
        self.binary = binary
        self.directory = directory
        self.environment = environment
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--permission-prompt-tool", "stdio"]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = environment
        for key in ["SHELL_APP_CTL", "SHELL_APP_SOCKET", "SHELL_APP_SESSION"] { env[key] = nil }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            // Empty = EOF. Without clearing the handler, GCD keeps calling it.
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stderrTail = Array((self.stderrTail + text.split(separator: "\n").map(String.init)).suffix(20))
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for w in self.waiters.values { w.resume(throwing: ClientError.notRunning) }
                    self.waiters.removeAll()
                    self.onExit?()
                }
            }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    func stop() {
        try? stdin?.close()
        stdin = nil
        if let p = process {
            for pipe in [p.standardOutput, p.standardError] { (pipe as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
            if p.isRunning { p.terminate() }
        }
        process = nil
    }

    /// Sends a control request and waits for its response.
    @discardableResult
    func request(_ body: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let stdin, isRunning else { throw ClientError.notRunning }
        counter += 1
        let id = "shell-mcp-\(counter)"
        var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": body])
        data.append(0x0A)
        let subtype = body["subtype"] as? String ?? "request"
        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONResponse, Error>) in
            waiters[id] = cont
            do { try stdin.write(contentsOf: data) } catch {
                waiters[id] = nil
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let w = self?.waiters.removeValue(forKey: id) else { return }
                    w.resume(throwing: ClientError.timedOut(subtype))
                }
            }
        }
        return response.value
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "control_response":
                guard let r = obj["response"] as? [String: Any], let id = r["request_id"] as? String,
                      let w = waiters.removeValue(forKey: id) else { continue }
                if r["subtype"] as? String == "error" {
                    w.resume(throwing: ClientError.failed(r["error"] as? String ?? "error"))
                } else {
                    w.resume(returning: JSONResponse(value: r["response"] as? [String: Any] ?? [:]))
                }
            case "control_request":
                // Nothing here should ask for permissions; refuse anything that does.
                if let id = obj["request_id"] as? String,
                   var out = try? JSONSerialization.data(withJSONObject: ["type": "control_response",
                                                                           "response": ["subtype": "error", "request_id": id, "error": "Not supported"]]) {
                    out.append(0x0A)
                    try? stdin?.write(contentsOf: out)
                }
            default:
                continue
            }
        }
    }
}
