import AppKit
import SwiftUI

/// What the Session tab shows besides the working tree's changes, which the
/// inspector reads from git itself. Supplied by the Claude pane.
struct InspectorSessionInputs {
    var todos: [InspectorTodo] = []
    var background: [InspectorBackgroundItem] = []
    /// Opens the review (diff) view. Hidden when nil.
    var onReview: (() -> Void)?
    /// Opens a changed file or its diff. Nil opens the file in the preferred editor.
    var onOpenFile: ((InspectorChange) -> Void)?
    var onStop: (InspectorBackgroundItem) -> Void = { _ in }
    var onViewTranscript: (InspectorBackgroundItem) -> Void = { _ in }
}

/// The window's right inspector for the focused pane's repository: Session
/// (Claude panes), Worktrees, Checks (repositories on GitHub) and Files.
/// Shown for native Claude sessions and (⌃⌘B) terminal panes.
struct RightSidebarView: View {
    let context: SidebarContext
    let repo: GitRepository
    let tree: FileTreeModel
    let worktrees: WorktreesModel
    /// The Pull Requests model once the repo's GitHub remote is known.
    let pullRequests: (GitHubRemote) -> PullRequestsModel
    let actions: (GitHubRemote) -> ActionsModel
    /// Called with the drag's total horizontal distance (positive = wider).
    var onResize: (CGFloat) -> Void
    var onResizeEnded: () -> Void
    var onClose: () -> Void
    /// The Claude session's to-dos and background work, read on each render.
    var session: (() -> InspectorSessionInputs)?
    /// Open tabs' working directories → their agent state, for Worktrees.
    var openTabs: () -> [String: WorktreeTabState] = { [:] }
    /// Check jobs Claude is already fixing (shows "Claude is fixing").
    var fixingChecks: () -> Set<String> = { [] }
    /// Fix with Claude for a failing job. Nil uses `ChecksFix.start`.
    var onFixCheck: ((CheckJob) -> Void)?
    /// "+ New" in Worktrees. Hidden when nil.
    var onNewWorktree: (() -> Void)?

    @State private var showAllRuns = false

    private var available: [InspectorTab] { InspectorTab.available(isClaude: context.isClaude, hasGitHub: repo.github != nil) }

    private var tab: InspectorTab {
        let preferred = context.isClaude ? InspectorTabMemory.shared.claudeTab : InspectorTab(SettingsStore.shared.settings.sidebarTab)
        return InspectorTab.resolve(preferred: preferred, available: available)
    }

    private var checks: BranchChecksModel? { repo.github == nil ? nil : BranchChecksModel.shared(for: repo) }

