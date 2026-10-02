import AppKit
import Observation
import UniformTypeIdentifiers

// MARK: - Model

struct ClaudeModelOption: Identifiable, Hashable {
    var value: String
    var displayName: String
    var description: String
    var effortLevels: [String]
    var supportsAutoMode: Bool
    var id: String { value }

    /// The real model and version ("Opus 5 (1M)", "Fable 5.1") instead of an
    /// alias like "Default" or "Fable". Claude Code puts it at the start of the
    /// description ("Opus 5 with 1M context · Best for…"); otherwise it's
    /// derived from the model ID.
    var label: String {
        let head = description.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if head.rangeOfCharacter(from: .decimalDigits) != nil, head.count <= 40 {
            return head.replacingOccurrences(of: " with 1M context", with: " (1M)")
        }
        if value.contains("-") { return ClaudeModelName.format(value) }
        return displayName.isEmpty ? value : displayName
    }

    /// What the option is for, with "Default" noted for the default entry.
    var detail: String {
        let parts = description.components(separatedBy: " · ")
        let rest = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : (label == description ? "" : description)
        guard value == "default" else { return rest }
        return rest.isEmpty ? "Default" : "Default · " + rest
    }
}

/// Human names for model IDs: "claude-opus-5-5" → "Opus 5.5",
/// "claude-fable-5-1[1m]" → "Fable 5.1 (1M)", "claude-haiku-4-5-20251001" → "Haiku 4.5".
enum ClaudeModelName {
    static func format(_ id: String) -> String {
        var base = id
        var suffix = ""
        if let bracket = base.firstIndex(of: "[") {
            if base[bracket...].lowercased() == "[1m]" { suffix = " (1M)" }
            base = String(base[..<bracket])
        }
        var parts = base.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() } // date suffix
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version) + suffix
    }
}

/// A slash command or skill the session offers (from `initialize`).
struct ClaudeCommandInfo: Identifiable, Hashable {
    var name: String
    var description: String
    var argumentHint: String
    var id: String { name }
}

struct ClaudeMCPServer: Identifiable, Hashable {
    var name: String
    var status: String
    var id: String { name }
    /// How the server is referenced in a prompt (`@name`), without spaces.
    var mention: String { name.replacingOccurrences(of: " ", with: "-") }
}

enum ClaudePermissionMode: String, CaseIterable, Identifiable {
    case `default`, acceptEdits, plan, auto, dontAsk, bypassPermissions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: "Ask before edits"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan mode"
        case .auto: "Auto mode"
        case .dontAsk: "Don't ask"
        case .bypassPermissions: "Bypass permissions"
        }
    }

    var detail: String {
        switch self {
        case .default: "Claude asks before editing files or running commands"
        case .acceptEdits: "File edits are applied without asking"
        case .plan: "Claude researches and proposes a plan without making changes"
        case .auto: "A classifier approves safe actions and asks about risky ones"
        case .dontAsk: "Anything not already allowed is denied without asking"
        case .bypassPermissions: "Every action runs without asking"
        }
    }

    var symbol: String {
        switch self {
        case .default: "hand.raised"
        case .acceptEdits: "forward.fill"
        case .plan: "pause.fill"
        case .auto: "bolt.fill"
        case .dontAsk: "nosign"
        case .bypassPermissions: "exclamationmark.triangle.fill"
        }
    }

    /// Shift-Tab order, like Claude Code's terminal UI.
    static func cycle(from mode: ClaudePermissionMode, autoAvailable: Bool) -> ClaudePermissionMode {
        let order: [ClaudePermissionMode] = autoAvailable ? [.default, .acceptEdits, .plan, .auto] : [.default, .acceptEdits, .plan]
        guard let i = order.firstIndex(of: mode) else { return .default }
        return order[(i + 1) % order.count]
    }
}

/// One entry in the transcript.
@MainActor
@Observable
final class ClaudeItem: Identifiable {
    enum Kind { case user, assistant, thinking, tool, notice, error, checkFailure }

    let id = UUID()
    /// Identifies the end-of-turn summary row that follows this turn.
    let summaryID = UUID()
    let kind: Kind
    var text: String
    /// When it began: the block started streaming, the tool started running,
    /// the message was sent (or its transcript timestamp, for history).
    var startedAt: Date
    /// When the block finished streaming or the tool's result arrived.
    var endedAt: Date?
    // Tool calls
    var toolID: String?
    var toolName = ""
    @ObservationIgnored var input: [String: Any] = [:]
    var summary = ""
    var result: String?
    var isError = false
    var isRunning = false
    /// The step's right-hand detail ("L1–184", "5 lines"), set with the result.
    var meta: String?
    /// Lines added and removed by an edit, set with the result.
    var diffStats: ClaudeDiffStats?
    /// A Write that created the file (Claude Code reports `type: create`).
    var createdFile = false
    /// AskUserQuestion: the answer per question text, once the user replied.
    var answers: [String: String]?
    /// Images and files sent with a user message.
    var attachments: [ClaudeAttachment] = []
    /// User messages: how long the turn they started took, and what it cost.
    var turnDuration: TimeInterval?
    var turnCost: Double?
    /// `.checkFailure`: the failed CI job and its log.
    var checkFailure: ClaudeCheckFailure?
    /// `.checkFailure`: "Fix with Claude" was used.
    var checkFixRequested = false

    init(kind: Kind, text: String = "", at date: Date = Date()) {
        self.kind = kind
        self.text = text
        startedAt = date
    }

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    func setInput(_ input: [String: Any]) {
        var input = input
        // A Write's full file stays in memory for the whole session otherwise;
        // the transcript only shows its first 400 lines.
        if let content = input["content"] as? String, content.utf8.count > ClaudeCodeSession.maxStoredText {
            input["content"] = String(content.prefix(ClaudeCodeSession.maxStoredText))
        }
        self.input = input
        summary = ClaudeToolFormat.summary(name: toolName, input: input)
    }
}

/// One question from Claude's AskUserQuestion tool.
struct ClaudeQuestion: Identifiable, Hashable {
    struct Option: Hashable {
        var label: String
        var description: String
        /// A mockup or snippet shown while the option is highlighted.
        var preview: String?
    }

    var question: String
    var header: String
    var options: [Option]
    var multiSelect: Bool
    var id: String { question }

