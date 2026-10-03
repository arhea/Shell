import AppKit
import CoreImage
import SwiftUI

/// Shell's native Claude Code view. Covers a pane while `claude` runs there.
struct ClaudePaneView: View {
    @Bindable var claude: ClaudeCodeSession
    let composer: ClaudeComposerModel
    var onClose: () -> Void
    var onContinueInTerminal: () -> Void
    var onToggleExplorer: () -> Void
    var onFocus: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Review changes, shown in place of the chat while set.
    @State private var review: ReviewChangesModel?

    private var palette: ClaudePalette { .current }
    private var fontSize: CGFloat { ChatTypography.current.size }
    /// Settings › Chat Text › Composer width (nil = the full pane).
    private var columnWidth: CGFloat? { ChatTypography.current.columnWidth }
    /// Settings › Chat Text › Maximum width, within the column (nil = the whole column).
    private var readingWidth: CGFloat? { [ChatTypography.current.maxWidth, columnWidth].compactMap(\.self).min() }
    /// The composer's width while it waits, centered, for the first message.
    private static let emptyStateWidth: CGFloat = 680

    var body: some View {
        let p = palette
        // Before the first message the composer sits in the middle of the pane
        // with the welcome above it; sending moves it to the bottom. `bottom` stays
        // at the same place in this builder, so the composer's text view (focus,
        // caret, the text being sent) is the same view before and after.
        let docked = claude.hasStarted
        VStack(spacing: 0) {
            ClaudeHeader(claude: claude, palette: p, onClose: onClose, onContinueInTerminal: onContinueInTerminal,
                         onToggleExplorer: onToggleExplorer)
            if let review {
                ReviewChangesView(model: review, onBack: { self.review = nil }) { text in
                    claude.send(text)
                    self.review = nil
                }
            } else {
                chat(p, docked: docked)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.12), value: docked)
        .background(p.background)
        .foregroundStyle(p.foreground)
        // System colors (status, labeled buttons, .primary) follow the terminal
        // theme, not the system appearance, so they read on its background.
        .environment(\.colorScheme, p.isDark ? .dark : .light)
        .onReceive(NotificationCenter.default.publisher(for: .shellReviewChanges)) { note in
            guard (note.object as AnyObject?) === claude, let repo = claude.repository else { return }
            openReview(repo, path: note.userInfo?["path"] as? String)
        }
    }

    private func openReview(_ repo: GitRepository, path: String?) {
        let model = review ?? ReviewChangesModel(repository: repo)
        if let path {
            let root = repo.root.standardizedFileURL.path + "/"
            let full = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.path : root + path
            model.selectedPath = full.hasPrefix(root) ? String(full.dropFirst(root.count)) : path
        }
        review = model
    }

    @ViewBuilder
    private func chat(_ p: ClaudePalette, docked: Bool) -> some View {
        if docked {
            transcript(p)
                .transition(.opacity)
        } else {
            emptyState(p)
                .transition(.opacity)
        }
        bottom(p, docked: docked)
        if !docked {
            // Matches the space above, so the composer is centered.
            Color.clear
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { composer.focus() }
        }
    }

    // MARK: Empty state

