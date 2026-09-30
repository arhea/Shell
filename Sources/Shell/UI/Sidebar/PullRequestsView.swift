import AppKit
import SwiftUI

/// The sidebar's Pull Requests tab: open PRs for the repo, with a one-click
/// way into each one's worktree — switching to it, or creating it.
struct PullRequestsView: View {
    let model: PullRequestsModel
    let worktrees: WorktreesModel
    let context: SidebarContext
    let repoName: String

    @State private var hovered: Int?

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            header(p)
            p.border.frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if let err = model.error {
                        notice(err, icon: "exclamationmark.triangle.fill", color: p.yellow, p)
                    }
                    if let msg = model.lastMessage {
                        notice(msg, icon: "info.circle.fill", color: p.red, p, dismiss: { model.lastMessage = nil })
                    }
                    ForEach(model.filtered) { pr in
                        row(pr, p)
                    }
                    if model.filtered.isEmpty && !model.isLoading && model.error == nil {
                        Text(model.filter == .review ? "Nothing waiting on your review." : model.filter == .mine ? "You have no open pull requests." : "No open pull requests.")
                            .font(.system(size: 12)).foregroundStyle(p.dim).padding(12)
                    }
                }
                .padding(8)
            }
        }
        .onAppear {
            model.refreshIfNeeded()
            worktrees.refreshIfNeeded()
        }
        .task {
            // Keep the list fresh while it's on screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if !model.isPaused { model.refresh() }
            }
        }
    }

    private func header(_ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("\(model.pullRequests.count) open pull request\(model.pullRequests.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.mini) }
                Button { model.refresh(); worktrees.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: false))
                    .help("Refresh")
            }
            Picker("", selection: Binding(get: { model.filter }, set: { model.filter = $0 })) {
                Text("All").tag(PullRequestsModel.Filter.all)
                Text("Review (\(model.reviewRequested.count))").tag(PullRequestsModel.Filter.review)
                Text("Mine").tag(PullRequestsModel.Filter.mine)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Row

    private func worktree(for pr: OpenPullRequest) -> WorktreeInfo? {
        worktrees.worktrees.first { $0.branch == pr.head && $0.exists }
    }

    private func row(_ pr: OpenPullRequest, _ p: ClaudePalette) -> some View {
        let wt = worktree(for: pr)
        let creating = model.creating.contains(pr.number)
        let requested = model.isReviewRequested(pr)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(pr.number)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(pr.isDraft ? p.dim : p.green)
                Text(pr.title).font(.system(size: 12, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(pr.author + (pr.authorIsBot ? " (bot)" : "")).foregroundStyle(model.isMine(pr) ? p.claude : p.foreground.opacity(0.8))
                if let updated = pr.updatedAt {
                    Text(RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: Date()))
                }
                Spacer(minLength: 2)
                Text("+\(pr.additions)").foregroundStyle(p.green).monospacedDigit()
                Text("−\(pr.deletions)").foregroundStyle(p.red).monospacedDigit()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(p.dim)
            HStack(spacing: 4) {
                if pr.isDraft { badge("draft", p.dim, p) }
                checksBadge(pr, p)
                reviewBadge(pr, p)
                if requested { badge("review requested", p.yellow, p) }
                ForEach(pr.labels.prefix(2), id: \.name) { l in badge(l.name, RGB(hex: l.color).map { Color(nsColor: $0.nsColor) } ?? p.dim, p) }
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundStyle(p.magenta)
                Text(pr.head).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(p.dim)
                Text(pr.base).foregroundStyle(p.dim)
                Spacer(minLength: 2)
                if let wt {
                    Label(wt.name, systemImage: "square.stack.3d.up.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(p.green)
                        .lineLimit(1).truncationMode(.middle)
                        .help("Checked out in \(wt.path)")
                }
            }
            .font(.system(size: 10.5))
            actions(pr, worktree: wt, creating: creating, p)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovered == pr.number ? p.raised : p.background.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(requested ? p.yellow.opacity(0.5) : p.border, lineWidth: requested ? 1 : 0.5))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? pr.number : (hovered == pr.number ? nil : hovered) }
        .contextMenu { menu(pr, worktree: wt) }
    }

    private func actions(_ pr: OpenPullRequest, worktree wt: WorktreeInfo?, creating: Bool, _ p: ClaudePalette) -> some View {
        HStack(spacing: 6) {
            if creating {
                ProgressView().controlSize(.mini)
                Text("Creating worktree…").font(.system(size: 10.5)).foregroundStyle(p.dim)
            } else if let wt {
                Button { context.switchTo?(wt.path) } label: { Label("Switch", systemImage: "arrow.right.circle") }
                    .help("Go to the tab in \(wt.name), or open one")
                Button { review(pr, in: wt.path) } label: { Label("Review", systemImage: "sparkle") }
                    .help("Start Claude in \(wt.name) to review #\(pr.number)")
            } else {
                Button { create(pr, thenReview: false) } label: { Label("Worktree", systemImage: "plus.square.on.square") }
                    .help("Check out \(pr.head) in a new worktree under \(ClaudeToolFormat.shortPath(WorktreeService.worktreeRoot(environment: model.environment)))/\(repoName)")
                Button { create(pr, thenReview: true) } label: { Label("Review", systemImage: "sparkle") }
                    .help("Create a worktree for #\(pr.number) and start Claude there to review it")
            }
            Spacer()
            Button { NSWorkspace.shared.open(pr.url) } label: { Image(systemName: "arrow.up.right.square") }
                .help("Open #\(pr.number) on GitHub")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .font(.system(size: 10.5))
        .disabled(creating)
    }

    @ViewBuilder
    private func menu(_ pr: OpenPullRequest, worktree wt: WorktreeInfo?) -> some View {
        if let wt {
            Button("Switch to \(wt.name)") { context.switchTo?(wt.path) }
            Button("Review with Claude") { review(pr, in: wt.path) }
            if let openTab = context.openTab { Button("Open in New Tab") { openTab(wt.path, nil) } }
            ForEach(ExternalEditor.installed) { editor in
                Button("Open in \(editor.name)") { editor.open([URL(fileURLWithPath: wt.path)]) }
            }
        } else {
            Button("Create Worktree") { create(pr, thenReview: false) }
            Button("Create Worktree and Review with Claude") { create(pr, thenReview: true) }
        }
        Divider()
        Button("Open on GitHub") { NSWorkspace.shared.open(pr.url) }
        Button("Copy Link") { copy(pr.url.absoluteString) }
        Button("Copy Branch Name") { copy(pr.head) }
        if let insert = context.insert, !context.isClaude {
            Button("Insert `gh pr checkout \(pr.number)`") { insert("gh pr checkout \(pr.number)") }
        }
    }

    // MARK: Actions

    private func create(_ pr: OpenPullRequest, thenReview: Bool) {
        Task {
            guard let path = await model.createWorktree(for: pr, repoName: repoName) else { return }
            worktrees.refresh()
            if thenReview { review(pr, in: path) } else { context.switchTo?(path) }
        }
    }

    /// Opens a new tab in the worktree running `claude` with a review prompt.
    private func review(_ pr: OpenPullRequest, in path: String) {
        let prompt = "Review pull request #\(pr.number) (\(pr.url.absoluteString)): \(pr.title). The branch \(pr.head) is checked out here; compare it with \(pr.base), then summarize the change and flag bugs, risks and missing tests."
        context.openTab?(path, "claude " + shellQuote(prompt))
    }

    private func shellQuote(_ s: String) -> String { ShellQuote.quote(s) }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Badges

    @ViewBuilder
    private func checksBadge(_ pr: OpenPullRequest, _ p: ClaudePalette) -> some View {
        switch pr.checks {
        case .passing: badge("✓ checks", p.green, p).help(pr.checksSummary)
        case .failing: badge("✗ checks", p.red, p).help(pr.checksSummary)
        case .pending: badge("● checks", p.yellow, p).help(pr.checksSummary)
        case .none: EmptyView()
        }
    }

    @ViewBuilder
    private func reviewBadge(_ pr: OpenPullRequest, _ p: ClaudePalette) -> some View {
        switch pr.reviewDecision {
        case "APPROVED": badge("approved", p.green, p)
        case "CHANGES_REQUESTED": badge("changes requested", p.red, p)
        case "REVIEW_REQUIRED": badge("needs review", p.dim, p)
        default: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color, _ p: ClaudePalette) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func notice(_ text: String, icon: String, color: Color, _ p: ClaudePalette, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.1)))
    }
}
