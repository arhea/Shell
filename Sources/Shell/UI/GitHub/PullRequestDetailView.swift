import AppKit
import SwiftUI

/// The GitHub tab's detail pane: one PR's overview (description, reviewers,
/// checks, its stack), conversation, checks and diff, led by Check Out in
/// Worktree and Review with Claude, with Comment / Request changes / Approve
/// (and Merge) along the bottom.
struct PullRequestDetailView: View {
    let model: GitHubBoardModel
    let controller: TerminalWindowController
    let pr: OpenPullRequest
    let stack: PullRequestBoard.Stack?

    enum Section: String, CaseIterable, Identifiable {
        case overview, conversation, checks, files
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum Compose { case comment, requestChanges }

    @State private var section: Section
    @State private var draft = ""
    @State private var composing: Compose?
    @State private var confirmMerge: PullRequestBoard.MergeMethod?
    @State private var confirmClose = false
    @State private var showAllPassed = false
    @FocusState private var composerFocused: Bool

    init(model: GitHubBoardModel, controller: TerminalWindowController, pr: OpenPullRequest, stack: PullRequestBoard.Stack?,
         section: Section = .overview) {
        self.model = model
        self.controller = controller
        self.pr = pr
        self.stack = stack
        _section = State(initialValue: section)
    }

