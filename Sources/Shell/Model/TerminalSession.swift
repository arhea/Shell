import AppKit
import GhosttyKit
import Observation
import UserNotifications

/// Where the shell is in its prompt/command cycle, as reported by Shell's
/// zsh integration.
enum ShellState: Equatable {
    /// Launched; integration hasn't reported a prompt yet.
    case starting
    /// At the prompt — the input editor owns typing.
    case idle
    /// A command is running — typing goes straight to the PTY.
    case running
    /// No integration (not zsh, disabled, or it never reported). Plain terminal.
    case unmanaged
}

enum AgentKind: String, Codable {
    case claude, codex, other
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .other: "Agent"
        }
    }
}

enum AgentStatus: Equatable {
    case working(AgentKind)
    case needsInput(AgentKind, String)
    case finished(AgentKind, String)

    var kind: AgentKind {
        switch self {
        case .working(let k), .needsInput(let k, _), .finished(let k, _): k
        }
    }
}

struct SearchState: Equatable {
    var needle: String = ""
    var total: Int?
    var selected: Int?
}

/// UI hooks implemented by the pane that hosts a session.
@MainActor
protocol TerminalSessionUI: AnyObject {
    func sessionStateDidChange(_ session: TerminalSession)
    func sessionInsertIntoEditor(_ text: String)
    func sessionCompletionsReceived(_ result: CompletionResult)
    func sessionSearchDidChange(_ session: TerminalSession)
    func sessionAppearanceDidChange(_ session: TerminalSession)
    func sessionNativeClaudeDidChange(_ session: TerminalSession)
    /// A command block started, finished or was trimmed from `blocks`.
    func sessionBlocksDidChange(_ session: TerminalSession)
}

