import AppKit
import SwiftUI

/// The Claude Sessions page's table of Claude Code sessions running outside
/// Shell. Background sessions open in a new tab with `claude attach`;
/// sessions another terminal or Claude desktop holds are listed but can't be
/// opened (Claude Code refuses to open a session another terminal holds).
/// Sessions that need permission sort first; idle ones fold away after five rows.
struct RunningElsewhereSection: View {
    let controller: TerminalWindowController
    let palette: ChromePalette
    /// The page's filter.
    var query = ""
    /// App-wide model (observed through property access; not state this view owns).
    private let model = ClaudeRunningSessions.shared
    @State private var expanded = false

    static let collapsedRows = 5

    var body: some View {
        let sessions = ClaudeRunningSession.sortedForDashboard(model.sessions.filter { $0.matches(query) })
        let visible = expanded ? sessions.count : ClaudeRunningSession.visibleCount(sessions, limit: Self.collapsedRows)
        let hidden = sessions.count - visible
        VStack(alignment: .leading, spacing: 10) {
            if !sessions.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Running elsewhere").font(.system(size: DS.Size.heading, weight: .semibold))
                    Text("\(sessions.count)").font(.system(size: DS.Size.body).monospacedDigit()).foregroundStyle(.secondary)
                    Text("Background sessions can be attached. Claude desktop sessions stay there.")
                        .font(.system(size: DS.Size.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ElsewhereColumns(status: Text("Status"), session: Text("Session"), folder: Text("Folder"), started: Text("Started"), trailing: Color.clear.frame(height: 1))
                        .font(.system(size: DS.Size.small, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .accessibilityHidden(true)
                    ForEach(sessions.prefix(visible)) { session in
                        Divider()
                        RunningElsewhereRow(session: session) { open(session) }
                    }
                    if hidden > 0 || expanded && sessions.count > Self.collapsedRows {
                        Divider()
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                        } label: {
                            Text(hidden > 0 ? ClaudeRunningSession.moreLabel(sessions.suffix(hidden)) : "Show fewer")
                                .font(.system(size: DS.Size.body))
                                .foregroundStyle(DS.Status.info)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .cardSurface()
            }
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func open(_ session: ClaudeRunningSession) {
        guard let command = session.attachCommand else { return }
        let dir = FileManager.default.fileExists(atPath: session.directory) ? session.directory : nil
        let tab = controller.newTab(directory: dir)
        tab.focusedSession?.pendingCommand = command
    }
}

/// The table's column widths, shared by the header and rows.
private struct ElsewhereColumns<Status: View, Session: View, Folder: View, Started: View, Trailing: View>: View {
    let status: Status
    let session: Session
    let folder: Folder
    let started: Started
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            status.frame(width: 150, alignment: .leading)
            session.frame(maxWidth: .infinity, alignment: .leading)
            folder.frame(width: 180, alignment: .leading)
            started.frame(width: 96, alignment: .leading)
            trailing.frame(width: 104, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
    }
}

struct RunningElsewhereRow: View {
    let session: ClaudeRunningSession
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let status = session.dashboardStatus
        ElsewhereColumns(
            status: HStack(spacing: 6) {
                switch status {
                case .working: SpinnerRing(size: 9)
                case .idle: Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)
                default: Circle().fill(status.color).frame(width: 7, height: 7)
                }
                Text(session.statusLabel)
                    .foregroundStyle(status == .idle ? Color.primary.opacity(0.85) : status.color)
            },
            session: Text(session.name ?? (session.directory as NSString).lastPathComponent)
                .fontWeight(.semibold)
                .truncationMode(.tail),
            folder: Text(session.folderLabel).truncationMode(.middle).foregroundStyle(.primary.opacity(0.85)),
            started: Text(session.startedAt > .distantPast ? session.startedAt.formatted(.relative(presentation: .named)) : "—")
                .foregroundStyle(.secondary),
            trailing: trailing)
            .font(.system(size: DS.Size.body))
            .padding(.vertical, 8)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { if session.canAttach { open() } }
            .contextMenu {
                if session.canAttach { Button("Attach in New Tab") { open() } }
                if let id = session.sessionID { Button("Copy Session ID") { copy(id) } }
                Button("Copy Path") { copy(session.directory) }
                if FileManager.default.fileExists(atPath: session.directory) {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.directory)]) }
                }
            }
            .help(help)
            .accessibilityElement(children: .combine)
            .accessibilityHint(session.canAttach ? "Attach opens this background session in a new tab" : help)
    }