    private func emptyState(_ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if claude.needsTrust {
                TrustGate(directory: claude.directory, palette: p, onTrust: { claude.trustAndStart() },
                          onOpenTerminal: onContinueInTerminal, onClose: onClose)
            } else if let login = claude.login {
                LoginGate(login: login, palette: p, onClose: onClose)
            } else {
                ClaudeWelcome(claude: claude, palette: p)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .frame(maxWidth: Self.emptyStateWidth + 28, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { composer.focus() }
    }

    // MARK: Transcript

    private func transcript(_ p: ClaudePalette) -> some View {
        let mentions = InlineMarkdown.MentionStyle(skills: claude.skills, commands: Set(claude.commands.map(\.name)),
                                                   mcpServers: Set(claude.mcpServers.map(\.mention)), agents: Set(claude.agents))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if claude.needsTrust {
                    TrustGate(directory: claude.directory, palette: p, onTrust: { claude.trustAndStart() },
                              onOpenTerminal: onContinueInTerminal, onClose: onClose)
                } else if claude.items.isEmpty && claude.login == nil {
                    ClaudeWelcome(claude: claude, palette: p)
                }
                ForEach(ClaudeTranscript.rows(claude.items, mode: ChatPreferences.shared.toolCalls, turnRunning: claude.isRunning)) { row in
                    ClaudeRowView(row: row, palette: p, mentions: mentions, fontSize: fontSize, directory: claude.directory, session: claude)
                }
                if let login = claude.login {
                    LoginGate(login: login, palette: p, onClose: onClose)
                }
            }
            // A comfortable reading measure on wide windows (Settings › Chat Text).
            .frame(maxWidth: readingWidth ?? .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .contentShape(Rectangle())
        .onTapGesture { composer.focus() }
    }

    // MARK: Bottom: prompts, status, composer, hints

    private func bottom(_ p: ClaudePalette, docked: Bool) -> some View {
        // Docked and centered, the composer lines up with the transcript's
        // reading width; full width, it fills the pane.
        let width = docked ? (columnWidth == nil ? nil : readingWidth) : min(Self.emptyStateWidth, columnWidth ?? .infinity)
        return VStack(alignment: .leading, spacing: 8) {
            if let req = claude.pending.first {
                if req.isQuestion {
                    QuestionCard(request: req, palette: p, fontSize: fontSize, directory: claude.directory) { answers in
                        claude.answer(req, answers: answers)
                        composer.focus()
                    } onDeny: {
                        claude.respond(req, allow: false, message: "The user declined to answer.")
                    }
                    .id(req.id)
                } else if req.isPlan {
                    PlanCard(request: req, palette: p, fontSize: fontSize, directory: claude.directory) { mode in
                        if let mode { claude.approvePlan(req, mode: mode) } else { claude.keepPlanning(req, feedback: "") }
                        composer.focus()
                    }
                } else {
                    PermissionCard(request: req, palette: p, fontSize: fontSize) { allow, always in
                        if !allow, let coordinator = composer.textView?.delegate as? ClaudeComposerField.Coordinator,
                           coordinator.denyWithTypedInstructions(req) {
                            // "Deny, and tell Claude what to do instead" with instructions typed.
                        } else {
                            claude.respond(req, allow: allow, always: always)
                        }
                        composer.focus()
                    }
                }
            }
            if composer.showsSuggestions {
                ClaudeSuggestionList(model: composer, palette: p) { s in
                    (composer.textView?.delegate as? ClaudeComposerField.Coordinator)?.accept(s)
                }
                .frame(maxWidth: 720, alignment: .leading)
            }
            ClaudeActivityLine(claude: claude, palette: p)
            composerBox(p)
            ClaudeComposerFooter(claude: claude, palette: p)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: width.map { $0 + 28 } ?? .infinity)
        .frame(maxWidth: .infinity)
        .zIndex(1)
    }

    private func composerBox(_ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !claude.draftAttachments.isEmpty {
                ClaudeAttachmentStrip(attachments: claude.draftAttachments, palette: p) { a in
                    claude.draftAttachments.removeAll { $0.id == a.id }
                    composer.focus()
                }
            }
            ClaudeComposerField(claude: claude, model: composer, palette: p, fontSize: fontSize, onExit: onClose, onFocus: onFocus)
                .frame(height: composer.height)
                .padding(.leading, 2)
            composerControls(p)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(composer.dropTargeted ? p.blue.opacity(0.1) : p.raised))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(composer.dropTargeted ? p.blue : borderColor(p), style: StrokeStyle(lineWidth: composer.dropTargeted ? 2 : 1,
                                                                                          dash: composer.dropTargeted ? [6, 4] : [])))
        .shadow(color: .black.opacity(p.isDark ? 0.25 : 0.08), radius: 12, y: 6)
        .overlay(alignment: .topTrailing) {
            if composer.dropTargeted {
                Label("Drop to attach", systemImage: "paperclip")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(p.surface))
                    .overlay(Capsule().strokeBorder(p.blue.opacity(0.6)))
                    .offset(x: -10, y: -11)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: composer.dropTargeted)
        // The padding and buttons around the text view take drops too.
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { composer.dropTargeted }, set: { composer.dropTargeted = $0 })) { providers in
            guard !claude.hasExited else { return false }
            ClaudeAttachment.load(providers: providers) { claude.draftAttachments.append($0) }
            composer.focus()
            return true
        }
    }

    /// "+", "@ Context", "/ Skills & commands", then stop or send.
    private func composerControls(_ p: ClaudePalette) -> some View {
        HStack(spacing: 4) {
            Button {
                ClaudeAttachmentPicker.choose(in: composer.textView?.window, directory: claude.directory) { new in
                    claude.draftAttachments += new
                    composer.focus()
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28)
            }
            .buttonStyle(ComposerToolButtonStyle(palette: p))
            .disabled(claude.hasExited)
            .help("Attach files or images (or paste / drop them here)")
            .accessibilityLabel("Attach files")
            Button { composer.beginToken("@") } label: {
                HStack(spacing: 5) {
                    Text("@").foregroundStyle(p.dim)
                    Text("Context")
                }
                .padding(.horizontal, 9).frame(height: 26)
            }
            .buttonStyle(ComposerToolButtonStyle(palette: p))
            .help("Mention files, MCP servers or subagents (@)")
            Button { composer.beginToken("/") } label: {
                HStack(spacing: 5) {
                    Text("/").foregroundStyle(p.dim)
                    Text("Skills & commands")
                }
                .padding(.horizontal, 9).frame(height: 26)
            }
            .buttonStyle(ComposerToolButtonStyle(palette: p))
            .help("Run a skill or slash command (/)")
            Spacer(minLength: 4)
            // While a prompt waits, typing answers it, so the button sends.
            if claude.isRunning && claude.pending.isEmpty {
                Button { claude.interrupt() } label: {
                    RoundedRectangle(cornerRadius: 2).fill(p.background).frame(width: 9, height: 9)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(p.foreground))
                }
                .buttonStyle(.plain)
                .help("Interrupt (Esc)")
                .accessibilityLabel("Interrupt Claude")
            } else {
                let empty = composer.isEmpty && claude.draftAttachments.isEmpty
                Button {
                    (composer.textView?.delegate as? ClaudeComposerField.Coordinator)?.submit()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(empty ? p.dim : Color.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(empty ? p.foreground.opacity(0.12) : p.claude))
                }
                .buttonStyle(.plain)
                .disabled(empty || !claude.canSend)
                .help("Send (Return)")
                .accessibilityLabel("Send")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(p.foreground.opacity(0.8))
    }

    private func borderColor(_ p: ClaudePalette) -> Color {
        switch claude.permissionMode {
        case .acceptEdits: p.magenta.opacity(0.6)
        case .plan: p.cyan.opacity(0.6)
        case .bypassPermissions: p.red.opacity(0.7)
        // Auto mode is the everyday mode; the toolbar names it.
        default: p.border
        }
    }
}

