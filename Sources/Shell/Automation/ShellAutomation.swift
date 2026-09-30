import AppKit

/// Errors surfaced to Shortcuts (and any other automation client).
enum AutomationError: Error, CustomLocalizedStringResourceConvertible {
    case sessionNotFound
    case noWindow
    case noIntegration
    case busy
    case nativeClaude
    case timedOut
    case sessionClosed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sessionNotFound: "That Shell session is no longer open."
        case .noWindow: "Shell couldn't open a window for the session."
        case .noIntegration:
            "This session doesn't have Shell's zsh integration, so Shell can't tell when a command finishes. Turn off Wait for Completion, or use a zsh session."
        case .busy: "A command is already running in this session."
        case .nativeClaude: "This session is showing Shell's native Claude Code view, which doesn't accept typed text from automation."
        case .timedOut: "Timed out waiting for the session."
        case .sessionClosed: "The session was closed while Shell was waiting for it."
        }
    }
}

/// What a finished command left behind.
struct CommandOutcome: Sendable {
    var command: String
    var exitCode: Int?
    var duration: TimeInterval?
    var output: String
}

/// What an agent reported while automation was waiting on it.
struct AgentOutcome: Sendable {
    var kind: AgentKind
    var event: String
    var message: String?
}

enum OutputScope: Sendable {
    case lastOutput, visibleScreen, scrollback
}

enum AgentWaitCondition: Sendable {
    case needsInput, finished, needsInputOrFinished

    func matches(_ event: String) -> Bool {
        switch self {
        case .needsInput: event == "needs-input"
        case .finished: event == "finished" || event == "ended"
        case .needsInputOrFinished: event == "needs-input" || event == "finished" || event == "ended"
        }
    }
}

/// The operations behind Shell's App Intents. The intents are thin wrappers
/// over this so the same behavior can back other automation surfaces.
@MainActor
enum ShellAutomation {
    /// How long to let libghostty render a finished command's output before
    /// reading it back from the scrollback.
    static let outputSettleDelay: Duration = .milliseconds(150)

    // MARK: Lookup

    /// Every window controller, including the hotkey window's.
    static var controllers: [TerminalWindowController] {
        var list = AppDelegate.shared.controllers
        if let hotkey = HotkeyWindow.shared.controller, !list.contains(where: { $0 === hotkey }) { list.append(hotkey) }
        return list
    }

    /// Sessions in window, tab, then pane order, followed by any the
    /// registry knows about that aren't in a window (mid-move).
    static var orderedSessions: [TerminalSession] {
        var seen = Set<UUID>()
        var result: [TerminalSession] = []
        for c in controllers {
            for tab in c.workspace.tabs {
                for s in tab.orderedSessions where seen.insert(s.id).inserted { result.append(s) }
            }
        }
        for s in SessionRegistry.shared.all where seen.insert(s.id).inserted { result.append(s) }
        return result
    }

    static func session(_ id: UUID) throws -> TerminalSession {
        guard let s = SessionRegistry.shared.session(id) else { throw AutomationError.sessionNotFound }
        return s
    }

    static func location(of session: TerminalSession) -> (controller: TerminalWindowController, tab: TerminalTab)? {
        for c in controllers {
            if let tab = c.workspace.tabs.first(where: { $0.sessions[session.id] != nil }) { return (c, tab) }
        }
        return nil
    }

    /// The pane the user is looking at in the frontmost Shell window.
    static var focusedSession: TerminalSession? {
        AppDelegate.shared.activeController?.focusedSession
    }

    // MARK: Opening

    static func openSession(directory: String?, command: String? = nil, newWindow: Bool = false) throws -> TerminalSession {
        guard let s = AppDelegate.shared.openTab(directory: directory, command: command, newWindow: newWindow) else {
            throw AutomationError.noWindow
        }
        return s
    }

    // MARK: Commands

