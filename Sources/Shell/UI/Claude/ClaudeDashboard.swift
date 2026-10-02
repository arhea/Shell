import AppKit
import SwiftUI

/// Every Claude Code session across Shell's windows, for the dashboard pinned
/// to the front of the tabs.
@MainActor
enum ClaudeDashboard {
    struct Entry: Identifiable {
        let session: TerminalSession
        let tab: TerminalTab
        let controller: TerminalWindowController
        /// "Window 2 · Tab 3 · Pane 2", trimmed to what's ambiguous.
        let location: String
        /// Zero-based index of the tab in its window, for "Open ⌘3".
        var tabIndex = 0
        var id: UUID { session.id }
    }

    enum Activity: Equatable {
        case needsInput(String)
        case working
        case finished(String)
        case starting
        case idle
        case exited

        var title: String {
            switch self {
            case .needsInput: "Needs input"
            case .working: "Working"
            case .finished: "Done"
            case .starting: "Starting"
            case .idle: "Idle"
            case .exited: "Exited"
            }
        }

        var message: String? {
            switch self {
            case .needsInput(let m), .finished(let m): m
            default: nil
            }
        }
    }

    struct Summary {
        var total = 0
        var working = 0
        var needsInput = 0
        var finished = 0

        var detail: String {
            var parts: [String] = []
            if needsInput > 0 { parts.append("\(needsInput) need\(needsInput == 1 ? "s" : "") input") }
            if working > 0 { parts.append("\(working) working") }
            if finished > 0 { parts.append("\(finished) done") }
            let idle = total - needsInput - working - finished
            if idle > 0 { parts.append("\(idle) idle") }
            return parts.joined(separator: " · ")
        }
    }

    static var controllers: [TerminalWindowController] {
        var list = AppDelegate.shared.controllers
        if let hotkey = HotkeyWindow.shared.controller, !list.contains(where: { $0 === hotkey }) { list.append(hotkey) }
        return list
    }

    /// Claude sessions by default; the widget also passes Codex and other agents.
    static func entries(where include: (TerminalSession) -> Bool = { $0.isClaude }) -> [Entry] {
        // Track panes opening and closing in any window.
        _ = SessionRegistry.shared.count
        let windows = controllers
        var result: [Entry] = []
        for (w, controller) in windows.enumerated() {
            for (t, tab) in controller.workspace.tabs.enumerated() {
                let panes = tab.orderedSessions
                for (p, session) in panes.enumerated() where include(session) {
                    var parts: [String] = []
                    if windows.count > 1 { parts.append(controller === HotkeyWindow.shared.controller ? "Hotkey Window" : "Window \(w + 1)") }
                    parts.append("Tab \(t + 1)")
                    if panes.count > 1 { parts.append("Pane \(p + 1)") }
                    result.append(Entry(session: session, tab: tab, controller: controller, location: parts.joined(separator: " · "), tabIndex: t))
                }
            }
        }
        return result
    }

    static func title(for entry: Entry) -> String {
        let session = entry.session
        if let custom = entry.tab.customTitle, !custom.isEmpty { return custom }
        if let claude = session.nativeClaude { return claude.tabTitle == "Claude" ? session.directoryName : claude.tabTitle }
        return session.directoryName
    }

    static func fullDirectory(for session: TerminalSession) -> String {
        session.nativeClaude?.directory ?? session.workingDirectory ?? NSHomeDirectory()
    }