/// The composer's "+", "@ Context" and "/ Skills & commands": quiet until hovered.
private struct ComposerToolButtonStyle: ButtonStyle {
    let palette: ClaudePalette

    func makeBody(configuration: Configuration) -> some View {
        ComposerToolButton(configuration: configuration, palette: palette)
    }

    private struct ComposerToolButton: View {
        let configuration: ButtonStyleConfiguration
        let palette: ClaudePalette
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(configuration.isPressed ? palette.foreground.opacity(0.12) : hovering ? palette.foreground.opacity(0.07) : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Under the composer: key hints, then the context meter and the session's cost.
struct ClaudeComposerFooter: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    var body: some View {
        let p = palette
        HStack(spacing: 12) {
            Text("⏎ send · ⇧⏎ new line · ↑ previous prompt").lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let tokens = claude.contextTokens {
                let window = claude.contextWindow
                HStack(spacing: 6) {
                    Text("Context")
                    ContextMeter(fraction: Double(tokens) / Double(max(window, 1)), palette: p)
                    Text("\(ClaudeFormat.tokens(tokens)) / \(ClaudeFormat.tokens(window))").monospacedDigit()
                }
                .help("\(tokens.formatted()) of \(window.formatted()) tokens of context in use")
                .fixedSize()
            }
            if claude.totalCost > 0 {
                Text(String(format: "$%.2f", claude.totalCost))
                    .monospacedDigit()
                    .help("Cost reported by Claude Code for this session")
                    .fixedSize()
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(p.dim)
        .padding(.horizontal, 6)
    }
}

/// A thin bar: how full the context window is. Turns yellow past 80%.
struct ContextMeter: View {
    let fraction: Double
    let palette: ClaudePalette

    var body: some View {
        let f = min(max(fraction, 0), 1)
        Capsule().fill(palette.foreground.opacity(0.1))
            .frame(width: 44, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(f > 0.8 ? DS.Status.needsYou : palette.dim).frame(width: max(2, 44 * f), height: 4)
            }
            .accessibilityLabel("Context \(Int(f * 100)) percent used")
    }
}

// MARK: - Header

/// The Claude view's header: title, repository / branch, PR and checks, then
/// model, effort, mode, MCP, "…" and the inspector toggle. With vertical
/// tabs the window's unified toolbar shows all of this for the focused pane,
/// so the pane draws no header of its own (one bar, not two).
struct ClaudeHeader: View {
    @Bindable var claude: ClaudeCodeSession
    let palette: ClaudePalette
    var onClose: () -> Void
    var onContinueInTerminal: () -> Void
    var onToggleExplorer: () -> Void

    var body: some View {
        if SettingsStore.shared.settings.tabBarStyle != .vertical {
            HStack(spacing: 12) {
                ClaudeMark(size: 15)
                ToolbarTitle(title: "Claude Code", subtitle: RepoSubtitleText(repo: claude.repository, directory: claude.directory, isClaude: true))
                StatusIndicator(status: status)
                if let repo = claude.repository {
                    StatusCapsules(repo: repo) {
                        claude.showExplorer = true
                        BranchChecksRequest.post(repository: repo, sessionID: nil)
                    }
                }
                Spacer(minLength: 8)
                ClaudeToolbarControls(
                    claude: claude, inspectorOn: claude.showExplorer,
                    onToggleInspector: claude.repository == nil ? nil : onToggleExplorer,
                    onClose: onClose, onContinueInTerminal: onContinueInTerminal) { EmptyView() }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(palette.surface)
            .overlay(alignment: .bottom) { palette.border.frame(height: 1) }
        }
    }

    private var status: StatusKind {
        if claude.hasExited { return .idle }
        if claude.login != nil || !claude.pending.isEmpty { return .needsYou }
        return claude.isRunning ? .working : .idle
    }
}

/// Remote Control status; the popover shows a QR code to continue on a phone.
struct RemoteControlButton: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette
    @State private var showing = false

    var body: some View {
        let on = claude.remoteControlURL != nil
        Button { showing.toggle() } label: {
            if claude.remoteControlBusy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: on ? "iphone.radiowaves.left.and.right" : "iphone.slash")
            }
        }
        .buttonStyle(HeaderButtonStyle(palette: palette, active: on))
        .help(on ? "Remote Control is on — continue this session in the Claude app" : "Remote Control is off")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            RemoteControlPopover(claude: claude, palette: palette)
        }
    }
}

struct RemoteControlPopover: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { claude.remoteControlURL != nil }, set: { claude.setRemoteControl($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote Control").font(.system(size: 13, weight: .semibold))
                    Text("Continue this session from the Claude app or claude.ai/code.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(claude.remoteControlBusy || claude.hasExited)
            if let url = claude.remoteControlURL {
                HStack(alignment: .top, spacing: 12) {
                    if let qr = QRCode.image(for: url.absoluteString, size: 132) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with your phone's camera, or open the session in the Claude app's Code tab.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(url.absoluteString)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        HStack {
                            Button(copied ? "Copied" : "Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                copied = true
                            }
                            Button("Open") { NSWorkspace.shared.open(url) }
                        }
                        .controlSize(.small)
                    }
                    .frame(width: 200)
                }
            }
            if let err = claude.remoteControlError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Turn on for every session", isOn: Binding(get: { SettingsStore.shared.settings.claudeRemoteControl },
                                                              set: { SettingsStore.shared.settings.claudeRemoteControl = $0 }))
                .font(.system(size: 11))
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
    }
}