    private var detail: PullRequestDetail? { model.details[pr.number] }
    private var busy: String? { model.busy[pr.number] }
    private var creating: Bool { model.creatingWorktree.contains(pr.number) }
    private var actions: PRActions { PRActions(model: model, controller: controller) }
    private var column: PullRequestBoard.Column { PullRequestBoard.column(for: pr) }

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            tabBar
            Divider().opacity(0.6)
            Group {
                switch section {
                case .overview: overview(p)
                case .conversation: conversation(p)
                case .checks: checks
                case .files: files(p)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Divider().opacity(0.6)
            bottomBar
        }
        // A shade off the board, like the design's #1f1f22 on #1b1b1d.
        .background(p.background.mix(with: p.foreground, by: p.isDark ? 0.02 : 0.015))
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
                case .comment, .approve, .requestChanges:
                    draft = ""
                    composing = nil
                default: break
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(pr.number)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Pill(column.title, color: GitHubBoardView.color(column))
                if creating || busy != nil {
                    SpinnerRing(size: 10)
                    Text(busy ?? "Creating worktree…").font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.selection = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.labeled(.plain, compact: true))
                .help("Close details (⎋)")
                .accessibilityLabel("Close details")
                .keyboardShortcut(.escape, modifiers: [])
            }
            Text(pr.title)
                .font(.system(size: 16, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                Text(pr.authorName ?? pr.author)
                Text(" wants to merge into ")
                Text(pr.base).font(.system(size: DS.Size.subtitle, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle)
                if let date = detail?.createdAt ?? pr.updatedAt {
                    Text(" · " + PullRequestBoard.shortAge(date) + " ago").help(detail?.createdAt != nil ? "Opened" : "Updated")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("\(pr.head) → \(pr.base)")
            // The full labels when the pane is wide enough; then the ↗ loses
            // its label before Review with Claude shortens to Review.
            ViewThatFits(in: .horizontal) {
                actionRow(reviewTitle: "Review with Claude")
                actionRow(reviewTitle: "Review with Claude", linkTitle: nil)
                actionRow(reviewTitle: "Review")
            }
            .disabled(creating)
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func actionRow(reviewTitle: String, linkTitle: String? = "GitHub") -> some View {
        HStack(spacing: 6) {
            checkoutButton
            Button { actions.review(pr) } label: {
                HStack(spacing: 5) { ClaudeMark(size: 11); Text(reviewTitle) }.fixedSize()
            }
            .buttonStyle(DetailButtonStyle())
            .help("Check out #\(pr.number) in a worktree and start a Claude review")
            Button { actions.openOnGitHub(pr) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    if let linkTitle { Text(linkTitle) }
                }
                .fixedSize()
            }
            .buttonStyle(DetailButtonStyle(horizontal: linkTitle == nil ? 9 : 10))
            .help("Open #\(pr.number) on github.com")
            .accessibilityLabel("Open on GitHub")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Check Out in Worktree ▾" (or "Open Worktree ▾" once checked out): the
    /// worktree actions, then the PR's state changes.
    private var checkoutButton: some View {
        let existing = model.worktree(for: pr) != nil
        return HStack(spacing: 0) {
            Button { actions.openInTerminal(pr) } label: {
                Text(existing ? "Open Worktree" : "Check Out in Worktree")
                    .font(.system(size: DS.Size.body, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(existing ? "Open a terminal in \(ShellQuote.path(model.plannedWorktreePath(for: pr)))"
                  : "Check out \(pr.head) into \(ShellQuote.path(model.plannedWorktreePath(for: pr))) and open a terminal there")
            Color.white.opacity(0.35).frame(width: 0.5, height: 14)
            // A menu button draws its image large and tinted, so draw the ▾
            // here and lay a see-through menu over it to take the click.
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7))
                .foregroundStyle(.white)
                .frame(width: 26, height: 28)
                .accessibilityHidden(true)
                .overlay {
            Menu {
                PRWorktreeMenuItems(pr: pr, actions: actions)
                Divider()
                if pr.isDraft {
                    Button("Mark Ready for Review") { run(.markReady) }
                } else {
                    Button("Convert to Draft") { run(.convertToDraft) }
                }
                if pr.checks == .failing { Button("Re-run Failed Checks") { run(.rerunFailedChecks) } }
                Button("Close Pull Request…") { confirmClose = true }
                Divider()
                Button("Copy Link") { PRContextMenu.copy(pr.url.absoluteString) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(0.011)
            .help("More worktree and pull request actions")
            .accessibilityLabel("More actions")
                }
        }
        .background(DS.Status.selection, in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 16) {
            ForEach(Section.allCases) { s in
                Button { section = s } label: {
                    HStack(spacing: 4) {
                        Text(s.title)
                        if let n = count(s) { Text("\(n)").monospacedDigit() }
                    }
                    .font(.system(size: DS.Size.body, weight: section == s ? .medium : .regular))
                    .foregroundStyle(section == s ? Color.primary : Color.secondary)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(section == s ? DS.Status.selection : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == s ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
    }

    private func count(_ s: Section) -> Int? {
        switch s {
        case .overview: nil
        case .conversation: detail?.events.count
        case .checks: detail.map { max($0.jobs.count, $0.checks.count) } ?? (pr.checksTotal > 0 ? pr.checksTotal : nil)
        case .files: model.diffs[pr.number]?.count ?? detail?.changedFiles
        }
    }

    // MARK: Overview

    private func overview(_ p: ClaudePalette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if pr.isDraft {
                    HStack(spacing: 8) {
                        Text("This pull request is still a draft.").font(.system(size: DS.Size.body))
                        Spacer(minLength: 4)
                        Button("Ready for Review") { run(.markReady) }
                            .buttonStyle(.labeled(.neutral, compact: true))
                            .disabled(busy != nil)
                    }
                    .padding(10)
                    .cardSurface()
                }
                if let detail {
                    MarkdownView(text: detail.body.isEmpty ? "_No description._" : detail.body, palette: p, fontSize: DS.Size.title)
                        .textSelection(.enabled)
                    reviewers(detail)
                    checksSummary(detail)
                } else {
                    loading("Loading…")
                }
                if let stack, stack.layers.count > 1 { stackSection(stack) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func loading(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: DS.Size.body)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private func reviewers(_ detail: PullRequestDetail) -> some View {
        // You first, then everyone else in the order the API gives.
        let reviewers = detail.reviewers.filter { $0.login == model.login } + detail.reviewers.filter { $0.login != model.login }
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Reviewers")
            if reviewers.isEmpty {
                Text("No reviewers yet").font(.system(size: DS.Size.body)).foregroundStyle(.secondary)
            }
            ForEach(reviewers) { r in
                HStack(spacing: 8) {
                    AvatarCircle(login: r.login.replacingOccurrences(of: "team:", with: ""), size: 20)
                    Text(r.login == model.login ? "You" : r.login).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.reviewerState(r.state)).font(.system(size: DS.Size.subtitle)).foregroundStyle(Self.reviewerColor(r.state))
                }
                .font(.system(size: DS.Size.body))
            }
        }
    }

    private static func sortedJobs(_ jobs: [CheckJob]) -> [CheckJob] {
        func rank(_ s: CheckJob.State) -> Int {
            switch s {
            case .failed: 0
            case .running: 1
            case .queued: 2
            case .passed: 3
            case .skipped, .cancelled: 4
            }
        }
        return jobs.sorted { (rank($0.state), $0.name) < (rank($1.state), $1.name) }
    }

    /// "4 passed · 1 running".
    static func checksLine(_ jobs: [CheckJob]) -> String {
        let failed = jobs.filter { $0.state == .failed }.count
        let running = jobs.filter { $0.state == .running || $0.state == .queued }.count
        let passed = jobs.filter { $0.state == .passed }.count
        return [failed > 0 ? "\(failed) failing" : nil, passed > 0 ? "\(passed) passed" : nil, running > 0 ? "\(running) running" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func checksSummary(_ detail: PullRequestDetail) -> some View {
        let jobs = Self.sortedJobs(detail.jobs)
        let unfinished = jobs.filter { $0.state != .passed && $0.state != .skipped }
        let passed = jobs.filter { $0.state == .passed || $0.state == .skipped }
        let shownPassed = showAllPassed ? passed : Array(passed.prefix(max(0, 3 - unfinished.count)))
        let hidden = passed.count - shownPassed.count
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Checks", trailing: AnyView(HStack(spacing: 8) {
                if pr.checks == .failing { rerunButton }
                Text(Self.checksLine(jobs)).font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary)
            }))
            if jobs.isEmpty {
                Text("No checks on the latest commit.").font(.system(size: DS.Size.body)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array((unfinished + shownPassed).enumerated()), id: \.element.id) { i, job in
                        if i > 0 { Divider().opacity(0.5) }
                        CheckJobRow(job: job)
                    }
                    if hidden > 0 || (showAllPassed && passed.count > max(0, 3 - unfinished.count)) {
                        Divider().opacity(0.5)
                        Button { showAllPassed.toggle() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: showAllPassed ? "chevron.up" : "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(showAllPassed ? Color.secondary : DS.Status.done)
                                    .frame(width: 13)
                                Text(showAllPassed ? "Show fewer" : "\(hidden) more passed")
                                Spacer()
                            }
                            .font(.system(size: DS.Size.body))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .cardSurface()
            }
        }
    }

    private var rerunButton: some View {
        Button("Re-run failed") { run(.rerunFailedChecks) }
            .buttonStyle(.labeled(.neutral, compact: true))
            .disabled(busy != nil)
            .help(pr.failedRunIDs.isEmpty ? "No failed GitHub Actions runs found"
                  : "Re-run the failed jobs of \(pr.failedRunIDs.count) workflow run\(pr.failedRunIDs.count == 1 ? "" : "s")")
    }

    private func stackSection(_ stack: PullRequestBoard.Stack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Stack", trailing: AnyView(Text("into \(stack.bottom.base)")
                .font(.system(size: DS.Size.small, design: .monospaced)).foregroundStyle(.tertiary)))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(stack.layers.reversed(), id: \.pr.number) { layer in
                    let current = layer.pr.number == pr.number
                    let layerColumn = PullRequestBoard.column(for: layer.pr)
                    Button { model.selection = .init(number: layer.pr.number, stackID: stack.id) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(GitHubBoardView.color(layerColumn)).frame(width: 7, height: 7)
                            Text("#\(layer.pr.number)").font(.system(size: DS.Size.subtitle, design: .monospaced)).foregroundStyle(.secondary)
                            Text(stack.shortTitle(layer.pr)).fontWeight(current ? .medium : .regular).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(current ? "Viewing" : Self.shortState(layerColumn)).font(.system(size: DS.Size.subtitle))
                                .foregroundStyle(current ? .secondary : .tertiary)
                        }
                        .font(.system(size: DS.Size.body))
                        .padding(.leading, 8 + (stack.isBranching ? CGFloat(layer.depth) * 10 : 0)).padding(.trailing, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(current ? Color.primary.opacity(0.07) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    static func shortState(_ column: PullRequestBoard.Column) -> String {
        switch column {
        case .draft: "Draft"
        case .waitingForReview: "Waiting"
        case .hasFeedback: "Feedback"
        case .changesRequested: "Changes requested"
        case .ready: "Ready"
        }
    }

    // MARK: Conversation

    private func conversation(_ p: ClaudePalette) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let detail {
                    eventCard(author: pr.author, label: "opened", date: detail.createdAt, body: detail.body.isEmpty ? "_No description._" : detail.body,
                              accent: DS.Status.selection, url: pr.url, p)
                    ForEach(detail.events) { event in
                        eventView(event, p)
                    }
                } else {
                    loading("Loading…")
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func eventView(_ e: PullRequestDetail.Event, _ p: ClaudePalette) -> some View {
        switch e.kind {
        case .comment:
            eventCard(author: e.author, label: "commented", date: e.date, body: e.body, accent: Color.primary.opacity(0.15), url: e.url, p)
        case .review(let state):
            eventCard(author: e.author, label: Self.reviewTitle(state).lowercased(), date: e.date, body: e.body,
                      accent: Self.reviewColor(state, p), url: e.url, p)
        case .reviewComment(let path, let line):
            eventCard(author: e.author, label: "on \(path)" + (line.map { ":\($0)" } ?? ""), date: e.date, body: e.body,
                      accent: DS.Status.info.opacity(0.6), url: e.url, p)
        }
    }

    private func eventCard(author: String, label: String, date: Date?, body: String, accent: Color, url: URL?, _ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AvatarCircle(login: author, size: 16)
                Text(author).font(.system(size: DS.Size.subtitle, weight: .semibold))
                Text(label).font(.system(size: DS.Size.small)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                if let date { Text(PRBadges.relative(date)).font(.system(size: DS.Size.caption)).foregroundStyle(.secondary) }
                if let url {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 9, weight: .bold))
                        .help("Open on GitHub")
                }
            }
            if !body.isEmpty {
                MarkdownView(text: body, palette: p, fontSize: DS.Size.body)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: DS.Radius.card, bottomLeadingRadius: DS.Radius.card).fill(accent).frame(width: 3)
        }
    }

    // MARK: Checks

    private var checks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let detail {
                    let jobs = Self.sortedJobs(detail.jobs)
                    HStack(spacing: 8) {
                        Text(jobs.isEmpty ? "No checks on the latest commit." : Self.checksLine(jobs))
                            .font(.system(size: DS.Size.body)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if pr.checks == .failing { rerunButton }
                    }
                    if !jobs.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(jobs.enumerated()), id: \.element.id) { i, job in
                                if i > 0 { Divider().opacity(0.5) }
                                CheckJobRow(job: job)
                            }
                        }
                        .cardSurface()
                    }
                    if detail.mergeStateStatus != "UNKNOWN" {
                        Text("Merge state: \(detail.mergeStateStatus.lowercased().replacingOccurrences(of: "_", with: " "))")
                            .font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
                    }
                } else {
                    loading("Loading…")
                }
            }
            .padding(14)
        }
    }

    // MARK: Files

    private func files(_ p: ClaudePalette) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let files = model.diffs[pr.number] {
                    if files.isEmpty { Text("No changes.").font(.system(size: DS.Size.body)).foregroundStyle(.secondary).padding(12) }
                    ForEach(files) { file in
                        PullRequestFileDiff(file: file, palette: p, startExpanded: files.count <= 30)
                    }
                } else {
                    loading("Loading diff…")
                }
            }
            .padding(14)
        }
        .onAppear { model.loadDiff(pr.number) }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        let mine = model.isMine(pr)
        let approvedByMe = model.login.map { me in pr.reviews.contains { $0.login == me && $0.state == "APPROVED" } } ?? false
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if let composing {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(composing == .comment ? "Leave a comment (Markdown)" : "What needs to change? (Markdown)")
                            .font(.system(size: DS.Size.body)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.system(size: DS.Size.body))
                        .scrollContentBackground(.hidden)
                        .focused($composerFocused)
                        .frame(minHeight: 54, maxHeight: 130)
                }
                .padding(4)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.row).strokeBorder(Color.primary.opacity(0.1)))
            }
            HStack(spacing: 6) {
                if let composing {
                    Button("Cancel") {
                        self.composing = nil
                        draft = ""
                    }
                    .buttonStyle(.labeled(.plain))
                    Spacer(minLength: 4)
                    Button(composing == .comment ? "Comment" : "Request Changes") {
                        run(composing == .comment ? .comment(draft) : .requestChanges(draft))
                    }
                    .buttonStyle(.labeled(composing == .comment ? .primary : .destructive))
                    .disabled(empty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Submit (⌘⏎)")
                } else {
                    Button("Comment…") { compose(.comment) }
                        .buttonStyle(DetailButtonStyle(horizontal: 12))
                    // GitHub doesn't let authors approve or request changes on their own PR.
                    if !mine {
                        Button("Request changes") { compose(.requestChanges) }
                            .buttonStyle(DetailButtonStyle(horizontal: 12))
                    }
                    Spacer(minLength: 4)
                    mergeButton
                    if !mine && !approvedByMe {
                        Button("Approve") { run(.approve("")) }
                            .buttonStyle(FilledButtonStyle(color: Self.approveGreen))
                            .help("Approve #\(pr.number)")
                    }
                }
            }
        }
        .disabled(busy != nil)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func compose(_ mode: Compose) {
        composing = mode
        composerFocused = true
    }