    /// Home-relative ("~/code/shell").
    static func directory(for session: TerminalSession) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = fullDirectory(for: session)
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }

    static func branch(for session: TerminalSession) -> String? {
        DashboardRepos.shared.repository(for: session)?.branchLabel ?? session.gitBranch
    }

    static func summary(of entries: [Entry]) -> Summary {
        var s = Summary(total: entries.count)
        for e in entries {
            let activity = activity(for: e.session)
            // Remember when each session entered its state, for "waiting 4 min".
            ActivityClock.shared.note(e.session.id, section: section(for: activity))
            switch activity {
            case .needsInput: s.needsInput += 1
            case .working, .starting: s.working += 1
            case .finished: s.finished += 1
            case .idle, .exited: break
            }
        }
        return s
    }

    static func activity(for session: TerminalSession) -> Activity {
        if let claude = session.nativeClaude {
            if claude.needsTrust { return .needsInput("Trust this folder to start Claude Code") }
            if let request = claude.pending.first {
                return .needsInput(request.isQuestion ? "Claude has a question" : "Allow \(request.displayName)?")
            }
            if claude.isStarting { return .starting }
            if claude.hasExited { return .exited }
        }
        switch session.agent {
        case .needsInput(_, let m): return .needsInput(m)
        case .working: return .working
        case .finished(_, let m): return .finished(m)
        case nil: return session.nativeClaude?.isRunning == true ? .working : .idle
        }
    }

    /// The conversation lines above Claude Code's input box in a terminal
    /// viewport: drops the prompt box and footer (everything from the second
    /// to last horizontal rule down), borders and blank lines.
    static func previewLines(fromViewport text: String, limit: Int = 6) -> [String] {
        var lines = text.components(separatedBy: "\n")
        let rules = lines.indices.filter { isRule(lines[$0]) }
        if rules.count >= 2 { lines = Array(lines[..<rules[rules.count - 2]]) }
        let borders = CharacterSet(charactersIn: "│┃║╭╮╰╯")
        let cleaned = lines.compactMap { line -> String? in
            guard !isRule(line) else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(borders)).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Array(cleaned.suffix(limit))
    }

    private static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 8 else { return false }
        return t.allSatisfy { "─━═╌╍┄┅╭╮╰╯".contains($0) }
    }

    /// A permission or question prompt showing in Claude Code's terminal UI.
    struct TerminalPrompt: Equatable {
        struct Option: Equatable {
            var key: String
            var label: String
        }
        var question: String
        /// What it's asking about ("Bash command", the command, its description).
        var context: [String]
        var options: [Option]
    }

    /// Finds a numbered-choice prompt ("Do you want to proceed?" / "❯ 1. Yes")
    /// near the bottom of a terminal viewport. Requires a question line and the
    /// ❯ selector, so ordinary numbered lists in Claude's replies don't match.
    static func terminalPrompt(fromViewport text: String) -> TerminalPrompt? {
        let borders = CharacterSet(charactersIn: "│┃║╭╮╰╯")
        let lines = text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces.union(borders)).trimmingCharacters(in: .whitespaces)
        }
        let optionPattern = /^(❯|>)?\s*([1-9])\.\s+(.+)$/
        let tail = max(0, lines.count - 25)
        guard let last = lines.indices.last(where: { $0 >= tail && lines[$0].wholeMatch(of: optionPattern) != nil }) else { return nil }
        var first = last
        while first > tail, lines[first - 1].wholeMatch(of: optionPattern) != nil { first -= 1 }
        let matches = lines[first...last].compactMap { $0.wholeMatch(of: optionPattern) }
        guard matches.count >= 2, matches.first?.2 == "1", matches.contains(where: { $0.1 != nil }) else { return nil }
        guard let qIndex = lines[..<first].lastIndex(where: { !$0.isEmpty }), lines[qIndex].hasSuffix("?") else { return nil }
        var context: [String] = []
        var i = qIndex - 1
        while i >= 0, context.count < 4 {
            let line = lines[i]
            if isRule(line) || line.hasPrefix("⏺") { break }
            if !line.isEmpty { context.insert(line, at: 0) }
            i -= 1
        }
        let options = matches.map { TerminalPrompt.Option(key: String($0.2), label: String($0.3).replacingOccurrences(of: " (esc)", with: "")) }
        return TerminalPrompt(question: lines[qIndex], context: context, options: options)
    }

    /// Picks an option in the terminal UI: the digit selects it; Return
    /// confirms only if the prompt is still up afterwards.
    static func choose(_ option: TerminalPrompt.Option, in session: TerminalSession) {
        let before = terminalPrompt(fromViewport: session.surfaceView.readText())
        session.surfaceView.sendText(option.key)
        DispatchQueue.main.asyncAfter(deadline: .now() + AppEnvironment.wait(0.35)) {
            MainActor.assumeIsolated {
                if let now = terminalPrompt(fromViewport: session.surfaceView.readText()), now == before { session.surfaceView.writeRaw("\r") }
            }
        }
    }

    /// The latest assistant text (or running tool) in a native session.
    static func nativePreview(_ claude: ClaudeCodeSession, limit: Int = 6) -> [String] {
        guard let item = claude.items.last(where: { $0.kind == .assistant || $0.kind == .tool || $0.kind == .error }) else { return [] }
        let text: String
        switch item.kind {
        case .tool: text = item.summary.isEmpty ? item.toolName : "\(item.toolName): \(item.summary)"
        default: text = item.text
        }
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(limit))
    }
}

