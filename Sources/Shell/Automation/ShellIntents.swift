import AppIntents
import AppKit
import UniformTypeIdentifiers

// Actions for Shortcuts and Spotlight. Each is a thin wrapper over
// `ShellAutomation`; sessions pass between actions as `SessionEntity`, so a
// shortcut can open a tab, run something in it, wait, and read the output.
//
// `openAppWhenRun` is true only for actions whose point is to show something.
// The rest run with Shell in the background (launching it if needed).

// MARK: - Opening

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Shell Tab"
    static let description = IntentDescription(
        "Opens a new Shell tab, optionally in a folder and running a command, and returns its session.",
        categoryName: "Sessions")
    static let openAppWhenRun = true

    @Parameter(title: "Folder", supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(title: "Command", description: "Runs once the shell is ready.")
    var command: String?

    @Parameter(title: "In New Window", default: false)
    var newWindow: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Open a Shell tab in \(\.$folder)") {
            \.$command
            \.$newWindow
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        let session = try ShellAutomation.openSession(directory: folder?.fileURL?.path, command: command, newWindow: newWindow)
        return .result(value: SessionEntity(session))
    }
}

struct StartClaudeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Claude Code in Shell"
    static let description = IntentDescription(
        "Opens a Shell tab in a folder and starts Claude Code there, in the native view or terminal UI per your settings.",
        categoryName: "Agents")
    static let openAppWhenRun = true

    @Parameter(title: "Folder", supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(title: "Prompt", description: "Sent to Claude as the first message.", inputOptions: .init(multiline: true))
    var prompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start Claude Code in \(\.$folder)") {
            \.$prompt
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        var command = "claude"
        if let prompt, !prompt.isEmpty { command += " " + ShellQuote.quote(prompt) }
        let session = try ShellAutomation.openSession(directory: folder?.fileURL?.path, command: command)
        return .result(value: SessionEntity(session))
    }
}

// MARK: - Commands

struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command in Shell"
    static let description = IntentDescription(
        """
        Runs a command in a Shell session, or in a new tab. Turn on Wait for Completion to get the exit code and \
        output back; that needs Shell's zsh integration.
        """,
        categoryName: "Commands")
    static let openAppWhenRun = false

    @Parameter(title: "Command", inputOptions: .init(multiline: true))
    var command: String

    @Parameter(title: "Session", description: "Leave empty to open a new tab.")
    var session: SessionEntity?

    @Parameter(title: "Folder", description: "For a new tab.", supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(title: "Wait for Completion", default: false)
    var waitForCompletion: Bool

    @Parameter(title: "Timeout (Seconds)", default: 600, inclusiveRange: (1, 86_400))
    var timeout: Int

    static var parameterSummary: some ParameterSummary {
        When(\.$waitForCompletion, .equalTo, true) {
            Summary("Run \(\.$command) in \(\.$session)") {
                \.$folder
                \.$waitForCompletion
                \.$timeout
            }
        } otherwise: {
            Summary("Run \(\.$command) in \(\.$session)") {
                \.$folder
                \.$waitForCompletion
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CommandResultEntity> {
        let target: TerminalSession
        if let session {
            target = try ShellAutomation.session(session.id)
        } else {
            // A fresh tab starts its shell asynchronously; `run` queues the
            // command for its first prompt.
            target = try ShellAutomation.openSession(directory: folder?.fileURL?.path)
        }
        let outcome = try await ShellAutomation.run(command, in: target, wait: waitForCompletion, timeout: TimeInterval(timeout))

        let result = CommandResultEntity()
        result.command = command
        result.exitCode = outcome?.exitCode
        result.succeeded = outcome.map { $0.exitCode == 0 } ?? false
        result.output = outcome?.output ?? ""
        result.duration = outcome?.duration
        result.session = SessionRegistry.shared.session(target.id).map(SessionEntity.init)
        return .result(value: result)
    }
}

struct SendTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Text to Shell Session"
    static let description = IntentDescription(
        """
        Types text into a Shell session. At a zsh prompt it runs as a command; otherwise it goes to whatever is \
        running, such as a Claude Code or Codex prompt.
        """,
        categoryName: "Commands")
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: .init(multiline: true))
    var text: String

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Press Return", default: true)
    var pressReturn: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to \(\.$session)") {
            \.$pressReturn
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        let target = try ShellAutomation.session(session.id)
        if case .working(let kind)? = target.agent {
            try await requestConfirmation(
                dialog: "\(kind.displayName) is working in \(target.displayTitle). Send the text anyway?")
        }
        try ShellAutomation.sendText(text, to: target, pressReturn: pressReturn)
        return .result(value: SessionEntity(target))
    }
}