enum QRCode {
    static func image(for text: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct HeaderButtonStyle: ButtonStyle {
    let palette: ClaudePalette
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? palette.claude : palette.dim)
            .frame(width: 24, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? palette.raised : .clear))
            .contentShape(Rectangle())
    }
}

// MARK: - Status line

struct ClaudeStatusLine: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    static func modeColor(_ mode: ClaudePermissionMode, _ p: ClaudePalette) -> Color {
        switch mode {
        case .default: p.dim
        case .acceptEdits: p.magenta
        case .plan: p.cyan
        case .auto: p.yellow
        case .dontAsk: p.dim
        case .bypassPermissions: p.red
        }
    }

    var body: some View {
        let p = palette
        HStack(spacing: 10) {
            Button { claude.cyclePermissionMode() } label: {
                HStack(spacing: 4) {
                    Image(systemName: claude.permissionMode.symbol)
                    Text(modeLine)
                }
                .foregroundStyle(Self.modeColor(claude.permissionMode, p))
            }
            .buttonStyle(.plain)
            .help("Click or press ⇧⇥ to change the permission mode")
            Spacer()
            if let tokens = claude.contextTokens {
                Text("\(Self.compact(tokens)) context").foregroundStyle(p.dim)
            }
            if claude.totalCost > 0 {
                Text(String(format: "$%.2f", claude.totalCost)).foregroundStyle(p.dim)
                    .help("Cost reported by Claude Code for this session")
            }
            Text(claude.resolvedModel.map(ClaudeModelName.format) ?? claude.modelTitle).foregroundStyle(p.dim)
                .help(claude.resolvedModel ?? "")
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 4)
    }

    private var modeLine: String {
        switch claude.permissionMode {
        case .default: "ask before edits · ⇧⇥ to cycle"
        case .acceptEdits: "accept edits on · ⇧⇥ to cycle"
        case .plan: "plan mode on · ⇧⇥ to cycle"
        case .auto: "auto mode on · ⇧⇥ to cycle"
        case .dontAsk: "don't ask mode"
        case .bypassPermissions: "bypass permissions on"
        }
    }

    static func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