// MARK: - Summaries

/// One-line summaries of what each Claude session is doing, from Apple
/// Intelligence. Refreshed while the session's tile is on screen, only when
/// its activity changed, and at most every 20 seconds per session.
@MainActor
@Observable
final class SessionSummaries {
    static let shared = SessionSummaries()

    private var lines: [UUID: String] = [:]
    @ObservationIgnored private var summarized: [UUID: Int] = [:]
    @ObservationIgnored private var lastRun: [UUID: Date] = [:]

    static let minimumInterval: TimeInterval = 20

    func line(for session: TerminalSession) -> String? {
        Intelligence.isEnabled(.sessionSummaries) ? lines[session.id] : nil
    }

    func refresh(_ session: TerminalSession) async {
        guard Intelligence.isEnabled(.sessionSummaries) else { return }
        let text = Self.transcript(for: session)
        guard !text.isEmpty else { return }
        let id = session.id
        let hash = text.hashValue
        guard summarized[id] != hash else { return }
        if let last = lastRun[id], Date().timeIntervalSince(last) < Self.minimumInterval { return }
        summarized[id] = hash
        lastRun[id] = Date()
        if let line = await Intelligence.sessionStatus(transcript: text) { lines[id] = line }
        prune()
    }

    /// Drops entries for sessions that have closed.
    private func prune() {
        let live = Set(SessionRegistry.shared.all.map(\.id))
        lines = lines.filter { live.contains($0.key) }
        summarized = summarized.filter { live.contains($0.key) }
        lastRun = lastRun.filter { live.contains($0.key) }
    }

    /// The latest turns of a native session, or the conversation lines of a
    /// terminal one, as plain text.
    static func transcript(for session: TerminalSession) -> String {
        if let claude = session.nativeClaude {
            let recent = claude.items.filter { $0.kind != .thinking && $0.kind != .notice }.suffix(10)
            return recent.map { item -> String in
                switch item.kind {
                case .user: "User: " + item.text
                case .tool: "Tool: " + (item.summary.isEmpty ? item.toolName : "\(item.toolName) \(item.summary)")
                case .error: "Error: " + item.text
                default: "Claude: " + item.text
                }
            }
            .joined(separator: "\n")
        }
        return ClaudeDashboard.previewLines(fromViewport: session.surfaceView.readText(), limit: 40).joined(separator: "\n")
    }
}

// MARK: - Tab strip entries

/// Whether a window shows the Claude Sessions entry, per Settings: always
/// (when Claude Code is installed), while any Claude session runs, or never.
/// It always shows while the dashboard itself is open.
@MainActor
struct DashboardVisibility {
    let summary: ClaudeDashboard.Summary?

    init(workspace: Workspace) {
        let mode = SettingsStore.shared.settings.claudeSessionsButton
        guard mode != .never || workspace.showsDashboard else {
            summary = nil
            return
        }
        let s = ClaudeDashboard.summary(of: ClaudeDashboard.entries())
        summary = Self.shows(mode: mode, sessions: s.total, claudeInstalled: ClaudeHistory.isClaudeAvailable,
                             dashboardOpen: workspace.showsDashboard) ? s : nil
    }