    @ViewBuilder
    private var mergeButton: some View {
        let methods = model.mergeMethods.isEmpty ? [PullRequestBoard.MergeMethod.merge] : model.mergeMethods
        if !pr.isDraft {
            let ready = column == .ready
            if methods.count == 1 {
                Button("Merge") { confirmMerge = methods[0] }
                    .buttonStyle(ready ? AnyButtonStyle(FilledButtonStyle(color: Self.approveGreen)) : AnyButtonStyle(DetailButtonStyle(horizontal: 12)))
                    .help("\(methods[0].title)…")
            } else {
                Menu {
                    ForEach(methods) { m in Button(m.title + "…") { confirmMerge = m } }
                } label: {
                    Text("Merge").font(.system(size: DS.Size.body, weight: .medium))
                } primaryAction: {
                    confirmMerge = methods[0]
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(ready ? DS.Status.done.opacity(0.22) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .help("\(methods[0].title) (click), or pick another method")
            }
        }
    }

    /// The design's deeper green for Approve and a ready Merge (#248a3d), so
    /// white text reads on it; the system green on light themes.
    static let approveGreen = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1) : .systemGreen
    })

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

    static func reviewColor(_ state: String, _ p: ClaudePalette) -> Color { reviewerColor(state) }

    /// The reviewer list's state words: "Requested", "Commented", "Approved".
    static func reviewerState(_ state: String) -> String {
        switch state {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "DISMISSED": "Dismissed"
        case "REQUESTED": "Requested"
        default: "Commented"
        }
    }

    static func reviewerColor(_ state: String) -> Color {
        switch state {
        case "APPROVED": DS.Status.done
        case "CHANGES_REQUESTED": DS.Status.failed
        case "REQUESTED": DS.Status.info
        case "DISMISSED": .secondary
        default: DS.Status.review
        }
    }
}

/// A solid button in one color: the green Approve and Merge.
struct FilledButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DS.Size.body, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// The detail pane's neutral buttons: 28pt tall, 12.5pt regular, on a faint fill.
struct DetailButtonStyle: ButtonStyle {
    var horizontal: CGFloat = 11

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DS.Size.body))
            .foregroundStyle(.primary)
            .padding(.horizontal, horizontal)
            .frame(minHeight: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Picks a button style at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
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
