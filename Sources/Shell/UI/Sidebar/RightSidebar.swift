import AppKit
import SwiftUI

/// The window's right sidebar for the focused pane's repository: Files and
/// Worktrees tabs. Shown for native Claude sessions and (⌃⌘B) terminal panes.
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

    /// The selected tab; GitHub falls back to Files when there's no GitHub remote.
    private var tab: SidebarTab {
        let t = SettingsStore.shared.settings.sidebarTab
        return t == .github && repo.github == nil ? .files : t
    }

    var body: some View {
        let p = ClaudePalette.current
        HStack(spacing: 0) {
            resizeHandle(p)
            VStack(spacing: 0) {
                tabBar(p)
                p.border.frame(height: 1)
                if tab == .worktrees {
                    WorktreesView(model: worktrees, context: context, currentPath: repo.root.path)
                } else if tab == .github, let gh = repo.github {
                    GitHubView(repo: repo, github: gh, pullRequests: pullRequests(gh), actions: actions(gh),
                               worktrees: worktrees, context: context)
                } else {
                    FileExplorerView(context: context, repo: repo, tree: tree, onClose: onClose)
                }
            }
        }
        .background(p.surface)
        .foregroundStyle(p.foreground)
    }

    private func tabBar(_ p: ClaudePalette) -> some View {
        HStack(spacing: 2) {
            tabButton("Files", icon: "doc.on.doc", id: .files, p)
            tabButton("Worktrees", icon: "square.stack.3d.up", id: .worktrees, p,
                      badge: worktrees.stale.isEmpty ? nil : "\(worktrees.stale.count)")
            if let gh = repo.github {
                let prs = pullRequests(gh)
                let running = actions(gh).activeCount
                tabButton("GitHub", icon: "arrow.triangle.pull", id: .github, p,
                          badge: prs.reviewRequested.isEmpty ? (running > 0 ? "\(running)" : nil) : "\(prs.reviewRequested.count)")
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "sidebar.right") }
                .buttonStyle(HeaderButtonStyle(palette: p, active: true))
                .help(context.isClaude ? "Hide sidebar" : "Hide sidebar (⌃⌘B)")
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private func tabButton(_ title: String, icon: String, id: SidebarTab, _ p: ClaudePalette, badge: String? = nil) -> some View {
        let selected = tab == id
        return Button {
            SettingsStore.shared.settings.sidebarTab = id
            if id == .worktrees { worktrees.refreshIfNeeded() }
            if id == .github, let gh = repo.github { pullRequests(gh).refreshIfNeeded() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                // Only the selected tab spells out its name; the others stay compact.
                if selected { Text(title).lineLimit(1).fixedSize() }
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(p.yellow))
                        .help(id == .github ? "Waiting on your review, or Actions running" : "\(badge) stale worktree\(badge == "1" ? "" : "s")")
                }
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? p.foreground : p.dim)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? p.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
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

// MARK: - Worktrees tab

struct WorktreesView: View {
    let model: WorktreesModel
    let context: SidebarContext
    /// The worktree the pane is in.
    let currentPath: String

    @State private var pendingDelete: WorktreeInfo?
    @State private var confirmCleanup = false
    /// The merged worktrees the confirmation dialog lists, captured when it opens.
    @State private var pendingMerged: [WorktreeInfo] = []
    @State private var confirmMergedCleanup = false
    @State private var hovered: String?

    var body: some View {
        let p = ClaudePalette.current
        let merged = model.merged(excluding: currentPath)
        VStack(spacing: 0) {
            header(p)
            p.border.frame(height: 1)
            if !merged.isEmpty {
                mergedCleanupBar(merged, p)
                p.border.frame(height: 1)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    if let err = model.lastError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.red)
                            Text(err).font(.system(size: 11)).textSelection(.enabled)
                            Spacer()
                            Button { model.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(p.red.opacity(0.1)))
                    }
                    ForEach(model.worktrees) { wt in
                        row(wt, p)
                    }
                    if model.worktrees.isEmpty && !model.isLoading {
                        Text("No worktrees").font(.system(size: 12)).foregroundStyle(p.dim).padding(12)
                    }
                }
                .padding(8)
            }
        }
        .onAppear { model.refreshIfNeeded() }
        .sheet(item: $pendingDelete) { wt in
            DeleteWorktreeSheet(worktree: wt, palette: p) { force, deleteBranch in
                Task { await model.remove(wt, force: force, deleteBranch: deleteBranch) }
            }
        }
        .confirmationDialog("Remove \(model.stale.count) stale worktree\(model.stale.count == 1 ? "" : "s")?", isPresented: $confirmCleanup) {
            Button("Remove", role: .destructive) {
                Task { await model.removeStale(deleteBranch: SettingsStore.shared.settings.worktreeCleanupDeleteMergedBranches) }
            }
        } message: {
            Text(model.stale.map(\.name).joined(separator: ", ")
                 + "\n\nEach has no uncommitted changes. Branches are "
                 + (SettingsStore.shared.settings.worktreeCleanupDeleteMergedBranches ? "deleted when merged." : "kept."))
        }
        .confirmationDialog("Remove \(pendingMerged.count) merged worktree\(pendingMerged.count == 1 ? "" : "s")?",
                            isPresented: $confirmMergedCleanup) {
            Button("Remove", role: .destructive) {
                let list = pendingMerged
                Task { await model.removeMerged(list) }
            }
        } message: {
            Text(pendingMerged.map { wt in wt.name + (wt.pullRequest.map { " (#\($0.number))" } ?? "") }.joined(separator: "\n")
                 + "\n\nEach PR has merged and the worktree has no uncommitted changes. "
                 + "A branch is deleted only if it has nothing beyond what merged; otherwise it's kept.")
        }
    }

    private func mergedCleanupBar(_ merged: [WorktreeInfo], _ p: ClaudePalette) -> some View {
        Button {
            pendingMerged = merged
            confirmMergedCleanup = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(p.magenta)
                Text("Clean up merged worktrees")
                Spacer()
                Text("\(merged.count)").monospacedDigit().foregroundStyle(p.magenta)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(p.magenta.opacity(0.08))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy.count > 0)
        .help("Remove worktrees whose pull request has merged and that have no uncommitted changes")
    }

    private func header(_ p: ClaudePalette) -> some View {
        let staleCount = model.stale.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(p.yellow)
                Text((model.repoRoot as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.mini) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: false))
                    .help("Refresh")
            }
            Text(summary).font(.system(size: 11)).foregroundStyle(p.dim)
            HStack(spacing: 6) {
                Button {
                    SettingsWindowController.shared.show(pane: .worktrees)
                } label: {
                    Text("Stale: clean & idle \(model.staleDays)+ days").underline()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(p.dim)
                .help("Change the threshold and schedule automatic cleanup in Settings › Worktrees")
                Spacer()
                if staleCount > 0 {
                    Button("Clean Up \(staleCount)") { confirmCleanup = true }
                        .controlSize(.small)
                        .tint(p.yellow)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let n = model.worktrees.count
        var parts = ["\(n) worktree\(n == 1 ? "" : "s")"]
        if !model.stale.isEmpty { parts.append("\(model.stale.count) stale") }
        if model.totalSize > 0 { parts.append(WorktreeService.formatBytes(model.totalSize)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Row

    private func row(_ wt: WorktreeInfo, _ p: ClaudePalette) -> some View {
        let stale = wt.isStale(days: model.staleDays)
        let current = URL(fileURLWithPath: wt.path).standardizedFileURL.path == URL(fileURLWithPath: currentPath).standardizedFileURL.path
        let busy = model.busy.contains(wt.path)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: wt.isMain ? "shippingbox" : "square.stack.3d.up")
                    .foregroundStyle(stale ? p.yellow : wt.isMain ? p.cyan : p.dim)
                    .frame(width: 14)
                Text(wt.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.mini) }
                if current { badge("here", p.claude, p) }
                if wt.isMain { badge("main", p.cyan, p) }
                if stale { badge("stale", p.yellow, p) }
                if wt.looksFinished && !wt.isMain { badge(wt.pullRequest?.state == .merged ? "merged" : "done?", p.magenta, p) }
                if wt.isLocked { badge("locked", p.dim, p) }
                if wt.isPrunable { badge("missing", p.red, p) }
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(p.magenta).font(.system(size: 9))
                Text(wt.branch ?? (wt.isBare ? "bare" : "detached @ \(wt.head ?? "?")"))
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                trackingLabel(wt, p)
            }
            .font(.system(size: 11))
            .foregroundStyle(p.foreground.opacity(0.85))
            // The main checkout's branch (develop/main) only has release PRs; skip them.
            if let pr = wt.pullRequest, !wt.isMain {
                prLine(pr, p)
            }
            HStack(spacing: 8) {
                changesLabel(wt, p)
                if let age = wt.ageDescription { Text(age) }
                Spacer()
                if let size = wt.sizeBytes { Text(WorktreeService.formatBytes(size)).monospacedDigit() }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(p.dim)
            if hovered == wt.path && !busy {
                actions(wt, current: current, p)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(stale ? p.yellow.opacity(0.1) : hovered == wt.path ? p.raised : p.background.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(stale ? p.yellow.opacity(0.45) : current ? p.claude.opacity(0.45) : p.border, lineWidth: stale || current ? 1 : 0.5))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? wt.path : (hovered == wt.path ? nil : hovered) }
        .contextMenu { menu(wt, current: current) }
        .help(wt.path + (wt.lockReason.map { "\nLocked: \($0)" } ?? "") + (wt.prunableReason.map { "\n\($0)" } ?? ""))
    }

    @ViewBuilder
    private func trackingLabel(_ wt: WorktreeInfo, _ p: ClaudePalette) -> some View {
        if wt.branch != nil, !wt.isMain || wt.ahead + wt.behind > 0 {
            trackingText(wt, p).fixedSize()
        }
    }

    @ViewBuilder
    private func trackingText(_ wt: WorktreeInfo, _ p: ClaudePalette) -> some View {
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

    private func prLine(_ pr: PullRequestInfo, _ p: ClaudePalette) -> some View {
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
    private func changesLabel(_ wt: WorktreeInfo, _ p: ClaudePalette) -> some View {
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

    private func actions(_ wt: WorktreeInfo, current: Bool, _ p: ClaudePalette) -> some View {
        HStack(spacing: 6) {
            if wt.exists {
                if let openTab = context.openTab {
                    Button { openTab(wt.path, nil) } label: { Label("New Tab", systemImage: "plus.rectangle") }
                    Button { openTab(wt.path, "claude") } label: { Label("Claude", systemImage: "sparkle") }
                }
                if let editor = ExternalEditor.preferred {
                    Button { editor.open([URL(fileURLWithPath: wt.path)]) } label: { Image(nsImage: editor.icon.resized(to: 12)) }
                        .help("Open in \(editor.name)")
                }
            }
            Spacer()
            if !wt.isMain {
                Button(role: .destructive) { pendingDelete = wt } label: { Image(systemName: "trash") }
                    .disabled(current)
                    .help(current ? "This pane is in this worktree" : wt.isPrunable ? "Prune (folder is already gone)" : "Delete worktree…")
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .font(.system(size: 10.5))
    }

    @ViewBuilder
    private func menu(_ wt: WorktreeInfo, current: Bool) -> some View {
        if wt.exists {
            if let openTab = context.openTab {
                Button("Open in New Tab") { openTab(wt.path, nil) }
                Button("Start Claude in New Tab") { openTab(wt.path, "claude") }
            }
            if let insert = context.insert, !context.isClaude {
                Button("Insert cd Command") { insert("cd " + shellQuote(wt.path)) }
            }
            ForEach(ExternalEditor.installed) { editor in
                Button("Open in \(editor.name)") { editor.open([URL(fileURLWithPath: wt.path)]) }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)]) }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(wt.path, forType: .string)
        }
        if !wt.isMain {
            Divider()
            Button(wt.isPrunable ? "Prune…" : "Delete Worktree…") { pendingDelete = wt }.disabled(current)
        }
    }

    private func badge(_ text: String, _ color: Color, _ p: ClaudePalette) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func shellQuote(_ s: String) -> String { ShellQuote.quote(s) }
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