    static func shows(mode: ClaudeSessionsButton, sessions: Int, claudeInstalled: Bool, dashboardOpen: Bool) -> Bool {
        if dashboardOpen { return true }
        switch mode {
        case .always: return claudeInstalled || sessions > 0
        case .whenActive: return sessions > 0
        case .never: return false
        }
    }
}

/// The dashboard's pinned chip at the front of the horizontal tab bar.
struct DashboardTabChip: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let summary: ClaudeDashboard.Summary
    let palette: ChromePalette
    @State private var hovering = false

    var body: some View {
        let selected = workspace.showsDashboard
        HStack(spacing: 6) {
            DashboardStatusIcon(summary: summary, palette: palette, active: controller.chrome.isVisible)
            Text("Claude")
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? palette.foreground : palette.secondary)
            DashboardCountBadge(summary: summary, palette: palette)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? palette.selected : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.toggleDashboard() }
        .dashboardEntryAccessibility(summary: summary, selected: selected) { controller.toggleDashboard() }
        .help("Claude Dashboard (\(ShortcutAction.claudeDashboard.shortcut?.displayString ?? "⌃⌘A")) — \(summary.detail)")
    }
}

/// The dashboard's pinned row at the top of the vertical tab sidebar.
struct DashboardSidebarRow: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let summary: ClaudeDashboard.Summary
    let palette: ChromePalette
    @State private var hovering = false

    var body: some View {
        let selected = workspace.showsDashboard
        HStack(spacing: 10) {
            KindTile(kind: .claude)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Sessions")
                    .font(.system(size: DS.Size.title, weight: .semibold))
                    .lineLimit(1)
                Text(Self.subtitle(summary))
                    .font(.system(size: DS.Size.subtitle))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if summary.needsInput > 0 {
                CountBadge(count: summary.needsInput)
            } else if summary.working > 0, controller.chrome.isVisible {
                SpinnerRing()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .rowBackground(selected: selected, hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.toggleDashboard() }
        .dashboardEntryAccessibility(summary: summary, selected: selected) { controller.toggleDashboard() }
    }

    /// "1 needs you · 2 working", "2 need you", "3 sessions", "No sessions".
    static func subtitle(_ s: ClaudeDashboard.Summary) -> String {
        var parts: [String] = []
        if s.needsInput > 0 { parts.append("\(s.needsInput) need\(s.needsInput == 1 ? "s" : "") you") }
        if s.working > 0 { parts.append("\(s.working) working") }
        if parts.isEmpty { return s.total == 0 ? "No sessions" : "\(s.total) session\(s.total == 1 ? "" : "s")" }
        return parts.joined(separator: " · ")
    }
}

/// The Claude mark in its brand color; turns slowly while sessions work and
/// carries a dot when one needs input.
///
/// The turn is a repeating rotation animation (the shape is drawn once), not a
/// per-frame redraw, and it stops for Reduce Motion or when the caller says
/// the window isn't visible.
struct ClaudeLogo: View {
    static let color = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    var size: CGFloat = 14
    var spinning = false
    var alert: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        let spin = spinning && !reduceMotion
        ClaudeLogoShape()
            .fill(Self.color)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(turning ? .linear(duration: 6).repeatForever(autoreverses: false) : .easeOut(duration: 0.2), value: turning)
            .onAppear { turning = spin }
            .onChange(of: spin) { _, value in turning = value }
            .accessibilityHidden(true)
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let alert {
                Circle().fill(alert).frame(width: size * 0.45, height: size * 0.45).offset(x: size * 0.15, y: -size * 0.1)
            }
        }
    }
}

struct DashboardStatusIcon: View {
    let summary: ClaudeDashboard.Summary
    let palette: ChromePalette
    /// False while the window is hidden or covered: no animation then.
    var active = true

    var body: some View {
        ClaudeLogo(size: 14, spinning: active && summary.working > 0, alert: summary.needsInput > 0 ? palette.yellow : nil)
    }
}