// MARK: - Reading

enum OutputScopeAppEnum: String, AppEnum {
    case lastOutput, visibleScreen, scrollback

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Output"
    static let caseDisplayRepresentations: [OutputScopeAppEnum: DisplayRepresentation] = [
        .lastOutput: "Last Command's Output",
        .visibleScreen: "Visible Screen",
        .scrollback: "Entire Scrollback",
    ]

    var scope: OutputScope {
        switch self {
        case .lastOutput: .lastOutput
        case .visibleScreen: .visibleScreen
        case .scrollback: .scrollback
        }
    }
}

struct GetSessionOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Shell Session Output"
    static let description = IntentDescription(
        "Returns text from a Shell session: the last command's output, the visible screen, or the whole scrollback.",
        categoryName: "Sessions")
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Output", default: .lastOutput)
    var scope: OutputScopeAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$scope) of \(\.$session)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let target = try ShellAutomation.session(session.id)
        return .result(value: ShellAutomation.output(of: target, scope: scope.scope))
    }
}

struct GetCurrentSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Shell Session"
    static let description = IntentDescription(
        "Returns the pane that's focused in the frontmost Shell window.", categoryName: "Sessions")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        guard let session = ShellAutomation.focusedSession else { throw AutomationError.sessionNotFound }
        return .result(value: SessionEntity(session))
    }
}

// MARK: - Windows

struct FocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Shell Session"
    static let description = IntentDescription(
        "Brings a session's window, tab and pane to the front.", categoryName: "Sessions")
    static let openAppWhenRun = true

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$session)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try ShellAutomation.focus(ShellAutomation.session(session.id))
        return .result()
    }
}

struct CloseSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Shell Session"
    static let description = IntentDescription(
        "Closes a session's pane. Asks first if a process is still running in it.", categoryName: "Sessions")
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Close \(\.$session)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let target = try ShellAutomation.session(session.id)
        if target.surfaceView.needsConfirmQuit {
            try await requestConfirmation(dialog: "A process is still running in \(target.displayTitle). Close it anyway?")
        }
        try ShellAutomation.close(target)
        return .result()
    }
}

// MARK: - Agents

enum AgentWaitAppEnum: String, AppEnum {
    case needsInputOrFinished, needsInput, finished

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent Event"
    static let caseDisplayRepresentations: [AgentWaitAppEnum: DisplayRepresentation] = [
        .needsInputOrFinished: "Needs Input or Finishes",
        .needsInput: "Needs Input",
        .finished: "Finishes",
    ]

    var condition: AgentWaitCondition {
        switch self {
        case .needsInputOrFinished: .needsInputOrFinished
        case .needsInput: .needsInput
        case .finished: .finished
        }
    }
}

struct WaitForAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Wait for Agent in Shell"
    static let description = IntentDescription(
        """
        Waits until Claude Code or Codex in a Shell session needs input or finishes. Needs Shell's agent hooks \
        (Settings › Claude & Codex › Install).
        """,
        categoryName: "Agents")
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Until", default: .needsInputOrFinished)
    var until: AgentWaitAppEnum

    @Parameter(title: "Timeout (Seconds)", default: 600, inclusiveRange: (1, 86_400))
    var timeout: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Wait until the agent in \(\.$session) \(\.$until)") {
            \.$timeout
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AgentUpdateEntity> {
        let target = try ShellAutomation.session(session.id)
        let outcome = try await ShellAutomation.waitForAgent(in: target, until: until.condition, timeout: TimeInterval(timeout))

        let update = AgentUpdateEntity()
        update.status = outcome.event == "needs-input" ? .needsInput : .finished
        update.agent = outcome.kind.displayName
        update.message = outcome.message
        update.session = SessionRegistry.shared.session(target.id).map(SessionEntity.init)
        return .result(value: update)
    }
}