    static func parse(_ input: [String: Any]) -> [ClaudeQuestion] {
        (input["questions"] as? [[String: Any]] ?? []).map { q in
            ClaudeQuestion(
                question: q["question"] as? String ?? "",
                header: q["header"] as? String ?? "",
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "",
                           preview: ($0["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                },
                multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// Answers from a tool result: the structured `answers` map when the CLI
    /// provides it, else the `"question"="answer"` pairs in its text.
    static func answers(structured: Any?, text: String) -> [String: String]? {
        if let result = structured as? [String: Any], let answers = result["answers"] as? [String: String], !answers.isEmpty {
            return answers
        }
        var answers: [String: String] = [:]
        for m in text.matches(of: /"((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)"/) {
            answers[String(m.output.1)] = String(m.output.2)
        }
        return answers.isEmpty ? nil : answers
    }
}

/// A tool call waiting for the user's decision.
struct ClaudePermissionRequest: Identifiable {
    var id: String // control request_id
    var toolName: String
    var displayName: String
    var input: [String: Any]
    var description: String?
    var suggestions: [Any]
    var reason: String?
    /// The transcript tool call this prompt belongs to.
    var toolUseID: String?

    var isQuestion: Bool { toolName == "AskUserQuestion" }
    /// ExitPlanMode: Claude is asking to leave plan mode with a plan.
    var isPlan: Bool { toolName == "ExitPlanMode" }
    var plan: String { input["plan"] as? String ?? "" }

    var questions: [ClaudeQuestion] { ClaudeQuestion.parse(input) }
}

// MARK: - Session

/// Drives `claude -p --input-format stream-json --output-format stream-json`
/// with the same control protocol the Agent SDK uses: permission prompts come
/// back as `can_use_tool` requests, and model, effort and permission mode can
/// be changed mid-session.
@MainActor
@Observable
final class ClaudeCodeSession {
    let request: ClaudeLaunchRequest
    let directory: String

    private(set) var items: [ClaudeItem] = []
    private(set) var pending: [ClaudePermissionRequest] = []
    private(set) var isRunning = false
    private(set) var isStarting = true
    private(set) var hasExited = false
    /// Set when the folder hasn't been trusted in Claude Code; nothing was started.
    private(set) var needsTrust = false
    /// Set while Claude Code isn't signed in; the view shows the sign-in card.
    private(set) var login: ClaudeLogin?
    /// A `claude` process was started (after the trust and sign-in checks).
    private(set) var isLaunched = false
    /// The conversation has begun: something is in the transcript, or this
    /// continues an earlier session. The view centers the composer until then.
    /// Never goes back to false, so the composer doesn't jump back up.
    private(set) var hasStarted: Bool
    private(set) var statusText: String?
    private(set) var sessionID: String?

    private(set) var models: [ClaudeModelOption] = []
    private(set) var model: String
    /// The model the API actually reported (e.g. claude-opus-5).
    private(set) var resolvedModel: String?
    private(set) var effort: String
    private(set) var permissionMode: ClaudePermissionMode
    /// Pass --permission-mode even for `.default`, so a chosen "Ask before edits"
    /// isn't overridden by Claude Code's settings.json.
    @ObservationIgnored private let explicitPermissionMode: Bool
    private(set) var commands: [ClaudeCommandInfo] = []
    private(set) var skills: Set<String> = []
    private(set) var mcpServers: [ClaudeMCPServer] = []
    private(set) var agents: [String] = []
    private(set) var accountLabel: String?
    private(set) var totalCost: Double = 0
    private(set) var lastTurnDuration: TimeInterval?
    private(set) var contextTokens: Int?
    /// When the running turn started (nil between turns).
    private(set) var turnStartedAt: Date?
    /// Output tokens generated in the running turn, estimated while a
    /// message streams and exact once its usage arrives.
    private(set) var turnOutputTokens = 0
    /// What the running turn is about when Shell started it ("Fixing Build and test").
    private(set) var turnTitle: String?
    /// Claude's latest TodoWrite list.
    private(set) var todos: [ClaudeTodo] = []
    /// Subagents and `run_in_background` commands, oldest first. Finished ones
    /// stay (with their status) until the session ends.
    private(set) var backgroundTasks: [ClaudeBackgroundTask] = []
    /// Files Claude changed this session, in first-changed order, with summed
    /// added/removed lines.
    private(set) var changedFiles: [ClaudeChangedFile] = []
    /// The git repository or worktree the session runs in, if any.
    private(set) var repository: GitRepository?
    private(set) var repositoryChecked = false
    /// claude.ai/code link while Remote Control is on (continue from the Claude app).
    private(set) var remoteControlURL: URL?
    private(set) var remoteControlBusy = false
    private(set) var remoteControlError: String?

    /// Whether the window's file explorer shows this session's repository.
    var showExplorer = SettingsStore.shared.settings.claudeFileExplorer
    /// Explorer UI state kept per session (expanded folders).
    @ObservationIgnored var explorerExpanded: Set<String> = []
    /// Set by the view so other UI (the file explorer) can add to the prompt.
    @ObservationIgnored var insertIntoPrompt: ((String) -> Void)?

    /// Drafts the composer should show (e.g. after "Edit last prompt").
    var draft = ""
    /// Attachments waiting in the composer (kept with the draft across view rebuilds).
    var draftAttachments: [ClaudeAttachment] = []
    @ObservationIgnored var onEvent: ((String, String?) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: FileHandle?
    @ObservationIgnored private var stderrTail: [String] = []
    @ObservationIgnored private var requestCounter = 0
    @ObservationIgnored private var callbacks: [String: ([String: Any]?, String?) -> Void] = [:]
    @ObservationIgnored private var streamed: Set<String> = []
    @ObservationIgnored private var blockItems: [Int: ClaudeItem] = [:]
    @ObservationIgnored private var toolItems: [String: ClaudeItem] = [:]
    @ObservationIgnored private var turnHadText = false
    /// Ignores output and exit from a process replaced after signing in.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var authChecked = false
    @ObservationIgnored private var hasSentMessage = false
    @ObservationIgnored private var hasCompletedTurn = false
    @ObservationIgnored private var closed = false
    /// The current turn failed because Claude Code isn't signed in.
    @ObservationIgnored private var turnNeedsLogin = false
    /// The last message sent, with its attachments, and the message to send
    /// again once signed in.
    @ObservationIgnored private var lastSent: SentMessage?
    @ObservationIgnored private var resendAfterLogin: SentMessage?
    /// The transcript timestamp of the history entry being applied; live
    /// events use the clock.
    @ObservationIgnored private var eventDate: Date?
    private var now: Date { eventDate ?? Date() }
    /// Output tokens per message in the running turn, the message streaming
    /// now, and the characters it has streamed (≈4 per token) before its usage arrives.
    @ObservationIgnored private var outputByMessage: [String: Int] = [:]
    @ObservationIgnored private var streamMessageID: String?
    @ObservationIgnored private var streamChars = 0
    @ObservationIgnored private var costAtTurnStart: Double = 0
    @ObservationIgnored private var todosUpdatedAt: Date?

    private struct SentMessage {
        var text: String
        var attachments: [ClaudeAttachment]
        var item: ClaudeItem
    }

    @ObservationIgnored private var mcpObserver: NSObjectProtocol?

    init(request: ClaudeLaunchRequest) {
        self.request = request
        directory = request.directory
        hasStarted = request.arguments.continuesSession || request.arguments.resumeID != nil
        let s = SettingsStore.shared.settings
        model = request.arguments.model ?? (s.claudeModel.isEmpty ? "default" : s.claudeModel)
        effort = request.arguments.effort ?? s.claudeEffort
        // --permission-mode on the command line, else Shell's default (Settings ›
        // Claude & Codex), else Claude Code's own `permissions.defaultMode`.
        let chosen = ClaudePermissionMode(rawValue: request.arguments.permissionMode ?? "")
            ?? ClaudePermissionMode(rawValue: s.claudePermissionMode)
        permissionMode = chosen ?? .default
        explicitPermissionMode = chosen != nil
    }

    // MARK: Derived

    var currentModel: ClaudeModelOption? { models.first { $0.value == model } }
    var effortLevels: [String] { currentModel?.effortLevels ?? ["low", "medium", "high", "xhigh", "max"] }
    var autoModeAvailable: Bool { currentModel?.supportsAutoMode ?? true }
    var availableModes: [ClaudePermissionMode] {
        ClaudePermissionMode.allCases.filter { mode in
            switch mode {
            case .auto: autoModeAvailable
            case .bypassPermissions: request.arguments.allowsBypass || permissionMode == .bypassPermissions
            default: true
            }
        }
    }

    /// The model's context window, for the composer's meter (see `ClaudeContextWindow`).
    var contextWindow: Int {
        max(ClaudeContextWindow.size(model: model, description: currentModel?.description, inUse: contextTokens),
            ClaudeContextWindow.size(model: resolvedModel))
    }

    /// Background work still running.
    var runningBackgroundTasks: [ClaudeBackgroundTask] { backgroundTasks.filter(\.isRunning) }

    /// What the status line says Claude is doing: a status ("Compacting…"),
    /// the turn's purpose, the to-do in progress, the running tool, or
    /// thinking / writing.
    var activityLabel: String {
        if let statusText { return statusText }
        if let turnTitle { return turnTitle }
        if let started = turnStartedAt, let updated = todosUpdatedAt, updated >= started,
           let todo = todos.first(where: { $0.status == .inProgress }) {
            return todo.activeForm.isEmpty ? todo.content : todo.activeForm
        }
        for item in items.reversed() {
            if item.kind == .user { break }
            guard item.isRunning || (item.kind == .assistant && item.endedAt == nil) else { continue }
            switch item.kind {
            case .tool: return ClaudeActivity.label(tool: item.toolName, input: item.input)
            case .thinking: return "Thinking"
            case .assistant: return "Writing"
            default: continue
            }
        }
        return "Working"
    }

    var modelTitle: String {
        if let m = currentModel { return m.label }
        if let resolvedModel { return ClaudeModelName.format(resolvedModel) }
        if model.contains("-") { return ClaudeModelName.format(model) }
        return model == "default" ? "Default" : model.capitalized
    }

    // MARK: Naming

    /// "owner/repo · branch · PR #12" when in a repository, for Claude Code's
    /// session list (/resume). Nil outside git.
    var sessionName: String? {
        guard let repo = repository else { return nil }
        var parts = [repo.github?.slug ?? repo.name, repo.branchLabel]
        if let pr = repo.pullRequest { parts.append("PR #\(pr.number)") }
        return parts.joined(separator: " · ")
    }

    /// Short form for the tab: "repo · branch · #12".
    var tabTitle: String {
        guard let repo = repository else { return "Claude" }
        var parts = [repo.github?.name ?? repo.name, repo.branchLabel]
        if let pr = repo.pullRequest { parts.append("#\(pr.number)") }
        return parts.joined(separator: " · ")
    }

    @ObservationIgnored private var sentName: String?
    @ObservationIgnored private var nameTrackingArmed = false

    /// Renames the Claude Code session whenever the repo, branch or PR
    /// changes — unless the user named it with -n/--name.
    private func syncSessionName() {
        guard !request.arguments.passthrough.contains(where: { $0 == "-n" || $0 == "--name" }) else { return }
        if !nameTrackingArmed {
            nameTrackingArmed = true
            withObservationTracking {
                _ = sessionName
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.nameTrackingArmed = false
                        self?.syncSessionName()
                    }
                }
            }
        }
        guard let name = sessionName, name != sentName, sessionID != nil, !hasExited else { return }
        sentName = name
        sendControl(["subtype": "rename_session", "title": name])
    }

    var skillCommands: [ClaudeCommandInfo] { commands.filter { skills.contains($0.name) } }

    // MARK: Lifecycle

    /// Trusts the folder in Claude Code's config (as its own trust prompt
    /// would), then starts the session.
    func trustAndStart() {
        do {
            try ClaudeTrust.trust(directory)
        } catch {
            Log.claude.error("trust failed for \(self.directory, privacy: .private): \(error.localizedDescription, privacy: .public)")
            append(ClaudeItem(kind: .error, text: "Couldn't update \(ClaudeTrust.configURL.path): \(error.localizedDescription)"))
            return
        }
        needsTrust = false
        hasExited = false
        isStarting = true
        start()
    }

    func start() {
        guard ClaudeTrust.ensureTrusted(directory) else {
            needsTrust = true
            isStarting = false
            hasExited = true
            return
        }
        // Print mode can't run /login, so check first and sign in from the view.
        guard authChecked else {
            Task { [weak self, request] in
                let status = await ClaudeAuth.status(binary: request.binary, environment: request.environment,
                                                     directory: request.directory)
                guard let self, !self.closed else { return }
                authChecked = true
                if status == .loggedOut { requireLogin(expired: false) } else { start() }
            }
            return
        }
        guard launch() else { return }

        loadHistory()
        // Pick up sign-ins and toggles made in the MCP manager.
        mcpObserver = NotificationCenter.default.addObserver(forName: .mcpServerDidChange, object: nil, queue: .main) { [weak self] note in
            guard let name = note.userInfo?["name"] as? String else { return }
            MainActor.assumeIsolated { self?.reconnectMCP(name) }
        }
        Task { [weak self, directory, env = request.environment] in
            let repo = await GitRepository.discover(from: directory, environment: env)
            guard let self else { repo?.stop(); return }
            if hasExited || closed { repo?.stop() } else { repository = repo; watchChecks() }
            repositoryChecked = true
            syncSessionName()
        }
        if let prompt = request.arguments.prompt { send(prompt) }
    }

    /// Starts the `claude` process. `resume` replaces the command line's
    /// -c/--resume when restarting a conversation after signing in.
    @discardableResult
    private func launch(resume: String? = nil) -> Bool {
        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: request.binary)
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        if model != "default" { args += ["--model", model] }
        if !effort.isEmpty { args += ["--effort", effort] }
        if permissionMode != .default || explicitPermissionMode { args += ["--permission-mode", permissionMode.rawValue] }
        if let resume {
            args += Self.withoutSessionSelection(request.arguments.passthrough) + ["--resume", resume]
        } else {
            args += request.arguments.passthrough
        }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = request.environment
        // Shell's hooks would double-report this session; the view reports directly.
        for key in ["SHELL_APP_CTL", "SHELL_APP_SOCKET", "SHELL_APP_SESSION"] { env[key] = nil }
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let decoder = StreamJSONDecoder { [weak self] batch in
            guard let self, gen == generation else { return }
            for obj in batch.objects { handle(obj) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Empty = EOF. Without clearing the handler, GCD keeps calling it.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            decoder.feed(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
                    if self.stderrTail.count > 40 { self.stderrTail.removeFirst(self.stderrTail.count - 40) }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.processExited(code: code)
                }
            }
        }
        do {
            try p.run()
        } catch {
            append(ClaudeItem(kind: .error, text: "Couldn't start \(request.binary): \(error.localizedDescription)"))
            isStarting = false
            hasExited = true
            return false
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        isLaunched = true

        sendControl(["subtype": "initialize"]) { [weak self] response, _ in
            guard let self else { return }
            applyInitialize(response ?? [:])
            if SettingsStore.shared.settings.claudeRemoteControl || request.arguments.passthrough.contains("--remote-control") {
                setRemoteControl(true)
            }
        }
        return true
    }

    /// Passthrough flags without the ones that pick a conversation
    /// (-c, --resume, --session-id, --fork-session).
    nonisolated static func withoutSessionSelection(_ passthrough: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < passthrough.count {
            switch passthrough[i] {
            case "-c", "--continue", "--fork-session": i += 1
            case "-r", "--resume", "--session-id": i += 2
            default:
                result.append(passthrough[i])
                i += 1
            }
        }
        return result
    }

    func terminate() {
        closed = true
        login?.stop()
        if let mcpObserver { NotificationCenter.default.removeObserver(mcpObserver) }
        mcpObserver = nil
        // Release our share of the repository once (it's shared with other views).
        if let repository, repository.github != nil { BranchChecksModel.shared(for: repository).removeFailureObserver(self) }
        repository?.stop()
        repository = nil
        try? stdin?.close()
        stdin = nil
        stopProcess()
    }

    private func stopProcess() {
        guard let p = process else { return }
        process = nil
        for pipe in [p.standardOutput, p.standardError] { (pipe as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + AppEnvironment.wait(2)) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private func processExited(code: Int32) {
        hasExited = true
        endProcessState(reason: "Claude Code exited")
        // Signed out: the sign-in card already says what happened.
        guard login == nil else { return }
        if code != 0 && code != SIGTERM {
            let detail = stderrTail.suffix(8).joined(separator: "\n")
            append(ClaudeItem(kind: .error, text: "Claude Code exited with status \(code)." + (detail.isEmpty ? "" : "\n\n" + detail)))
        }
        onEvent?("ended", nil)
    }

    /// Clears everything tied to the running process.
    private func endProcessState(reason: String) {
        isRunning = false
        isStarting = false
        turnStartedAt = nil
        turnTitle = nil
        pending.removeAll()
        for item in toolItems.values where item.isRunning { item.isRunning = false; item.endedAt = item.endedAt ?? now }
        // Nothing reports on these any more.
        for i in backgroundTasks.indices where backgroundTasks[i].isRunning {
            backgroundTasks[i].status = .stopped
            backgroundTasks[i].endedAt = now
        }
        // Nothing will answer these now.
        for callback in callbacks.values { callback(nil, reason) }
        callbacks.removeAll()
        toolItems.removeAll()
        blockItems = [:]
        turnNeedsLogin = false
        try? stdin?.close()
        stdin = nil
    }

    // MARK: Sign-in

    /// Shows the sign-in card. `expired` when a running session lost its sign-in.
    private func requireLogin(expired: Bool) {
        isStarting = false
        guard login == nil else { return }
        let login = ClaudeLogin(binary: request.binary, environment: request.environment, directory: directory, expired: expired)
        login.onSignedIn = { [weak self] in self?.signedIn() }
        self.login = login
    }

    /// Starts the session, or restarts it so Claude Code picks up the new
    /// sign-in, continuing the conversation and sending the message that failed.
    private func signedIn() {
        login = nil
        guard !closed else { return }
        guard isLaunched else {
            start()
            return
        }
        generation += 1
        stopProcess()
        endProcessState(reason: "Claude Code restarted after signing in")
        stderrTail.removeAll()
        hasExited = false
        isStarting = true
        // A conversation exists once a message was sent; otherwise start as the command line asked.
        guard launch(resume: hasSentMessage ? sessionID : nil) else { return }
        if let message = resendAfterLogin {
            resendAfterLogin = nil
            items.removeAll { $0 === message.item }
            send(message.text, attachments: message.attachments)
        }
    }

    /// Tool output kept per call in the transcript (whole-file reads and long
    /// command output otherwise stay in memory for the whole session).
    nonisolated static let maxStoredText = 64 * 1024

    nonisolated static func capped(_ text: String) -> String {
        guard text.utf8.count > maxStoredText else { return text }
        let kept = String(text.prefix(maxStoredText))
        return kept + "\n… (\(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count - kept.utf8.count), countStyle: .file)) more not shown)"
    }

    // MARK: Sending

    /// False while starting up, signed out, or after Claude Code exited; the
    /// composer keeps its text until then.
    var canSend: Bool { isLaunched && !hasExited && login == nil }

    func send(_ text: String, attachments: [ClaudeAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, canSend else { return }
        let item = ClaudeItem(kind: .user, text: trimmed)
        // Sent: keep the thumbnail and file, not the encoded image bytes.
        item.attachments = attachments.map { $0.withoutImageData() }
        append(item)
        // Kept until the turn succeeds, to send again if it fails for want of a sign-in.
        lastSent = SentMessage(text: trimmed, attachments: attachments, item: item)
        hasSentMessage = true
        write(["type": "user",
               "message": ["role": "user", "content": ClaudeAttachment.content(text: trimmed, attachments: attachments, directory: directory)],
               "parent_tool_use_id": NSNull(),
               "session_id": sessionID ?? ""])
        isRunning = true
        turnHadText = false
        statusText = nil
        turnTitle = nil
        // A message sent mid-turn joins the running turn.
        if turnStartedAt == nil {
            turnStartedAt = item.startedAt
            costAtTurnStart = totalCost
            outputByMessage = [:]
            streamChars = 0
            turnOutputTokens = 0
        }
        onEvent?("working", nil)
    }

    // MARK: CI checks

    /// Shows a failed CI check in the transcript, with Fix with Claude,
    /// Re-run and Full log. Wiring new failures to sessions is up to the caller.
    func appendCheckFailure(_ job: CheckJob, log: String) {
        let item = ClaudeItem(kind: .checkFailure, at: now)
        item.checkFailure = ClaudeCheckFailure(job: job, log: Self.capped(log), headSHA: checkHeadSHA())
        append(item)
    }

    /// Asks Claude to fix a failed check: sends "Fix the failing check: …"
    /// with the log attached as a file Claude reads. False when nothing could
    /// be sent (Claude isn't running).
    @discardableResult
    func fixCheckFailure(_ job: CheckJob, log: String) -> Bool {
        guard canSend else { return false }
        let failure = ClaudeCheckFailure(job: job, log: Self.capped(log), headSHA: checkHeadSHA())
        for item in items where item.kind == .checkFailure && item.checkFailure?.job.id == job.id { item.checkFixRequested = true }
        var attachments: [ClaudeAttachment] = []
        if let url = Self.writeCheckLog(failure), var attachment = ClaudeAttachment.load(url) {
            attachment.tag = "LOG"
            attachment.name = failure.slug
            attachment.note = "\(ClaudeOutput.lineCount(failure.log)) lines"
            attachments = [attachment]
        }
        send("Fix the failing check: \(failure.title).", attachments: attachments)
        turnTitle = "Fixing \(job.name)"
        return true
    }

    /// Check jobs Claude is fixing in the current turn ("Claude is fixing").
    var checksBeingFixed: Set<String> {
        guard isRunning else { return [] }
        return Set(items.lazy.filter { $0.kind == .checkFailure && $0.checkFixRequested }.compactMap { $0.checkFailure?.job.id })
    }

    /// Follows CI for the session's branch: a check that newly fails lands in
    /// the transcript, and with "Send failures to Claude" on, Claude starts
    /// fixing it when it isn't busy.
    private func watchChecks() {
        guard let repo = repository, repo.github != nil else { return }
        let checks = BranchChecksModel.shared(for: repo)
        checks.addFailureObserver(self) { [weak self, weak checks] job in
            guard let self, let checks, !self.closed else { return }
            Task { @MainActor in
                let log = await checks.failedLog(for: job)
                self.appendCheckFailure(job, log: log)
                if checks.sendFailuresToClaude, !self.isRunning { self.fixCheckFailure(job, log: log) }
            }
        }
    }

    private func checkHeadSHA() -> String? {
        guard let repo = repository else { return nil }
        let sha = BranchChecksModel.shared(for: repo).snapshot?.headSHA ?? repo.pullRequest?.headOID
        return sha.map { String($0.prefix(7)) }
    }

    /// The log, with what it is, in a file Claude reads with its own tools.
    private static func writeCheckLog(_ failure: ClaudeCheckFailure) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent((failure.slug.isEmpty ? "check" : failure.slug) + ".log")
        var header = "Failed check: \(failure.title)\n"
        if let step = failure.failedStep { header += "Failed step: \(step)\n" }
        if let sha = failure.headSHA { header += "Commit: \(sha)\n" }
        if let url = failure.job.url { header += "Run: \(url.absoluteString)\n" }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data((header + "\n" + failure.log).utf8).write(to: url)
            return url
        } catch {
            Log.claude.error("couldn't write the check log: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Asks the window to open Review Changes for this session (⌘⇧R).
    func requestReviewChanges(path: String? = nil) {
        NotificationCenter.default.post(name: .shellReviewChanges, object: self, userInfo: path.map { ["path": $0] })
    }

    func interrupt() {
        guard isRunning else { return }
        for p in pending { respond(p, allow: false, message: "The user interrupted.") }
        sendControl(["subtype": "interrupt"])
        statusText = "Interrupting…"
    }

    func setModel(_ value: String) {
        let previous = model
        model = value
        sendControl(["subtype": "set_model", "model": value]) { [weak self] _, error in
            guard let self, let error else { return }
            model = previous
            append(ClaudeItem(kind: .error, text: "Couldn't switch model: \(error)"))
        }
        SettingsStore.shared.settings.claudeModel = value == "default" ? "" : value
        // Keep the effort valid for the new model.
        if !effort.isEmpty, !effortLevels.contains(effort) { setEffort("") }
    }

    func setEffort(_ level: String) {
        effort = level
        sendControl(["subtype": "apply_flag_settings", "settings": ["effortLevel": level.isEmpty ? NSNull() as Any : level as Any]]) { [weak self] _, error in
            guard let self, let error else { return }
            append(ClaudeItem(kind: .error, text: "Couldn't change effort: \(error)"))
        }
        SettingsStore.shared.settings.claudeEffort = level
    }

    func setPermissionMode(_ mode: ClaudePermissionMode) {
        let previous = permissionMode
        permissionMode = mode
        sendControl(["subtype": "set_permission_mode", "mode": mode.rawValue]) { [weak self] response, error in
            guard let self else { return }
            if let error {
                permissionMode = previous
                append(ClaudeItem(kind: .error, text: "Couldn't switch to \(mode.title): \(error)"))
            } else if let m = (response?["mode"] as? String).flatMap(ClaudePermissionMode.init(rawValue:)) {
                permissionMode = m
            }
        }
    }

    // MARK: Remote Control

    /// Turns Remote Control on or off for this session.
    func setRemoteControl(_ enabled: Bool) {
        guard !hasExited, !remoteControlBusy else { return }
        remoteControlBusy = true
        remoteControlError = nil
        sendControl(["subtype": "remote_control", "enabled": enabled]) { [weak self] response, error in
            guard let self else { return }
            remoteControlBusy = false
            if let error {
                remoteControlError = error
                return
            }
            remoteControlURL = enabled ? (response?["session_url"] as? String).flatMap(URL.init(string:)) : nil
        }
    }

    var mcpNeedsAuth: [ClaudeMCPServer] { mcpServers.filter { $0.status == "needs-auth" } }

    /// Reconnects one server (after it was signed in elsewhere), then refreshes statuses.
    func reconnectMCP(_ name: String) {
        guard !hasExited, mcpServers.contains(where: { $0.name == name }) else { return }
        sendControl(["subtype": "mcp_reconnect", "serverName": name]) { [weak self] _, _ in self?.refreshMCPStatus() }
    }

    func refreshMCPStatus() {
        sendControl(["subtype": "mcp_status"]) { [weak self] response, _ in
            guard let self, let list = response?["mcpServers"] as? [[String: Any]] else { return }
            mcpServers = list.map { ClaudeMCPServer(name: $0["name"] as? String ?? "", status: $0["status"] as? String ?? "") }
        }
    }

    func cyclePermissionMode() {
        setPermissionMode(ClaudePermissionMode.cycle(from: permissionMode, autoAvailable: autoModeAvailable))
    }

    /// Answers a permission prompt. `always` applies Claude Code's suggested rule.
    func respond(_ req: ClaudePermissionRequest, allow: Bool, always: Bool = false, message: String? = nil) {
        pending.removeAll { $0.id == req.id }
        var body: [String: Any]
        if allow {
            body = ["behavior": "allow", "updatedInput": req.input]
            if always, !req.suggestions.isEmpty { body["updatedPermissions"] = req.suggestions }
        } else {
            body = ["behavior": "deny", "message": message ?? "The user doesn't want to proceed with this tool use."]
        }
        write(["type": "control_response", "response": ["subtype": "success", "request_id": req.id, "response": body]])
        if pending.isEmpty, isRunning { onEvent?("working", nil) }
    }

    /// "Deny, and tell Claude what to do instead": denies the request with
    /// the user's instructions, which also show in the transcript.
    func denyWithInstructions(_ req: ClaudePermissionRequest, _ instructions: String) {
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return respond(req, allow: false) }
        append(ClaudeItem(kind: .user, text: text, at: now))
        respond(req, allow: false, message: "The user doesn't want to proceed with this tool use. The tool use was rejected. "
                + "Do what they ask instead:\n\n\(text)")
    }

    /// Answers an AskUserQuestion prompt with the chosen labels per question.
    func answer(_ req: ClaudePermissionRequest, answers: [String: String]) {
        pending.removeAll { $0.id == req.id }
        var input = req.input
        input["answers"] = answers
        write(["type": "control_response", "response": ["subtype": "success", "request_id": req.id,
                                                        "response": ["behavior": "allow", "updatedInput": input]]])
        if let id = req.toolUseID { toolItems[id]?.answers = answers }
        if pending.isEmpty, isRunning { onEvent?("working", nil) }
    }

    /// Approves an ExitPlanMode plan and switches to `mode` for the work,
    /// like the terminal UI's "Yes, and auto-accept edits" / "Yes, and
    /// manually approve edits".
    func approvePlan(_ req: ClaudePermissionRequest, mode: ClaudePermissionMode) {
        pending.removeAll { $0.id == req.id }
        let body: [String: Any] = [
            "behavior": "allow", "updatedInput": req.input,
            "updatedPermissions": [["type": "setMode", "mode": mode.rawValue, "destination": "session"]],
        ]
        write(["type": "control_response", "response": ["subtype": "success", "request_id": req.id, "response": body]])
        permissionMode = mode
        if pending.isEmpty, isRunning { onEvent?("working", nil) }
    }

    /// Rejects a plan; Claude stays in plan mode and gets the feedback.
    func keepPlanning(_ req: ClaudePermissionRequest, feedback: String) {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        respond(req, allow: false, message: trimmed.isEmpty
            ? "The user doesn't want to proceed with this plan yet. Keep planning and ask what to change."
            : "The user wants to keep planning. Their feedback on the plan:\n\n\(trimmed)")
    }

    private func sendControl(_ request: [String: Any], completion: (([String: Any]?, String?) -> Void)? = nil) {
        requestCounter += 1
        let id = "shell-\(requestCounter)"
        if let completion { callbacks[id] = completion }
        write(["type": "control_request", "request_id": id, "request": request])
    }

    private func write(_ object: [String: Any]) {
        guard let stdin, !hasExited,
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        do { try stdin.write(contentsOf: data) } catch { log.error("claude stdin write failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Receiving

    func handle(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""
        let subagent = !(msg["parent_tool_use_id"] is NSNull || msg["parent_tool_use_id"] == nil)
        switch type {
        case "stream_event":
            if !subagent, let event = msg["event"] as? [String: Any] { handleStreamEvent(event) }
        case "assistant":
            // "Not logged in · Please run /login": the result shows the sign-in card instead.
            if ClaudeAuth.isAuthFailure(msg) {
                turnNeedsLogin = true
                return
            }
            guard let message = msg["message"] as? [String: Any] else { return }
            if subagent {
                if let parent = msg["parent_tool_use_id"] as? String { recordSubagentActivity(parent, message) }
            } else {
                handleAssistant(message)
            }
        case "user":
            if let message = msg["message"] as? [String: Any] { handleUser(message, subagent: subagent, toolResult: msg["tool_use_result"]) }
        case "result":
            handleResult(msg)
        case "system":
            handleSystem(msg)
        case "control_request":
            handleControlRequest(msg)
        case "control_response":
            guard let response = msg["response"] as? [String: Any], let id = response["request_id"] as? String,
                  let callback = callbacks.removeValue(forKey: id) else { return }
            if response["subtype"] as? String == "error" {
                callback(nil, response["error"] as? String ?? "error")
            } else {
                callback(response["response"] as? [String: Any], nil)
            }
        case "control_cancel_request":
            if let id = msg["request_id"] as? String { pending.removeAll { $0.id == id } }
        case "rate_limit_event":
            if let info = msg["rate_limit_info"] as? [String: Any] { ClaudeUsage.shared.record(rateLimitInfo: info) }
        default:
            break
        }
    }

    private func handleStreamEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            blockItems = [:]
            let message = event["message"] as? [String: Any]
            if let id = message?["id"] as? String {
                streamed.insert(id)
                streamMessageID = id
                streamChars = 0
                if let out = (message?["usage"] as? [String: Any])?["output_tokens"] as? Int { recordOutput(id, out) }
            }
            statusText = nil
        case "message_delta":
            if let id = streamMessageID, let out = (event["usage"] as? [String: Any])?["output_tokens"] as? Int {
                streamChars = 0
                recordOutput(id, out)
            }
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return }
            switch block["type"] as? String {
            case "text":
                let item = ClaudeItem(kind: .assistant, at: now)
                blockItems[index] = item
                append(item)
            case "thinking":
                let item = ClaudeItem(kind: .thinking, at: now)
                item.isRunning = true
                blockItems[index] = item
                append(item)
            case "tool_use", "server_tool_use":
                let item = toolItem(id: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "Tool")
                blockItems[index] = item
            default:
                break
            }
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any], let item = blockItems[index] else { return }
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                item.text += text
                turnHadText = true
                countStreamed(text)
            case "thinking_delta":
                let text = delta["thinking"] as? String ?? ""
                item.text += text
                countStreamed(text)
            case "input_json_delta":
                countStreamed(delta["partial_json"] as? String ?? "")
            default:
                break
            }
        case "content_block_stop":
            guard let index = event["index"] as? Int, let item = blockItems[index] else { return }
            switch item.kind {
            case .thinking:
                item.isRunning = false
                item.endedAt = now
                if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.removeAll { $0 === item } }
            case .assistant:
                item.endedAt = now
            case .tool:
                // The input is complete: the tool starts running now.
                if item.result == nil { item.startedAt = now }
            default:
                break
            }
        default:
            break
        }
    }

    private func recordOutput(_ messageID: String, _ tokens: Int) {
        guard turnStartedAt != nil else { return }
        outputByMessage[messageID] = max(outputByMessage[messageID] ?? 0, tokens)
        updateTurnOutput()
    }

    private func countStreamed(_ text: String) {
        guard turnStartedAt != nil, !text.isEmpty else { return }
        streamChars += text.count
        updateTurnOutput()
    }

    private func updateTurnOutput() {
        let total = outputByMessage.values.reduce(0, +) + streamChars / 4
        if total != turnOutputTokens { turnOutputTokens = total }
    }

    private func handleAssistant(_ message: [String: Any]) {
        let id = message["id"] as? String ?? ""
        let wasStreamed = streamed.contains(id)
        if let usage = message["usage"] as? [String: Any] {
            let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
            if total > 0 { contextTokens = total }
            if !wasStreamed, !id.isEmpty, let out = usage["output_tokens"] as? Int { recordOutput(id, out) }
        }
        if let m = message["model"] as? String, m != "<synthetic>" { resolvedModel = m }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                guard !wasStreamed, let text = block["text"] as? String, !text.isEmpty else { continue }
                let item = ClaudeItem(kind: .assistant, text: text, at: now)
                item.endedAt = item.startedAt
                append(item)
                turnHadText = true
            case "thinking":
                guard !wasStreamed, let text = block["thinking"] as? String, !text.isEmpty else { continue }
                append(ClaudeItem(kind: .thinking, text: text, at: now))
            case "tool_use", "server_tool_use":
                let item = toolItem(id: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "Tool")
                let isNew = item.summary.isEmpty && item.input.isEmpty
                item.setInput(block["input"] as? [String: Any] ?? [:])
                if isNew { toolStarted(item) }
            default:
                continue
            }
        }
    }

    private func handleUser(_ message: [String: Any], subagent: Bool, toolResult: Any? = nil) {
        guard let content = message["content"] as? [[String: Any]] else { return }
        for block in content where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String, let item = toolItems[id] else { continue }
            item.result = Self.capped(Self.text(of: block["content"]))
            item.isError = block["is_error"] as? Bool ?? false
            item.isRunning = false
            item.endedAt = now
            item.meta = ClaudeStepMeta.meta(tool: item.toolName, input: item.input, result: item.result, isError: item.isError)
            if !item.isError {
                item.diffStats = ClaudeStepMeta.diffStats(tool: item.toolName, input: item.input, structured: toolResult)
                item.createdFile = item.toolName == "Write" && (toolResult as? [String: Any])?["type"] as? String == "create"
                if let stats = item.diffStats { recordChange(item, stats) }
            }
            if item.toolName == "AskUserQuestion", !item.isError,
               let answers = ClaudeQuestion.answers(structured: toolResult, text: item.result ?? "") {
                item.answers = answers
            }
            toolFinished(item, structured: toolResult)
            if !subagent, ["Edit", "Write", "MultiEdit", "NotebookEdit", "Bash"].contains(item.toolName) {
                repository?.refresh()
            }
        }
    }

    // MARK: To-dos, changes and background work

    private func recordChange(_ item: ClaudeItem, _ stats: ClaudeDiffStats) {
        guard let path = (item.input["file_path"] ?? item.input["notebook_path"]) as? String else { return }
        if let i = changedFiles.firstIndex(where: { $0.path == path }) {
            changedFiles[i].added += stats.added
            changedFiles[i].removed += stats.removed
        } else {
            changedFiles.append(ClaudeChangedFile(path: path, added: stats.added, removed: stats.removed, isNew: item.createdFile))
        }
    }

    /// A main-thread tool call got its input: track to-dos, subagents and
    /// background commands.
    private func toolStarted(_ item: ClaudeItem) {
        guard let id = item.toolID else { return }
        let input = item.input
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let async = input["run_in_background"] as? Bool == true
        let kind: ClaudeBackgroundTask.Kind
        switch item.toolName {
        case "TodoWrite":
            todos = ClaudeTodo.parse(input)
            todosUpdatedAt = now
            return
        case "Task", "Agent": kind = .subagent
        case "Bash" where async: kind = .backgroundTask
        default: return
        }
        guard !backgroundTasks.contains(where: { $0.id == id }) else { return }
        let command = s("command")
        let title = kind == .subagent
            ? (s("subagent_type") ?? s("description") ?? "Subagent")
            : (s("description") ?? command.map { String(($0.components(separatedBy: "\n").first ?? $0).prefix(60)) } ?? "Background task")
        var task = ClaudeBackgroundTask(id: id, title: title, kind: kind, status: .running, startedAt: now,
                                        detail: kind == .subagent ? s("description") : nil, command: command)
        task.isAsync = async
        backgroundTasks.append(task)
    }

    private func toolFinished(_ item: ClaudeItem, structured: Any?) {
        guard let id = item.toolID else { return }
        let result = item.result ?? ""
        if let i = backgroundTasks.firstIndex(where: { $0.id == id }) {
            var task = backgroundTasks[i]
            if item.isError {
                task.status = .failed
                task.endedAt = now
                task.detail = ClaudeOutput.lines(ClaudeToolFormat.visibleResult(result)).first.map(String.init) ?? task.detail
            } else if task.isAsync {
                // Launched; it reports later. Remember the id Claude Code gave it.
                let info = structured as? [String: Any]
                task.taskID = (info?["backgroundTaskId"] ?? info?["agentId"] ?? info?["taskId"]) as? String
                    ?? result.firstMatch(of: /(?i:\bid)[:=]\s*`?([A-Za-z0-9_\-]+)/).map { String($0.output.1) }
            } else {
                task.status = .completed
                task.endedAt = now
            }
            backgroundTasks[i] = task
            return
        }
        let input = item.input
        let reference = (input["bash_id"] ?? input["shell_id"] ?? input["task_id"]) as? String
        guard let reference, let i = backgroundTasks.firstIndex(where: { $0.matches(reference) }), !item.isError else { return }
        var task = backgroundTasks[i]
        switch item.toolName {
        case "BashOutput", "TaskOutput":
            if let m = result.firstMatch(of: /<status>(\w+)<\/status>/) {
                switch m.output.1 {
                case "running": task.status = .running
                case "completed": task.status = .completed
                case "failed": task.status = .failed
                case "killed", "stopped": task.status = .stopped
                default: break
                }
            }
            if let m = result.firstMatch(of: /<exit_code>(\d+)<\/exit_code>/), Int(m.output.1) != 0 { task.status = .failed }
            let output = result.firstMatch(of: /<stdout>([\s\S]*?)<\/stdout>/).map { String($0.output.1) } ?? ""
            if let last = ClaudeOutput.lines(ClaudeOutput.stripANSI(output)).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                task.detail = String(last.trimmingCharacters(in: .whitespaces).prefix(200))
            }
        case "KillShell", "KillBash", "TaskStop":
            task.status = .stopped
        default:
            return
        }
        if !task.isRunning { task.endedAt = task.endedAt ?? now }
        backgroundTasks[i] = task
    }

    /// A subagent's own message: count its tool calls and keep its latest activity.
    private func recordSubagentActivity(_ parentID: String, _ message: [String: Any]) {
        guard let i = backgroundTasks.firstIndex(where: { $0.id == parentID }) else { return }
        var task = backgroundTasks[i]
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "tool_use":
                let name = block["name"] as? String ?? "Tool"
                task.toolCounts[ClaudeToolFormat.displayName(name), default: 0] += 1
                task.detail = ClaudeActivity.label(tool: name, input: block["input"] as? [String: Any] ?? [:])
            case "text":
                let line = (block["text"] as? String ?? "").split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let line { task.detail = String(line.prefix(200)) }
            default:
                continue
            }
        }
        if task != backgroundTasks[i] { backgroundTasks[i] = task }
    }

    /// Claude Code's task events (`task_started`, `task_progress`,
    /// `task_notification`) for subagents and background commands.
    private func handleTaskEvent(_ msg: [String: Any]) {
        let refs = [msg["task_id"], msg["tool_use_id"]].compactMap { $0 as? String }
        guard let i = backgroundTasks.firstIndex(where: { t in refs.contains { t.matches($0) } }) else { return }
        var task = backgroundTasks[i]
        if let summary = (msg["summary"] ?? msg["description"]) as? String, !summary.isEmpty {
            task.detail = String(summary.split(separator: "\n").first?.prefix(200) ?? "")
        }
        if msg["subtype"] as? String == "task_notification" {
            switch msg["status"] as? String {
            case "failed", "error": task.status = .failed
            case "stopped", "killed", "cancelled": task.status = .stopped
            default: task.status = .completed
            }
            task.endedAt = now
        }
        if task != backgroundTasks[i] { backgroundTasks[i] = task }
    }

    private func handleResult(_ msg: [String: Any]) {
        isRunning = false
        statusText = nil
        pending.removeAll()
        for item in toolItems.values where item.isRunning { item.isRunning = false; item.endedAt = item.endedAt ?? now }
        if let cost = msg["total_cost_usd"] as? Double { totalCost = cost }
        if let ms = msg["duration_ms"] as? Double { lastTurnDuration = ms / 1000 }
        let isError = msg["is_error"] as? Bool ?? false
        let text = msg["result"] as? String ?? ""
        let failed = isError || (msg["subtype"] as? String ?? "success") != "success"
        let sent = lastSent
        lastSent = nil
        // The turn's time and cost go on the message that started it.
        if let started = turnStartedAt, let user = sent?.item ?? items.last(where: { $0.kind == .user }) {
            user.turnDuration = (msg["duration_ms"] as? Double).map { $0 / 1000 } ?? now.timeIntervalSince(started)
            if totalCost > costAtTurnStart { user.turnCost = totalCost - costAtTurnStart }
        }
        turnStartedAt = nil
        turnTitle = nil
        // Subagents that ran in the foreground are done with the turn.
        for i in backgroundTasks.indices where backgroundTasks[i].isRunning && !backgroundTasks[i].isAsync {
            backgroundTasks[i].status = .completed
            backgroundTasks[i].endedAt = now
        }
        if turnNeedsLogin || (failed && ClaudeAuth.isLoginError(text)) {
            turnNeedsLogin = false
            resendAfterLogin = sent
            requireLogin(expired: hasCompletedTurn)
            onEvent?("needs-input", "Sign in to Claude Code to continue")
            return
        }
        if !failed { hasCompletedTurn = true }
        if failed {
            let errors = (msg["errors"] as? [String] ?? []).joined(separator: "\n")
            let detail = !errors.isEmpty ? errors : !text.isEmpty ? text : (msg["subtype"] as? String ?? "error")
            if detail.localizedCaseInsensitiveContains("interrupt") || msg["subtype"] as? String == "error_during_execution" {
                append(ClaudeItem(kind: .notice, text: "Interrupted"))
            } else {
                append(ClaudeItem(kind: .error, text: detail))
            }
        } else if !turnHadText, !text.isEmpty {
            // Local slash commands (/cost, /context…) answer with just a result.
            append(ClaudeItem(kind: .assistant, text: text))
        }
        onEvent?("finished", text.isEmpty ? nil : String(text.prefix(240)))
        repository?.refresh()
        // Claude may have just pushed or opened a PR.
        repository?.refreshPullRequest(force: true)
    }

    private func handleSystem(_ msg: [String: Any]) {
        switch msg["subtype"] as? String {
        case "init":
            isStarting = false
            let hadSession = sessionID != nil
            sessionID = msg["session_id"] as? String ?? sessionID
            if !hadSession { sentName = nil; syncSessionName() }
            if let m = msg["model"] as? String { resolvedModel = m }
            if let mode = (msg["permissionMode"] as? String).flatMap(ClaudePermissionMode.init(rawValue:)) { permissionMode = mode }
            mcpServers = (msg["mcp_servers"] as? [[String: Any]] ?? []).map {
                ClaudeMCPServer(name: $0["name"] as? String ?? "", status: $0["status"] as? String ?? "")
            }
            if let s = msg["skills"] as? [String] { skills = Set(s) }
            if let a = msg["agents"] as? [String] { agents = a }
            if commands.isEmpty, let names = msg["slash_commands"] as? [String] {
                commands = names.map { ClaudeCommandInfo(name: $0, description: "", argumentHint: "") }
            }
        case "status":
            let status = msg["status"] as? String
            statusText = status == "compacting" ? "Compacting conversation…" : nil
        case "compact_boundary":
            append(ClaudeItem(kind: .notice, text: "Conversation compacted"))
        case "api_retry":
            statusText = "Retrying request…"
        case "commands_changed":
            if let list = msg["commands"] as? [[String: Any]] { commands = Self.parseCommands(list) }
        case "task_started", "task_progress", "task_notification":
            handleTaskEvent(msg)
        default:
            break
        }
    }

    private func handleControlRequest(_ msg: [String: Any]) {
        guard let id = msg["request_id"] as? String, let req = msg["request"] as? [String: Any] else { return }
        guard req["subtype"] as? String == "can_use_tool" else {
            write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Not supported by Shell"]])
            return
        }
        let name = req["tool_name"] as? String ?? "Tool"
        let perm = ClaudePermissionRequest(
            id: id, toolName: name, displayName: req["display_name"] as? String ?? name,
            input: req["input"] as? [String: Any] ?? [:], description: req["description"] as? String,
            suggestions: req["permission_suggestions"] as? [Any] ?? [],
            reason: req["decision_reason"] as? String,
            toolUseID: req["tool_use_id"] as? String)
        pending.append(perm)
        let note = perm.isQuestion ? "Claude has a question" : perm.isPlan ? "Claude has a plan for you to review" : "Claude wants to use \(perm.displayName)"
        onEvent?("needs-input", note)
    }

    private func applyInitialize(_ r: [String: Any]) {
        isStarting = false
        models = (r["models"] as? [[String: Any]] ?? []).map {
            ClaudeModelOption(
                value: $0["value"] as? String ?? "", displayName: $0["displayName"] as? String ?? "",
                description: $0["description"] as? String ?? "",
                effortLevels: ($0["supportsEffort"] as? Bool ?? false) ? ($0["supportedEffortLevels"] as? [String] ?? []) : [],
                supportsAutoMode: $0["supportsAutoMode"] as? Bool ?? false)
        }
        commands = Self.parseCommands(r["commands"] as? [[String: Any]] ?? [])
        if let account = r["account"] as? [String: Any] {
            accountLabel = [account["email"] as? String, account["subscriptionType"] as? String].compactMap { $0 }.joined(separator: " · ")
        }
        if let mode = (r["current_permission_mode"] as? String).flatMap(ClaudePermissionMode.init(rawValue:)) { permissionMode = mode }
    }

    private static func parseCommands(_ list: [[String: Any]]) -> [ClaudeCommandInfo] {
        list.map {
            ClaudeCommandInfo(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "",
                              argumentHint: $0["argumentHint"] as? String ?? "")
        }.filter { !$0.name.isEmpty }
    }

    // MARK: Helpers

    private func append(_ item: ClaudeItem) {
        items.append(item)
        if !hasStarted { hasStarted = true }
    }

    private func toolItem(id: String, name: String) -> ClaudeItem {
        if let existing = toolItems[id] { return existing }
        let item = ClaudeItem(kind: .tool, at: now)
        item.toolID = id
        item.toolName = name
        item.isRunning = true
        toolItems[id] = item
        append(item)
        return item
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { b in
                if let t = b["text"] as? String { return t }
                if b["type"] as? String == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: History (claude -c / --resume)

    /// Shows the earlier conversation when continuing or resuming, read from
    /// Claude Code's transcript in ~/.claude/projects.
    /// A transcript entry read from disk (plain JSON values; applied on the main actor).
    private enum HistoryEntry: @unchecked Sendable {
        case userText(String, Date?)
        case userBlocks(texts: [String], images: [ClaudeAttachment], message: [String: Any], toolResult: Any?, date: Date?)
        case assistant([String: Any], Date?)
    }

    /// Shows the conversation being continued. The transcript (often tens of
    /// MB) is read and decoded off the main thread, then added in one batch
    /// ahead of anything the new process has already streamed.
    private func loadHistory() {
        guard request.arguments.continuesSession || request.arguments.resumeID != nil else { return }
        let resumeID = request.arguments.resumeID, directory = directory
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = Self.readHistory(resumeID: resumeID, directory: directory)
            guard !entries.isEmpty else { return }
            await MainActor.run { self?.applyHistory(entries) }
        }
    }

    /// Unit tests point this at a temporary folder; nil means ~/.claude/projects.
    nonisolated(unsafe) static var projectsDirectoryOverride: URL?

    private nonisolated static func readHistory(resumeID: String?, directory: String) -> [HistoryEntry] {
        let fm = FileManager.default
        let projects = projectsDirectoryOverride ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var file: URL?
        if let id = resumeID {
            let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            file = dirs.map { $0.appendingPathComponent("\(id).jsonl") }.first { fm.fileExists(atPath: $0.path) }
        } else {
            let dir = projects.appendingPathComponent(projectDirectoryName(for: directory))
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            file = files.filter { $0.pathExtension == "jsonl" }.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        }
        guard let file, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        var entries: [HistoryEntry] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            let date = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
            switch obj["type"] as? String {
            case "user":
                if let text = message["content"] as? String {
                    if let shown = historyPrompt(text) { entries.append(.userText(shown, date)) }
                } else if let blocks = message["content"] as? [[String: Any]] {
                    let texts = blocks.compactMap { $0["type"] as? String == "text" ? ($0["text"] as? String).flatMap(historyPrompt) : nil }
                    let images = blocks.compactMap { block -> ClaudeAttachment? in
                        guard block["type"] as? String == "image", let source = block["source"] as? [String: Any],
                              let b64 = source["data"] as? String, let data = Data(base64Encoded: b64),
                              let type = (source["media_type"] as? String).flatMap({ UTType(mimeType: $0) }) else { return nil }
                        return ClaudeAttachment.historyImage(data, type: type)
                    }
                    entries.append(.userBlocks(texts: texts, images: images, message: message, toolResult: obj["toolUseResult"], date: date))
                }
            case "assistant":
                entries.append(.assistant(message, date))
            default:
                continue
            }
        }
        return entries
    }

    private func applyHistory(_ entries: [HistoryEntry]) {
        // Build the history on its own, then put it ahead of anything live.
        let live = items
        // Background work from the earlier process isn't running any more.
        let liveTasks = backgroundTasks
        items = []
        for entry in entries {
            switch entry {
            case .userText(let text, let date):
                eventDate = date
                append(ClaudeItem(kind: .user, text: text, at: now))
            case .userBlocks(let texts, let images, let message, let toolResult, let date):
                eventDate = date
                if !texts.isEmpty || !images.isEmpty {
                    let item = ClaudeItem(kind: .user, text: texts.joined(separator: "\n"), at: now)
                    item.attachments = images
                    append(item)
                }
                handleUser(message, subagent: false, toolResult: toolResult)
            case .assistant(let message, let date):
                eventDate = date
                handleAssistant(message)
            }
        }
        eventDate = nil
        backgroundTasks = liveTasks
        for item in toolItems.values where item.isRunning { item.isRunning = false; item.endedAt = item.endedAt ?? item.startedAt }
        if !items.isEmpty { append(ClaudeItem(kind: .notice, text: "Continuing the conversation above")) }
        items += live
    }

    /// What a transcript's user entry showed: the prompt, or `/name args` for
    /// a slash command. Nil for Claude Code's own wrapped context
    /// (`<system-reminder>`, command output, caveats).
    nonisolated static func historyPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("<") else { return trimmed }
        func tag(_ name: String) -> String? {
            guard let open = trimmed.range(of: "<\(name)>"), let close = trimmed.range(of: "</\(name)>"),
                  open.upperBound <= close.lowerBound else { return nil }
            return String(trimmed[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name = tag("command-name"), !name.isEmpty {
            let command = name.hasPrefix("/") ? name : "/" + name
            let args = tag("command-args") ?? ""
            return args.isEmpty ? command : command + " " + args
        }
        if let input = tag("bash-input"), !input.isEmpty { return "! " + input }
        return nil
    }

    /// Claude Code's per-project folder name: the path with separators and dots as dashes.
    nonisolated static func projectDirectoryName(for path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
}

// MARK: - Tool formatting

enum ClaudeToolFormat {
    static func summary(name: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash": return s("command")?.replacingOccurrences(of: "\n", with: " ") ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            return (s("file_path") ?? s("notebook_path")).map(shortPath) ?? ""
        case "Glob": return s("pattern") ?? ""
        case "Grep": return [s("pattern"), s("path").map(shortPath)].compactMap { $0 }.joined(separator: "  in ")
        case "WebFetch": return s("url") ?? ""
        case "WebSearch": return s("query") ?? ""
        case "Task", "Agent": return s("description") ?? s("prompt") ?? ""
        case "Skill": return s("skill") ?? s("command") ?? ""
        case "TodoWrite": return "\((input["todos"] as? [Any])?.count ?? 0) items"
        case "AskUserQuestion":
            let questions = ClaudeQuestion.parse(input)
            return questions.count == 1 ? questions[0].question : "\(questions.count) questions"
        case "ExitPlanMode":
            let plan = s("plan") ?? ""
            let title = plan.components(separatedBy: "\n").lazy.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.first { !$0.isEmpty }
            return title ?? "Plan"
        default:
            if let first = input.values.compactMap({ $0 as? String }).first { return String(first.prefix(120)) }
            return ""
        }
    }

    static func displayName(_ name: String) -> String {
        // mcp__server__tool → server · tool
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : name
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write": "doc.badge.plus"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Glob": "doc.text.magnifyingglass"
        case "Grep": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        case "Skill": "sparkles"
        case "AskUserQuestion": "questionmark.bubble"
        case "ExitPlanMode": "list.bullet.clipboard"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// A tool result without the `<system-reminder>` context Claude Code appends for the model.
    static func visibleResult(_ result: String) -> String {
        guard result.contains("<system-reminder>") else { return result }
        return result.replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    typealias Todo = ClaudeTodo

    static func todos(_ input: [String: Any]) -> [Todo] { ClaudeTodo.parse(input) }

    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    typealias DiffLine = ClaudeDiff.Line

    /// A line diff of an Edit/MultiEdit/Write for the transcript and permission card.
    static func diff(name: String, input: [String: Any]) -> [DiffLine]? {
        ClaudeDiff.lines(tool: name, input: input)
    }
}