// MARK: - Items

struct ClaudeWelcome: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What should we work on?").font(.system(size: 15, weight: .semibold))
            Text("Type / for skills and commands, @ to mention files or MCP servers. ⇧⇥ changes the permission mode, Esc interrupts, ⌃D returns to the shell.")
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
            if let account = claude.accountLabel {
                Text(account).font(.system(size: 11)).foregroundStyle(palette.dim)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Shown instead of starting Claude in a folder Claude Code hasn't been trusted in.
struct TrustGate: View {
    let directory: String
    let palette: ClaudePalette
    var onTrust: () -> Void
    var onOpenTerminal: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Do you trust the files in this folder?", systemImage: "lock.shield").font(.system(size: 15, weight: .semibold))
            Text(ClaudeToolFormat.shortPath(directory))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.foreground)
            Text("Claude Code will be able to read, edit and run files here, and will start this folder's hooks and .mcp.json servers. Only trust folders whose code you trust. This is the same choice as Claude Code's own trust prompt, and it's saved in ~/.claude.json.")
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Trust and Start", action: onTrust)
                    .buttonStyle(.borderedProminent).tint(palette.claude)
                Button("Review in Terminal UI", action: onOpenTerminal)
                Button("Close", action: onClose)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.yellow.opacity(0.5)))
    }
}

