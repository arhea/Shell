import AppKit
import SwiftUI

// MARK: - Page

/// The Claude Sessions page, shown in place of the terminal area: a control
/// row, the usage strip, Shell's sessions grouped as Needs you / Working /
/// Idle, Claude Code sessions running elsewhere, and the Recent drawer.
///
/// The window's unified toolbar already shows the page title and summary;
/// the page's own controls (filter, New Session, Recent) sit in a slim row at
/// the top of the content, since the toolbar's trailing items are shared.
struct ClaudeDashboardView: View {
    let controller: TerminalWindowController
    /// App-wide model (observed through property access; not state this view owns).
    private let agents = AgentIntegrations.shared
    /// Data sources, replaceable for tests: plan limits and tokens, past
    /// sessions, and a fixed list of sessions running elsewhere (nil: ask
    /// Claude Code).
    var usage: ClaudeUsage = .shared
    var history: ClaudeHistory = .shared
    var elsewhere: [ClaudeRunningSession]?
    @State private var query = ""

    private let workingColumns = [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)]

    var body: some View {
        let palette = ChromePalette.current
        let all = ClaudeDashboard.entries()
        let entries = query.isEmpty ? all : all.filter { ClaudeDashboard.matches(query, entry: $0) }
        let groups = ClaudeDashboard.grouped(entries) { ClaudeDashboard.activity(for: $0.session) }
        let showsHistory = SettingsStore.shared.settings.claudeSessionsHistory
        HStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    // Page actions, right-aligned under the toolbar's trailing items.
                    DashboardControls(controller: controller, query: $query, showsHistory: showsHistory)
                    VStack(alignment: .leading, spacing: 22) {
                        if agents.claude != .installed { hooksBanner(palette) }
                        ClaudeUsageTile(palette: palette, usage: usage)
                        if !groups.needsYou.isEmpty {
                            section(.needsYou, count: groups.needsYou.count) {
                                VStack(spacing: 10) { tiles(groups.needsYou, palette) }
                            }
                        }
                        if !groups.working.isEmpty {
                            section(.working, count: groups.working.count) {
                                LazyVGrid(columns: workingColumns, alignment: .leading, spacing: 12) { tiles(groups.working, palette) }
                            }
                        }
                        if !groups.idle.isEmpty {
                            section(.idle, count: groups.idle.count) {
                                VStack(spacing: 0) {
                                    ForEach(Array(groups.idle.enumerated()), id: \.element.id) { i, entry in
                                        if i > 0 { Divider().padding(.leading, 40) }
                                        tile(entry, palette)
                                    }
                                }
                                .dashboardCard()
                            }
                        }
                        if all.isEmpty {
                            emptyState(palette)
                        } else if entries.isEmpty {
                            Text("No sessions in Shell match “\(query)”.")
                                .font(.system(size: DS.Size.body))
                                .foregroundStyle(.secondary)
                        }
                        RunningElsewhereSection(controller: controller, palette: palette, query: query, fixed: elsewhere)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsHistory {
                PastSessionsDrawer(controller: controller, live: all, history: history)
                    .frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(palette.background)
    }

    @ViewBuilder private func tiles(_ entries: [ClaudeDashboard.Entry], _ palette: ChromePalette) -> some View {
        ForEach(entries) { tile($0, palette) }
    }

    private func tile(_ entry: ClaudeDashboard.Entry, _ palette: ChromePalette) -> some View {
        ClaudeSessionTile(entry: entry, palette: palette) { entry.controller.reveal(entry.session) }
    }

    private func section<Content: View>(_ section: ClaudeDashboard.Section, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader(title: section.title, count: count) {
                switch section {
                case .needsYou: Circle().fill(DS.Status.needsYou).frame(width: 8, height: 8)
                case .working: SpinnerRing(size: 10)
                case .idle: EmptyView()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func hooksBanner(_ palette: ChromePalette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(DS.Status.info)
            Text("Install the Claude Code hooks to see when terminal sessions are working, waiting on you, or done.")
                .font(.system(size: DS.Size.body))
                .foregroundStyle(.primary.opacity(0.85))
            Spacer()
            Button("Install Hooks") { agents.installClaude() }.buttonStyle(.labeled(.neutral, compact: true))
        }
        .padding(10)
        .cardSurface(radius: DS.Radius.row)
    }

    private func emptyState(_ palette: ChromePalette) -> some View {
        VStack(spacing: 8) {
            ClaudeLogo(size: 28)
            Text("No Claude sessions are running in Shell").font(.system(size: DS.Size.title, weight: .medium))
            Text("Start one with New Session, or run `claude` in any tab.").font(.system(size: DS.Size.body)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

// MARK: - Controls

/// The page's actions, styled and sized like the toolbar's trailing items
/// (28pt tall, 8pt corners) and right-aligned under them: the filter field,
/// the New Session split button and the Recent drawer toggle.
struct DashboardControls: View {
    let controller: TerminalWindowController
    @Binding var query: String
    let showsHistory: Bool

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            DashboardSearchField(placeholder: "Filter sessions", text: $query)
                .frame(width: 220)
            HStack(spacing: 0) {
                Button { DashboardActions.newSession(directory: nil, controller: controller) } label: {
                    HStack(spacing: 6) {
                        Text("✻").foregroundStyle(DS.claude)
                        Text("New Session")
                    }
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Start a Claude session in a new tab")
                Color.primary.opacity(0.15).frame(width: 0.5, height: 14)
                Menu {
                    Button("New Session") { DashboardActions.newSession(directory: nil, controller: controller) }
                    Button("New Session in Folder…") { DashboardActions.chooseFolder(controller: controller) }
                    Button("Claude in New Worktree…") { controller.perform(.claudeInNewWorktree) }
                    let recent = DashboardActions.recentFolders(ClaudeHistory.shared.sessions)
                    if !recent.isEmpty {
                        Divider()
                        Section("Recent Folders") {
                            ForEach(recent, id: \.self) { dir in
                                Button(PastSessionCard.homeRelative(dir)) { DashboardActions.newSession(directory: dir, controller: controller) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .help("More ways to start a session")
            }
            .font(.system(size: DS.Size.body))
            .frame(height: 28)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .fixedSize()
            Button {
                withAnimation(.easeOut(duration: 0.2)) { SettingsStore.shared.settings.claudeSessionsHistory.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13))
                    .frame(width: 32, height: 28)
                    .background(Color.primary.opacity(showsHistory ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: DS.Radius.row))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsHistory ? "Hide recent sessions" : "Show recent sessions")
            .accessibilityLabel("Recent Sessions")
            .accessibilityAddTraits(showsHistory ? .isSelected : [])
        }
    }
}

/// A rounded search field: "○ Filter sessions".
struct DashboardSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: DS.Size.body))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.row))
    }
}

/// "● Needs you  1": a 14pt section title with its marker and count.
struct DashboardSectionHeader<Marker: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var marker: Marker

    var body: some View {
        HStack(spacing: 8) {
            marker
            Text(title).font(.system(size: 14, weight: .semibold))
            Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The page's buttons: 28pt (24pt compact) with 7pt corners, as designed.
struct DashboardButtonStyle: ButtonStyle {
    var primary = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        DashboardButtonBody(label: configuration.label, pressed: configuration.isPressed, primary: primary, compact: compact)
    }
}

private struct DashboardButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let primary: Bool
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let radius: CGFloat = compact ? DS.Radius.control : 7
        label
            .font(.system(size: compact ? 12 : DS.Size.body, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : primary ? 14 : 12)
            .frame(height: compact ? 24 : 28)
            .background(primary ? DS.Status.selection.opacity(pressed ? 0.8 : 1) : Color.primary.opacity(pressed ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: radius))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    /// The page's raised card: a faint fill, a hairline and 12pt corners.
    func dashboardCard(hovering: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(Color.primary.opacity(hovering ? 0.05 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

@MainActor
enum DashboardActions {
    /// A new tab that starts `claude` at the prompt, so the native view /
    /// terminal UI choice applies.
    static func newSession(directory: String?, controller: TerminalWindowController) {
        let dir = directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let tab = controller.newTab(directory: dir)
        tab.focusedSession?.pendingCommand = "claude"
    }

    static func chooseFolder(controller: TerminalWindowController) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Claude"
        panel.message = "Choose a folder to start a Claude session in."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            newSession(directory: url.path, controller: controller)
        }
        if let window = controller.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// The most recently used folders, newest first, without repeats.
    static func recentFolders(_ sessions: [ClaudePastSession], limit: Int = 5) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for s in sessions.sorted(by: { $0.lastActive > $1.lastActive }) where seen.insert(s.directory).inserted {
            result.append(s.directory)
            if result.count == limit { break }
        }
        return result
    }
}

// MARK: - Session cards

/// One Shell session on the page, drawn for its section: a yellow card to
/// approve from (Needs you), a card with live activity (Working), or a
/// compact row (Idle).
struct ClaudeSessionTile: View {
    let entry: ClaudeDashboard.Entry
    let palette: ChromePalette
    let open: () -> Void

    private var session: TerminalSession { entry.session }

    var body: some View {
        let activity = ClaudeDashboard.activity(for: session)
        let section = ClaudeDashboard.section(for: activity)
        let since = ActivityClock.shared.since(session.id, section: section)
        Group {
            switch section {
            case .needsYou: NeedsYouCard(entry: entry, activity: activity, since: since, palette: palette, open: open)
            case .working: WorkingCard(entry: entry, since: since, palette: palette, open: open)
            case .idle: IdleRow(entry: entry, activity: activity, palette: palette, open: open)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ClaudeDashboard.title(for: entry)), \(activity.title), \(ClaudeDashboard.directory(for: session))")
        .accessibilityAction(named: "Show Session", open)
        .task(id: session.workingDirectory) { await DashboardRepos.shared.refresh(session) }
        .task(id: section == .idle ? nil : session.id) {
            guard section != .idle else { return }
            while !Task.isCancelled {
                await SessionSummaries.shared.refresh(session)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .contextMenu { SessionTileMenu(entry: entry, open: open) }
    }
}

private struct SessionTileMenu: View {
    let entry: ClaudeDashboard.Entry
    let open: () -> Void

    var body: some View {
        let dir = ClaudeDashboard.fullDirectory(for: entry.session)
        Button("Show Session") { open() }
        if let pr = DashboardRepos.shared.repository(for: entry.session)?.pullRequest {
            Button("Open PR #\(pr.number)") { NSWorkspace.shared.open(pr.url) }
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(dir, forType: .string)
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)]) }
    }
}

/// Shared pieces of the session cards.
@MainActor
private enum TileParts {
    static func kind(_ session: TerminalSession) -> String { session.nativeClaude != nil ? "Native view" : "Terminal UI" }

    /// "Tab 3 · Native view · Opus 5.5 · $2.59".
    static func footer(_ entry: ClaudeDashboard.Entry) -> String {
        var parts = [entry.location, kind(entry.session)]
        if let claude = entry.session.nativeClaude {
            parts.append(claude.modelTitle)
            if claude.totalCost > 0 { parts.append(String(format: "$%.2f", claude.totalCost)) }
        }
        return parts.joined(separator: " · ")
    }

    /// The tab's shortcut, only when there's one window (⌘N picks a tab in the
    /// focused window, which may not be the session's).
    static func shortcut(_ entry: ClaudeDashboard.Entry) -> String? {
        ClaudeDashboard.controllers.count == 1 ? ClaudeDashboard.tabShortcut(entry.tabIndex) : nil
    }

    static func groupDot(_ entry: ClaudeDashboard.Entry) -> TabGroup? {
        entry.tab.groupID.flatMap { entry.controller.workspace.group($0) }
    }
}

/// "Open ⌘3" / "Open tab ⌘4" in link blue.
private struct OpenLink: View {
    let title: String
    let shortcut: String?
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(shortcut.map { "\(title) \($0)" } ?? title)
                .font(.system(size: size))
                .foregroundStyle(DS.Status.info)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show this session")
    }
}

/// "Shell / ⎇ feature/editor-tabs · 18 changes · waiting 4 min" (dotted, on
/// the Needs you card) or "Shell / ⎇ bug/38-…  PR #39  12 changes" (Working).
private struct SessionSubtitle: View {
    let session: TerminalSession
    let palette: ChromePalette
    var trailing: [String] = []
    var dotted = false

    var body: some View {
        let repo = DashboardRepos.shared.repository(for: session)
        var details: [String] = []
        if let changes = repo?.status.changeCount, changes > 0 { details.append("\(changes) change\(changes == 1 ? "" : "s")") }
        details += trailing
        return HStack(spacing: dotted ? 0 : 8) {
            if let repo {
                let name = ClaudeDashboard.repoName(slug: repo.github?.slug, folder: repo.name)
                Text("\(name) / \(Image(systemName: "arrow.triangle.branch")) \(repo.branchLabel)")
                    .lineLimit(1).truncationMode(.middle)
                if let pr = repo.pullRequest {
                    PullRequestLink(pr: pr, palette: palette, plain: true).padding(.leading, dotted ? 8 : 0)
                }
            } else {
                Text(ClaudeDashboard.directory(for: session)).lineLimit(1).truncationMode(.head)
            }
            if dotted {
                if !details.isEmpty { Text(" · " + details.joined(separator: " · ")).lineLimit(1).fixedSize() }
            } else {
                ForEach(details, id: \.self) { Text($0).lineLimit(1).fixedSize() }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

/// A yellow-bordered card for a session waiting on the user, with the
/// request and its answers right there.
private struct NeedsYouCard: View {
    let entry: ClaudeDashboard.Entry
    let activity: ClaudeDashboard.Activity
    let since: Date
    let palette: ChromePalette
    let open: () -> Void

    private var session: TerminalSession { entry.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(ClaudeDashboard.title(for: entry)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text("\(TileParts.kind(session)) · \(entry.location)")
                            .font(.system(size: DS.Size.small))
                            .foregroundStyle(.primary.opacity(0.75))
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        SessionSubtitle(session: session, palette: palette, trailing: [ClaudeDashboard.waiting(context.date.timeIntervalSince(since))], dotted: true)
                    }
                }
                Spacer(minLength: 8)
                OpenLink(title: "Open tab", shortcut: TileParts.shortcut(entry), action: open)
            }
            request
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Status.needsYou.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Status.needsYou.opacity(0.3), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
    }

    @ViewBuilder private var request: some View {
        if let claude = session.nativeClaude {
            if claude.needsTrust {
                Text("Claude Code hasn’t been trusted in this folder yet. Open the tab to trust it and start the session.")
                    .font(.system(size: DS.Size.body))
            } else {
                DashboardApproval(session: session, palette: palette)
            }
        } else {
            // Claude Code's terminal UI: read its prompt from the viewport.
            TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                if let prompt = ClaudeDashboard.terminalPrompt(fromViewport: session.surfaceView.readText()) {
                    DashboardApproval(session: session, palette: palette, terminalPrompt: prompt)
                } else if let message = activity.message {
                    Text(message).font(.system(size: DS.Size.body, weight: .semibold))
                }
            }
        }
    }
}

/// A session at work: elapsed time, branch and PR, the last two lines of what
/// it's doing, and where it lives.
private struct WorkingCard: View {
    let entry: ClaudeDashboard.Entry
    let since: Date
    let palette: ChromePalette
    let open: () -> Void
    @State private var hovering = false

    private var session: TerminalSession { entry.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ClaudeDashboard.title(for: entry)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                // Only this text redraws each second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ClaudeDashboard.elapsed(context.date.timeIntervalSince(since)))
                        .font(.system(size: DS.Size.subtitle).monospacedDigit())
                        .foregroundStyle(DS.Status.working)
                }
            }
            SessionSubtitle(session: session, palette: palette)
            preview
                .font(.system(size: DS.Size.title))
                .lineSpacing(3)
                .foregroundStyle(.primary.opacity(0.86))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let group = TileParts.groupDot(entry) {
                    Circle().fill(group.color.color).frame(width: 6, height: 6)
                }
                Text(TileParts.footer(entry)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                OpenLink(title: "Open", shortcut: TileParts.shortcut(entry), size: DS.Size.subtitle, action: open)
            }
            .font(.system(size: DS.Size.subtitle))
            .foregroundStyle(.tertiary)
            .padding(.top, 10)
            .overlay(alignment: .top) { Color.primary.opacity(0.06).frame(height: 0.5) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardCard(hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Show this session")
    }

    @ViewBuilder private var preview: some View {
        if let line = SessionSummaries.shared.line(for: session) {
            Text("\(Image(systemName: "sparkles")) \(line)").help("Summarized by Apple Intelligence on this Mac")
        } else if let claude = session.nativeClaude {
            Text(ClaudeDashboard.nativePreview(claude, limit: 2).joined(separator: " "))
        } else {
            TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                Text(ClaudeDashboard.previewLines(fromViewport: session.surfaceView.readText(), limit: 2).joined(separator: " "))
            }
        }
    }
}

/// A compact row for a session that's done, idle or exited.
private struct IdleRow: View {
    let entry: ClaudeDashboard.Entry
    let activity: ClaudeDashboard.Activity
    let palette: ChromePalette
    let open: () -> Void
    @State private var hovering = false

    private var session: TerminalSession { entry.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                icon.frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(ClaudeDashboard.title(for: entry)).font(.system(size: DS.Size.title, weight: .semibold)).lineLimit(1)
                        if case .exited = activity { Pill("Exited", color: DS.Status.failed) }
                    }
                    SessionSubtitle(session: session, palette: palette, trailing: activity.message.map { [$0] } ?? [])
                }
                Spacer(minLength: 8)
                Text(TileParts.footer(entry))
                    .font(.system(size: DS.Size.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                OpenLink(title: "Open", shortcut: TileParts.shortcut(entry), action: open)
            }
            // Without hooks a terminal session reads as idle: still catch its prompts.
            if session.nativeClaude == nil {
                TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                    if let prompt = ClaudeDashboard.terminalPrompt(fromViewport: session.surfaceView.readText()) {
                        DashboardApproval(session: session, palette: palette, terminalPrompt: prompt)
                            .padding(.leading, 28)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Show this session")
    }

    @ViewBuilder private var icon: some View {
        switch activity {
        case .finished: StatusIndicator(status: .done)
        case .exited: StatusIndicator(status: .failed)
        default: Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 8, height: 8)
        }
    }
}

// MARK: - Approvals

/// Approve or answer from the page: the native view's request (a compact
/// permission row, or its question and plan cards), or the options of a
/// prompt in Claude Code's terminal UI.
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
                        DashboardPermissionRow(request: req) { allow, always in
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
            Text(prompt.question).font(.system(size: DS.Size.body, weight: .semibold))
            if !prompt.context.isEmpty {
                Text(prompt.context.joined(separator: "\n"))
                    .font(.system(size: DS.Size.small, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(5)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(prompt.options, id: \.key) { option in
                    Button { ClaudeDashboard.choose(option, in: session) } label: {
                        HStack(spacing: 8) {
                            Text(option.label).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 6)
                            KeyHint(option.key, boxed: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.labeled(option.key == "1" ? .primary : .neutral))
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// "Claude wants to edit TabStore.swift  to …" with its file chips, and
/// Deny / (Always allow…) / Allow once on the right; stacks when narrow.
struct DashboardPermissionRow: View {
    let request: ClaudePermissionRequest
    let onDecide: (_ allow: Bool, _ always: Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                // Side by side whenever the request gets ~280pt: long chips
                // truncate rather than pushing the buttons underneath.
                summary
                    .frame(minWidth: 0, idealWidth: 280, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                buttons
            }
            VStack(alignment: .leading, spacing: 10) {
                summary
                buttons
            }
        }
    }

    private var summary: some View {
        let headline = DashboardRequestText.headline(toolName: request.toolName, input: request.input)
        let chips = DashboardRequestText.chips(toolName: request.toolName, input: request.input)
        let detail = request.description.flatMap { $0.isEmpty ? nil : $0 }
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(Text(headline).fontWeight(.semibold))\(Text(detail.map { " " + $0 } ?? "").foregroundStyle(.primary.opacity(0.78)))")
                .font(.system(size: DS.Size.title))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: DS.Size.subtitle, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            // Recessed into the yellow card: darker in dark mode, a faint tint in light.
                            .background(colorScheme == .dark ? Color.black.opacity(0.25) : Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: DS.Radius.pill))
                    }
                }
            }
            if let reason = request.reason, !reason.isEmpty {
                Text(reason).font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Deny") { onDecide(false, false) }
                .buttonStyle(DashboardButtonStyle())
                .help("Deny this request; Claude continues without it")
            if let always = DashboardRequestText.alwaysLabel(suggestions: request.suggestions) {
                Button(always) { onDecide(true, true) }
                    .buttonStyle(DashboardButtonStyle())
                    .help("Allow and apply Claude Code’s suggested permission update")
            }
            Button("Allow once") { onDecide(true, false) }
                .buttonStyle(DashboardButtonStyle(primary: true))
                .help("Allow this request only")
        }
        .fixedSize()
    }
}
