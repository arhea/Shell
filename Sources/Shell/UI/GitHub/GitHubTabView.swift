import AppKit
import SwiftUI

/// The GitHub tab: a kanban board of the repository's open pull requests,
/// with a detail pane for the selected PR (or stack). Shown in place of the
/// terminals, like the Claude dashboard.
struct GitHubTabView: View {
    let controller: TerminalWindowController
    @Bindable var workspace: Workspace

    var body: some View {
        let p = ClaudePalette.current
        Group {
            if let board = workspace.githubBoard {
                // A new identity per repository, so switching detaches the old board's polling.
                GitHubBoardView(model: board, controller: controller).id(board.repoRoot)
            } else {
                emptyState(p)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.background)
        .foregroundStyle(p.foreground)
    }

    private func emptyState(_ p: ClaudePalette) -> some View {
        let repos = controller.githubRepositories
        return VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 30)).foregroundStyle(p.dim)
            Text("No GitHub repository").font(.system(size: 15, weight: .semibold))
            Text(repos.isEmpty
                 ? "Open the GitHub tab from a pane inside a GitHub repository to see its pull requests."
                 : "Choose a repository open in this window.")
                .font(.system(size: 12)).foregroundStyle(p.dim).multilineTextAlignment(.center).frame(maxWidth: 360)
            ForEach(repos, id: \.root) { repo in
                Button(repo.remote.slug) { controller.showGitHub(repoRoot: repo.root, remote: repo.remote) }
            }
        }
        .padding(40)
    }
}

// MARK: - Board

struct GitHubBoardView: View {
    let model: GitHubBoardModel
    let controller: TerminalWindowController
    /// The title, filter, search and refresh row. With vertical tabs these
    /// live in the window's unified toolbar instead.
    var showsHeader = SettingsStore.shared.settings.tabBarStyle != .vertical

    /// The narrowest a column gets before the board scrolls sideways.
    static let columnWidth: CGFloat = 236
    static let defaultDetailWidth: CGFloat = 440
    @State private var boardWidth: CGFloat = 0
    @State private var detailWidth: CGFloat = GitHubBoardView.defaultDetailWidth
    @State private var dragBase: CGFloat?

