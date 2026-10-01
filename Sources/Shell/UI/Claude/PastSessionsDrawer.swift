import AppKit
import SwiftUI

/// The Claude Sessions page's Recent drawer: past Claude Code sessions,
/// newest first and grouped by day, each with its repository, branch, PR and
/// working-tree state. Hovering a row shows Resume, New and Terminal.
struct PastSessionsDrawer: View {
    let controller: TerminalWindowController
    /// Sessions open in Shell right now, to mark (and jump to) the live ones.
    let live: [ClaudeDashboard.Entry]
    /// App-wide model (observed through property access; not state this view owns).
    private let history = ClaudeHistory.shared
    @State private var query = ""
    /// Rescans transcripts while the drawer is open. Off in unit tests, so
    /// rendering the drawer never reads the user's ~/.claude/projects.
    static let refreshesHistory = !AppEnvironment.isRunningTests

    var body: some View {
        let p = ClaudePalette.current
        let groups = Self.dayGroups(Self.filter(history.sessions, query: query))
        HStack(spacing: 0) {
            Color.primary.opacity(0.08).frame(width: 0.5)
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            Text(group.title)
                                .font(.system(size: DS.Size.small, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.sessions) { session in
                                PastSessionCard(session: session, liveEntry: liveEntry(for: session), palette: p) { action in
                                    PastSessionAction.perform(action, session: session, controller: controller)
                                }
                            }
                        }
                        if groups.isEmpty && !history.isLoading { emptyState }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(p.surface)
        .task {
            // Pick up sessions that finish while the page is open.
            while !Task.isCancelled {
                if Self.refreshesHistory { history.refresh() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Sessions whose title, first prompt, folder or branch contains `query`.
    static func filter(_ sessions: [ClaudePastSession], query: String) -> [ClaudePastSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.prompt?.localizedCaseInsensitiveContains(q) ?? false)
                || $0.directory.localizedCaseInsensitiveContains(q)
                || ($0.branch?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    struct DayGroup: Identifiable, Equatable {
        var title: String
        var sessions: [ClaudePastSession]
        var id: String { title }
    }

    /// Sessions by the day they were last active, newest first: "Today",
    /// "Yesterday", a weekday within the last week, else the date.
    static func dayGroups(_ sessions: [ClaudePastSession], now: Date = Date(), calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        var index: [Date: Int] = [:]
        for s in sessions.sorted(by: { $0.lastActive > $1.lastActive }) {
            let day = calendar.startOfDay(for: s.lastActive)
            if let i = index[day] {
                groups[i].sessions.append(s)
            } else {
                index[day] = groups.count
                groups.append(DayGroup(title: dayTitle(day, now: now, calendar: calendar), sessions: [s]))
            }
        }
        return groups
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case 2...6:
            var style = Date.FormatStyle.dateTime.weekday(.wide)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return day.formatted(style)
        default:
            var style = calendar.isDate(day, equalTo: now, toGranularity: .year)
                ? Date.FormatStyle.dateTime.month(.abbreviated).day()
                : Date.FormatStyle.dateTime.month(.abbreviated).day().year()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return day.formatted(style)
        }
    }

    /// A native session open in Shell that is this conversation.
    private func liveEntry(for session: ClaudePastSession) -> ClaudeDashboard.Entry? {
        live.first { $0.session.nativeClaude?.sessionID == session.id }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Recent").font(.system(size: DS.Size.title, weight: .semibold))
                Spacer()
                if history.isLoading { ProgressView().controlSize(.mini) }
                if !history.sessions.isEmpty {
                    Text("\(history.sessions.count) session\(history.sessions.count == 1 ? "" : "s")")
                        .font(.system(size: DS.Size.small).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Menu {
                    Button("Refresh") {
                        DirectoryWorktreeStatus.shared.invalidate()
                        history.refresh(force: true)
                    }
                    Button("Hide Recent Sessions") {
                        withAnimation(.easeOut(duration: 0.2)) { SettingsStore.shared.settings.claudeSessionsHistory = false }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Refresh or hide recent sessions")
            }
            DashboardSearchField(placeholder: "Title, prompt, folder or branch", text: $query)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(query.isEmpty ? "No recent sessions" : "No matching sessions").font(.system(size: DS.Size.body))
            if query.isEmpty {
                Text("Claude Code conversations from ~/.claude/projects show up here.")
                    .font(.system(size: DS.Size.small))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }
}

/// What a past session row can do.
enum PastSessionAction {
    case resume
    case newSession
    case terminal
    /// Jump to the pane where the conversation is already open.
    case show(ClaudeDashboard.Entry)

    /// The command a new tab runs: `claude --resume <id>` or `claude`, typed
    /// at the user's prompt so the native view / terminal UI choice applies.
    static func command(for action: PastSessionAction, session: ClaudePastSession) -> String? {
        switch action {
        case .resume:
            // IDs come from transcript file names and are checked to be UUIDs.
            guard session.id.wholeMatch(of: ClaudeArguments.sessionIDPattern) != nil else { return nil }
            return "claude --resume \(session.id)"
        case .newSession: return "claude"
        case .terminal, .show: return nil
        }
    }

    @MainActor
    static func perform(_ action: PastSessionAction, session: ClaudePastSession, controller: TerminalWindowController) {
        if case .show(let entry) = action {
            entry.controller.reveal(entry.session)
            return
        }
        guard FileManager.default.fileExists(atPath: session.directory) else { return }
        let tab = controller.newTab(directory: session.directory)
        if let command = command(for: action, session: session) { tab.focusedSession?.pendingCommand = command }
    }
}

/// A Recent row: "repo / ⎇ branch", the title in bold (two lines), and
/// "#674 open · clean · 20 min ago". Hover highlights it and shows its actions.
struct PastSessionCard: View {
    let session: ClaudePastSession
    let liveEntry: ClaudeDashboard.Entry?
    let palette: ClaudePalette
    let perform: (PastSessionAction) -> Void
    @State var hovering = false

    private var status: DirectoryWorktreeStatus { DirectoryWorktreeStatus.shared }

    var body: some View {
        let state = status.state(for: session.directory)
        let (wt, repo): (WorktreeInfo?, String?) = if case .worktree(let w, let r)? = state { (w, r) } else { (nil, nil) }
        let missing = state == .missing
        let branch = wt?.branch ?? (wt?.isDetached == true ? "detached @ \(wt?.head ?? "?")" : session.branch)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Group {
                    if let branch {
                        Text("\(repo ?? (session.directory as NSString).lastPathComponent) / \(Image(systemName: "arrow.triangle.branch")) \(branch)")
                    } else {
                        Text(repo ?? (session.directory as NSString).lastPathComponent)
                    }
                }
                .font(.system(size: DS.Size.subtitle))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if liveEntry != nil { Pill("Open", color: DS.claude) }
                if missing { Pill("Missing", color: DS.Status.failed) }
            }
            Text(session.prompt ?? session.title)
                .font(.system(size: DS.Size.title, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            if hovering {
                actions(missing: missing).padding(.top, 5)
            } else {
                meta(wt: wt, state: state)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowBackground(selected: false, hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !missing { perform(primaryAction) } }
        .contextMenu { menu(missing: missing) }
        .task(id: session.directory) { await status.refresh(session.directory) }
        .help("\(session.title)\n\(session.prompt ?? "")\n\(session.directory)\nDouble-click to \(liveEntry != nil ? "show" : "resume")")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(repo ?? session.directory)\(branch.map { ", " + $0 } ?? ""): \(session.prompt ?? session.title)")
    }

    private var primaryAction: PastSessionAction { liveEntry.map { .show($0) } ?? .resume }

    /// "#674 open · clean · 20 min ago".
    private func meta(wt: WorktreeInfo?, state: DirectoryWorktreeStatus.State?) -> some View {
        HStack(spacing: 4) {
            if let pr = wt?.pullRequest, wt?.isMain == false {
                let (label, color) = Self.pullRequestLabel(pr)
                Text(label).foregroundStyle(color)
                Text("·")
            }
            if let wt {
                if let n = wt.changes {
                    if n == 0 { Text("clean") } else { Text("\(n) change\(n == 1 ? "" : "s")").foregroundStyle(DS.Status.working) }
                } else {
                    Text("checking…")
                }
            } else if state == .notRepository {
                Text("not a git repository")
            } else if state == .missing {
                Text("folder missing").foregroundStyle(DS.Status.failed)
            } else {
                Text("checking…")
            }
            Text("·")
            Text(session.lastActive.formatted(.relative(presentation: .named))).fixedSize()
        }
        .font(.system(size: DS.Size.small))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// "#674 open" in green, "#37 merged" in purple, "#4 draft" in gray, "#9 closed" in red.
    static func pullRequestLabel(_ pr: PullRequestInfo) -> (String, Color) {
        switch pr.state {
        case .merged: ("#\(pr.number) merged", DS.Status.review)
        case .closed: ("#\(pr.number) closed", DS.Status.failed)
        case .open: pr.isDraft ? ("#\(pr.number) draft", .secondary) : ("#\(pr.number) open", DS.Status.done)
        }
    }

    private func actions(missing: Bool) -> some View {
        HStack(spacing: 6) {
            if let liveEntry {
                Button("Show") { perform(.show(liveEntry)) }
                    .buttonStyle(.labeled(.primary, compact: true))
                    .help("Go to the pane where this session is open")
            } else {
                Button("Resume") { perform(.resume) }
                    .buttonStyle(.labeled(.primary, compact: true))
                    .help("Resume this conversation in a new tab (claude --resume)")
                    .disabled(missing)
            }
            Button("New") { perform(.newSession) }
                .buttonStyle(.labeled(.neutral, compact: true))
                .help("Start a new Claude session in this folder")
                .disabled(missing)
            Button("Terminal") { perform(.terminal) }
                .buttonStyle(.labeled(.neutral, compact: true))
                .help("Open a terminal tab in this folder")
                .disabled(missing)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func menu(missing: Bool) -> some View {
        if let liveEntry { Button("Show Session") { perform(.show(liveEntry)) } }
        Button("Resume in New Tab") { perform(.resume) }.disabled(missing)
        Button("New Session in This Folder") { perform(.newSession) }.disabled(missing)
        Button("Open Terminal Here") { perform(.terminal) }.disabled(missing)
        Divider()
        if !missing {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.directory)]) }
        }
        Button("Copy Path") { copy(session.directory) }
        Button("Copy Session ID") { copy(session.id) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
