import AppKit
import Darwin

/// A single completion candidate captured from zsh's completion system.
struct CompletionItem: Identifiable, Hashable {
    enum Kind { case command, file, directory, option, argument, history, variable, host, branch }

    var id: Int
    /// Text that replaces the current word (already shell-quoted by zsh).
    var insertion: String
    var display: String
    var description: String
    /// zsh completion tag, e.g. `commands`, `files`, `options`, `git-branches`.
    var tag: String
    var isDirectory: Bool
    var isFile: Bool

    var kind: Kind {
        if isDirectory { return .directory }
        if isFile { return .file }
        switch tag {
        case let t where t.contains("option"): return .option
        case "commands", "builtins", "functions", "aliases", "reserved-words", "suffix-aliases", "precommands", "external-commands": return .command
        case let t where t.contains("branch") || t.contains("head") || t.contains("tag") || t.contains("commit"): return .branch
        case let t where t.contains("parameter") || t.contains("variable"): return .variable
        case let t where t.contains("host"): return .host
        case "history": return .history
        default: return display.hasPrefix("-") ? .option : .argument
        }
    }

    var symbol: String {
        switch kind {
        case .command: "terminal"
        case .file: "doc"
        case .directory: "folder"
        case .option: "flag"
        case .argument: "chevron.right"
        case .history: "clock.arrow.circlepath"
        case .variable: "dollarsign"
        case .host: "network"
        case .branch: "arrow.triangle.branch"
        }
    }
}

struct CompletionResult {
    var requestID: Int
    var items: [CompletionItem]
}

/// Glue between sessions and Shell's zsh integration (Resources/shell/zsh).
///
/// App → shell: requests are written to per-session files in the runtime
/// directory, then a private key sequence is written to the PTY to trigger a
/// zle widget that reads them. This keeps zle in charge of history, aliases
/// and accept-line hooks while the app owns the editing UI.
///
/// Shell → app: the integration connects to `ControlServer` with `zsocket`.
@MainActor
enum ShellIntegration {
    static let runSequence = "\u{1b}[9001~"
    static let completeSequence = "\u{1b}[9002~"
    static let configureSequence = "\u{1b}[9003~"

    private(set) static var runtimeDirectory: URL = {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("app.bethesdalabs.Shell", isDirectory: true)
        return base
    }()

    static var socketPath: String { runtimeDirectory.appendingPathComponent("ctl-\(getpid()).sock").path }