    private var actions: PRActions { PRActions(model: model, controller: controller) }

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 12) {
                    GitHubToolbarTitle(model: model, controller: controller)
                    Spacer(minLength: 8)
                    GitHubToolbarControls(model: model)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                Divider()
            }
            subHeader
            Divider()
            notices(p)
            HStack(spacing: 0) {
                board(p)
                if let selection = model.selection, let pr = model.pullRequest(selection.number) {
                    resizeHandle
                    PullRequestDetailView(model: model, controller: controller, pr: pr, stack: model.selectedStack)
                        .frame(width: detailWidth)
                        .id(pr.number)
                }
            }
        }
        .onAppear {
            model.attach()
            model.refreshWorktrees()
        }
        .onDisappear { model.detach() }
        .onChange(of: model.pullRequests) { _, prs in
            // The selected PR merged or closed elsewhere.
            if let n = model.selection?.number, !model.isLoading, !prs.contains(where: { $0.number == n }) { model.selection = nil }
        }
        .onChange(of: model.selection) { _, selection in
            // Selecting a stack layer opens its stack, as in the design.
            if selection?.stackID != nil, let stack = model.selectedStack { model.setExpanded(stack, true) }
        }
    }

    // MARK: Sub-header

    private var subHeader: some View {
        let counts = model.layout.counts
        return HStack(spacing: 8) {
            Text(PullRequestBoard.explanation(filter: model.filter, narrowing: model.narrowing, query: model.searchText,
                                              slug: model.remote.slug))
                .font(.system(size: DS.Size.subtitle))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            NarrowingChip(title: "Review requested", count: counts.reviewRequested,
                          active: model.narrowing.contains(.reviewRequested)) { model.toggleNarrowing(.reviewRequested) }
                .help("Only pull requests waiting on your review (and their stacks)")
            NarrowingChip(title: "Assigned", count: counts.assigned,
                          active: model.narrowing.contains(.assigned)) { model.toggleNarrowing(.assigned) }
                .help("Only pull requests assigned to you (and their stacks)")
            Toggle("Collapse stacks", isOn: Binding(get: { model.collapseStacks }, set: { model.collapseStacks = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: DS.Size.subtitle))
                .help("Show each stack as one compact card until you expand it")
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    @ViewBuilder
    private func notices(_ p: ClaudePalette) -> some View {
        if let err = model.error {
            BoardNotice(text: err, icon: "exclamationmark.triangle.fill", color: DS.Status.needsYou, palette: p, dismiss: nil)
        }
        if let msg = model.message {
            BoardNotice(text: msg.text, icon: msg.isError ? "xmark.octagon.fill" : "checkmark.circle.fill",
                        color: msg.isError ? DS.Status.failed : DS.Status.done, palette: p, dismiss: { model.message = nil })
        }
    }

    // MARK: Columns

    private func board(_ p: ClaudePalette) -> some View {
        let columns = model.layout.columns
        let count = CGFloat(PullRequestBoard.Column.allCases.count)
        // Columns share the width, scrolling sideways once they'd get narrower than the minimum.
        let width = max(Self.columnWidth, (boardWidth - 28 - 12 * (count - 1)) / count)
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(PullRequestBoard.Column.allCases) { column in
                    columnView(column, stacks: columns[column] ?? [], width: width, p)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boardWidth = $0 }
    }

    private func columnView(_ column: PullRequestBoard.Column, stacks: [PullRequestBoard.Stack], width: CGFloat, _ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Self.color(column)).frame(width: 7, height: 7)
                Text(column.title).font(.system(size: DS.Size.body, weight: .semibold))
                Text("\(stacks.count)").font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(stacks) { stack in
                        if stack.layers.count > 1 {
                            StackCard(stack: stack, model: model, palette: p, actions: actions)
                        } else {
                            PullRequestCard(pr: stack.bottom, model: model, palette: p, actions: actions,
                                            tabMatch: tabMatch(for: stack.bottom))
                        }
                    }
                    if stacks.isEmpty {
                        Text(model.lastUpdated == nil && model.error == nil ? "Loading…" : "None")
                            .font(.system(size: DS.Size.small)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4).padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// A tab in this window on the PR's branch: "Open in Tab 3 with Claude".
    private func tabMatch(for pr: OpenPullRequest) -> BoardTabMatch? {
        for (i, tab) in controller.workspace.tabs.enumerated() {
            let sessions = tab.orderedSessions
            guard let session = sessions.first(where: {
                ($0.nativeClaude?.repository?.status.branch ?? $0.gitBranch) == pr.head
            }) else { continue }
            let claude = session.nativeClaude != nil || session.agent != nil
            return BoardTabMatch(index: i + 1, withClaude: claude) { [controller] in controller.reveal(session) }
        }
        return nil
    }

    private var resizeHandle: some View {
        Divider()
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()).onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { g in
                if dragBase == nil { dragBase = detailWidth }
                detailWidth = min(max((dragBase ?? Self.defaultDetailWidth) - g.translation.width, 360), 900)
            }.onEnded { _ in dragBase = nil }))
    }

    /// Column (and state dot) colors: gray draft, blue waiting, purple
    /// feedback, red changes requested, green ready.
    static func color(_ column: PullRequestBoard.Column) -> Color {
        switch column {
        case .draft: Color.secondary
        case .waitingForReview: DS.Status.info
        case .hasFeedback: DS.Status.review
        case .changesRequested: DS.Status.failed
        case .ready: DS.Status.done
        }
    }

    static func color(_ column: PullRequestBoard.Column, _ p: ClaudePalette) -> Color { color(column) }
}

/// "Review requested 3": a narrowing toggle, blue while on.
struct NarrowingChip: View {
    let title: String
    let count: Int
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").monospacedDigit().opacity(0.8)
            }
            .font(.system(size: DS.Size.subtitle, weight: .medium))
            .foregroundStyle(active ? DS.Status.info : .primary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(active ? DS.Status.info.opacity(0.16) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A tab already on a PR's branch, for the card's "Open in Tab 3" link.
struct BoardTabMatch {
    var index: Int
    var withClaude: Bool
    var open: () -> Void
}

struct BoardNotice: View {
    let text: String
    let icon: String
    let color: Color
    let palette: ClaudePalette
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: DS.Size.subtitle)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: DS.Radius.row).fill(color.opacity(0.1)))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - Actions

/// What a card's hover row, its Worktree menu and the detail pane do with a
/// PR: check it out into a worktree (or reuse one), open a terminal or Claude
/// there, and the GitHub links.
@MainActor
struct PRActions {
    let model: GitHubBoardModel
    let controller: TerminalWindowController

