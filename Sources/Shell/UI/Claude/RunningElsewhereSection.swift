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
    /// A fixed list instead of asking Claude Code (tests).
    var fixed: [ClaudeRunningSession]?
    /// Asks Claude Code while the page is on screen. Off in unit tests, so
    /// rendering the page never runs the user's `claude`.
    static let refreshesSessions = !AppEnvironment.isRunningTests
    @State private var expanded = false

    static let collapsedRows = 5

    var body: some View {
        let sessions = ClaudeRunningSession.sortedForDashboard((fixed ?? model.sessions).filter { $0.matches(query) })
        let visible = expanded ? sessions.count : ClaudeRunningSession.visibleCount(sessions, limit: Self.collapsedRows)
        let hidden = sessions.count - visible
        VStack(alignment: .leading, spacing: 10) {
            if !sessions.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Running elsewhere").font(.system(size: 14, weight: .semibold))
                    Text("\(sessions.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Text("Background sessions can be attached. Claude desktop sessions stay there.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ElsewhereColumns(status: Text("Status"), session: Text("Session"), folder: Text("Folder"), started: Text("Started"), trailing: Color.clear.frame(height: 1))
                        .font(.system(size: DS.Size.small, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(height: 30)
                        .accessibilityHidden(true)
                    Color.primary.opacity(0.07).frame(height: 0.5)
                    ForEach(Array(sessions.prefix(visible).enumerated()), id: \.element.id) { i, session in
                        if i > 0 { Color.primary.opacity(0.05).frame(height: 0.5) }
                        RunningElsewhereRow(session: session) { open(session) }
                    }
                    if hidden > 0 || expanded && sessions.count > Self.collapsedRows {
                        Color.primary.opacity(0.05).frame(height: 0.5)
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                        } label: {
                            Text(hidden > 0 ? ClaudeRunningSession.moreLabel(sessions.suffix(hidden)) : "Show fewer")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Status.info)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
                .dashboardCard()
            }
        }
        .task {
            while !Task.isCancelled {
                if fixed == nil && Self.refreshesSessions { model.refresh() }
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
        ElsewhereColumnsLayout {
            status.frame(maxWidth: .infinity, alignment: .leading)
            session.frame(maxWidth: .infinity, alignment: .leading)
            folder.frame(maxWidth: .infinity, alignment: .leading)
            started.frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
    }
}

/// The design's grid: 150pt status, session and folder sharing the rest
/// 1.4 : 1, 110pt started and a 90pt action column, 12pt apart.
private struct ElsewhereColumnsLayout: Layout {
    static let fixed: [CGFloat?] = [150, nil, nil, 110, 90]
    static let flex: [CGFloat] = [0, 1.4, 1, 0, 0]
    static let gap: CGFloat = 12

    static func widths(for total: CGFloat) -> [CGFloat] {
        let fixedSum = fixed.compactMap { $0 }.reduce(0, +) + gap * CGFloat(fixed.count - 1)
        let rest = max(0, total - fixedSum)
        let flexSum = flex.reduce(0, +)
        return zip(fixed, flex).map { f, x in f ?? rest * x / flexSum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        let widths = Self.widths(for: width)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, Self.widths(for: bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + Self.gap
        }
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
                case .idle: Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 7, height: 7)
                default: Circle().fill(status.color).frame(width: 7, height: 7)
                }
                Text(session.statusLabel)
                    .foregroundStyle(status == .idle ? Color.primary.opacity(0.78) : status.color)
            },
            session: Text(session.name ?? (session.directory as NSString).lastPathComponent)
                .fontWeight(.medium)
                .truncationMode(.tail),
            folder: Text(session.folderLabel).truncationMode(.tail).foregroundStyle(.secondary),
            started: Text(session.startedAt > .distantPast ? session.startedAt.formatted(.relative(presentation: .named)) : "—")
                .foregroundStyle(.secondary),
            trailing: trailing)
            .font(.system(size: DS.Size.body))
            .frame(height: 38)
            .background(hovering ? Color.primary.opacity(0.03) : .clear)
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
            Button(action: open) {
                Text("Attach")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.Radius.control))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Attach to this background session in a new tab (claude attach)")
        } else {
            Text(session.hostLabel).font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary)
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
