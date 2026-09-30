import AppKit
import SwiftUI

/// The GitHub tab's detail pane: one PR's description, conversation, checks
/// and diff, with review and merge actions. For a stack, the layers are
/// listed on top to switch between.
struct PullRequestDetailView: View {
    let model: GitHubBoardModel
    let controller: TerminalWindowController
    let pr: OpenPullRequest
    let stack: PullRequestBoard.Stack?

    enum Section: String, CaseIterable { case conversation, checks, files }

    @State private var section: Section = .conversation
    @State private var draft = ""
    @State private var confirmMerge: PullRequestBoard.MergeMethod?
    @State private var confirmClose = false

    private var detail: PullRequestDetail? { model.details[pr.number] }
    private var busy: String? { model.busy[pr.number] }

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            if let stack { stackList(stack, p) }
            header(p)
            actionBar(p)
            p.border.frame(height: 1)
            Picker("", selection: $section) {
                Text("Conversation").tag(Section.conversation)
                Text("Checks" + (detail.map { " (\($0.checks.count))" } ?? "")).tag(Section.checks)
                Text("Files" + (model.diffs[pr.number].map { " (\($0.count))" } ?? "")).tag(Section.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch section {
            case .conversation: conversation(p)
            case .checks: checks(p)
            case .files: files(p)
            }
        }
        .background(p.surface)
        .confirmationDialog("Merge #\(pr.number)?", isPresented: Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } }),
                            presenting: confirmMerge) { method in
            Button(method.title) { run(.merge(method)) }
            Button("Cancel", role: .cancel) {}
        } message: { method in
            Text("\(pr.title)\n\n\(pr.head) → \(pr.base) with \"\(method.title)\".")
        }
        .confirmationDialog("Close #\(pr.number) without merging?", isPresented: $confirmClose) {
            Button("Close Pull Request", role: .destructive) { run(.close) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pr.title)
        }
    }

    private func run(_ action: GitHubBoardModel.Action) {
        Task {
            if await model.perform(action, on: pr) {
                switch action {
                case .comment, .approve, .requestChanges: draft = ""
                default: break
                }
            }
        }
    }

    // MARK: Stack

    private func stackList(_ stack: PullRequestBoard.Stack, _ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(p.accent)
                Text("Stack of \(stack.layers.count)").font(.system(size: 11.5, weight: .semibold))
                Text("top to bottom, merging into \(stack.bottom.base)").font(.system(size: 10.5)).foregroundStyle(p.dim)
                Spacer()
            }
            ForEach(Array(stack.layers.enumerated().reversed()), id: \.element.pr.number) { _, layer in
                StackLayerRow(layer: layer, model: model, palette: p, stackID: stack.id, selected: layer.pr.number == pr.number)
            }
        }
        .padding(10)
        .background(p.background.opacity(0.5))
        .overlay(alignment: .bottom) { p.border.frame(height: 1) }
    }

    // MARK: Header

    private func header(_ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(pr.number)").font(.system(size: 14, weight: .bold)).foregroundStyle(pr.isDraft ? p.dim : p.green)
                Text(pr.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { model.selection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: false))
                    .help("Close details")
                    .keyboardShortcut(.escape, modifiers: [])
            }
            HStack(spacing: 6) {
                Text(pr.author).foregroundStyle(model.isMine(pr) ? p.claude : p.foreground.opacity(0.85))
                Text("wants to merge").foregroundStyle(p.dim)
                Text(pr.head).foregroundStyle(p.magenta).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(p.dim)
                Text(pr.base).foregroundStyle(p.foreground.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 2)
                Text("+\(pr.additions)").foregroundStyle(p.green).monospacedDigit()
                Text("−\(pr.deletions)").foregroundStyle(p.red).monospacedDigit()
            }
            .font(.system(size: 11))
            HStack(spacing: 6) {
                PRBadges(pr: pr, palette: p)
                Spacer(minLength: 0)
                if let updated = pr.updatedAt {
                    Text("updated " + PRBadges.relative(updated)).font(.system(size: 10.5)).foregroundStyle(p.dim)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Actions

    private func actionBar(_ p: ClaudePalette) -> some View {
        let worktree = model.worktree(for: pr)
        let creating = model.creatingWorktree.contains(pr.number)
        return HStack(spacing: 6) {
            if pr.isDraft {
                Button { run(.markReady) } label: { Label("Ready for Review", systemImage: "eye") }
            }
            if pr.checks == .failing {
                Button { run(.rerunFailedChecks) } label: { Label("Re-run Failed", systemImage: "arrow.clockwise") }
                    .help(pr.failedRunIDs.isEmpty ? "No failed GitHub Actions runs found" : "Re-run the failed jobs of \(pr.failedRunIDs.count) workflow run\(pr.failedRunIDs.count == 1 ? "" : "s")")
            }
            mergeButton(p)
            Menu {
                if let worktree {
                    Button("Open Terminal in Worktree") { controller.switchToDirectory(worktree) }
                    Button("Open Claude in Worktree") { openClaude(in: worktree) }
                    Button("Open Terminal in New Tab") { controller.newTab(directory: worktree) }
                } else {
                    Button("Check Out in Worktree") { checkout(then: nil) }
                    Button("Check Out and Open Claude") { checkout(then: .claude) }
                }
                Divider()
                if !pr.isDraft { Button("Convert to Draft") { run(.convertToDraft) } }
                if pr.checks == .failing { Button("Re-run Failed Checks") { run(.rerunFailedChecks) } }
                Button("Close Pull Request…") { confirmClose = true }
                Divider()
                Button("Copy Link") { PRContextMenu.copy(pr.url.absoluteString) }
                Button("Copy Branch Name") { PRContextMenu.copy(pr.head) }
            } label: {
                Label(worktree != nil ? "Worktree" : "More", systemImage: worktree != nil ? "square.stack.3d.up.fill" : "ellipsis.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            Spacer()
            if creating {
                ProgressView().controlSize(.mini)
                Text("Creating worktree…").font(.system(size: 10.5)).foregroundStyle(p.dim)
            } else if let busy {
                ProgressView().controlSize(.mini)
                Text(busy).font(.system(size: 10.5)).foregroundStyle(p.dim)
            }
            Button { NSWorkspace.shared.open(pr.url) } label: { Image(systemName: "arrow.up.right.square") }
                .help("Open #\(pr.number) on GitHub")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(busy != nil || creating)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func mergeButton(_ p: ClaudePalette) -> some View {
        let methods = model.mergeMethods.isEmpty ? [PullRequestBoard.MergeMethod.merge] : model.mergeMethods
        if !pr.isDraft {
            if methods.count == 1 {
                Button { confirmMerge = methods[0] } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                    .tint(PullRequestBoard.column(for: pr) == .ready ? p.green : nil)
            } else {
                Menu {
                    ForEach(methods) { m in Button(m.title + "…") { confirmMerge = m } }
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                } primaryAction: {
                    confirmMerge = methods[0]
                }
                .menuStyle(.button)
                .fixedSize()
                .help("\(methods[0].title) (click), or pick another method")
            }
        }
    }

    private enum Then { case claude }

    private func checkout(then: Then?) {
        Task {
            guard let path = await model.createWorktree(for: pr) else { return }
            if then == .claude { openClaude(in: path) } else { controller.switchToDirectory(path) }
        }
    }

    /// A new tab in the worktree running `claude` (native view or TUI, per Settings).
    private func openClaude(in path: String) {
        let tab = controller.newTab(directory: path)
        tab.focusedSession?.pendingCommand = "claude"
    }

    // MARK: Conversation

    private func conversation(_ p: ClaudePalette) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let detail {
                        if !detail.reviewers.isEmpty { reviewers(detail.reviewers, p) }
                        eventCard(author: pr.author, label: "opened", date: nil, body: detail.body.isEmpty ? "_No description._" : detail.body,
                                  accent: p.accent, url: pr.url, p)
                        ForEach(detail.events) { event in
                            eventView(event, p)
                        }
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading…").font(.system(size: 12)).foregroundStyle(p.dim)
                        }
                        .padding(20)
                    }
                }
                .padding(12)
            }
            p.border.frame(height: 1)
            composer(p)
        }
    }

    private func reviewers(_ list: [PullRequestDetail.Reviewer], _ p: ClaudePalette) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("Reviewers").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.dim)
            FlowBadges {
                ForEach(list) { r in
                    HStack(spacing: 3) {
                        Image(systemName: Self.reviewIcon(r.state)).foregroundStyle(Self.reviewColor(r.state, p))
                        Text(r.login)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(p.raised))
                    .help(Self.reviewTitle(r.state))
                }
            }
        }
    }

    @ViewBuilder
    private func eventView(_ e: PullRequestDetail.Event, _ p: ClaudePalette) -> some View {
        switch e.kind {
        case .comment:
            eventCard(author: e.author, label: "commented", date: e.date, body: e.body, accent: p.border, url: e.url, p)
        case .review(let state):
            eventCard(author: e.author, label: Self.reviewTitle(state).lowercased(), date: e.date, body: e.body,
                      accent: Self.reviewColor(state, p), url: e.url, p)
        case .reviewComment(let path, let line):
            eventCard(author: e.author, label: "on \(path)" + (line.map { ":\($0)" } ?? ""), date: e.date, body: e.body,
                      accent: p.blue.opacity(0.6), url: e.url, p)
        }
    }

    private func eventCard(author: String, label: String, date: Date?, body: String, accent: Color, url: URL?, _ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(author).font(.system(size: 11.5, weight: .semibold))
                Text(label).font(.system(size: 11)).foregroundStyle(p.dim).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                if let date { Text(PRBadges.relative(date)).font(.system(size: 10.5)).foregroundStyle(p.dim) }
                if let url {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right") }
                        .buttonStyle(.plain).foregroundStyle(p.dim).font(.system(size: 9, weight: .bold))
                        .help("Open on GitHub")
                }
            }
            if !body.isEmpty {
                MarkdownView(text: body, palette: p, fontSize: 12.5)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.background.opacity(0.6)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(accent).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border, lineWidth: 0.5))
    }

    private func composer(_ p: ClaudePalette) -> some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let mine = model.isMine(pr)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Leave a comment or review (Markdown)").font(.system(size: 12)).foregroundStyle(p.dim)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 54, maxHeight: 130)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7).fill(p.background))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
            HStack(spacing: 6) {
                Spacer()
                // GitHub doesn't let authors approve or request changes on their own PR.
                if !mine {
                    Button { run(.requestChanges(draft)) } label: { Label("Request Changes", systemImage: "exclamationmark.bubble") }
                        .disabled(empty)
                        .help("Submit a review requesting changes (needs a comment)")
                    Button { run(.approve(draft)) } label: { Label("Approve", systemImage: "checkmark.seal") }
                        .help("Approve, with the comment above if any")
                }
                Button { run(.comment(draft)) } label: { Label("Comment", systemImage: "text.bubble") }
                    .disabled(empty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busy != nil)
        }
        .padding(10)
    }

    // MARK: Checks

    private func checks(_ p: ClaudePalette) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if let detail {
                    if detail.checks.isEmpty {
                        Text("No checks on the latest commit.").font(.system(size: 12)).foregroundStyle(p.dim).padding(12)
                    }
                    ForEach(detail.checks.sorted { Self.order($0.state) < Self.order($1.state) }) { check in
                        Button { if let u = check.url { NSWorkspace.shared.open(u) } } label: {
                            HStack(spacing: 7) {
                                Self.checkIcon(check.state, p).frame(width: 14)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(check.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    if let wf = check.workflow { Text(wf).font(.system(size: 10.5)).foregroundStyle(p.dim).lineLimit(1) }
                                }
                                Spacer()
                                if check.url != nil { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(p.dim) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(p.background.opacity(0.5)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(check.url == nil)
                        .help(check.url == nil ? "" : "Open details")
                    }
                    if detail.mergeStateStatus != "UNKNOWN" {
                        Text("Merge state: \(detail.mergeStateStatus.lowercased().replacingOccurrences(of: "_", with: " "))")
                            .font(.system(size: 11)).foregroundStyle(p.dim).padding(.top, 8)
                    }
                } else {
                    ProgressView().controlSize(.small).padding(20)
                }
            }
            .padding(12)
        }
    }

    private static func order(_ s: PullRequestDetail.Check.State) -> Int {
        switch s {
        case .failing: 0
        case .pending: 1
        case .passing: 2
        case .skipped: 3
        }
    }

    @ViewBuilder
    private static func checkIcon(_ s: PullRequestDetail.Check.State, _ p: ClaudePalette) -> some View {
        switch s {
        case .passing: Image(systemName: "checkmark.circle.fill").foregroundStyle(p.green)
        case .failing: Image(systemName: "xmark.circle.fill").foregroundStyle(p.red)
        case .pending: Image(systemName: "clock").foregroundStyle(p.yellow)
        case .skipped: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(p.dim)
        }
    }

    // MARK: Files

    private func files(_ p: ClaudePalette) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let files = model.diffs[pr.number] {
                    if files.isEmpty { Text("No changes.").font(.system(size: 12)).foregroundStyle(p.dim).padding(12) }
                    ForEach(files) { file in
                        PullRequestFileDiff(file: file, palette: p, startExpanded: files.count <= 30)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading diff…").font(.system(size: 12)).foregroundStyle(p.dim)
                    }
                    .padding(20)
                }
            }
            .padding(12)
        }
        .onAppear { model.loadDiff(pr.number) }
    }

    // MARK: Review states

    static func reviewTitle(_ state: String) -> String {
        switch state {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Requested changes"
        case "DISMISSED": "Dismissed"
        case "REQUESTED": "Review requested"
        default: "Reviewed"
        }
    }

    static func reviewIcon(_ state: String) -> String {
        switch state {
        case "APPROVED": "checkmark.circle.fill"
        case "CHANGES_REQUESTED": "exclamationmark.circle.fill"
        case "REQUESTED": "circle.dotted"
        default: "text.bubble"
        }
    }

    static func reviewColor(_ state: String, _ p: ClaudePalette) -> Color {
        switch state {
        case "APPROVED": p.green
        case "CHANGES_REQUESTED": p.red
        case "REQUESTED": p.yellow
        default: p.dim
        }
    }
}