/// Shown while Claude Code isn't signed in. Runs Claude Code's own login
/// (`claude auth login`), so the sign-in is the same as `/login` in its terminal UI.
struct LoginGate: View {
    @Bindable var login: ClaudeLogin
    let palette: ClaudePalette
    var onClose: () -> Void
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(login.expired ? "Sign in to Claude Code again" : "Sign in to Claude Code", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 15, weight: .semibold))
            Text(login.expired
                 ? "Claude Code's sign-in expired or was revoked. Sign in again and the conversation continues, starting with the message that didn't go through."
                 : "Claude Code isn't signed in. Sign in here the same way as /login in Claude Code. Claude Code saves the sign-in, so `claude` in your terminals is signed in too.")
                .font(.system(size: 12))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            switch login.phase {
            case .choosing, .failed:
                if case .failed(let message) = login.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(ClaudeLogin.Method.allCases) { method in
                    Button { login.begin(method) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(method.title).font(.system(size: 12, weight: .semibold))
                            Text(method.detail).font(.system(size: 11)).foregroundStyle(palette.dim)
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                HStack {
                    Toggle("Use single sign-on (SSO)", isOn: $login.useSSO).toggleStyle(.checkbox)
                    Spacer()
                    Button("Close", action: onClose)
                }
                .frame(maxWidth: 360)
            case .signingIn:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.system(size: 12))
                }
                Text("If the page shows a code, paste it here:")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.dim)
                HStack {
                    TextField("Code", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 320)
                        .onSubmit(submitCode)
                    Button("Submit", action: submitCode)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Button("Open Sign-in Page") { login.openSignInPage() }
                        .disabled(login.url == nil)
                        .help("Opens the sign-in page again, if the browser didn't open")
                    Button("Cancel") { login.cancel() }
                }
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking sign-in…").font(.system(size: 12))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.yellow.opacity(0.5)))
    }

    private func submitCode() {
        login.submit(code: code)
        code = ""
    }
}

struct ClaudeItemView: View, Equatable {
    let item: ClaudeItem
    let palette: ClaudePalette
    let mentions: InlineMarkdown.MentionStyle
    let fontSize: CGFloat
    var directory: String?
    /// For actions that need the session (Review, Fix with Claude).
    var session: ClaudeCodeSession?

    /// Lets the transcript skip items whose inputs didn't change when the
    /// pane re-renders. Changes inside `item` still arrive via Observation.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.item === b.item && a.fontSize == b.fontSize && a.mentions == b.mentions && a.palette == b.palette
                && a.directory == b.directory && a.session === b.session
        }
    }

    var body: some View {
        let p = palette
        switch item.kind {
        case .user:
            UserMessageView(item: item, palette: p, mentions: mentions, fontSize: fontSize, directory: directory)
        case .assistant:
            MarkdownView(text: item.text, palette: p, mentions: mentions, fontSize: fontSize, directory: directory)
        case .thinking:
            ThinkingView(item: item, palette: p, fontSize: fontSize)
        case .tool:
            switch item.toolName {
            case "AskUserQuestion": QuestionSummaryView(item: item, palette: p, fontSize: fontSize, directory: directory)
            case "ExitPlanMode": PlanSummaryView(item: item, palette: p, fontSize: fontSize, directory: directory)
            case "TodoWrite": TodoListView(item: item, palette: p, fontSize: fontSize)
            default: ToolCallView(item: item, palette: p, fontSize: fontSize, directory: directory, session: session)
            }
        case .checkFailure:
            CheckFailureCard(item: item, palette: p, fontSize: fontSize, session: session)
        case .notice:
            HStack(spacing: 6) {
                Rectangle().fill(p.border).frame(height: 1)
                Text(item.text).font(.system(size: 11)).foregroundStyle(p.dim).fixedSize()
                Rectangle().fill(p.border).frame(height: 1)
            }
        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Status.failed)
                Text(item.text).font(.system(size: fontSize - 1, design: .monospaced)).foregroundStyle(p.red).textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.row).fill(DS.Status.failed.opacity(0.08)))
        }
    }
}

/// Your message: a right-aligned bubble, with its attachments above it.
struct UserMessageView: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let mentions: InlineMarkdown.MentionStyle
    let fontSize: CGFloat
    var directory: String?

    var body: some View {
        let p = palette
        let context = item.attachments.filter { $0.tag != nil }
        let files = item.attachments.filter { $0.tag == nil }
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(context) { a in
                ContextChip(attachment: a, palette: p)
            }
            if !files.isEmpty {
                ClaudeAttachmentStrip(attachments: files, palette: p)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if !item.text.isEmpty {
                MarkdownView(text: item.text, palette: p, mentions: mentions, fontSize: fontSize, directory: directory, fills: false)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
                                                       topTrailingRadius: 16).fill(p.raised))
            }
        }
        .padding(.leading, 60)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Context Shell attached to a message: "LOG build-and-test · 212 lines".