struct DashboardCountBadge: View {
    let summary: ClaudeDashboard.Summary
    let palette: ChromePalette

    var body: some View {
        if summary.total > 0 { badge }
    }

    private var badge: some View {
        Text("\(summary.total)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(summary.needsInput > 0 ? Color.black.opacity(0.8) : palette.foreground.opacity(0.8))
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(summary.needsInput > 0 ? palette.yellow : palette.hover))
    }
}

// MARK: - Pull requests for terminal sessions

/// The repository behind each terminal Claude session on the dashboard (the
/// native view already has its own), for the live branch and its PR.
@MainActor
@Observable
final class DashboardRepos {
    static let shared = DashboardRepos()
    private var repos: [UUID: (directory: String, repo: GitRepository?)] = [:]
    @ObservationIgnored private var discovering: Set<UUID> = []
    /// Bumped by `releaseAll()`, so a discovery that finishes after the
    /// dashboard closed stops its repository instead of keeping it.
    @ObservationIgnored private var generation = 0

    func repository(for session: TerminalSession) -> GitRepository? {
        session.nativeClaude?.repository ?? repos[session.id]?.repo
    }

    /// Discovers the session's repository when its directory changes.
    func refresh(_ session: TerminalSession) async {
        guard session.nativeClaude == nil, let dir = session.workingDirectory,
              repos[session.id]?.directory != dir, !discovering.contains(session.id) else { return }
        discovering.insert(session.id)
        defer { discovering.remove(session.id) }
        let started = generation
        let repo = await GitRepository.discover(from: dir, environment: MCPManager.defaultEnvironment())
        guard generation == started, !Task.isCancelled else {
            repo?.stop()
            return
        }
        repos[session.id]?.repo?.stop()
        repos[session.id] = (dir, repo)
        prune()
    }

    /// The dashboard closed everywhere: let go of the repositories it held.
    func releaseAll() {
        generation += 1
        for entry in repos.values { entry.repo?.stop() }
        repos.removeAll()
    }

    private func prune() {
        let live = Set(SessionRegistry.shared.all.map(\.id))
        for (id, entry) in repos where !live.contains(id) {
            entry.repo?.stop()
            repos[id] = nil
        }
    }
}

/// "PR #123" linking to the pull request, colored by state. `plain` drops
/// the capsule and icon, for inline use in a subtitle.
struct PullRequestLink: View {
    let pr: PullRequestInfo
    let palette: ChromePalette
    var plain = false

    var body: some View {
        let color: Color = pr.state == .merged ? palette.purple : pr.state == .closed ? palette.red : pr.isDraft ? palette.secondary : palette.green
        if plain {
            Button { NSWorkspace.shared.open(pr.url) } label: {
                Text("PR #\(pr.number)\(pr.isDraft ? " draft" : "")\(pr.state != .open ? " " + pr.state.rawValue.lowercased() : "")")
                    .font(.system(size: DS.Size.subtitle, weight: .semibold))
                    .foregroundStyle(color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(pr.title)\n\(pr.url.absoluteString)")
        } else {
            capsule(color)
        }
    }

    private func capsule(_ color: Color) -> some View {
        Button { NSWorkspace.shared.open(pr.url) } label: {
            HStack(spacing: 4) {
                Image(systemName: pr.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                Text("PR #\(pr.number)").fontWeight(.semibold)
                if pr.isDraft { Text("draft") }
                if pr.state != .open { Text(pr.state.rawValue.lowercased()) }
            }
            .font(.system(size: 11))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(pr.title)\n\(pr.url.absoluteString)")
    }
}

extension View {
    /// The pinned Claude entry in the tab bar or sidebar, for VoiceOver.
    func dashboardEntryAccessibility(summary: ClaudeDashboard.Summary, selected: Bool, action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel("Claude sessions")
            .accessibilityValue(summary.detail.isEmpty ? "\(summary.total) sessions" : summary.detail)
            .accessibilityHint("Shows every Claude session. Control-Command-A")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}