    /// A terminal in the PR's worktree (checking it out first if needed).
    func openInTerminal(_ pr: OpenPullRequest) {
        Task {
            guard let path = await model.ensureWorktree(for: pr) else { return }
            controller.switchToDirectory(path)
        }
    }

    /// A new tab in the PR's worktree running the default agent, with `prompt` when given.
    func startClaude(_ pr: OpenPullRequest, name: String? = nil, prompt: String? = nil) {
        Task {
            guard let path = await model.ensureWorktree(for: pr) else { return }
            let tab = controller.newTab(directory: path)
            tab.focusedSession?.pendingCommand = Self.command(name: name ?? pr.head, prompt: prompt)
        }
    }

    func review(_ pr: OpenPullRequest) {
        startClaude(pr, name: "Review #\(pr.number)", prompt: PullRequestBoard.reviewPrompt(pr))
    }

    func fixFeedback(_ pr: OpenPullRequest) {
        startClaude(pr, name: "Fix #\(pr.number)", prompt: PullRequestBoard.fixFeedbackPrompt(pr, slug: model.remote.slug))
    }

    func openOnGitHub(_ pr: OpenPullRequest) { NSWorkspace.shared.open(pr.url) }

    func copyBranch(_ pr: OpenPullRequest) { PRContextMenu.copy(pr.head) }

    /// `claude -n <name> [--permission-mode …] ['<prompt>']`.
    static func command(name: String, prompt: String?) -> String {
        let s = SettingsStore.shared.settings
        var cmd = s.defaultAgent.command(name: name, permissionMode: s.claudePermissionMode)
        if let prompt, !prompt.isEmpty { cmd += " " + ShellQuote.quote(prompt) }
        return cmd
    }
}

/// The Worktree menu: where the checkout goes, then Terminal, Claude and
/// GitHub. Shared by the card's hover row and the detail pane.
struct PRWorktreeMenuItems: View {
    let pr: OpenPullRequest
    let actions: PRActions

    var body: some View {
        let existing = actions.model.worktree(for: pr) != nil
        Section(existing ? "Checked out in a worktree" : "Check out into a new worktree") {
            Text(ShellQuote.path(actions.model.plannedWorktreePath(for: pr)))
        }
        Button { actions.openInTerminal(pr) } label: { Label("Open in Terminal", systemImage: "apple.terminal") }
        Button { actions.startClaude(pr) } label: { Label("Start Claude There", systemImage: "sparkle") }
        Button { actions.review(pr) } label: { Label("Start Claude Review…", systemImage: "sparkle.magnifyingglass") }
        Divider()
        Button { actions.openOnGitHub(pr) } label: { Label("Open on github.com", systemImage: "arrow.up.right") }
        Button { actions.copyBranch(pr) } label: { Label("Copy Branch Name", systemImage: "doc.on.doc") }
    }
}

// MARK: - Cards

/// Initials in a small circle, for authors and reviewers.
struct AvatarCircle: View {
    let login: String
    var name: String?
    var size: CGFloat = 18

    var body: some View {
        Text(PullRequestBoard.initials(login: login, name: name))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(0.14)))
            .help(name.map { "\($0) (\(login))" } ?? login)
            .accessibilityLabel(login)
    }
}

/// "✓ 6/6", "✕ 1 failing", a spinner with "4/6", or "No checks".
struct CardChecksLabel: View {
    let pr: OpenPullRequest

    var body: some View {
        HStack(spacing: 3) {
            switch pr.checks {
            case .passing:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                if pr.checksTotal > 0 { Text("\(pr.checksPassing)/\(pr.checksTotal)") }
            case .failing:
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                Text("\(max(pr.checksFailing, 1)) failing")
            case .pending:
                SpinnerRing(size: 9)
                Text(pr.checksTotal > 0 ? "\(pr.checksPassing)/\(pr.checksTotal)" : "running")
            case .none:
                Text("No checks")
            }
        }
        .foregroundStyle(Self.color(pr.checks))
        .monospacedDigit()
        .help(pr.checksSummary)
    }

    static func color(_ checks: OpenPullRequest.Checks) -> Color {
        switch checks {
        case .passing: DS.Status.done
        case .failing: DS.Status.failed
        case .pending: DS.Status.working
        case .none: .secondary
        }
    }
}