    static var bundleShellDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("shell/zsh") }
    static var shellctlPath: String? { Bundle.main.resourceURL?.appendingPathComponent("bin/shellctl").path }

    static func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Clear stale request files from previous runs of this pid slot.
        if let items = try? fm.contentsOfDirectory(atPath: runtimeDirectory.path) {
            for item in items where item.hasPrefix("ctl-") && item.hasSuffix(".sock") {
                let pid = Int32(item.dropFirst(4).dropLast(5)) ?? 0
                if pid != getpid() && kill(pid, 0) != 0 {
                    try? fm.removeItem(at: runtimeDirectory.appendingPathComponent(item))
                }
            }
            for item in items where [".cmd", ".req", ".cfg", ".claude", ".env"].contains(where: { item.hasSuffix($0) }) {
                try? fm.removeItem(at: runtimeDirectory.appendingPathComponent(item))
            }
        }
        ControlServer.shared.onMessage = { records in
            DispatchQueue.main.async { MainActor.assumeIsolated { handle(records) } }
        }
        do {
            try ControlServer.shared.start(path: socketPath)
        } catch {
            log.error("control socket failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func stop() { ControlServer.shared.stop() }

    /// The user's shell: the configured one, else their login shell.
    static func resolvedShell(settings: AppSettings) -> String {
        if !settings.shellPath.isEmpty { return settings.shellPath }
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func isActive(settings: AppSettings, command: String?) -> Bool {
        guard settings.shellIntegration, command == nil else { return false }
        let shell = resolvedShell(settings: settings).split(separator: " ").first.map(String.init) ?? ""
        return (shell as NSString).lastPathComponent == "zsh"
    }

    static func environment(for id: UUID, settings: AppSettings, command: String?) -> [String: String] {
        var env = settings.environment
        env["SHELL_APP_SESSION"] = id.uuidString
        env["SHELL_APP_SOCKET"] = socketPath
        env["SHELL_APP_RUNTIME"] = runtimeDirectory.path
        if let ctl = shellctlPath { env["SHELL_APP_CTL"] = ctl }
        env["SHELL_APP_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        if isActive(settings: settings, command: command), let dir = bundleShellDirectory {
            if let orig = ProcessInfo.processInfo.environment["ZDOTDIR"] {
                env["SHELL_APP_ORIG_ZDOTDIR"] = orig
            }
            env["ZDOTDIR"] = dir.path
            env["SHELL_APP_ZDOTDIR"] = dir.path
            env["SHELL_APP_EDITOR"] = settings.inputEditor ? "1" : "0"
            env["SHELL_APP_PROMPT"] = settings.promptStyle.rawValue
            env["SHELL_APP_CLAUDE"] = settings.claudeLaunchMode.rawValue
            env["SHELL_APP_CLAUDE_RC"] = settings.claudeRemoteControl ? "1" : "0"
        }
        return env
    }

    static func run(command: String, in session: TerminalSession) {
        let url = runtimeDirectory.appendingPathComponent("\(session.id.uuidString).cmd")
        write(command, to: url)
        session.surfaceView.writeRaw(runSequence)
    }

    static func requestCompletions(buffer: String, id: Int, in session: TerminalSession) {
        let url = runtimeDirectory.appendingPathComponent("\(session.id.uuidString).req")
        write("\(id)\n\(buffer)", to: url)
        session.surfaceView.writeRaw(completeSequence)
    }

    /// Pushes a prompt-style change to a running shell.
    static func refreshPrompt(in session: TerminalSession, settings: AppSettings) {
        guard session.state == .idle else { return }
        let style = settings.promptStyle.rawValue
        let url = runtimeDirectory.appendingPathComponent("\(session.id.uuidString).cfg")
        write("prompt=\(style)\neditor=\(settings.inputEditor ? 1 : 0)\nclaude=\(settings.claudeLaunchMode.rawValue)\nclaude_rc=\(settings.claudeRemoteControl ? 1 : 0)\n", to: url)
        session.surfaceView.writeRaw(configureSequence)
    }

    static func cleanup(sessionID: UUID) {
        let fm = FileManager.default
        for ext in ["cmd", "req", "cfg", "claude", "env"] {
            try? fm.removeItem(at: runtimeDirectory.appendingPathComponent("\(sessionID.uuidString).\(ext)"))
        }
    }

    /// Answers a waiting `claude` wrapper: "native", "terminal", "terminal-rc"
    /// (terminal UI with --remote-control) or "cancel".
    static func answerClaude(_ answer: String, in session: TerminalSession) {
        write(answer, to: runtimeDirectory.appendingPathComponent("\(session.id.uuidString).claude"))
    }

    /// Reads (and deletes) the environment the `claude` wrapper exported.
    static func takeEnvironment(for sessionID: UUID) -> [String: String]? {
        let url = runtimeDirectory.appendingPathComponent("\(sessionID.uuidString).env")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        var env: [String: String] = [:]
        for chunk in data.split(separator: 0) {
            guard let pair = String(data: Data(chunk), encoding: .utf8), let eq = pair.firstIndex(of: "=") else { continue }
            env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }

    private static func write(_ text: String, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        let data = Array(text.utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    // MARK: Messages

    static func handle(_ records: [[String]]) {
        guard let first = records.first, first.count >= 2 else { return }
        let type = first[0]
        DebugCommands.trace("msg \(type) records=\(records.count)")
        if type == "debug" {
            DebugCommands.handle(first)
            return
        }
        guard let sid = UUID(uuidString: first[1]), let session = SessionRegistry.shared.session(sid) else {
            if type == "notify" { handleUnattributedNotify(first) }
            return
        }
        func field(_ i: Int) -> String? { first.count > i ? first[i] : nil }

        switch type {
        case "init":
            session.integrationDidInitialize(histFile: field(2).flatMap { $0.isEmpty ? nil : $0 })
            AgentIntegrations.shared.shellReported(omz: field(4), theme: field(5))
            CommandIndex.shared.update(path: field(6), aliases: field(7), functions: field(8))
        case "prompt":
            session.promptReady(
                exitCode: field(2).flatMap(Int.init),
                directory: field(3),
                branch: field(4),
                duration: field(5).flatMap(Double.init))
        case "exec":
            session.commandStarted(field(2) ?? "", directory: field(3))
        case "comp":
            guard let reqID = field(2).flatMap(Int.init) else { return }
            var items: [CompletionItem] = []
            var seen = Set<String>()
            for rec in records.dropFirst() where rec.count >= 6 && rec[0] == "m" {
                let insertion = rec[1]
                guard seen.insert(insertion).inserted else { continue }
                items.append(CompletionItem(
                    id: items.count, insertion: insertion, display: rec[2].isEmpty ? insertion : rec[2],
                    description: rec[3], tag: rec[4],
                    isDirectory: rec[5].contains("d"), isFile: rec[5].contains("f")))
            }
            // Command names arrive in hash order; show short/alphabetical first.
            if !items.isEmpty, items.allSatisfy({ $0.kind == .command }) {
                items.sort { ($0.display.count, $0.display) < ($1.display.count, $1.display) }
                items = items.enumerated().map { var i = $0.element; i.id = $0.offset; return i }
            }
            session.completionsReceived(CompletionResult(requestID: reqID, items: items))
        case "agent":
            let kind = AgentKind(rawValue: field(2) ?? "") ?? .other
            session.agentEvent(kind: kind, event: field(3) ?? "", message: field(4).flatMap { $0.isEmpty ? nil : $0 })
        case "claude":
            ClaudeLauncher.handle(session: session, directory: field(2) ?? "", binary: field(3) ?? "claude",
                                  arguments: Array(first.dropFirst(4)))
        case "notify":
            NotificationManager.shared.post(title: field(2) ?? "Shell", body: field(3) ?? "", session: session, force: true)
        default:
            break
        }
    }

    private static func handleUnattributedNotify(_ record: [String]) {
        let title = record.count > 2 ? record[2] : "Shell"
        let body = record.count > 3 ? record[3] : ""
        NotificationManager.shared.post(title: title, body: body, session: nil, force: true)
    }
}