/// One file of a PR's diff, collapsible, drawn with the Claude view's `DiffView`.
struct PullRequestFileDiff: View {
    let file: PullRequestDiff.File
    let palette: ClaudePalette
    @State private var expanded: Bool
    @State private var showAll = false

    /// Lines drawn before "Show all", so a huge generated file doesn't stall the pane.
    static let collapsedLimit = 400

    init(file: PullRequestDiff.File, palette: ClaudePalette, startExpanded: Bool) {
        self.file = file
        self.palette = palette
        _expanded = State(initialValue: startExpanded && file.lines.count <= 1500)
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(p.dim)
                        .frame(width: 10)
                    Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    Text("+\(file.additions)").foregroundStyle(p.green).monospacedDigit()
                    Text("−\(file.deletions)").foregroundStyle(p.red).monospacedDigit()
                }
                .font(.system(size: 10.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { Button("Copy Path") { PRContextMenu.copy(file.path) } }
            if expanded {
                if file.isBinary {
                    Text("Binary file").font(.system(size: 11)).foregroundStyle(p.dim).padding(.leading, 16)
                } else if !file.lines.isEmpty {
                    DiffView(lines: file.lines, palette: p, fontSize: 11,
                             collapsedLimit: showAll ? nil : Self.collapsedLimit)
                    if !showAll, file.lines.count > Self.collapsedLimit {
                        Button("Show all \(file.lines.count) lines") { showAll = true }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
        }
    }
}
