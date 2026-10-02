import AppKit
import Observation

/// Whether Claude Code is signed in, and how to tell from its output.
///
/// Shell never reads, stores or copies Claude credentials. It asks
/// `claude auth status` and signs in with `claude auth login` (`ClaudeLogin`),
/// which saves them where Claude Code always does, so `claude` in any
/// terminal is signed in too.
enum ClaudeAuth {
    enum Status: Equatable { case loggedIn, loggedOut, unknown }

    /// `claude auth status --json`. Only Anthropic's own sign-in can be fixed
    /// with a login; Bedrock, Vertex and gateways report `loggedIn: false`
    /// but work, so they count as unknown.
    static func parseStatus(_ data: Data) -> Status {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = obj["loggedIn"] as? Bool else { return .unknown }
        if loggedIn { return .loggedIn }
        return (obj["apiProvider"] as? String ?? "firstParty") == "firstParty" ? .loggedOut : .unknown
    }

    static func status(binary: String, environment: [String: String], directory: String) async -> Status {
        let r = await ProcessRunner.run(binary, ["auth", "status", "--json"], environment: environment,
                                        directory: directory, timeout: 15)
        guard !r.timedOut else { return .unknown }
        return parseStatus(r.stdout)
    }

    /// Claude Code's "Not logged in · Please run /login" (also sent for an
    /// expired or revoked sign-in).
    static func isLoginError(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("please run /login") || text.localizedCaseInsensitiveContains("not logged in")
    }

    /// A stream-json `assistant` message Claude Code made up because the
    /// request couldn't be authenticated.
    static func isAuthFailure(_ msg: [String: Any]) -> Bool {
        if msg["error"] as? String == "authentication_failed" { return true }
        guard let message = msg["message"] as? [String: Any], message["model"] as? String == "<synthetic>" else { return false }
        let text = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return isLoginError(text)
    }

    /// CLI output without terminal escapes (colors, OSC 8 links).
    static func plainText(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    /// The sign-in page `claude auth login` prints in case the browser didn't open.
    static func loginURL(in output: String) -> URL? {
        guard let match = plainText(output).firstMatch(of: /https:\/\/\S+/) else { return nil }
        return URL(string: String(match.output))
    }

    static let codePrompt = "Paste code here if prompted >"

    /// Why `claude auth login` failed: its last line of output, without the code prompt.
    static func failureMessage(in output: String) -> String? {
        let lines = plainText(output).split(whereSeparator: \.isNewline).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: codePrompt) else { return s }
            return String(s[r.upperBound...])
        }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

/// One sign-in through Claude Code's own `claude auth login`, for the native
/// view's sign-in card: pick the account type, finish in the browser (which
/// Claude Code opens), and paste the code back if the page shows one.
@MainActor
@Observable
final class ClaudeLogin {
    /// The account types `/login` offers.
    enum Method: String, CaseIterable, Identifiable {
        case claudeAI, console
        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeAI: "Claude account with subscription"
            case .console: "Anthropic Console account"
            }
        }

        var detail: String {
            switch self {
            case .claudeAI: "Pro, Max, Team or Enterprise"
            case .console: "API usage billing"
            }
        }

        var arguments: [String] {
            switch self {
            case .claudeAI: ["--claudeai"]
            case .console: ["--console"]
            }
        }
    }

    enum Phase: Equatable {
        case choosing
        case signingIn
        case verifying
        case failed(String)
    }

    private(set) var phase: Phase = .choosing
    /// The sign-in page, once `claude auth login` prints it.
    private(set) var url: URL?
    /// Forces the SSO flow (`--sso`).
    var useSSO = false
    /// Set when a running session lost its sign-in, rather than never having one.
    let expired: Bool
    @ObservationIgnored var onSignedIn: (() -> Void)?

    @ObservationIgnored private let binary: String
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let directory: String
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: FileHandle?
    @ObservationIgnored private var output = ""
    /// Ignores output and exit from a login that was cancelled or replaced.
    @ObservationIgnored private var generation = 0

    init(binary: String, environment: [String: String], directory: String, expired: Bool) {
        self.binary = binary
        self.environment = environment
        self.directory = directory
        self.expired = expired
    }

    func begin(_ method: Method) {
        stop()
        generation += 1
        let gen = generation
        output = ""
        url = nil
        phase = .signingIn

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["auth", "login"] + method.arguments + (useSSO ? ["--sso"] : [])
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = environment
        for key in ["SHELL_APP_CTL", "SHELL_APP_SOCKET", "SHELL_APP_SESSION"] { env[key] = nil }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(text, generation: gen) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(status: status, generation: gen) }
            }
        }
        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            Log.claude.error("claude auth login failed to start: \(error.localizedDescription, privacy: .public)")
            phase = .failed("Couldn't start \(binary): \(error.localizedDescription)")
            return
        }
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    /// Sends the code from the sign-in page to `claude auth login`.
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stdin else { return }
        do {
            try stdin.write(contentsOf: Data((trimmed + "\n").utf8))
        } catch {
            Log.claude.error("claude auth login stdin write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openSignInPage() {
        if let url { NSWorkspace.shared.open(url) }
    }

    func cancel() {
        guard phase == .signingIn else { return }
        stop()
        phase = .failed("Sign-in was cancelled.")
    }

    /// Stops a login in progress without reporting it.
    func stop() {
        generation += 1
        try? stdin?.close()
        stdin = nil
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + AppEnvironment.wait(2)) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private func received(_ text: String, generation gen: Int) {
        guard gen == generation else { return }
        output += text
        if output.utf8.count > 32 * 1024 { output = String(output.suffix(16 * 1024)) }
        if url == nil { url = ClaudeAuth.loginURL(in: output) }
    }

    private func exited(status: Int32, generation gen: Int) {
        guard gen == generation else { return }
        process = nil
        try? stdin?.close()
        stdin = nil
        guard status == 0 else {
            phase = .failed(ClaudeAuth.failureMessage(in: output) ?? "claude auth login exited with status \(status).")
            return
        }
        // Make sure the sign-in took before starting the session.
        phase = .verifying
        Task { [weak self, binary, environment, directory] in
            let status = await ClaudeAuth.status(binary: binary, environment: environment, directory: directory)
            guard let self, gen == generation else { return }
            if status == .loggedOut {
                phase = .failed("Claude Code still isn't signed in. Try again.")
            } else {
                onSignedIn?()
            }
        }
    }
}