    var body: some View {
        let p = ClaudePalette.current
        HStack(spacing: 0) {
            resizeHandle(p)
            VStack(spacing: 0) {
                tabBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(p.surface)
        .foregroundStyle(p.foreground)
        // The toolbar's failing-checks capsule asks for the Checks view.
        .onReceive(NotificationCenter.default.publisher(for: BranchChecksRequest.notification)) { note in
            guard note.object == nil || (note.object as AnyObject?) === repo, available.contains(.checks) else { return }
            select(.checks)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .session:
            InspectorSessionPanel(repo: repo, context: context, inputs: session?() ?? InspectorSessionInputs())
        case .worktrees:
            WorktreesView(model: worktrees, context: context, currentPath: repo.root.path, openTabs: openTabs(),
                          checks: { [repo] wt in
                              // Only the pane's own branch has a live checks model.
                              guard WorktreeGroups.standardized(wt.path) == WorktreeGroups.standardized(repo.root.path),
                                    repo.github != nil else { return nil }
                              return BranchChecksModel.shared(for: repo).snapshot
                          },
                          onNewWorktree: onNewWorktree)
        case .checks:
            if let checks, let gh = repo.github {
                InspectorChecksView(model: checks, fixing: fixingChecks(), showsAutoFix: context.isClaude,
                                    extra: AnyView(checksExtra(gh))) { job in
                    if let onFixCheck { onFixCheck(job) } else { ChecksFix.start([job], model: checks, context: context) }
                }
            }
        case .files:
            FileExplorerView(context: context, repo: repo, tree: tree, onClose: onClose)
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        let failing = (checks?.snapshot?.failing.isEmpty == false)
        let items = available.map { t in
            SegmentedTabs<InspectorTab>.Item(
                id: t, title: t.title,
                dot: t == .checks && failing ? DS.Status.failed : t == .worktrees && !worktrees.stale.isEmpty ? DS.Status.needsYou : nil)
        }
        return HStack(spacing: 6) {
            SegmentedTabs(items: items, selection: Binding(get: { tab }, set: { select($0) }))
            Button(action: onClose) { Image(systemName: "sidebar.right") }
                .buttonStyle(.labeled(.plain, compact: true))
                .help(context.isClaude ? "Hide inspector" : "Hide inspector (⌃⌘B)")
                .accessibilityLabel("Hide inspector")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func select(_ t: InspectorTab) {
        if context.isClaude {
            InspectorTabMemory.shared.claudeTab = t
        } else if let stored = t.storedTab {
            SettingsStore.shared.settings.sidebarTab = stored
        }
        switch t {
        case .worktrees: worktrees.refreshIfNeeded()
        case .checks: checks?.refresh()
        case .session, .files: break
        }
    }

    // MARK: Checks extras

    /// Below the branch's checks: a way to open a PR, the repo's pull requests
    /// (on the board) and every workflow run, which the old GitHub tab listed.
    private func checksExtra(_ gh: GitHubRemote) -> some View {
        let prs = pullRequests(gh)
        let runs = actions(gh)
        return VStack(alignment: .leading, spacing: 10) {
            if repo.pullRequest == nil, let branch = repo.status.branch, repo.isBranchPublished, branch != repo.defaultBranch {
                Link(destination: gh.compareURL(branch)) { Text("Create pull request for \(branch) ↗").lineLimit(1) }
                    .font(.system(size: DS.Size.small))
            }
            HStack(spacing: 6) {
                Text(prs.pullRequests.isEmpty ? "Pull requests" : "\(prs.pullRequests.count) open pull request\(prs.pullRequests.count == 1 ? "" : "s")")
                if !prs.reviewRequested.isEmpty { Pill("\(prs.reviewRequested.count) to review", color: DS.Status.needsYou) }
                Spacer(minLength: 4)
                if let openGitHub = context.openGitHub {
                    Button("Open board", action: openGitHub)
                        .buttonStyle(.labeled(.neutral, compact: true))
                        .help("Open the GitHub tab: a board of pull requests and stacks (\(ShortcutAction.github.shortcut?.displayString ?? "⌃⌘H"))")
                }
            }
            .font(.system(size: DS.Size.small))
            DisclosureGroup(isExpanded: $showAllRuns) {
                ActionsView(model: runs, currentBranch: repo.status.branch)
                    .frame(height: 380)
                    .cardSurface()
            } label: {
                HStack(spacing: 6) {
                    Text("All workflow runs").font(.system(size: DS.Size.small, weight: .semibold))
                    if runs.activeCount > 0 { Pill("\(runs.activeCount) running", color: DS.Status.working) }
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            prs.refreshIfNeeded()
            runs.branch = repo.status.branch
        }
        .onChange(of: repo.status.branch) { _, b in runs.branch = b }
    }

    private func resizeHandle(_ p: ClaudePalette) -> some View {
        p.border
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in onResize(-v.translation.width) }
                        .onEnded { _ in onResizeEnded() })
            }
    }
}

/// The Session tab bound to live data: changes from git (with line counts),
/// to-dos and background work from the Claude session.
struct InspectorSessionPanel: View {
    let repo: GitRepository
    let context: SidebarContext
    let inputs: InspectorSessionInputs

    var body: some View {
        let changes = WorkingChangesModel.shared(for: repo)
        InspectorSessionView(
            changes: changes.changes, todos: inputs.todos, background: inputs.background,
            onReview: inputs.onReview,
            onOpenFile: { change in
                if let open = inputs.onOpenFile { open(change) } else { Self.openInEditor(repo.root.appendingPathComponent(change.path)) }
            },
            onStop: inputs.onStop, onViewTranscript: inputs.onViewTranscript)
            .onAppear { changes.refresh() }
            .onChange(of: repo.status) { _, _ in changes.refresh() }
    }

    static func openInEditor(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let editor = ExternalEditor.preferred { editor.open([url]) } else { NSWorkspace.shared.open(url) }
    }
}

/// A worktree's tracking, pull request and changes, as the Worktrees sidebar
/// shows them. Shared with the Claude Sessions page's past sessions drawer.
@MainActor
enum WorktreeLabels {
    @ViewBuilder
    static func tracking(_ wt: WorktreeInfo, _ p: ClaudePalette) -> some View {
        if wt.upstreamGone {
            Text("upstream deleted").foregroundStyle(p.dim).help("The remote branch is gone — usually deleted after its PR merged")
        } else if wt.upstream == nil && wt.trackingKnown {
            Text("not pushed").foregroundStyle(p.yellow).help("No upstream branch: commits here exist only locally")
        } else if wt.ahead > 0 || wt.behind > 0 {
            HStack(spacing: 3) {
                if wt.ahead > 0 { Text("↑\(wt.ahead)").foregroundStyle(p.yellow) }
                if wt.behind > 0 { Text("↓\(wt.behind)").foregroundStyle(p.dim) }
            }
            .help("\(wt.ahead) commit\(wt.ahead == 1 ? "" : "s") not pushed, \(wt.behind) behind \(wt.upstream ?? "upstream")")
        }
    }

    static func pullRequest(_ pr: PullRequestInfo, _ p: ClaudePalette) -> some View {
        let (label, color, icon): (String, Color, String) = switch pr.state {
        case .merged: ("merged", p.magenta, "arrow.triangle.merge")
        case .closed: ("closed", p.red, "xmark.circle")
        case .open: pr.isDraft ? ("draft", p.dim, "circle.dashed") : ("open", p.green, "arrow.triangle.pull")
        }
        return Button { NSWorkspace.shared.open(pr.url) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(color)
                Text("#\(pr.number)").fontWeight(.semibold).foregroundStyle(color)
                Text(label).foregroundStyle(color)
                if pr.state == .open, let review = pr.reviewDecision {
                    Text(review == "APPROVED" ? "· approved" : review == "CHANGES_REQUESTED" ? "· changes requested" : "· review required")
                        .foregroundStyle(review == "APPROVED" ? p.green : review == "CHANGES_REQUESTED" ? p.red : p.dim)
                }
                Text(pr.title).foregroundStyle(p.dim).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 10.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(pr.title)\nOpen #\(pr.number) on GitHub")
    }

    @ViewBuilder
    static func changes(_ wt: WorktreeInfo, _ p: ClaudePalette) -> some View {
        if let n = wt.changes {
            if n == 0 {
                Label("clean", systemImage: "checkmark.circle").foregroundStyle(p.green)
            } else {
                Label("\(n) change\(n == 1 ? "" : "s")", systemImage: "pencil.circle").foregroundStyle(p.yellow)
            }
        } else if wt.isPrunable {
            Text("folder missing").foregroundStyle(p.red)
        } else {
            Text("checking…")
        }
    }

    static func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct DeleteWorktreeSheet: View {
    let worktree: WorktreeInfo
    let palette: ClaudePalette
    var onDelete: (_ force: Bool, _ deleteBranch: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var deleteBranch = SettingsStore.shared.settings.worktreeCleanupDeleteMergedBranches
    @State private var discard = false

    var body: some View {
        let dirty = (worktree.changes ?? 0) > 0
        VStack(alignment: .leading, spacing: 12) {
            Label(worktree.isPrunable ? "Prune \(worktree.name)?" : "Delete \(worktree.name)?", systemImage: "trash")
                .font(.system(size: 14, weight: .semibold))
            Text(worktree.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if worktree.isPrunable {
                Text("The folder is already gone; this removes git's record of it (`git worktree prune`).").font(.system(size: 12))
            } else {
                Text("Runs `git worktree remove`. The folder is deleted; commits on \(worktree.branch.map { "`\($0)`" } ?? "its branch") stay in the repository.")
                    .font(.system(size: 12))
                if dirty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(worktree.changes ?? 0) uncommitted change\(worktree.changes == 1 ? "" : "s") would be lost.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(palette.red)
                            .font(.system(size: 12, weight: .medium))
                        Toggle("Discard them and delete anyway (--force)", isOn: $discard)
                    }
                }
                if worktree.branch != nil {
                    Toggle("Also delete branch \(worktree.branch ?? "") if it's merged (`git branch -d`)", isOn: $deleteBranch)
                        .font(.system(size: 12))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(worktree.isPrunable ? "Prune" : "Delete", role: .destructive) {
                    onDelete(discard, deleteBranch)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(dirty && !discard)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
