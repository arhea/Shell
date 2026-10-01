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
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.12), value: docked)
        .background(p.background)
        .foregroundStyle(p.foreground)
        // System colors (status, labeled buttons, .primary) follow the terminal
        // theme, not the system appearance, so they read on its background.
        .environment(\.colorScheme, p.isDark ? .dark : .light)
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
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            // A comfortable reading measure on wide windows (Settings › Chat Text).
            .frame(maxWidth: readingWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .contentShape(Rectangle())
        .onTapGesture { composer.focus() }
    }

    // MARK: Bottom: prompts, status, composer, hints

    private func bottom(_ p: ClaudePalette, docked: Bool) -> some View {
        let width = docked ? columnWidth : min(Self.emptyStateWidth, columnWidth ?? .infinity)
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
            if claude.isRunning {
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
        case .auto: p.yellow.opacity(0.6)
        case .bypassPermissions: p.red.opacity(0.7)
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

struct ClaudeHeader: View {
    @Bindable var claude: ClaudeCodeSession
    let palette: ClaudePalette
    var onClose: () -> Void
    var onContinueInTerminal: () -> Void
    var onToggleExplorer: () -> Void

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(p.claude)
                Text("Claude Code").font(.system(size: 13, weight: .semibold))
                stateBadge(p)
                Spacer(minLength: 8)
                ModelMenu(claude: claude, palette: p)
                EffortMenu(claude: claude, palette: p)
                ModeMenu(claude: claude, palette: p)
                RemoteControlButton(claude: claude, palette: p)
                MCPHeaderButton(claude: claude, palette: p)
                if claude.repository != nil {
                    Button(action: onToggleExplorer) {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: claude.showExplorer))
                    .help(claude.showExplorer ? "Hide file explorer" : "Show file explorer")
                }
                Menu {
                    Button("Continue in Terminal UI") { onContinueInTerminal() }
                        .disabled(claude.sessionID == nil)
                    Button("Interrupt") { claude.interrupt() }.disabled(!claude.isRunning)
                    Divider()
                    Button("Close Claude") { onClose() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(p.dim)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: false))
                    .help("Close Claude and return to the shell (⌃D)")
            }
            ClaudeContextBar(claude: claude, palette: p)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(p.surface)
        .overlay(alignment: .bottom) { p.border.frame(height: 1) }
    }

    @ViewBuilder
    private func stateBadge(_ p: ClaudePalette) -> some View {
        if claude.login != nil {
            badge("signed out", p.yellow, p)
        } else if claude.hasExited {
            badge("ended", p.dim, p)
        } else if !claude.pending.isEmpty {
            badge("needs you", p.yellow, p)
        } else if claude.isRunning {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("working").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.claude)
            }
        } else if claude.isStarting {
            badge("starting", p.dim, p)
        }
    }

    private func badge(_ text: String, _ color: Color, _ p: ClaudePalette) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
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

/// Opens the MCP manager; badged with the number of servers needing sign-in.
struct MCPHeaderButton: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    var body: some View {
        let waiting = claude.mcpNeedsAuth.count
        Button {
            MCPManagerWindowController.show(directory: claude.directory, binary: claude.request.binary,
                                            environment: claude.request.environment, select: claude.mcpNeedsAuth.first?.name)
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .overlay(alignment: .topTrailing) {
                    if waiting > 0 {
                        Text("\(waiting)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(palette.yellow))
                            .offset(x: 7, y: -6)
                    }
                }
        }
        .buttonStyle(HeaderButtonStyle(palette: palette, active: false))
        .help(waiting > 0 ? "MCP servers — \(waiting) need sign-in" : "MCP servers (\(claude.mcpServers.count))")
    }
}