// MARK: - Menu actions

/// The menu commands that make sense to trigger from a shortcut. Raw values
/// match `ShortcutAction`.
enum ShellActionAppEnum: String, AppEnum {
    case newWindow, newTab, closeTab, splitRight, splitDown, nextTab, previousTab, zoomPane, equalizePanes
    case broadcastInput, moveTabToNewWindow, clearBuffer, scrollToTop, scrollToBottom
    case increaseFontSize, decreaseFontSize, resetFontSize, toggleInputEditor, toggleTabBarStyle, toggleSidebar
    case claudeDashboard, toggleNotifications, commandPalette, settings, reloadConfig, mcpServers, homebrew

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Shell Action"
    static let caseDisplayRepresentations: [ShellActionAppEnum: DisplayRepresentation] = [
        .newWindow: "New Window",
        .newTab: "New Tab",
        .closeTab: "Close Tab",
        .splitRight: "Split Right",
        .splitDown: "Split Down",
        .nextTab: "Show Next Tab",
        .previousTab: "Show Previous Tab",
        .zoomPane: "Maximize Pane",
        .equalizePanes: "Equalize Pane Sizes",
        .broadcastInput: "Broadcast Input to All Panes",
        .moveTabToNewWindow: "Move Tab to New Window",
        .clearBuffer: "Clear Buffer",
        .scrollToTop: "Scroll to Top",
        .scrollToBottom: "Scroll to Bottom",
        .increaseFontSize: "Make Text Bigger",
        .decreaseFontSize: "Make Text Smaller",
        .resetFontSize: "Make Text Normal Size",
        .toggleInputEditor: "Toggle Native Prompt",
        .toggleTabBarStyle: "Toggle Vertical Tabs",
        .toggleSidebar: "Toggle Files & Worktrees Sidebar",
        .claudeDashboard: "Claude Dashboard",
        .toggleNotifications: "Agent Activity",
        .commandPalette: "Command Palette",
        .settings: "Settings",
        .reloadConfig: "Reload Configuration",
        .mcpServers: "MCP Servers",
        .homebrew: "Homebrew Packages",
    ]

    var action: ShortcutAction? { ShortcutAction(rawValue: rawValue) }
}

struct PerformShellActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Perform Shell Action"
    static let description = IntentDescription(
        "Runs a Shell menu command in the frontmost window, the same as its keyboard shortcut.", categoryName: "Windows")
    static let openAppWhenRun = true

    @Parameter(title: "Action")
    var action: ShellActionAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Perform \(\.$action)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let action = action.action { AppDelegate.shared.perform(action) }
        return .result()
    }
}

// MARK: - App Shortcuts

struct ShellShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewTabIntent(),
                    phrases: ["New \(.applicationName) tab", "Open a \(.applicationName) tab"],
                    shortTitle: "New Tab", systemImageName: "plus.rectangle.on.rectangle")
        AppShortcut(intent: RunCommandIntent(),
                    phrases: ["Run a command in \(.applicationName)"],
                    shortTitle: "Run Command", systemImageName: "terminal")
        AppShortcut(intent: StartClaudeIntent(),
                    phrases: ["Start Claude in \(.applicationName)"],
                    shortTitle: "Start Claude", systemImageName: "sparkle")
        AppShortcut(intent: FocusSessionIntent(),
                    phrases: ["Show a \(.applicationName) session"],
                    shortTitle: "Show Session", systemImageName: "macwindow")
        AppShortcut(intent: PerformShellActionIntent(),
                    phrases: ["Perform a \(.applicationName) action", "\(\.$action) in \(.applicationName)"],
                    shortTitle: "Shell Action", systemImageName: "command")
    }
}