/// One shell: a libghostty surface plus everything we know about what's
/// happening inside it.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    @ObservationIgnored let surfaceView: TerminalSurfaceView
    @ObservationIgnored weak var ui: TerminalSessionUI?
    /// Called when the session wants focus (e.g. from a notification click).
    @ObservationIgnored var onRequestFocus: (() -> Void)?
    /// A command to run as soon as the shell reaches its first prompt.
    @ObservationIgnored var pendingCommand: String?

    private(set) var state: ShellState = .starting
    private(set) var terminalTitle: String = ""
    private(set) var workingDirectory: String? {
        didSet { if let workingDirectory, workingDirectory != oldValue { RecentDirectories.note(workingDirectory) } }
    }
    private(set) var gitBranch: String?
    private(set) var runningCommand: String?
    private(set) var lastExitCode: Int?
    private(set) var lastDuration: TimeInterval?
    private(set) var commandStartedAt: Date?
    private(set) var lastCommand: String?

    /// A command plus the prompt context it ran in — enough to find its
    /// header line ("~/dir branch ❯ cmd") in the scrollback later — and how
    /// it went once it finished.
    struct CommandBlock: Equatable, Identifiable {
        var id = UUID()
        var command: String
        /// The abbreviated directory as the header shows it ("~/code").
        var directory: String
        var branch: String?
        /// The absolute working directory the command ran in.
        var cwd: String?
        var startedAt = Date()
        /// Set when the command finishes.
        var duration: TimeInterval?
        var exitCode: Int?
        var isFinished = false

        var failed: Bool { isFinished && (exitCode ?? 0) != 0 }
    }
    @ObservationIgnored private(set) var currentBlock: CommandBlock?
    @ObservationIgnored private(set) var lastBlock: CommandBlock?
    /// Recent command blocks, oldest first (the running one last), bounded by
    /// `maxBlocks`. Drives the block decorations over the terminal.
    @ObservationIgnored private(set) var blocks: [CommandBlock] = []
    static let maxBlocks = 200
    var bell = false
    var hasUnseenOutput = false
    private(set) var progressPercent: Int?
    private(set) var progressActive = false
    var agent: AgentStatus?
    var search: SearchState? {
        didSet { ui?.sessionSearchDidChange(self) }
    }
    private(set) var backgroundOverride: NSColor?
    private(set) var histFile: String?
    private(set) var isFocused = false
    /// Whether the right sidebar is showing for this pane (set by the window).
    var showSidebar = false
    /// The user's choice for this pane (⌃⌘B / close); nil = automatic
    /// (shown in GitHub repositories, or everywhere with `terminalSidebar`).
    var sidebarChoice: Bool?
    @ObservationIgnored var sidebarExpanded: Set<String> = []
    /// Shell's native Claude Code view, when `claude` was opened there.
    private(set) var nativeClaude: ClaudeCodeSession?

    @ObservationIgnored private var startupTimer: Timer?
    @ObservationIgnored private var pendingCompletionID = 0
    @ObservationIgnored private var runningHideWork: DispatchWorkItem?

    init(id: UUID = UUID(), workingDirectory: String?, command: String? = nil, fontSize: Float? = nil) {
        self.id = id
        let settings = SettingsStore.shared.settings
        var opts = SurfaceOptions()
        opts.workingDirectory = workingDirectory.map { ($0 as NSString).expandingTildeInPath }
        opts.command = command
        opts.fontSize = fontSize
        opts.environment = ShellIntegration.environment(for: id, settings: settings, command: command)
        surfaceView = TerminalSurfaceView(options: opts)
        self.workingDirectory = opts.workingDirectory
        surfaceView.session = self
        SessionRegistry.shared.register(self)

        if !ShellIntegration.isActive(settings: settings, command: command) {
            state = .unmanaged
        } else {
            // If the integration never reports in (custom shell, broken rc),
            // fall back to a plain terminal so typing still works.
            startupTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .starting else { return }
                    self.setState(.unmanaged)
                    self.flushPendingCommandWithoutIntegration()
                }
            }
        }
    }

    /// Without integration we can't know when the prompt is ready; type it in.
    func flushPendingCommandWithoutIntegration() {
        guard let cmd = pendingCommand else { return }
        pendingCommand = nil
        surfaceView.sendText(cmd)
        surfaceView.writeRaw("\r")
    }

    func close() {
        startupTimer?.invalidate()
        runningHideWork?.cancel()
        nativeClaude?.terminate()
        SessionRegistry.shared.unregister(self)
        SessionWaiters.shared.notify(id, .closed)
        ShellIntegration.cleanup(sessionID: id)
        // Its notifications can't be clicked through to anything any more.
        NotificationManager.shared.clearNotifications(for: id)
        surfaceView.destroy()
    }

    // MARK: Derived

    var displayTitle: String {
        if let claude = nativeClaude { return claude.tabTitle }
        if let cmd = runningCommand, state == .running {
            return cmd.split(separator: " ").first.map(String.init) ?? cmd
        }
        if !terminalTitle.isEmpty, state == .unmanaged || state == .starting { return terminalTitle }
        return directoryName
    }

    var directoryName: String {
        guard let dir = workingDirectory else { return "~" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir == home { return "~" }
        return (dir as NSString).lastPathComponent
    }

    var abbreviatedDirectory: String {
        guard let dir = workingDirectory else { return "~" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }

    /// True when typed text should go to the native input editor.
    var acceptsEditorInput: Bool {
        SettingsStore.shared.settings.inputEditor && state == .idle
    }

    var isBusy: Bool { state == .running || progressActive }

    /// True while Claude Code is running here: the native view, a `claude`
    /// command in the terminal, or an agent hook reporting from a running command.
    var isClaude: Bool {
        if nativeClaude != nil { return true }
        if state == .running, let cmd = runningCommand, Self.isClaudeCommand(cmd) { return true }
        return agent?.kind == .claude && state != .idle
    }

    /// Whether a command line launches Claude Code (`claude`, a path to it,
    /// `command claude`, `npx @anthropic-ai/claude-code`, env prefixes allowed).
    static func isClaudeCommand(_ command: String) -> Bool {
        let firstLine = command.split(separator: "\n", maxSplits: 1).first ?? ""
        let wrappers: Set<Substring> = ["command", "builtin", "exec", "noglob", "nocorrect", "env", "time", "npx", "bunx", "pnpx"]
        for word in firstLine.split(whereSeparator: \.isWhitespace) {
            if wrappers.contains(word) || word.hasPrefix("-") || (word.contains("=") && !word.hasPrefix("=")) { continue }
            let name = word.split(separator: "/").last ?? word
            return name == "claude" || name.hasPrefix("claude-code")
        }
        return false
    }

    // MARK: Focus

    func focusChanged(_ focused: Bool) {
        isFocused = focused
        if focused {
            bell = false
            hasUnseenOutput = false
            if case .finished = agent { agent = nil }
            if case .needsInput = agent { agent = nil }
            NotificationManager.shared.clearNotifications(for: id)
        }
    }

    func userDidType() {
        bell = false
    }

    // MARK: State from integration

    private func setState(_ new: ShellState) {
        guard state != new else { return }
        state = new
        ui?.sessionStateDidChange(self)
    }

    func integrationDidInitialize(histFile: String?) {
        self.histFile = histFile
        if let histFile { HistoryStore.shared.load(path: histFile) }
    }

    func promptReady(exitCode: Int?, directory: String?, branch: String?, duration: TimeInterval?) {
        startupTimer?.invalidate()
        let ranCommand = state == .running || runningCommand != nil
        if ranCommand {
            lastExitCode = exitCode
            lastDuration = duration
            lastCommand = runningCommand
            if let cmd = runningCommand {
                var block = currentBlock.flatMap { $0.command == cmd ? $0 : nil } ?? newBlock(cmd)
                block.isFinished = true
                block.exitCode = exitCode
                block.duration = duration ?? Date().timeIntervalSince(block.startedAt)
                lastBlock = block
                recordBlock(block)
            }
            if !isFocused { hasUnseenOutput = true }
        }
        currentBlock = nil
        if let directory, !directory.isEmpty { workingDirectory = directory }
        gitBranch = (branch?.isEmpty ?? true) ? nil : branch
        runningCommand = nil
        commandStartedAt = nil
        runningHideWork?.cancel()
        setState(.idle)
        if let histFile { HistoryStore.shared.reloadIfChanged(path: histFile) }
        if ranCommand { SessionWaiters.shared.notify(id, .commandFinished) }
        if let cmd = pendingCommand {
            pendingCommand = nil
            submit(command: cmd)
        }
    }

    func commandStarted(_ command: String, directory: String?) {
        if currentBlock?.command != command {
            // Typed straight into the terminal (native prompt off).
            let block = newBlock(command)
            currentBlock = block
            recordBlock(block)
        }
        if let directory, !directory.isEmpty { workingDirectory = directory }
        runningCommand = command
        commandStartedAt = Date()
        setState(.running)
    }

    /// Submits a command typed in the input editor.
    func submit(command: String) {
        guard state == .idle else { return }
        HistoryStore.shared.add(command)
        let block = newBlock(command)
        currentBlock = block
        recordBlock(block)
        runningCommand = command
        commandStartedAt = Date()
        setState(.running)
        ShellIntegration.run(command: command, in: self)
    }

    // MARK: Block history

    private func newBlock(_ command: String) -> CommandBlock {
        CommandBlock(command: command, directory: abbreviatedDirectory, branch: gitBranch, cwd: workingDirectory)
    }

    /// Adds `block` to `blocks`, or replaces the entry with its id.
    private func recordBlock(_ block: CommandBlock) {
        Self.record(block, in: &blocks)
        ui?.sessionBlocksDidChange(self)
    }

    /// Inserts or replaces `block` (by id), keeping the newest `limit` blocks.
    static func record(_ block: CommandBlock, in blocks: inout [CommandBlock], limit: Int = maxBlocks) {
        if let i = blocks.lastIndex(where: { $0.id == block.id }) {
            blocks[i] = block
        } else {
            // An unfinished block left behind (the shell never reported it ending) is dropped.
            if let last = blocks.last, !last.isFinished { blocks.removeLast() }
            blocks.append(block)
        }
        if blocks.count > limit { blocks.removeFirst(blocks.count - limit) }
    }

    func block(id: UUID) -> CommandBlock? { blocks.last { $0.id == id } }

    /// The recorded block just before `block` (for a block not recorded yet,
    /// the newest one).
    private func olderBlock(than block: CommandBlock) -> CommandBlock? {
        guard let i = blocks.lastIndex(where: { $0.id == block.id }) else { return blocks.last }
        return i > 0 ? blocks[i - 1] : nil
    }

    // MARK: Command output

    /// The output of the last finished command, found by locating its header
    /// line in the scrollback and taking everything up to the next prompt.
    /// Returns nil when it's no longer on screen (e.g. after ⌘K).
    func lastOutput() -> String? {
        guard let block = lastBlock else { return nil }
        return output(of: block)
    }

    /// The output of any recorded block: from its header line to the next
    /// newer block's header (or the end of the screen). Nil when the header
    /// is no longer in the scrollback.
    func output(of block: CommandBlock) -> String? {
        let lines = surfaceView.readText(screen: true)
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        var newer = Array(blocks.drop(while: { $0.id != block.id }).dropFirst().reversed())
        // If a newer command is running that isn't recorded yet, stop at its header too.
        if state == .running, let cur = currentBlock, !newer.contains(where: { $0.id == cur.id }), cur.id != block.id {
            newer.insert(cur, at: 0)
        }
        var end = lines.count
        for b in newer {
            if let idx = Self.headerIndex(of: b, in: lines, before: end, older: olderBlock(than: b)) { end = idx }
        }
        guard let header = Self.headerIndex(of: block, in: lines, before: end, older: olderBlock(than: block)) else { return nil }
        let commandLines = block.command.components(separatedBy: "\n").count
        let start = min(header + commandLines, end)
        var output = Array(lines[start..<end])

        func trimTrailingBlank() { while let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty { output.removeLast() } }
        trimTrailingBlank()
        if let last = output.last, last.hasPrefix("✗ exit ") { output.removeLast() }
        trimTrailingBlank()
        // Without the native prompt, the live zsh prompt is the last line.
        if end == lines.count, state == .idle, !SettingsStore.shared.settings.inputEditor, !output.isEmpty {
            output.removeLast()
            trimTrailingBlank()
        }
        return output.joined(separator: "\n")
    }

    /// Whether the last command printed anything, judged from the viewport
    /// alone (cheap): true when its header has scrolled out of view.
    func lastBlockPrintedOutput() -> Bool {
        guard let block = lastBlock else { return false }
        let lines = surfaceView.readText().components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        guard let header = Self.headerIndex(of: block, in: lines, before: lines.count, older: olderBlock(than: block)) else { return true }
        let start = header + block.command.components(separatedBy: "\n").count
        return lines.dropFirst(start).contains { !$0.isEmpty && !$0.hasPrefix("✗ exit ") }
    }

    /// Finds the last line (before `end`) that shows `block`'s command:
    /// the exact compact header first, then any line ending in "❯ cmd",
    /// then (custom themes) any line ending in the command.
    ///
    /// A command typed ahead while the previous one ran is read by zsh with
    /// the idle prompt hidden, so its line is the bare command ("make test")
    /// with no header. Such a line is taken when nothing better matches, or
    /// when `older` (the block just before this one) shows its header between
    /// the best header-style match and it: that match must then belong to an
    /// earlier run of the same command.
    static func headerIndex(of block: CommandBlock, in lines: [String], before end: Int,
                            older: CommandBlock? = nil) -> Int? {
        guard let first = firstCommandLine(block) else { return nil }
        let end = max(0, min(end, lines.count))
        let styled = styledHeaderIndex(first: first, block: block, in: lines, before: end)
        guard let bare = lines.indices.prefix(end).last(where: { lines[$0] == first }),
              bare > (styled ?? -1) else { return styled }
        guard let styled else { return bare }
        if let older, let olderFirst = firstCommandLine(older),
           let o = styledHeaderIndex(first: olderFirst, block: older, in: lines, before: bare), o > styled {
            return bare
        }
        return styled
    }

    /// The command's first line without trailing whitespace; nil when blank.
    nonisolated static func firstCommandLine(_ block: CommandBlock) -> String? {
        let first = (block.command.components(separatedBy: "\n").first ?? block.command)
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return first.isEmpty ? nil : first
    }

    /// The last header-style line before `end`: the exact compact header,
    /// then "… ❯ cmd", then (custom themes) any line ending in " cmd".
    private static func styledHeaderIndex(first: String, block: CommandBlock, in lines: [String], before end: Int) -> Int? {
        let compact = "\(block.directory)\(block.branch.map { " " + $0 } ?? "") ❯ \(first)"
        let range = lines.indices.prefix(end).reversed()
        if let i = range.first(where: { lines[$0] == compact }) { return i }
        if let i = range.first(where: { lines[$0].hasSuffix("❯ " + first) }) { return i }
        return range.first { lines[$0].hasSuffix(" " + first) && lines[$0].count > first.count + 1 }
    }

    func requestCompletions(for buffer: String) -> Int {
        pendingCompletionID += 1
        DebugCommands.trace("req id=\(pendingCompletionID) buf=\(buffer)")
        ShellIntegration.requestCompletions(buffer: buffer, id: pendingCompletionID, in: self)
        return pendingCompletionID
    }

    func completionsReceived(_ result: CompletionResult) {
        DebugCommands.trace("recv id=\(result.requestID) pending=\(pendingCompletionID) count=\(result.items.count)")
        guard result.requestID == pendingCompletionID else { return }
        ui?.sessionCompletionsReceived(result)
    }

    func insertIntoEditor(_ text: String) {
        ui?.sessionInsertIntoEditor(text)
    }

    // MARK: Events from libghostty

    func terminalTitleChanged(_ title: String) {
        terminalTitle = title
    }

    func workingDirectoryChanged(_ dir: String) {
        let path = dir.hasPrefix("file://") ? (URL(string: dir)?.path ?? dir) : dir
        workingDirectory = path
    }

    func bellRang() {
        let settings = SettingsStore.shared.settings
        if !isFocused { bell = true }
        if settings.bellSound { NSSound.beep() }
        if settings.bounceDockOnBell, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func desktopNotification(title: String, body: String) {
        NotificationManager.shared.post(title: title.isEmpty ? directoryName : title, body: body, session: self, force: false)
    }

    func commandFinished(exitCode: Int?, duration: TimeInterval) {
        let s = SettingsStore.shared.settings
        guard s.notifyCommandFinished, duration >= s.commandFinishedThreshold else { return }
        guard !(s.notifyOnlyWhenInactive && isFocused && NSApp.isActive) else { return }
        let cmd = runningCommand ?? "Command"
        let status = exitCode.map { $0 == 0 ? "succeeded" : "failed (exit \($0))" } ?? "finished"
        NotificationManager.shared.post(
            title: "\(cmd.prefix(60)) \(status)",
            body: "Took \(Self.format(duration: duration)) in \(abbreviatedDirectory)",
            session: self, force: false)
    }

    func progressChanged(state: ghostty_action_progress_report_state_e, percent: Int?) {
        switch state {
        case GHOSTTY_PROGRESS_STATE_REMOVE:
            progressActive = false
            progressPercent = nil
        default:
            progressActive = true
            progressPercent = percent
        }
    }

    func childExited(code: Int, runtimeMs: UInt64) {
        lastExitCode = code
    }

    func backgroundColorChanged(_ color: NSColor) {
        backgroundOverride = color
        ui?.sessionAppearanceDidChange(self)
    }

    func searchStarted(needle: String?) {
        search = SearchState(needle: needle ?? search?.needle ?? "")
    }

    func searchEnded() { search = nil }
    func searchTotalChanged(_ total: Int) { search?.total = total >= 0 ? total : nil }
    func searchSelectedChanged(_ selected: Int) { search?.selected = selected >= 0 ? selected : nil }

    // MARK: Agents

    func agentEvent(kind: AgentKind, event: String, message: String?) {
        defer { SessionWaiters.shared.notify(id, .agent(kind, event: event, message: message)) }
        let s = SettingsStore.shared.settings
        switch event {
        case "working":
            agent = .working(kind)
        case "needs-input":
            let msg = message ?? "\(kind.displayName) needs your input"
            agent = .needsInput(kind, msg)
            if s.agentNotifications {
                NotificationManager.shared.post(title: "\(kind.displayName) needs your input", body: msg, session: self, force: false,
                                                timeSensitive: s.timeSensitiveAgentAlerts)
            }
        case "finished":
            let msg = message ?? "\(kind.displayName) finished"
            agent = isFocused && NSApp.isActive ? nil : .finished(kind, msg)
            if s.agentNotifications {
                NotificationManager.shared.post(title: "\(kind.displayName) is done", body: msg, session: self, force: false)
            }
        case "ended":
            agent = nil
        default:
            break
        }
    }

    // MARK: Native Claude Code

    func startNativeClaude(_ request: ClaudeLaunchRequest) {
        nativeClaude?.terminate()
        let claude = ClaudeCodeSession(request: request)
        claude.onEvent = { [weak self, weak claude] event, message in
            guard let self, let claude, nativeClaude === claude else { return }
            switch event {
            case "ended":
                agent = nil
            default:
                agentEvent(kind: .claude, event: event, message: message)
            }
        }
        nativeClaude = claude
        claude.start()
        ui?.sessionNativeClaudeDidChange(self)
        NotificationCenter.default.post(name: .nativeClaudeDidChange, object: self)
    }

    /// Closes the native view and returns to the shell.
    func endNativeClaude() {
        guard let claude = nativeClaude else { return }
        claude.terminate()
        nativeClaude = nil
        if case .some(let a) = agent, a.kind == .claude { agent = nil }
        ui?.sessionNativeClaudeDidChange(self)
        NotificationCenter.default.post(name: .nativeClaudeDidChange, object: self)
    }

    /// Hands the conversation to Claude Code's terminal UI in this pane.
    func continueClaudeInTerminal() {
        guard let claude = nativeClaude else { return }
        let id = claude.sessionID
        endNativeClaude()
        var cmd = "command claude" + (id.map { " --resume \($0)" } ?? "")
        if SettingsStore.shared.settings.claudeRemoteControl { cmd += " --remote-control" }
        if state == .idle {
            submit(command: cmd)
        } else {
            pendingCommand = cmd
        }
    }

    static func format(duration: TimeInterval) -> String {
        if duration < 1 { return String(format: "%.0fms", duration * 1000) }
        if duration < 60 { return String(format: "%.1fs", duration) }
        let m = Int(duration) / 60, sec = Int(duration) % 60
        if m < 60 { return "\(m)m \(sec)s" }
        return "\(m / 60)h \(m % 60)m"
    }
}

extension Notification.Name {
    /// Posted (object: TerminalSession) when a native Claude view opens or closes.
    static let nativeClaudeDidChange = Notification.Name("ShellNativeClaudeDidChange")
}

/// Global lookup so socket messages and notifications can find sessions.
/// Observable so app-wide views (the Claude dashboard) update as panes come and go.
@MainActor
@Observable
final class SessionRegistry {
    static let shared = SessionRegistry()
    private var sessions: [UUID: WeakSession] = [:]

    private struct WeakSession { weak var value: TerminalSession? }

    func register(_ s: TerminalSession) { sessions[s.id] = WeakSession(value: s) }
    func unregister(_ s: TerminalSession) { sessions[s.id] = nil }
    func session(_ id: UUID) -> TerminalSession? { sessions[id]?.value }
    var all: [TerminalSession] { sessions.values.compactMap(\.value) }
    var count: Int { sessions.count }
}
