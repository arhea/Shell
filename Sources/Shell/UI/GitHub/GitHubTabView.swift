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

    /// The narrowest a column gets before the board scrolls sideways.
    static let columnWidth: CGFloat = 240
    @State private var boardWidth: CGFloat = 0
    @State private var detailWidth: CGFloat = 520
    @State private var dragBase: CGFloat?

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            header(p)
            p.border.frame(height: 1)
            notices(p)
            HStack(spacing: 0) {
                board(p)
                if let selection = model.selection, let pr = model.pullRequest(selection.number) {
                    resizeHandle(p)
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
    }

    // MARK: Header

    private func header(_ p: ClaudePalette) -> some View {
        HStack(spacing: 10) {
            Link(destination: model.remote.url.appendingPathComponent("pulls")) {
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox").foregroundStyle(p.cyan)
                    Text(model.remote.slug).font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold)).foregroundStyle(p.dim)
                }
            }
            .foregroundStyle(p.foreground)
            .help("Open pull requests on GitHub")
            let repos = controller.githubRepositories.filter { $0.root != model.repoRoot }
            if !repos.isEmpty {
                Menu {
                    ForEach(repos, id: \.root) { repo in
                        Button(repo.remote.slug) { controller.showGitHub(repoRoot: repo.root, remote: repo.remote) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Show another repository open in this window")
            }
            Text("\(model.pullRequests.count) open").font(.system(size: 11)).foregroundStyle(p.dim)
            Spacer()
            Picker("", selection: Binding(get: { model.filter }, set: { model.filter = $0 })) {
                Text("Mine").tag(PullRequestBoard.Filter.mine)
                Text("All").tag(PullRequestBoard.Filter.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Show your pull requests (and the stacks they're in), or everyone's")
            if model.isLoading { ProgressView().controlSize(.mini) }
            if let updated = model.lastUpdated {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(ActionsView.ago(updated)).font(.system(size: 10)).foregroundStyle(p.dim)
                }
                .help("Refreshes every 2 minutes while this tab is showing")
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(HeaderButtonStyle(palette: p, active: false))
                .help("Refresh")
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    @ViewBuilder
    private func notices(_ p: ClaudePalette) -> some View {
        if let err = model.error {
            BoardNotice(text: err, icon: "exclamationmark.triangle.fill", color: p.yellow, palette: p, dismiss: nil)
        }
        if let msg = model.message {
            BoardNotice(text: msg.text, icon: msg.isError ? "xmark.octagon.fill" : "checkmark.circle.fill",
                        color: msg.isError ? p.red : p.green, palette: p, dismiss: { model.message = nil })
        }
    }

    // MARK: Columns

    private func board(_ p: ClaudePalette) -> some View {
        let columns = model.columns
        let count = CGFloat(PullRequestBoard.Column.allCases.count)
        // Columns share the width, scrolling sideways once they'd get narrower than the minimum.
        let width = max(Self.columnWidth, (boardWidth - 24 - 10 * (count - 1)) / count)
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(PullRequestBoard.Column.allCases) { column in
                    columnView(column, stacks: columns[column] ?? [], width: width, p)
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boardWidth = $0 }
    }

    private func columnView(_ column: PullRequestBoard.Column, stacks: [PullRequestBoard.Stack], width: CGFloat, _ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Self.color(column, p)).frame(width: 8, height: 8)
                Text(column.title).font(.system(size: 12, weight: .semibold))
                Text("\(stacks.reduce(0) { $0 + $1.layers.count })").font(.system(size: 11)).foregroundStyle(p.dim).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(stacks) { stack in
                        if stack.layers.count > 1 {
                            StackCard(stack: stack, model: model, palette: p)
                        } else {
                            PullRequestCard(pr: stack.bottom, model: model, palette: p)
                        }
                    }
                    if stacks.isEmpty {
                        Text(model.lastUpdated == nil && model.error == nil ? "Loading…" : "None")
                            .font(.system(size: 11)).foregroundStyle(p.dim).padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border.opacity(0.7), lineWidth: 0.5))
    }

    private func resizeHandle(_ p: ClaudePalette) -> some View {
        p.border.frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()).onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { g in
                if dragBase == nil { dragBase = detailWidth }
                detailWidth = min(max((dragBase ?? 520) - g.translation.width, 360), 900)
            }.onEnded { _ in dragBase = nil }))
    }

    static func color(_ column: PullRequestBoard.Column, _ p: ClaudePalette) -> Color {
        switch column {
        case .draft: p.dim
        case .waitingForReview: p.yellow
        case .hasFeedback: p.blue
        case .changesRequested: p.red
        case .ready: p.green
        }
    }
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
            Text(text).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(palette.dim) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.1)))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

