import AppKit
import SwiftUI

/// The Claude Sessions page's list of Claude Code sessions running outside
/// Shell. Background sessions open in a new tab with `claude attach`;
/// sessions another terminal or Claude desktop holds are shown but can't be
/// opened (Claude Code refuses to open a session another terminal holds).
struct RunningElsewhereSection: View {
    let controller: TerminalWindowController
    let palette: ChromePalette
    /// App-wide model (observed through property access; not state this view owns).
    private let model = ClaudeRunningSessions.shared

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 12, alignment: .top)]

    var body: some View {
        let sessions = model.sessions
        VStack(alignment: .leading, spacing: 10) {
            if !sessions.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Running Elsewhere").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.foreground)
                    Text("\(sessions.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(palette.secondary)
                    Text("Background sessions open in a new tab. Sessions another app holds stay there.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(sessions) { session in
                        RunningElsewhereTile(session: session, palette: palette) { open(session) }
                    }
                }
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

struct RunningElsewhereTile: View {
    let session: ClaudeRunningSession
    let palette: ChromePalette
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let attachable = session.canAttach
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusLabel
                Spacer()
                pill(where_)
            }
            Text(session.name ?? (session.directory as NSString).lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10)).frame(width: 14)
                Text(PastSessionCard.homeRelative(session.directory)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                if session.startedAt > .distantPast {
                    Text("started \(session.startedAt.formatted(.relative(presentation: .named)))").fixedSize()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.secondary)
            HStack(spacing: 6) {
                if attachable {
                    Image(systemName: "arrow.up.forward.square")
                    Text("Open in a new tab")
                } else {
                    Image(systemName: "lock")
                    Text("Open it in \(session.host == .claudeDesktop ? "Claude desktop" : "the terminal running it")")
                }
            }
            .font(.system(size: 11, weight: attachable ? .medium : .regular))
            .foregroundStyle(attachable ? ClaudeLogo.color : palette.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(attachable && hovering ? palette.hover : palette.bar))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: attachable ? [] : [4, 3])))
        .opacity(attachable ? 1 : 0.75)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if attachable { open() } }
        .contextMenu {
            if attachable { Button("Open in New Tab") { open() } }
            if let id = session.sessionID { Button("Copy Session ID") { copy(id) } }
            Button("Copy Path") { copy(session.directory) }
            if FileManager.default.fileExists(atPath: session.directory) {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.directory)]) }
            }
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(attachable ? .isButton : [])
        .accessibilityHint(attachable ? "Opens this background session in a new tab" : help)
    }

    private var where_: String {
        if session.canAttach { return "Background" }
        return session.host == .claudeDesktop ? "Claude desktop" : "Other terminal"
    }

    private var help: String {
        if session.canAttach { return "Attach to this background session in a new tab (claude attach)" }
        return "Running in \(session.host == .claudeDesktop ? "Claude desktop" : "another terminal"). Claude Code can't open a session another app holds."
    }

    /// Normalized status: interactive sessions report busy/waiting/idle,
    /// background jobs a state.
    private var statusLabel: some View {
        let (title, color, symbol): (String, Color, String) = switch session.status ?? session.state {
        case "busy", "working": ("Working", palette.purple, "circle.dotted")
        case "waiting", "blocked": (session.waitingFor.map { "Waiting on \($0)" } ?? "Needs input", palette.yellow, "exclamationmark.bubble.fill")
        case "done": ("Done", palette.green, "checkmark.circle.fill")
        case "failed": ("Failed", palette.red, "xmark.octagon.fill")
        case "stopped": ("Stopped", palette.secondary, "stop.circle")
        default: ("Idle", palette.secondary, "circle")
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(palette.border))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