/// Directory, branch, worktree and change count.
struct ClaudeContextBar: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    var body: some View {
        let p = palette
        HStack(spacing: 6) {
            if let repo = claude.repository {
                let st = repo.status
                let gh = repo.github
                // Repository: GitHub link when there's a GitHub remote.
                if let gh {
                    chip(icon: "shippingbox", text: gh.slug, color: p.cyan, url: gh.url, help: "Open \(gh.slug) on GitHub", priority: 3)
                } else {
                    chip(icon: "shippingbox", text: repo.name, color: p.cyan, help: "Repository root: \(repo.root.path)", priority: 3)
                        .onTapGesture { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.root.path) }
                }
                // Branch: its page on GitHub once pushed.
                let branchText = repo.branchLabel + (st.ahead > 0 ? " ↑\(st.ahead)" : "") + (st.behind > 0 ? " ↓\(st.behind)" : "")
                if let gh, let branch = st.branch, repo.isBranchPublished {
                    chip(icon: "arrow.triangle.branch", text: branchText, color: p.magenta, url: gh.branchURL(branch),
                         help: "Open \(branch) on GitHub (tracking \(st.upstream ?? ""))", priority: 1, truncation: .middle)
                } else {
                    chip(icon: "arrow.triangle.branch", text: branchText, color: p.magenta,
                         help: gh == nil ? "No GitHub remote" : "Not pushed yet — no upstream branch", priority: 1, truncation: .middle)
                }
                // Pull request, or a shortcut to open one.
                if let pr = repo.pullRequest {
                    chip(icon: prIcon(pr), text: "#\(pr.number)", color: prColor(pr, p), url: pr.url,
                         help: "\(pr.title)\n\(pr.isDraft ? "Draft" : pr.state.rawValue.capitalized) — open on GitHub", priority: 3)
                } else if let gh, let branch = st.branch, repo.isBranchPublished, branch != repo.defaultBranch {
                    chip(icon: "plus", text: "Create PR", color: p.green, url: gh.compareURL(branch), help: "Open a pull request for \(branch) on GitHub", priority: 3)
                }
                if repo.isLinkedWorktree {
                    chip(icon: "square.stack.3d.up", text: "worktree", color: p.yellow,
                         help: "Linked worktree at \(repo.root.path)" + (repo.mainWorktree.map { "\nMain checkout: \($0.path)" } ?? ""),
                         priority: 2)
                        .onTapGesture { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.root.path) }
                }
            }
            chip(icon: "folder", text: ClaudeToolFormat.shortPath(claude.directory), color: p.blue,
                 help: "\(claude.directory)\nClick to reveal in Finder")
                .onTapGesture { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: claude.directory) }
            if let repo = claude.repository {
                let changes = repo.status.changeCount
                if changes > 0 { chip(icon: "plusminus", text: "\(changes) changed", color: p.yellow, help: "Uncommitted changes", priority: 2) }
            } else if claude.repositoryChecked {
                chip(icon: "questionmark.folder", text: "not a git repository", color: p.dim, help: "")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func prIcon(_ pr: PullRequestInfo) -> String {
        switch pr.state {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .open: pr.isDraft ? "circle.dashed" : "arrow.triangle.pull"
        }
    }

    private func prColor(_ pr: PullRequestInfo, _ p: ClaudePalette) -> Color {
        switch pr.state {
        case .merged: p.magenta
        case .closed: p.red
        case .open: pr.isDraft ? p.dim : p.green
        }
    }

    @ViewBuilder
    /// Chips with higher `priority` keep their full text when space is short.
    private func chip(icon: String, text: String, color: Color, url: URL? = nil, help: String,
                      priority: Double = 0, truncation: Text.TruncationMode = .head) -> some View {
        let body = HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(palette.foreground.opacity(0.88)).lineLimit(1).truncationMode(truncation)
            if url != nil {
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold)).foregroundStyle(palette.dim)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(palette.raised))
        .overlay(Capsule().strokeBorder(palette.border, lineWidth: 0.5))
        .help(help)
        .fixedSize(horizontal: priority >= 2, vertical: false)
        .layoutPriority(priority)
        if let url {
            Button { NSWorkspace.shared.open(url) } label: { body }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        } else {
            body
        }
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