// MARK: - Cards

struct PullRequestCard: View {
    let pr: OpenPullRequest
    let model: GitHubBoardModel
    let palette: ClaudePalette
    @State private var hovered = false

    var body: some View {
        let p = palette
        let selected = model.selection?.number == pr.number && model.selection?.stackID == nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(pr.number)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(pr.isDraft ? p.dim : p.green)
                Text(pr.title).font(.system(size: 12, weight: .medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(pr.author + (pr.authorIsBot ? " (bot)" : "")).foregroundStyle(model.isMine(pr) ? p.claude : p.foreground.opacity(0.8))
                if let updated = pr.updatedAt { Text(PRBadges.relative(updated)) }
                Spacer(minLength: 2)
                Text("+\(pr.additions)").foregroundStyle(p.green).monospacedDigit()
                Text("−\(pr.deletions)").foregroundStyle(p.red).monospacedDigit()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(p.dim)
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundStyle(p.magenta)
                Text(pr.head).lineLimit(1).truncationMode(.middle)
                if model.worktree(for: pr) != nil {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9)).foregroundStyle(p.green)
                        .help("Checked out in a worktree")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(p.foreground.opacity(0.85))
            PRBadges(pr: pr, palette: p)
            if let busy = model.busy[pr.number] {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(.system(size: 10.5)).foregroundStyle(p.dim)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? p.raised : hovered ? p.raised.opacity(0.7) : p.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? p.accent : p.border, lineWidth: selected ? 1.5 : 0.5))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.selection = selected ? nil : .init(number: pr.number) }
        .contextMenu { PRContextMenu(pr: pr, model: model) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the pull request's details")
    }
}

/// Several stacked PRs as one card: each layer, bottom first, with its state.
struct StackCard: View {
    let stack: PullRequestBoard.Stack
    let model: GitHubBoardModel
    let palette: ClaudePalette
    @State private var hovered = false

    var body: some View {
        let p = palette
        let selected = model.selection?.stackID != nil && stack.pullRequests.contains { $0.number == model.selection?.stackID }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(p.accent)
                Text("Stack of \(stack.layers.count)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(stack.bottom.base).font(.system(size: 10)).foregroundStyle(p.dim).lineLimit(1).truncationMode(.middle)
                    .help("The stack merges into \(stack.bottom.base)")
            }
            ForEach(Array(stack.layers.enumerated().reversed()), id: \.element.pr.number) { _, layer in
                StackLayerRow(layer: layer, model: model, palette: p, stackID: stack.id, selected: selected && model.selection?.number == layer.pr.number)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? p.raised : hovered ? p.raised.opacity(0.7) : p.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? p.accent : p.accent.opacity(0.35), lineWidth: selected ? 1.5 : 0.75))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.selection = .init(number: stack.bottom.number, stackID: stack.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stack of \(stack.layers.count) pull requests")
    }
}

/// One layer in a stack (card or detail pane): state dot, number, title.
struct StackLayerRow: View {
    let layer: PullRequestBoard.Stack.Layer
    let model: GitHubBoardModel
    let palette: ClaudePalette
    let stackID: Int
    let selected: Bool

    var body: some View {
        let p = palette
        let column = PullRequestBoard.column(for: layer.pr)
        Button { model.selection = .init(number: layer.pr.number, stackID: stackID) } label: {
            HStack(spacing: 6) {
                Circle().fill(GitHubBoardView.color(column, p)).frame(width: 7, height: 7)
                    .help(column.title)
                Text("#\(layer.pr.number)").font(.system(size: 11, weight: .bold)).foregroundStyle(layer.pr.isDraft ? p.dim : p.green)
                Text(layer.pr.title).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                PRBadges.checksIcon(layer.pr, p)
            }
            .padding(.leading, CGFloat(layer.depth) * 12)
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? p.accent.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("#\(layer.pr.number) \(layer.pr.title), \(column.title)")
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? palette.accent : palette.secondary)
                .frame(width: 14, height: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub")
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? palette.foreground : palette.foreground.opacity(0.85))
                Text(workspace.githubBoard.map { "\($0.remote.slug) · \($0.pullRequests.count) open" } ?? "Pull requests")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button { controller.closeGitHub() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
                .help("Close the GitHub tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? palette.selected : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.toggleGitHub() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GitHub pull requests")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { controller.toggleGitHub() }
    }
}
