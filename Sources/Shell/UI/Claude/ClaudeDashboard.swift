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
                    result.append(Entry(session: session, tab: tab, controller: controller, location: parts.joined(separator: " · ")))
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
            switch activity(for: e.session) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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
        HStack(alignment: .top, spacing: 8) {
            DashboardStatusIcon(summary: summary, palette: palette, active: controller.chrome.isVisible).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Sessions")
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? palette.foreground : palette.foreground.opacity(0.85))
                Text(summary.detail.isEmpty ? "No sessions" : summary.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(summary.needsInput > 0 ? palette.yellow : palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            DashboardCountBadge(summary: summary, palette: palette)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? palette.selected : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.toggleDashboard() }
        .dashboardEntryAccessibility(summary: summary, selected: selected) { controller.toggleDashboard() }
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

// MARK: - Dashboard

/// Tiles for every Claude session; shown in place of the terminal area.
struct ClaudeDashboardView: View {
    let controller: TerminalWindowController
    /// App-wide model (observed through property access; not state this view owns).
    private let agents = AgentIntegrations.shared

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 12, alignment: .top)]

    var body: some View {
        let palette = ChromePalette.current
        let entries = ClaudeDashboard.entries()
        let summary = ClaudeDashboard.summary(of: entries)
        let showsHistory = SettingsStore.shared.settings.claudeSessionsHistory
        HStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    header(summary, showsHistory: showsHistory, palette: palette)
                    if agents.claude != .installed { hooksBanner(palette) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ClaudeUsageTile(palette: palette)
                        ForEach(entries) { entry in
                            ClaudeSessionTile(entry: entry, palette: palette) {
                                entry.controller.reveal(entry.session)
                            }
                        }
                        if entries.isEmpty { emptyState(palette) }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsHistory {
                PastSessionsDrawer(controller: controller, live: entries)
                    .frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(palette.background)
    }

    private func header(_ summary: ClaudeDashboard.Summary, showsHistory: Bool, palette: ChromePalette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Claude Sessions").font(.system(size: 18, weight: .semibold)).foregroundStyle(palette.foreground)
            Text(summary.detail).font(.system(size: 12)).foregroundStyle(palette.secondary)
            Spacer()
            Button("Back to Tab") { controller.hideDashboard() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
                .help("Return to the selected tab (\(ShortcutAction.claudeDashboard.shortcut?.displayString ?? "⌃⌘A"))")
            if !showsHistory {
                ChromeIconButton(symbol: "clock.arrow.circlepath", help: "Show Past Sessions", palette: palette) {
                    withAnimation(.easeOut(duration: 0.2)) { SettingsStore.shared.settings.claudeSessionsHistory = true }
                }
            }
        }
    }

    private func hooksBanner(_ palette: ChromePalette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(palette.accent)
            Text("Install the Claude Code hooks to see when terminal sessions are working, waiting on you, or done.")
                .font(.system(size: 12))
                .foregroundStyle(palette.foreground.opacity(0.85))
            Spacer()
            Button("Install Hooks") { agents.installClaude() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.bar))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
    }

    private func emptyState(_ palette: ChromePalette) -> some View {
        VStack(spacing: 8) {
            ClaudeLogo(size: 28)
            Text("No Claude sessions are running").foregroundStyle(palette.foreground)
            Text("Run `claude` in any tab and it shows up here.").font(.system(size: 12)).foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

struct ClaudeSessionTile: View {
    let entry: ClaudeDashboard.Entry
    let palette: ChromePalette
    let open: () -> Void
    @State private var hovering = false

    private var session: TerminalSession { entry.session }

    var body: some View {
        let activity = ClaudeDashboard.activity(for: session)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                activityLabel(activity)
                Spacer()
                pill(session.nativeClaude != nil ? "Native" : "Terminal")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                if let summary = SessionSummaries.shared.line(for: session) {
                    Label(summary, systemImage: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.foreground.opacity(0.85))
                        .lineLimit(1)
                        .help("Summarized by Apple Intelligence on this Mac")
                }
                if let command = session.nativeClaude == nil ? session.runningCommand : nil {
                    Text("$ " + command.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                info("folder", directory)
                if let branch {
                    HStack(spacing: 8) {
                        info("arrow.triangle.branch", branch)
                        if let pr = DashboardRepos.shared.repository(for: session)?.pullRequest {
                            PullRequestLink(pr: pr, palette: palette)
                        }
                    }
                }
            }
            if let message = activity.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(color(for: activity))
                    .lineLimit(2)
            }
            live
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? palette.hover : palette.bar))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor(activity), lineWidth: isUrgent(activity) ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(ClaudeDashboard.activity(for: session).title), \(directory)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show Session", open)
        .task(id: session.workingDirectory) { await DashboardRepos.shared.refresh(session) }
        .task(id: session.id) {
            while !Task.isCancelled {
                await SessionSummaries.shared.refresh(session)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .contextMenu {
            Button("Show Session") { open() }
            if let pr = DashboardRepos.shared.repository(for: session)?.pullRequest {
                Button("Open PR #\(pr.number)") { NSWorkspace.shared.open(pr.url) }
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullDirectory, forType: .string)
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullDirectory)]) }
        }
        .help("Show this session")
    }

    // MARK: Parts

    private var title: String { ClaudeDashboard.title(for: entry) }
    private var fullDirectory: String { ClaudeDashboard.fullDirectory(for: session) }
    private var directory: String { ClaudeDashboard.directory(for: session) }
    private var branch: String? { ClaudeDashboard.branch(for: session) }

    private func info(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).frame(width: 14)
            Text(text).lineLimit(1).truncationMode(.head)
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.secondary)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(palette.border))
    }

    @ViewBuilder private func activityLabel(_ activity: ClaudeDashboard.Activity) -> some View {
        HStack(spacing: 6) {
            switch activity {
            case .working, .starting:
                ProgressView().controlSize(.mini).tint(palette.purple)
            case .needsInput:
                Image(systemName: "exclamationmark.bubble.fill")
            case .finished:
                Image(systemName: "checkmark.circle.fill")
            case .idle:
                Circle().fill(palette.secondary).frame(width: 7, height: 7)
            case .exited:
                Image(systemName: "xmark.octagon.fill")
            }
            Text(activity.title)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color(for: activity))
        .frame(height: 16)
    }

    /// Live snapshot of the conversation, refreshed while the dashboard is up.
    /// Approval or live preview. Native sessions update through Observation;
    /// terminal sessions read the viewport once per tick for both.
    @ViewBuilder private var live: some View {
        if let claude = session.nativeClaude {
            DashboardApproval(session: session, palette: palette)
            if claude.pending.isEmpty { previewBox(ClaudeDashboard.nativePreview(claude)) }
        } else {
            TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                let viewport = session.surfaceView.readText()
                if let prompt = ClaudeDashboard.terminalPrompt(fromViewport: viewport) {
                    DashboardApproval(session: session, palette: palette, terminalPrompt: prompt)
                } else {
                    previewBox(ClaudeDashboard.previewLines(fromViewport: viewport))
                }
            }
        }
    }

    private func previewBox(_ lines: [String]) -> some View {
        Text(lines.isEmpty ? " " : lines.joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(palette.foreground.opacity(0.75))
            .lineLimit(6)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.background))
    }

    private var footer: some View {
        HStack(spacing: 6) {
                Text(entry.location)
                if let group = entry.tab.groupID.flatMap({ entry.controller.workspace.group($0) }) {
                    Circle().fill(group.color.color).frame(width: 6, height: 6)
                    Text(group.name.isEmpty ? "Group" : group.name)
                }
                Spacer()
                if let claude = session.nativeClaude {
                    Text(claude.modelTitle)
                    if claude.totalCost > 0 { Text(String(format: "$%.2f", claude.totalCost)) }
                } else if let started = session.commandStartedAt {
                    Image(systemName: "clock").font(.system(size: 9))
                    // Updated by the system each second without re-rendering the tile.
                    Text(started, style: .timer).monospacedDigit()
                }
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.secondary)
        .lineLimit(1)
    }

    private func isUrgent(_ activity: ClaudeDashboard.Activity) -> Bool {
        if case .needsInput = activity { return true }
        return false
    }

    private func color(for activity: ClaudeDashboard.Activity) -> Color {
        switch activity {
        case .needsInput: palette.yellow
        case .working, .starting: palette.purple
        case .finished: palette.green
        case .idle: palette.secondary
        case .exited: palette.red
        }
    }

    private func borderColor(_ activity: ClaudeDashboard.Activity) -> Color {
        isUrgent(activity) ? palette.yellow.opacity(0.8) : palette.border
    }
}