    /// Runs `command` in `session`. With `wait`, suspends until the shell is
    /// back at a prompt and returns the exit code and output; without it,
    /// returns nil as soon as the command is sent.
    static func run(_ command: String, in session: TerminalSession, wait: Bool, timeout: TimeInterval) async throws -> CommandOutcome? {
        if session.nativeClaude != nil { throw AutomationError.nativeClaude }
        if wait, session.state == .unmanaged { throw AutomationError.noIntegration }
        if session.state == .running || session.pendingCommand != nil { throw AutomationError.busy }

        guard wait else {
            send(command, to: session)
            return nil
        }
        let sessionID = session.id
        _ = try await SessionWaiters.shared.wait(on: sessionID, timeout: timeout, register: {
            send(command, to: session)
        }, match: { event in
            if case .commandFinished = event { return true }
            return nil
        })
        try? await Task.sleep(for: outputSettleDelay)
        guard let finished = SessionRegistry.shared.session(sessionID) else { throw AutomationError.sessionClosed }
        return CommandOutcome(
            command: command,
            exitCode: finished.lastExitCode,
            duration: finished.lastDuration,
            output: finished.lastOutput() ?? "")
    }

    /// Queues or submits a command the way the rest of the app does: through
    /// the integration when there is one, typed in otherwise.
    private static func send(_ command: String, to session: TerminalSession) {
        switch session.state {
        case .idle:
            session.submit(command: command)
        case .starting:
            session.pendingCommand = command
        case .running, .unmanaged:
            session.surfaceView.sendText(command)
            session.surfaceView.writeRaw("\r")
        }
    }

    /// Types `text` into the session. At an idle zsh prompt with `pressReturn`
    /// this submits it as a command (so it's tracked like one); otherwise it
    /// goes to whatever is running, e.g. a coding agent's prompt.
    static func sendText(_ text: String, to session: TerminalSession, pressReturn: Bool) throws {
        if session.nativeClaude != nil { throw AutomationError.nativeClaude }
        if pressReturn, session.state == .idle {
            session.submit(command: text)
            return
        }
        if !text.isEmpty { session.surfaceView.sendText(text) }
        if pressReturn { session.surfaceView.writeRaw("\r") }
    }

    // MARK: Reading

    static func output(of session: TerminalSession, scope: OutputScope) -> String {
        let text: String
        switch scope {
        case .lastOutput: return session.lastOutput() ?? ""
        case .visibleScreen: text = session.surfaceView.readText(screen: false)
        case .scrollback: text = session.surfaceView.readText(screen: true)
        }
        return text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    // MARK: Windows

    static func focus(_ session: TerminalSession) throws {
        guard let (controller, _) = location(of: session) else { throw AutomationError.sessionNotFound }
        controller.reveal(session)
    }

    /// Closes the pane without the "process still running" sheet; callers
    /// confirm first when that matters.
    static func close(_ session: TerminalSession) throws {
        guard let (controller, tab) = location(of: session) else { throw AutomationError.sessionNotFound }
        controller.closePane(session, in: tab, confirm: false)
    }

    // MARK: Agents

    /// Suspends until an agent in `session` reports an event matching
    /// `condition`. Returns at once if the session is already in that state.
    static func waitForAgent(in session: TerminalSession, until condition: AgentWaitCondition, timeout: TimeInterval) async throws -> AgentOutcome {
        switch (session.agent, condition) {
        case (.needsInput(let kind, let msg)?, .needsInput), (.needsInput(let kind, let msg)?, .needsInputOrFinished):
            return AgentOutcome(kind: kind, event: "needs-input", message: msg)
        case (.finished(let kind, let msg)?, .finished), (.finished(let kind, let msg)?, .needsInputOrFinished):
            return AgentOutcome(kind: kind, event: "finished", message: msg)
        default:
            break
        }
        return try await SessionWaiters.shared.wait(on: session.id, timeout: timeout) { event in
            guard case .agent(let kind, let name, let message) = event, condition.matches(name) else { return nil }
            return AgentOutcome(kind: kind, event: name, message: message)
        }
    }
}