struct ContextChip: View {
    let attachment: ClaudeAttachment
    let palette: ClaudePalette

    var body: some View {
        HStack(spacing: 6) {
            if let tag = attachment.tag {
                Text(tag).font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.Status.failed)
            }
            Text([attachment.name, attachment.note].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11.5))
                .foregroundStyle(palette.foreground.opacity(0.8))
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { QuickLookController.shared.toggle([attachment.url]) }
        .help(attachment.url.path)
    }
}

// MARK: - Question, plan and todo transcript entries

/// An AskUserQuestion call in the transcript: each question and the answer given.
struct QuestionSummaryView: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?

    var body: some View {
        let p = palette
        // `summary` changes when the input arrives; reading it tracks that.
        let questions = item.summary.isEmpty && item.input.isEmpty ? [] : ClaudeQuestion.parse(item.input)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble").foregroundStyle(p.claude).frame(width: 14)
                Text(questions.count > 1 ? "Claude asked \(questions.count) questions" : "Claude asked")
                    .font(.system(size: fontSize - 1, weight: .semibold))
            }
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !q.header.isEmpty { QuestionHeaderChip(text: q.header, palette: p) }
                        Text(InlineMarkdown.attributed(q.question, palette: p, directory: directory))
                            .font(.system(size: fontSize - 0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    answerLine(q, single: questions.count == 1)
                }
                .padding(.leading, 21)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func answerLine(_ q: ClaudeQuestion, single: Bool) -> some View {
        let p = palette
        let answer = item.answers?[q.question] ?? (single ? item.answers?.values.first : nil)
        if let answer {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(p.dim)
                Text(answer).font(.system(size: fontSize - 0.5, weight: .medium)).foregroundStyle(p.claude).textSelection(.enabled)
            }
        } else if item.isRunning {
            Text("Waiting for your answer…").font(.system(size: fontSize - 1.5)).italic().foregroundStyle(p.dim)
        } else if item.isError {
            Text("Not answered").font(.system(size: fontSize - 1.5)).foregroundStyle(p.dim)
        }
    }
}

/// An ExitPlanMode call in the transcript: the plan and what became of it.
struct PlanSummaryView: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    @State private var collapsed = false

    var body: some View {
        let p = palette
        let plan = item.summary.isEmpty ? "" : (item.input["plan"] as? String ?? "")
        VStack(alignment: .leading, spacing: 6) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet.clipboard").foregroundStyle(p.cyan).frame(width: 14)
                    Text("Plan").font(.system(size: fontSize - 1, weight: .semibold))
                    Text(status).font(.system(size: fontSize - 1.5)).foregroundStyle(p.dim)
                    Spacer(minLength: 0)
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9)).foregroundStyle(p.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed, !plan.isEmpty {
                MarkdownView(text: plan, palette: p, fontSize: fontSize - 0.5, directory: directory)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.cyan.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        if item.isRunning { return "waiting for review" }
        if item.isError { return "kept planning" }
        return item.result == nil ? "" : "approved"
    }
}

/// A TodoWrite call as the checklist Claude is working through.
struct TodoListView: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat

    var body: some View {
        let p = palette
        let todos = item.summary.isEmpty ? [] : ClaudeToolFormat.todos(item.input)
        let done = todos.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: fontSize - 2)).foregroundStyle(p.dim).frame(width: 14)
                Text("To-dos").font(.system(size: fontSize - 1.5, weight: .semibold))
                if !todos.isEmpty {
                    Text("\(done) of \(todos.count)").font(.system(size: fontSize - 2)).foregroundStyle(p.dim)
                }
            }
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    TodoStateMark(state: InspectorTodo.State(todo.status), size: 14)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    Text(todo.content)
                        .font(.system(size: fontSize - 1.5, weight: todo.status == .inProgress ? .medium : .regular))
                        .strikethrough(todo.status == .completed, color: p.dim)
                        .foregroundStyle(todo.status == .completed ? p.dim : todo.status == .pending ? p.foreground.opacity(0.8) : p.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension Bool? {
    var isTrue: Bool { self == true }
}