// MARK: - Usage

/// The dashboard's first tile: plan limits and local token totals.
struct ClaudeUsageTile: View {
    let palette: ChromePalette
    /// App-wide model (observed through property access; not state this view owns).
    private let usage = ClaudeUsage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ClaudeLogo(size: 16)
                Text("Claude Usage").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.foreground)
                Spacer()
                if usage.isScanning && usage.tokens == nil { ProgressView().controlSize(.mini) }
            }
            limits
            palette.border.frame(height: 1)
            tokens
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.bar))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border))
        .task {
            while !Task.isCancelled {
                usage.refreshIfNeeded()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: Plan limits

    @ViewBuilder private var limits: some View {
        if let limits = usage.limits, limits.fiveHour != nil || limits.sevenDay != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let w = limits.fiveHour { meter("Current session", w, weekly: false) }
                if let w = limits.sevenDay { meter("Weekly", w, weekly: true) }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Plan limits as of \(Self.relative(limits.updatedAt, now: context.date))")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondary)
                }
            }
        } else {
            Text("Plan limits appear here once a Claude session in the native view reports them.")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func meter(_ label: String, _ window: ClaudeUsage.LimitWindow, weekly: Bool) -> some View {
        let fraction = min(max(window.utilization, 0), 1)
        let color = fraction >= 0.9 ? palette.red : fraction >= 0.7 ? palette.yellow : palette.green
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(palette.foreground.opacity(0.9))
                Text("\(Int((fraction * 100).rounded()))% used").fontWeight(.semibold).foregroundStyle(palette.foreground).monospacedDigit()
                Spacer()
                if let reset = window.resetsAt {
                    Text("Resets \(Self.resetText(reset, weekly: weekly))").foregroundStyle(palette.secondary)
                }
            }
            .font(.system(size: 11))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.hover)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .help("\(label): \(Int((fraction * 100).rounded()))% of your plan's limit used")
    }

    // MARK: Tokens

    @ViewBuilder private var tokens: some View {
        if let stats = usage.tokens {
            HStack(alignment: .top, spacing: 16) {
                stat("Today", stats.today.total, detail: "\(stats.sessionsToday) session\(stats.sessionsToday == 1 ? "" : "s")")
                stat("Last 5 hours", stats.lastFiveHours.total, detail: "\(Self.compact(stats.lastFiveHours.output)) output")
                Spacer(minLength: 0)
                dailyBars(stats.days)
            }
            HStack(spacing: 10) {
                Text("in \(Self.compact(stats.today.input)) · out \(Self.compact(stats.today.output)) · cache \(Self.compact(stats.today.cacheWrite + stats.today.cacheRead))")
                Spacer()
                if let (model, count) = stats.modelsToday.first, stats.today.total > 0 {
                    Text("\(Self.modelName(model)) \(Int((Double(count) / Double(stats.today.total) * 100).rounded()))%")
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(palette.secondary)
            .lineLimit(1)
        } else {
            Text("Reading token usage from ~/.claude/projects…")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
        }
    }

    private func stat(_ label: String, _ value: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(palette.secondary)
            Text(Self.compact(value)).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(palette.foreground)
            Text(detail).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
        .help("\(value.formatted()) tokens, including cache reads and writes")
    }

    /// Tokens per day for the last week, today last.
    private func dailyBars(_ days: [ClaudeUsage.DayTotal]) -> some View {
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        let height: CGFloat = 44
        return VStack(alignment: .trailing, spacing: 3) {
            Text("7 days").font(.system(size: 10)).foregroundStyle(palette.secondary)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    VStack(spacing: 3) {
                        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                            .fill(ClaudeLogo.color.opacity(Calendar.current.isDateInToday(day.day) ? 1 : 0.55))
                            .frame(width: 9, height: day.tokens == 0 ? 1 : max(3, height * CGFloat(day.tokens) / CGFloat(peak)))
                            .frame(height: height, alignment: .bottom)
                        Text(Self.weekday(day.day)).font(.system(size: 9)).foregroundStyle(palette.secondary)
                    }
                    .frame(width: 13)
                    .contentShape(Rectangle())
                    .help("\(day.day.formatted(.dateTime.weekday(.abbreviated).month().day())): \(day.tokens.formatted()) tokens")
                }
            }
        }
    }

    // MARK: Formatting

    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(n)"
        }
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    static func modelName(_ id: String) -> String { ClaudeModelName.format(id) }

    private static func weekday(_ date: Date) -> String {
        String(date.formatted(.dateTime.weekday(.narrow)))
    }

    private static func resetText(_ date: Date, weekly: Bool) -> String {
        if weekly && !Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.hour().minute())
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named))
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

    func repository(for session: TerminalSession) -> GitRepository? {
        session.nativeClaude?.repository ?? repos[session.id]?.repo
    }

    /// Discovers the session's repository when its directory changes.
    func refresh(_ session: TerminalSession) async {
        guard session.nativeClaude == nil, let dir = session.workingDirectory,
              repos[session.id]?.directory != dir, !discovering.contains(session.id) else { return }
        discovering.insert(session.id)
        defer { discovering.remove(session.id) }
        let repo = await GitRepository.discover(from: dir, environment: MCPManager.defaultEnvironment())
        repos[session.id]?.repo?.stop()
        repos[session.id] = (dir, repo)
        prune()
    }

    /// The dashboard closed everywhere: let go of the repositories it held.
    func releaseAll() {
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

/// "PR #123" linking to the pull request, colored by state.
struct PullRequestLink: View {
    let pr: PullRequestInfo
    let palette: ChromePalette

    var body: some View {
        let color: Color = pr.state == .merged ? palette.purple : pr.state == .closed ? palette.red : pr.isDraft ? palette.secondary : palette.green
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

/// Approve or answer from a dashboard tile: the native view's own cards, or
/// the options of a prompt in Claude Code's terminal UI.
struct DashboardApproval: View {
    let session: TerminalSession
    let palette: ChromePalette
    /// For terminal sessions: the prompt the tile found in the viewport.
    var terminalPrompt: ClaudeDashboard.TerminalPrompt?

    var body: some View {
        if let claude = session.nativeClaude {
            if let req = claude.pending.first {
                let p = ClaudePalette.current
                Group {
                    if req.isQuestion {
                        QuestionCard(request: req, palette: p, fontSize: 12, directory: claude.directory) { answers in
                            claude.answer(req, answers: answers)
                        } onDeny: {
                            claude.respond(req, allow: false, message: "The user declined to answer.")
                        }
                    } else if req.isPlan {
                        PlanCard(request: req, palette: p, fontSize: 12, directory: claude.directory) { mode in
                            if let mode { claude.approvePlan(req, mode: mode) } else { claude.keepPlanning(req, feedback: "") }
                        }
                    } else {
                        PermissionCard(request: req, palette: p, fontSize: 12, showsKeyHint: false) { allow, always in
                            claude.respond(req, allow: allow, always: always)
                        }
                    }
                }
                .id(req.id)
                .contentShape(Rectangle())
                .onTapGesture {} // keep clicks inside the card from opening the session
            }
        } else if let terminalPrompt {
            promptView(terminalPrompt)
        }
    }

    private func promptView(_ prompt: ClaudeDashboard.TerminalPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !prompt.context.isEmpty {
                Text(prompt.context.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.foreground.opacity(0.85))
                    .lineLimit(5)
            }
            Text(prompt.question).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.foreground)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(prompt.options, id: \.key) { option in
                    Button { ClaudeDashboard.choose(option, in: session) } label: {
                        HStack(spacing: 6) {
                            Text(option.key).font(.system(size: 10, weight: .bold).monospacedDigit())
                                .frame(width: 16, height: 16)
                                .background(RoundedRectangle(cornerRadius: 4).fill(option.key == "1" ? ClaudeLogo.color : palette.hover))
                                .foregroundStyle(option.key == "1" ? Color.white : palette.foreground)
                            Text(option.label).font(.system(size: 12)).foregroundStyle(palette.foreground).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.background))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.bar))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.yellow.opacity(0.6)))
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

extension View {
    /// The pinned Claude entry in the tab bar or sidebar, for VoiceOver.
    func dashboardEntryAccessibility(summary: ClaudeDashboard.Summary, selected: Bool, action: @escaping () -> Void) -> some View {
        self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Claude sessions")
            .accessibilityValue(summary.detail.isEmpty ? "\(summary.total) sessions" : summary.detail)
            .accessibilityHint("Shows every Claude session. Control-Command-A")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}
