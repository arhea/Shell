import AppKit

/// What the native view needs to start `claude` the way the shell would have.
struct ClaudeLaunchRequest {
    var directory: String
    var binary: String
    var arguments: ClaudeArguments
    /// The shell's exported environment (PATH, credentials, provider settings).
    var environment: [String: String]
}

/// The parts of a `claude …` command line the native view understands.
///
/// Anything that isn't an interactive session (print mode, subcommands,
/// pickers, remote/cloud sessions, help) returns nil from `parse` and runs in
/// the terminal UI instead.
struct ClaudeArguments: Equatable {
    var prompt: String?
    var model: String?
    var effort: String?
    var permissionMode: String?
    /// Flags passed through to the native process unchanged.
    var passthrough: [String] = []

    var continuesSession: Bool { passthrough.contains("-c") || passthrough.contains("--continue") }
    var resumeID: String? {
        guard let i = passthrough.firstIndex(where: { $0 == "-r" || $0 == "--resume" }), i + 1 < passthrough.count else { return nil }
        return passthrough[i + 1]
    }
    var allowsBypass: Bool {
        passthrough.contains("--dangerously-skip-permissions") || passthrough.contains("--allow-dangerously-skip-permissions")
    }

    static let subcommands: Set<String> = [
        "agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs", "mcp", "plugin", "plugins",
        "project", "respawn", "rm", "setup-token", "stop", "ultrareview", "update", "upgrade", "config", "migrate-installer",
    ]

    /// Flags that only make sense in the terminal (or aren't sessions at all).
    static let terminalOnly: Set<String> = [
        "-p", "--print", "-h", "--help", "-v", "--version", "--cloud", "--teleport", "--remote-control", "--bg", "--background",
        "--tmux", "-w", "--worktree", "--from-pr", "--ide", "--output-format", "--input-format", "--ax-screen-reader",
        "--environment", "--json-schema",
    ]

    /// Flags that take exactly one value.
    static let singleValue: Set<String> = [
        "--agent", "--agents", "--append-system-prompt", "--system-prompt", "--settings", "--setting-sources", "--fallback-model",
        "-n", "--name", "--session-id", "--plugin-url", "--autocompact", "--max-budget-usd", "--debug-file",
        "--permission-prompts", "--system-prompt-snapshot", "--remote-control-session-name-prefix",
    ]

    /// Flags that take one or more values (commander consumes until the next flag).
    static let multiValue: Set<String> = [
        "--add-dir", "--allowed-tools", "--allowedTools", "--disallowed-tools", "--disallowedTools", "--mcp-config",
        "--betas", "--tools", "--file",
    ]

    // Regex is immutable once built; it just isn't marked Sendable.

    nonisolated(unsafe) static let sessionIDPattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

    static func parse(_ args: [String]) -> ClaudeArguments? {
        var result = ClaudeArguments()
        var positionals: [String] = []
        var i = 0
        func next() -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        while i < args.count {
            let raw = args[i]
            defer { i += 1 }
            if raw == "--" {
                positionals.append(contentsOf: args[(i + 1)...])
                break
            }
            guard raw.hasPrefix("-"), raw.count > 1 else {
                positionals.append(raw)
                continue
            }
            // --flag=value
            var flag = raw
            var inline: String?
            if raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") {
                flag = String(raw[..<eq])
                inline = String(raw[raw.index(after: eq)...])
            }
            if terminalOnly.contains(flag) { return nil }
            switch flag {
            case "--model":
                guard let v = inline ?? next() else { return nil }
                result.model = v
            case "--effort":
                guard let v = inline ?? next() else { return nil }
                result.effort = v
            case "--permission-mode":
                guard let v = inline ?? next() else { return nil }
                result.permissionMode = v == "manual" ? "default" : v
            case "-r", "--resume":
                // Without a session ID this opens the terminal picker.
                let v = inline ?? (i + 1 < args.count ? args[i + 1] : nil)
                guard let v, v.wholeMatch(of: sessionIDPattern) != nil else { return nil }
                if inline == nil { i += 1 }
                result.passthrough += ["--resume", v]
            case "-d", "--debug":
                result.passthrough.append(raw)
                // Optional filter value.
                if inline == nil, i + 1 < args.count, !args[i + 1].hasPrefix("-"), args[i + 1].contains(",") || args[i + 1].contains("!") {
                    result.passthrough.append(args[i + 1])
                    i += 1
                }
            default:
                if singleValue.contains(flag) {
                    guard let v = inline ?? next() else { return nil }
                    result.passthrough += [flag, v]
                } else if multiValue.contains(flag) {
                    result.passthrough.append(flag)
                    if let inline {
                        result.passthrough.append(inline)
                    } else {
                        var took = false
                        while i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                            result.passthrough.append(args[i + 1])
                            i += 1
                            took = true
                        }
                        if !took { return nil }
                    }
                } else {
                    // Boolean flags (-c, --verbose, --dangerously-skip-permissions…).
                    result.passthrough.append(raw)
                }
            }
        }
        if let first = positionals.first, subcommands.contains(first) { return nil }
        // claude takes a single prompt argument; more is a usage error the TUI reports.
        guard positionals.count <= 1 else { return nil }
        result.prompt = positionals.first.flatMap { $0.isEmpty ? nil : $0 }
        return result
    }
}