/// Why the PR is on your board: "Review requested" (blue) or "Assigned" (gray).
struct ReasonPill: View {
    let reasons: PullRequestBoard.Reasons

    var body: some View {
        if reasons.contains(.reviewRequested) {
            Pill("Review requested", color: DS.Status.info)
        } else if reasons.contains(.assigned) {
            Pill("Assigned", color: .primary)
        }
    }
}

/// The card surface: opaque (so a stack's layered edge doesn't show
/// through), raised on hover, outlined in the accent when selected.
private struct CardChrome: ViewModifier {
    let palette: ClaudePalette
    let hovered: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(hovered || selected ? palette.raised : palette.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(selected ? DS.Status.selection : Color.primary.opacity(0.09), lineWidth: selected ? 1.5 : 0.5))
    }
}

struct PullRequestCard: View {
    let pr: OpenPullRequest
    let model: GitHubBoardModel
    let palette: ClaudePalette
    var actions: PRActions?
    var tabMatch: BoardTabMatch?
    @State private var hovered = false

    var body: some View {
        let selected = model.selection?.number == pr.number && model.selection?.stackID == nil
        let column = PullRequestBoard.column(for: pr)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("#\(pr.number)").font(.system(size: DS.Size.small)).foregroundStyle(.secondary).monospacedDigit()
                ReasonPill(reasons: model.reasons(pr))
                Spacer(minLength: 4)
                AvatarCircle(login: pr.author, name: pr.authorName)
            }
            Text(pr.title)
                .font(.system(size: DS.Size.title, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(pr.head).lineLimit(1).truncationMode(.middle)
                if model.worktree(for: pr) != nil {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9)).foregroundStyle(DS.Status.done)
                        .help("Checked out in a worktree")
                }
            }
            .font(.system(size: DS.Size.small, design: .monospaced))
            .foregroundStyle(.secondary)
            footer(column)
            if column == .changesRequested { changesRequested }
            if let tabMatch {
                Button(action: tabMatch.open) {
                    HStack(spacing: 5) {
                        Circle().fill(tabMatch.withClaude ? DS.claude : DS.Status.done).frame(width: 6, height: 6)
                        Text("Open in Tab \(tabMatch.index)" + (tabMatch.withClaude ? " with Claude" : ""))
                    }
                    .font(.system(size: DS.Size.small))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the tab on \(pr.head)")
            }
            if let busy = model.busy[pr.number] ?? (model.creatingWorktree.contains(pr.number) ? "Creating worktree…" : nil) {
                HStack(spacing: 5) {
                    SpinnerRing(size: 9)
                    Text(busy).font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
                }
            }
            if let actions, hovered || selected {
                CardActionRow(pr: pr, actions: actions)
            }
        }
        .modifier(CardChrome(palette: palette, hovered: hovered, selected: selected))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.selection = selected ? nil : .init(number: pr.number) }
        .contextMenu { PRContextMenu(pr: pr, model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("#\(pr.number) \(pr.title), \(column.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selection = .init(number: pr.number) }
    }

    private func footer(_ column: PullRequestBoard.Column) -> some View {
        HStack(spacing: 8) {
            CardChecksLabel(pr: pr)
            Text("+\(PullRequestBoard.compact(pr.additions)) −\(PullRequestBoard.compact(pr.deletions))")
                .font(.system(size: DS.Size.small, design: .monospaced))
                .foregroundStyle(.secondary)
            if pr.reviewDecision == "APPROVED" {
                Text("Approved").foregroundStyle(DS.Status.done)
            }
            if pr.unresolvedThreads > 0 {
                Text(column == .hasFeedback ? "\(pr.unresolvedThreads) open thread\(pr.unresolvedThreads == 1 ? "" : "s")"
                     : "\(pr.unresolvedThreads) thread\(pr.unresolvedThreads == 1 ? "" : "s")")
                    .foregroundStyle(column == .hasFeedback ? DS.Status.review : .secondary)
            }
            Spacer(minLength: 2)
            if let updated = pr.updatedAt {
                Text(PullRequestBoard.shortAge(updated)).foregroundStyle(.secondary).help("Updated \(PRBadges.relative(updated))")
            }
        }
        .font(.system(size: DS.Size.small))
        .lineLimit(1)
    }

    private var changesRequested: some View {
        let who = PullRequestBoard.changesRequestedBy(pr)
        return HStack(spacing: 6) {
            Text((who.first.map { PullRequestBoard.initials(login: $0) + " " } ?? "") + "requested changes").lineLimit(1)
                .foregroundStyle(DS.Status.failed)
                .help(who.isEmpty ? "Changes requested" : "Requested by " + who.joined(separator: ", "))
            Spacer(minLength: 4)
            if let actions {
                Button { actions.fixFeedback(pr) } label: {
                    HStack(spacing: 3) { ClaudeMark(size: 9); Text("Fix with Claude") }.foregroundStyle(DS.claude).fixedSize()
                }
                .buttonStyle(.plain)
                .help("Check out #\(pr.number) and start Claude on the review feedback")
            }
        }
        .font(.system(size: DS.Size.small, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(DS.Status.failed.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}

/// "✻ Review", "Worktree ▾", "↗": a card's actions, shown on hover.
struct CardActionRow: View {
    let pr: OpenPullRequest
    let actions: PRActions

    var body: some View {
        HStack(spacing: 6) {
            Button { actions.review(pr) } label: {
                HStack(spacing: 4) { ClaudeMark(size: 10); Text("Review") }
            }
            .buttonStyle(.labeled(.neutral, compact: true))
            .help("Check out #\(pr.number) in a worktree and start a Claude review")
            Menu { PRWorktreeMenuItems(pr: pr, actions: actions) } label: {
                Text("Worktree").font(.system(size: DS.Size.small, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .help("Check out the branch into a worktree, then open a terminal or Claude there")
            Button { actions.openOnGitHub(pr) } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.labeled(.neutral, compact: true))
            .help("Open #\(pr.number) on github.com")
            .accessibilityLabel("Open on GitHub")
            Spacer(minLength: 0)
        }
    }
}

/// Several stacked PRs as one card. Collapsed: one line per layer. Expanded:
/// a connected list of layers ending in the base branch.
struct StackCard: View {
    let stack: PullRequestBoard.Stack
    let model: GitHubBoardModel
    let palette: ClaudePalette
    var actions: PRActions?
    @State private var hovered = false

    var body: some View {
        let selectedLayer = model.selection?.stackID != nil ? model.selection?.number : nil
        let selected = selectedLayer.map { n in stack.pullRequests.contains { $0.number == n } } ?? false
        let expanded = model.isExpanded(stack)
        VStack(alignment: .leading, spacing: 7) {
            if expanded {
                expandedBody(selectedLayer: selected ? selectedLayer : nil)
            } else {
                collapsedBody
            }
        }
        .modifier(CardChrome(palette: palette, hovered: hovered, selected: selected && !expanded))
        .background(alignment: .bottom) {
            if !expanded {
                // The layered edge: two cards peeking out below.
                ZStack(alignment: .bottom) {
                    edge(inset: 10, drop: 6)
                    edge(inset: 5, drop: 3)
                }
            }
        }
        .padding(.bottom, expanded ? 0 : 6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            model.selection = .init(number: stack.top.number, stackID: stack.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stack of \(stack.layers.count) pull requests: \(stack.name)")
    }

    private func edge(inset: CGFloat, drop: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.card)
            .fill(palette.surface)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            .frame(height: 30)
            .padding(.horizontal, inset)
            .offset(y: drop)
    }

    private var stackPill: some View { Pill("Stack of \(stack.layers.count)", color: .primary) }

    private var collapsedBody: some View {
        let toReview = stack.toReview(login: model.login)
        return Group {
            HStack(spacing: 6) {
                stackPill
                if toReview > 0 { Pill("\(toReview) to review", color: DS.Status.info) }
                Spacer(minLength: 4)
                AvatarCircle(login: stack.top.author, name: stack.top.authorName)
            }
            Text(stack.name)
                .font(.system(size: DS.Size.title, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(stack.layers.reversed(), id: \.pr.number) { layer in
                    Button { select(layer.pr) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(GitHubBoardView.color(PullRequestBoard.column(for: layer.pr))).frame(width: 6, height: 6)
                            Text("#\(layer.pr.number)").foregroundStyle(.secondary).monospacedDigit()
                            Text(stack.shortTitle(layer.pr)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: DS.Size.subtitle))
                        .padding(.leading, CGFloat(layer.depth) * 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("#\(layer.pr.number) \(layer.pr.title) — \(PullRequestBoard.column(for: layer.pr).title)")
                }
            }
            HStack(spacing: 8) {
                stackChecks
                Text("+\(PullRequestBoard.compact(stack.additions)) −\(PullRequestBoard.compact(stack.deletions))")
                    .font(.system(size: DS.Size.small, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Button { model.setExpanded(stack, true) } label: {
                    HStack(spacing: 2) { Text("Expand"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Status.info)
            }
            .font(.system(size: DS.Size.small))
            .lineLimit(1)
        }
    }

    @ViewBuilder private var stackChecks: some View {
        if stack.failingLayers > 0 {
            HStack(spacing: 3) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                Text("\(stack.failingLayers) failing")
            }
            .foregroundStyle(DS.Status.failed)
        } else if stack.pendingLayers > 0 {
            HStack(spacing: 3) { SpinnerRing(size: 9); Text("\(stack.pendingLayers) running") }
                .foregroundStyle(DS.Status.working)
        } else if stack.pullRequests.allSatisfy({ $0.checks == .none }) {
            Text("No checks").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("passing")
            }
            .foregroundStyle(DS.Status.done)
        }
    }

    private func expandedBody(selectedLayer: Int?) -> some View {
        Group {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stackPill
                Text(stack.name).font(.system(size: DS.Size.title, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Button { model.setExpanded(stack, false) } label: {
                    HStack(spacing: 2) { Text("Collapse"); Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)) }
                }
                .buttonStyle(.plain)
                .font(.system(size: DS.Size.small))
                .foregroundStyle(DS.Status.info)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(stack.layers.reversed(), id: \.pr.number) { layer in
                    StackLayerRow(layer: layer, model: model, palette: palette, stackID: stack.id,
                                  selected: selectedLayer == layer.pr.number, title: stack.shortTitle(layer.pr))
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9))
                    Text(stack.bottom.base)
                }
                .font(.system(size: DS.Size.small, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.top, 4)
                .help("The stack merges into \(stack.bottom.base)")
            }
        }
    }

    private func select(_ pr: OpenPullRequest) {
        model.selection = .init(number: pr.number, stackID: stack.id)
        model.setExpanded(stack, true)
    }
}

/// One layer in an expanded stack: a state dot on the connector line, the
/// number and title, then its state and checks. The selected layer fills blue.
struct StackLayerRow: View {
    let layer: PullRequestBoard.Stack.Layer
    let model: GitHubBoardModel
    let palette: ClaudePalette
    let stackID: Int
    let selected: Bool
    var title: String?

    var body: some View {
        let column = PullRequestBoard.column(for: layer.pr)
        let pr = layer.pr
        Button { model.selection = .init(number: pr.number, stackID: stackID) } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 2) {
                    Circle().fill(selected ? Color.white : GitHubBoardView.color(column)).frame(width: 7, height: 7).padding(.top, 4)
                    Rectangle().fill((selected ? Color.white : Color.primary).opacity(0.25)).frame(width: 1.5).frame(maxHeight: .infinity)
                }
                .frame(width: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("#\(pr.number)").monospacedDigit()
                        Text(title ?? pr.title).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: DS.Size.subtitle, weight: .semibold))
                    HStack(spacing: 4) {
                        Text(column.title)
                        Text("·")
                        LayerChecks(pr: pr, inverted: selected)
                    }
                    .font(.system(size: DS.Size.caption))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.leading, 6 + CGFloat(layer.depth) * 10)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(selected ? DS.Status.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("#\(pr.number) \(pr.title), \(column.title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A layer's checks in words: "checks running", "✓ 6/6", "1 failing", "no checks yet".
struct LayerChecks: View {
    let pr: OpenPullRequest
    var inverted = false

    var body: some View {
        switch pr.checks {
        case .none: Text("no checks yet")
        case .pending:
            HStack(spacing: 3) {
                SpinnerRing(color: inverted ? .white : DS.Status.working, size: 8)
                Text("checks running")
            }
        case .passing, .failing:
            CardChecksLabel(pr: pr).foregroundStyle(inverted ? Color.white : CardChecksLabel.color(pr.checks))
        }
    }
}

/// Draft, checks, review and label badges.
struct PRBadges: View {
    let pr: OpenPullRequest
    let palette: ClaudePalette

    var body: some View {
        let p = palette
        FlowBadges {
            if pr.isDraft { Self.badge("draft", p.dim) }
            switch pr.checks {
            case .passing: Self.badge("✓ checks", p.green).help(pr.checksSummary)
            case .failing: Self.badge("✗ checks", p.red).help(pr.checksSummary)
            case .pending: Self.badge("● checks", p.yellow).help(pr.checksSummary)
            case .none: EmptyView()
            }
            switch pr.reviewDecision {
            case "APPROVED": Self.badge("approved", p.green)
            case "CHANGES_REQUESTED": Self.badge("changes requested", p.red)
            case "REVIEW_REQUIRED": Self.badge("needs review", p.dim)
            default: EmptyView()
            }
            if pr.unresolvedThreads > 0 { Self.badge("\(pr.unresolvedThreads) unresolved", p.blue) }
            ForEach(pr.labels.prefix(3), id: \.name) { l in
                Self.badge(l.name, RGB(hex: l.color).map { Color(nsColor: $0.nsColor) } ?? p.dim)
            }
        }
    }

    static func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    @ViewBuilder
    static func checksIcon(_ pr: OpenPullRequest, _ p: ClaudePalette) -> some View {
        switch pr.checks {
        case .passing: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(p.green).help(pr.checksSummary)
        case .failing: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(p.red).help(pr.checksSummary)
        case .pending: Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(p.yellow).help(pr.checksSummary)
        case .none: EmptyView()
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Badges that wrap onto more lines instead of overflowing the card.
struct FlowBadges<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: 4) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (i, origin) in rows.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, maxX, subviews.isEmpty ? 0 : y + rowHeight)
    }
}

struct PRContextMenu: View {
    let pr: OpenPullRequest
    let model: GitHubBoardModel

    var body: some View {
        Button("Open on GitHub") { NSWorkspace.shared.open(pr.url) }
        Button("Copy Link") { Self.copy(pr.url.absoluteString) }
        Button("Copy Branch Name") { Self.copy(pr.head) }
        Button("Copy `gh pr checkout \(pr.number)`") { Self.copy("gh pr checkout \(pr.number)") }
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Tab bar entries

/// The GitHub tab's chip in the horizontal tab bar.
struct GitHubTabChip: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let palette: ChromePalette
    @State private var hovering = false

    var body: some View {
        let selected = workspace.showsGitHub
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? palette.accent : palette.secondary)
            Text("GitHub")
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? palette.foreground : palette.secondary)
            if hovering || selected {
                Button { controller.closeGitHub() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
                .help("Close the GitHub tab")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? palette.selected : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.toggleGitHub() }
        .help("GitHub (\(ShortcutAction.github.shortcut?.displayString ?? "⌃⌘H"))" + (workspace.githubBoard.map { " — \($0.remote.slug)" } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GitHub pull requests")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { controller.toggleGitHub() }
    }
}

/// The GitHub tab's row in the vertical tab sidebar.
struct GitHubSidebarRow: View {
    let controller: TerminalWindowController
    let workspace: Workspace
    let palette: ChromePalette
    @State private var hovering = false

    var body: some View {
        let selected = workspace.showsGitHub
        let board = workspace.githubBoard
        let counts = board.map { Self.counts($0.pullRequests, login: $0.login) }
        HStack(spacing: 10) {
            KindTile(kind: .github)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pull Requests")
                    .font(.system(size: DS.Size.title, weight: .medium))
                    .lineLimit(1)
                Text(board.map { "\($0.remote.slug) · \(counts?.forYou ?? 0) for you" } ?? "GitHub")
                    .font(.system(size: DS.Size.subtitle))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button { controller.closeGitHub() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close the GitHub tab")
            } else if let review = counts?.toReview, review > 0 {
                Pill("\(review) to review", color: DS.Status.info)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .rowBackground(selected: selected, hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.toggleGitHub() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pull requests" + ((counts?.toReview ?? 0) > 0 ? ", \(counts?.toReview ?? 0) to review" : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { controller.toggleGitHub() }
    }

    /// PRs waiting on the viewer's review, and those that are theirs or wait
    /// on them ("for you"). Zero until the viewer's login is known.
    static func counts(_ prs: [OpenPullRequest], login: String?) -> (toReview: Int, forYou: Int) {
        // Same definition as the board's For you filter.
        guard login != nil else { return (0, 0) }
        let c = PullRequestBoard.counts(prs, login: login)
        return (c.reviewRequested, c.forYou)
    }
}