    @ViewBuilder private var trailing: some View {
        if session.canAttach {
            Button("Attach", action: open)
                .buttonStyle(.labeled(.neutral, compact: true))
                .help("Attach to this background session in a new tab (claude attach)")
        } else {
            Text(session.hostLabel).foregroundStyle(.secondary)
        }
    }

    private var help: String {
        if session.canAttach { return "\(session.directory)\nAttach to this background session in a new tab (claude attach)" }
        return "\(session.directory)\nRunning in \(session.host == .claudeDesktop ? "Claude desktop" : "another terminal"). "
            + "Claude Code can’t open a session another app holds."
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Table model

extension ClaudeRunningSession {
    /// The page's status vocabulary. Interactive sessions report
    /// busy/waiting/idle, background jobs a state.
    var dashboardStatus: StatusKind {
        switch status ?? state {
        case "waiting", "blocked": .needsYou
        case "busy", "working": .working
        case "done": .done
        case "failed": .failed
        default: .idle
        }
    }

    /// "Needs permission", "Working", "Idle · Background", "Idle".
    var statusLabel: String {
        switch dashboardStatus {
        case .needsYou:
            if let waitingFor, waitingFor.localizedCaseInsensitiveContains("permission") { return "Needs permission" }
            return waitingFor.map { "Waiting on \($0)" } ?? "Needs input"
        case .working: return "Working"
        case .done: return "Done"
        case .failed: return "Failed"
        case .idle:
            let base = (status ?? state) == "stopped" ? "Stopped" : "Idle"
            return canAttach ? base + " · Background" : base
        }
    }

    /// Where a session that can't be attached lives.
    var hostLabel: String { host == .claudeDesktop ? "Claude desktop" : "Other terminal" }

    /// The last two folders of the path: "takt-corp/backend".
    var folderLabel: String {
        let parts = directory.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return (name?.localizedCaseInsensitiveContains(q) ?? false) || directory.localizedCaseInsensitiveContains(q)
    }

    /// Needs you first, then working, failed, done and idle; newest first within each.
    static func sortedForDashboard(_ sessions: [ClaudeRunningSession]) -> [ClaudeRunningSession] {
        sessions.enumerated().sorted { a, b in
            let pa = a.element.dashboardStatus.priority, pb = b.element.dashboardStatus.priority
            if pa != pb { return pa < pb }
            if a.element.startedAt != b.element.startedAt { return a.element.startedAt > b.element.startedAt }
            return a.offset < b.offset
        }
        .map(\.element)
    }

    /// Rows to show folded: everything that isn't idle, and at least `limit`.
    static func visibleCount(_ sorted: [ClaudeRunningSession], limit: Int) -> Int {
        let active = sorted.filter { $0.dashboardStatus != .idle }.count
        return min(sorted.count, max(active, limit))
    }

    /// "Show 9 more idle sessions", or "Show 3 more sessions" when not all idle.
    static func moreLabel<C: Collection>(_ hidden: C) -> String where C.Element == ClaudeRunningSession {
        let n = hidden.count
        let idle = hidden.allSatisfy { $0.dashboardStatus == .idle }
        return "Show \(n) more \(idle ? "idle " : "")session\(n == 1 ? "" : "s")"
    }
}