/// Pill-shaped menu used for model, effort and mode.
struct PillMenu<Content: View>: View {
    let icon: String
    let title: String
    let color: Color
    let palette: ClaudePalette
    let help: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).foregroundStyle(palette.foreground)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(palette.dim)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.raised))
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

struct ModelMenu: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    var body: some View {
        PillMenu(icon: "cpu", title: claude.modelTitle, color: palette.claude, palette: palette,
                 help: "Model" + (claude.resolvedModel.map { " — using \($0)" } ?? "")) {
            if claude.models.isEmpty {
                ForEach(["default", "opus", "sonnet", "haiku"], id: \.self) { m in
                    Toggle(m.capitalized, isOn: Binding(get: { claude.model == m }, set: { _ in claude.setModel(m) }))
                }
            } else {
                ForEach(claude.models) { m in
                    Toggle(isOn: Binding(get: { claude.model == m.value }, set: { _ in claude.setModel(m.value) })) {
                        Text(m.label)
                        if !m.detail.isEmpty { Text(m.detail) }
                    }
                }
            }
        }
    }
}

struct EffortMenu: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    var body: some View {
        if !claude.effortLevels.isEmpty {
            PillMenu(icon: "gauge.with.dots.needle.50percent", title: claude.effort.isEmpty ? "Auto effort" : claude.effort.capitalized,
                     color: palette.yellow, palette: palette, help: "Effort: how much Claude thinks before acting") {
                Toggle("Model default", isOn: Binding(get: { claude.effort.isEmpty }, set: { _ in claude.setEffort("") }))
                Divider()
                ForEach(claude.effortLevels, id: \.self) { level in
                    Toggle(level == "xhigh" ? "Extra high" : level.capitalized,
                           isOn: Binding(get: { claude.effort == level }, set: { _ in claude.setEffort(level) }))
                }
            }
        }
    }
}

struct ModeMenu: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    var body: some View {
        PillMenu(icon: claude.permissionMode.symbol, title: claude.permissionMode.title,
                 color: ClaudeStatusLine.modeColor(claude.permissionMode, palette), palette: palette,
                 help: "Permission mode (⇧⇥ to cycle)") {
            ForEach(claude.availableModes) { mode in
                Toggle(isOn: Binding(get: { claude.permissionMode == mode }, set: { _ in claude.setPermissionMode(mode) })) {
                    Text(mode.title)
                    Text(mode.detail)
                }
            }
        }
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
                MarkdownView(text: item.text, palette: p, mentions: mentions, fontSize: fontSize, directory: directory)
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "checklist").foregroundStyle(p.dim).frame(width: 14)
                Text("Todos").font(.system(size: fontSize - 1, weight: .semibold))
                if !todos.isEmpty {
                    Text("\(done) of \(todos.count) done").font(.system(size: fontSize - 1.5)).foregroundStyle(p.dim)
                }
            }
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(todo.status)).foregroundStyle(color(todo.status, p)).font(.system(size: fontSize - 2))
                    Text(todo.status == .inProgress && !todo.activeForm.isEmpty ? todo.activeForm : todo.content)
                        .font(.system(size: fontSize - 1, weight: todo.status == .inProgress ? .semibold : .regular))
                        .strikethrough(todo.status == .completed, color: p.dim)
                        .foregroundStyle(todo.status == .completed ? p.dim : p.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 21)
            }
        }
        .padding(.vertical, 2)
    }

    private func symbol(_ s: ClaudeToolFormat.Todo.Status) -> String {
        switch s {
        case .completed: "checkmark.square.fill"
        case .inProgress: "arrow.right.square.fill"
        case .pending: "square"
        }
    }

    private func color(_ s: ClaudeToolFormat.Todo.Status, _ p: ClaudePalette) -> Color {
        switch s {
        case .completed: p.green
        case .inProgress: p.claude
        case .pending: p.dim
        }
    }
}

extension Optional where Wrapped == Bool {
    var isTrue: Bool { self == true }
}
