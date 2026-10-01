import AppKit
import SwiftUI

/// The Claude Sessions page's right-hand drawer: past Claude Code sessions,
/// newest first, each with its worktree, branch and status. Resume one, start
/// a new session in its directory, or open a terminal there.
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
        let sessions = filtered
        HStack(spacing: 0) {
            p.border.frame(width: 1)
            VStack(spacing: 0) {
                header(p)
                p.border.frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sessions) { session in
                            PastSessionCard(session: session, liveEntry: liveEntry(for: session), palette: p) { action in
                                PastSessionAction.perform(action, session: session, controller: controller)
                            }
                        }
                        if sessions.isEmpty && !history.isLoading { emptyState(p) }
                    }
                    .padding(8)
                }
            }
        }
        .background(p.surface)
        .foregroundStyle(p.foreground)
        .task {
            // Pick up sessions that finish while the page is open.
            while !Task.isCancelled {
                if Self.refreshesHistory { history.refresh() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var filtered: [ClaudePastSession] { Self.filter(history.sessions, query: query) }

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

    /// A native session open in Shell that is this conversation.
    private func liveEntry(for session: ClaudePastSession) -> ClaudeDashboard.Entry? {
        live.first { $0.session.nativeClaude?.sessionID == session.id }
    }

    private func header(_ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(p.claude)
                Text("Past Sessions").font(.system(size: 12, weight: .semibold))
                if !history.sessions.isEmpty {
                    Text("\(history.sessions.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(p.dim)
                }
                Spacer()
                if history.isLoading { ProgressView().controlSize(.mini) }
                Button {
                    DirectoryWorktreeStatus.shared.invalidate()
                    history.refresh(force: true)
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: false))
                    .help("Refresh")
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { SettingsStore.shared.settings.claudeSessionsHistory = false }
                } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: true))
                    .help("Hide Past Sessions")
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.dim).font(.system(size: 11))
                TextField("Filter by title, prompt, folder or branch", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(p.dim)
                        .help("Clear filter")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.background.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.border, lineWidth: 0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func emptyState(_ p: ClaudePalette) -> some View {
        VStack(spacing: 6) {
            Text(query.isEmpty ? "No past sessions" : "No matching sessions").font(.system(size: 12))
            if query.isEmpty {
                Text("Claude Code conversations from ~/.claude/projects show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.dim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }
}

/// What a past session card can do.
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

struct PastSessionCard: View {
    let session: ClaudePastSession
    let liveEntry: ClaudeDashboard.Entry?
    let palette: ClaudePalette
    let perform: (PastSessionAction) -> Void
    @State var hovering = false

    private var status: DirectoryWorktreeStatus { DirectoryWorktreeStatus.shared }

    var body: some View {
        let p = palette
        let state = status.state(for: session.directory)
        let (wt, repo): (WorktreeInfo?, String?) = if case .worktree(let w, let r)? = state { (w, r) } else { (nil, nil) }
        let missing = state == .missing
        let branch = wt?.branch ?? (wt?.isDetached == true ? "detached @ \(wt?.head ?? "?")" : session.branch)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: wt?.isMain == true ? "shippingbox" : "square.stack.3d.up")
                    .foregroundStyle(missing ? p.red : wt?.isMain == true ? p.cyan : p.dim)
                    .font(.system(size: 10))
                    .frame(width: 12)
                Text(repo ?? (session.directory as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if let branch {
                    Text("/").foregroundStyle(p.dim)
                    Text(branch)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.magenta)
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                }
                if let wt, wt.branch != nil, !wt.isMain || wt.ahead + wt.behind > 0 {
                    WorktreeLabels.tracking(wt, p).font(.system(size: 11)).fixedSize()
                }
                Spacer(minLength: 4)
                if liveEntry != nil { WorktreeLabels.badge("open", p.claude) }
                if wt?.isMain == true { WorktreeLabels.badge("main", p.cyan) }
                if missing { WorktreeLabels.badge("missing", p.red) }
            }
            Text(session.prompt ?? session.title)
                .font(.system(size: 12))
                .foregroundStyle(p.foreground.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.tail)
            if let wt, let pr = wt.pullRequest, !wt.isMain {
                WorktreeLabels.pullRequest(pr, p)
            }
            HStack(spacing: 8) {
                if let wt {
                    WorktreeLabels.changes(wt, p)
                } else if state == .notRepository {
                    Text("not a git repository")
                } else if missing {
                    Text("folder missing").foregroundStyle(p.red)
                } else {
                    Text("checking…")
                }
                Text(Self.homeRelative(session.directory)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text(session.lastActive.formatted(.relative(presentation: .named))).fixedSize()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(p.dim)
            if hovering { actions(missing: missing) }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? p.raised : p.background.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(liveEntry != nil ? p.claude.opacity(0.45) : p.border, lineWidth: liveEntry != nil ? 1 : 0.5))
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

    private func actions(missing: Bool) -> some View {
        HStack(spacing: 6) {
            if let liveEntry {
                Button { perform(.show(liveEntry)) } label: { Label("Show", systemImage: "arrow.up.forward.square") }
                    .help("Go to the pane where this session is open")
            } else {
                Button { perform(.resume) } label: { Label("Resume", systemImage: "arrow.uturn.forward") }
                    .help("Resume this conversation in a new tab (claude --resume)")
                    .disabled(missing)
            }
            Button { perform(.newSession) } label: { Label("New", systemImage: "sparkle") }
                .help("Start a new Claude session in this folder")
                .disabled(missing)
            Button { perform(.terminal) } label: { Label("Terminal", systemImage: "terminal") }
                .help("Open a terminal tab in this folder")
                .disabled(missing)
            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .font(.system(size: 10.5))
        .padding(.top, 2)
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