/// Handles `claude` typed at a Shell prompt: decides between the native view
/// and the terminal UI, asking (and remembering) when the user wants that.
@MainActor
enum ClaudeLauncher {
    /// The environment from the most recent `claude` launch, reused by the MCP manager.
    private(set) static var lastEnvironment: [String: String]?

    static func handle(session: TerminalSession, directory: String, binary: String, arguments: [String]) {
        let environment = ShellIntegration.takeEnvironment(for: session.id)
        if let environment { lastEnvironment = environment }
        guard let parsed = ClaudeArguments.parse(arguments), session.nativeClaude == nil else {
            ShellIntegration.answerClaude("terminal", in: session)
            return
        }
        let terminalAnswer = terminalAnswer(for: arguments)
        let request = ClaudeLaunchRequest(
            directory: directory.isEmpty ? (session.workingDirectory ?? NSHomeDirectory()) : directory,
            binary: binary, arguments: parsed,
            environment: environment ?? ProcessInfo.processInfo.environment)

        switch SettingsStore.shared.settings.claudeLaunchMode {
        case .terminal:
            ShellIntegration.answerClaude(terminalAnswer, in: session)
        case .native:
            open(request, in: session)
        case .ask:
            ask(in: session) { choice in
                switch choice {
                case .native: open(request, in: session)
                case .terminal: ShellIntegration.answerClaude(terminalAnswer, in: session)
                case .ask: ShellIntegration.answerClaude("cancel", in: session)
                }
            }
        }
    }

    /// Interactive terminal-UI launches get --remote-control when the setting is on
    /// (unless the command already mentions it, or ends positional arguments with --).
    static func terminalAnswer(for arguments: [String]) -> String {
        guard SettingsStore.shared.settings.claudeRemoteControl,
              !arguments.contains("--"),
              !arguments.contains(where: { $0.hasPrefix("--remote-control") }) else { return "terminal" }
        return "terminal-rc"
    }

    static func open(_ request: ClaudeLaunchRequest, in session: TerminalSession) {
        ShellIntegration.answerClaude("native", in: session)
        session.startNativeClaude(request)
    }

    /// Shows the one-time choice. `.ask` in the completion means cancelled.
    private static func ask(in session: TerminalSession, completion: @escaping (ClaudeLaunchMode) -> Void) {
        session.onRequestFocus?()
        let alert = NSAlert()
        alert.messageText = "Open Claude Code in Shell's native view?"
        alert.informativeText = "The native view gives you a chat transcript, model, effort and permission-mode pickers, "
            + "and a file explorer with git status. The terminal UI is Claude Code's own interface."
        alert.addButton(withTitle: "Native View")
        alert.addButton(withTitle: "Terminal UI")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice (change it in Settings › Claude & Codex)"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let choice: ClaudeLaunchMode = switch response {
            case .alertFirstButtonReturn: .native
            case .alertSecondButtonReturn: .terminal
            default: .ask
            }
            if choice != .ask, alert.suppressionButton?.state == .on {
                SettingsStore.shared.settings.claudeLaunchMode = choice
            }
            completion(choice)
        }
        if let window = session.surfaceView.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
