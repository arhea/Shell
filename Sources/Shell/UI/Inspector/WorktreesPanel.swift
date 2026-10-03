import AppKit
import SwiftUI

/// What a tab open in a worktree is doing, for the "Open in tabs" group.
struct WorktreeTabState: Equatable {
    var agent: StatusKind = .idle
    /// "Claude needs approval", "Claude working". Nil derives one from `agent`.
    var label: String?

    init(agent: StatusKind = .idle, label: String? = nil) {
        self.agent = agent
        self.label = label
    }

    /// From a pane's agent status, e.g. "Claude needs approval".
    init(_ status: AgentStatus?) {
        agent = StatusKind(status)
        label = status.map { s in
            switch s {
            case .working(let k): "\(k.displayName) working"
            case .needsInput(let k, _): "\(k.displayName) needs approval"
            case .finished(let k, _): "\(k.displayName) finished"
            }
        }
    }

    var text: String? {
        label ?? {
            switch agent {
            case .working: "Agent working"
            case .needsYou: "Agent needs you"
            case .done: "Agent finished"
            case .failed: "Agent failed"
            case .idle: nil
            }
        }()
    }
}

/// The inspector's Worktrees tab: worktrees open in tabs, the main checkout,
/// the rest, filter chips, and a card for cleaning up stale ones.
struct WorktreesView: View {
    let model: WorktreesModel
    let context: SidebarContext
    /// The worktree the pane is in.
    let currentPath: String
    /// Working directories of open tabs → what's running there. The current
    /// pane's directory always counts as open.
    var openTabs: [String: WorktreeTabState] = [:]
    /// Checks for a worktree's branch, when known (shown on open worktrees).
    var checks: ((WorktreeInfo) -> BranchChecksSnapshot?)?
    /// Starts a new worktree (e.g. Claude in a new worktree). Hidden when nil.
    var onNewWorktree: (() -> Void)?

    @State private var filter: WorktreeFilter = .all
    @State private var showAllOthers = false
    @State private var pendingDelete: WorktreeInfo?
    @State private var confirmCleanup = false
    @State private var pendingMerged: [WorktreeInfo] = []
    @State private var confirmMergedCleanup = false
    @State private var hovered: String?

    /// Rows shown in "Agent worktrees" before "Show N more".
    static let collapsedCount = 4

    var body: some View {
        let merged = model.merged(excluding: currentPath)
        let staleDays = model.staleDays
        let visible = model.worktrees.filter { filter.matches($0, staleDays: staleDays) }
        let groups = WorktreeGroups.group(visible, openPaths: Array(openTabs.keys) + [currentPath])
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    chips
                    if let err = model.lastError { errorBanner(err) }
                    if !merged.isEmpty { mergedCleanupButton(merged) }
                    if !groups.open.isEmpty {
                        group("Open in tabs", count: nil) {
                            ForEach(groups.open) { wt in row(wt, style: .open) }
                        }
                    }
                    if let main = groups.main {
                        group("Main checkout", count: nil) { row(main, style: .main) }
                    }
                    if !groups.others.isEmpty {
                        let shown = showAllOthers ? groups.others : Array(groups.others.prefix(Self.collapsedCount))
                        group("Agent worktrees", count: groups.others.count) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(shown) { wt in row(wt, style: .compact) }
                            }
                            if groups.others.count > shown.count {
                                Button("Show \(groups.others.count - shown.count) more") { showAllOthers = true }
                                    .buttonStyle(.plain)
                                    .font(.system(size: DS.Size.subtitle))
                                    .foregroundStyle(DS.Status.info)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                        }
                    }
                    if visible.isEmpty && !model.isLoading {
                        Text(model.worktrees.isEmpty ? "No worktrees" : "No worktrees match this filter")
                            .font(.system(size: DS.Size.body)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
            if !model.stale.isEmpty { staleCard.padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 4) }
        }
        .onAppear { model.refreshIfNeeded() }
        .sheet(item: $pendingDelete) { wt in
            DeleteWorktreeSheet(worktree: wt, palette: ClaudePalette.current) { force, deleteBranch in
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(repositoryName).font(.system(size: DS.Size.title, weight: .semibold)).lineLimit(1)
                Text(summary).font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 2)
            Spacer(minLength: 4)
            if model.isLoading { ProgressView().controlSize(.mini) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.labeled(.plain, compact: true))
                .help("Refresh")
                .accessibilityLabel("Refresh worktrees")
            if let onNewWorktree {
                Button(action: onNewWorktree) { Text("+ New") }
                    .buttonStyle(CheckCardButtonStyle())
                    .help("Start Claude in a new worktree")
            }
        }
    }

    /// The repository's name: its main checkout's folder, not the linked worktree this pane is in.
    private var repositoryName: String {
        let root = model.worktrees.first(where: \.isMain)?.path ?? model.repoRoot
        return (root as NSString).lastPathComponent
    }

    private var summary: String {
        let n = model.worktrees.count
        var parts = ["\(n) worktree\(n == 1 ? "" : "s")"]
        if model.totalSize > 0 { parts.append(WorktreeService.formatBytes(model.totalSize)) }
        return parts.joined(separator: " · ")
    }

    private var chips: some View {
        let counts = WorktreeFilter.counts(model.worktrees, staleDays: model.staleDays)
        return HStack(spacing: 4) {
            ForEach(WorktreeFilter.allCases) { f in
                Button { filter = f } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(f.title).lineLimit(1)
                        Text("\(counts[f] ?? 0)").monospacedDigit()
                    }
                    .font(.system(size: DS.Size.subtitle))
                    .foregroundStyle(filter == f ? Color.primary : Color.primary.opacity(0.8))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(filter == f ? Color.primary.opacity(0.14) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 12))
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == f ? .isSelected : [])
                .help(f == .stale ? "Clean and idle for \(model.staleDays)+ days" : f.title)
            }
        }
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Status.failed)
            Text(err).font(.system(size: DS.Size.small)).textSelection(.enabled)
            Spacer()
            Button { model.lastError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(8)
        .cardSurface(tint: DS.Status.failed, radius: DS.Radius.row)
    }

    private func mergedCleanupButton(_ merged: [WorktreeInfo]) -> some View {
        Button {
            pendingMerged = merged
            confirmMergedCleanup = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(DS.Status.review)
                Text("Clean up merged worktrees")
                Spacer()
                Text("\(merged.count)").monospacedDigit().foregroundStyle(DS.Status.review)
            }
            .font(.system(size: DS.Size.small, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .cardSurface(tint: DS.Status.review, radius: DS.Radius.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.busy.isEmpty)
        .help("Remove worktrees whose pull request has merged and that have no uncommitted changes")
    }

    private func group(_ title: String, count: Int?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title, count: count).padding(.horizontal, 2).padding(.top, 4).padding(.bottom, 2)
            content()
        }
    }

    private var staleCard: some View {
        let deletes = SettingsStore.shared.settings.worktreeCleanupDeleteMergedBranches
        let n = model.stale.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(n) stale worktree\(n == 1 ? "" : "s")" + (model.staleSize > 0 ? " use \(WorktreeService.formatBytes(model.staleSize))" : ""))
                .font(.system(size: DS.Size.body, weight: .semibold))
            Button {
                SettingsWindowController.shared.show(pane: .worktrees)
            } label: {
                Text("Clean and idle for \(model.staleDays)+ days. "
                     + (deletes ? "Merged branches are deleted; other branches stay." : "Branches stay; only the folders are removed."))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .font(.system(size: DS.Size.subtitle))
            .lineSpacing(2)
            .foregroundStyle(.secondary)
            .help("Change the threshold and schedule automatic cleanup in Settings › Worktrees")
            Button { confirmCleanup = true } label: { Text("Review & Remove…").frame(maxWidth: .infinity) }
                .buttonStyle(CheckCardButtonStyle())
                .disabled(!model.busy.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: Rows

    private func isCurrent(_ wt: WorktreeInfo) -> Bool {
        WorktreeGroups.owner(of: currentPath, in: model.worktrees) == wt.path
    }

    private func tabState(_ wt: WorktreeInfo) -> WorktreeTabState? {
        let states = openTabs.filter { WorktreeGroups.owner(of: $0.key, in: model.worktrees) == wt.path }.map(\.value)
        return states.min { $0.agent.priority < $1.agent.priority }
    }

    /// Open worktrees are cards with their PR and agent state; the main
    /// checkout sits on a faint fill; the rest are compact two-line rows.
    enum RowStyle { case open, main, compact }

    private func row(_ wt: WorktreeInfo, style: RowStyle) -> some View {
        let current = isCurrent(wt)
        let busy = model.busy.contains(wt.path)
        let stale = wt.isStale(days: model.staleDays)
        let open = style == .open
        return VStack(alignment: .leading, spacing: style == .compact ? 2 : 4) {
            HStack(spacing: 6) {
                Text(wt.branch ?? wt.name)
                    .font(.system(size: DS.Size.body, weight: style == .compact ? .regular : .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if wt.isMain { mainTracking(wt) }
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.mini) }
                if let size = wt.sizeBytes {
                    Text(WorktreeService.formatBytes(size)).font(.system(size: DS.Size.small)).monospacedDigit().foregroundStyle(.secondary)
                }
                if wt.isMain && wt.behind > 0 && wt.exists {
                    Button("Pull") { Task { await model.pull(wt) } }
                        .buttonStyle(CheckCardButtonStyle())
                        .disabled(busy)
                        .help("git pull --ff-only")
                }
            }
            HStack(spacing: 8) {
                if open, let pr = wt.pullRequest { prLine(wt, pr) }
                detailLine(wt, stale: stale, brief: open && wt.pullRequest != nil)
            }
            if open, let state = tabState(wt), let text = state.text {
                HStack(spacing: 6) {
                    Circle().fill(state.agent.color).frame(width: 6, height: 6)
                    Text(text).foregroundStyle(state.agent == .needsYou ? DS.Status.needsYou : state.agent == .idle ? .secondary : state.agent.color)
                }
                .font(.system(size: DS.Size.subtitle))
            }
            if hovered == wt.path && !busy { actions(wt, current: current) }
        }
        .padding(.horizontal, 10).padding(.vertical, style == .compact ? 6 : 9)
        .background(
            RoundedRectangle(cornerRadius: style == .compact ? 7 : 9)
                .fill(current ? DS.Status.selection.opacity(0.16)
                      : hovered == wt.path ? Color.primary.opacity(0.05)
                      : style == .main ? Color.primary.opacity(0.03) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: style == .compact ? 7 : 9)
                .strokeBorder(current ? DS.Status.selection.opacity(0.45) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? wt.path : (hovered == wt.path ? nil : hovered) }
        .onTapGesture(count: 2) { if wt.exists, !current { context.switchTo?(wt.path) } }
        .contextMenu { menu(wt, current: current) }
        .help(wt.path + (wt.lockReason.map { "\nLocked: \($0)" } ?? "") + (wt.prunableReason.map { "\n\($0)" } ?? ""))
    }

    @ViewBuilder
    private func mainTracking(_ wt: WorktreeInfo) -> some View {
        HStack(spacing: 4) {
            if wt.behind > 0 { Text("↓\(wt.behind) behind").foregroundStyle(DS.Status.info) }
            if wt.ahead > 0 { Text("↑\(wt.ahead) ahead").foregroundStyle(DS.Status.working) }
        }
        .font(.system(size: DS.Size.small))
        .fixedSize()
    }

    private func prLine(_ wt: WorktreeInfo, _ pr: PullRequestInfo) -> some View {
        let snap = checks?(wt)
        let (dot, text): (Color, String) = {
            if let snap, let overall = snap.overall {
                switch overall {
                case .failed: return (DS.Status.failed, "PR #\(pr.number) \(snap.summary)")
                case .running, .queued: return (DS.Status.working, "PR #\(pr.number) checks running")
                default: return (DS.Status.done, "PR #\(pr.number) checks passed")
                }
            }
            switch pr.state {
            case .merged: return (DS.Status.review, "PR #\(pr.number) merged")
            case .closed: return (DS.Status.failed, "PR #\(pr.number) closed")
            case .open: return (pr.isDraft ? Color.secondary : DS.Status.done, "PR #\(pr.number) \(pr.isDraft ? "draft" : "open")")
            }
        }()
        return Button { NSWorkspace.shared.open(pr.url) } label: {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(text).foregroundStyle(dot == .secondary ? .secondary : dot)
            }
            .font(.system(size: DS.Size.subtitle))
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(pr.title)\nOpen #\(pr.number) on GitHub")
    }

    /// "clean · not pushed · today", "18 changes  not pushed", "detached @ d8013cf · 1 day ago".
    /// `brief` (next to a PR line) leaves out the age.
    private func detailLine(_ wt: WorktreeInfo, stale: Bool, brief: Bool = false) -> some View {
        HStack(spacing: 4) {
            if wt.isPrunable {
                Text("folder missing").foregroundStyle(DS.Status.failed)
            } else if let n = wt.changes {
                if n == 0 { Text("clean") } else { Text("\(n) change\(n == 1 ? "" : "s")").foregroundStyle(DS.Status.needsYou) }
            } else {
                Text("checking…")
            }
            if wt.isDetached || wt.branch == nil {
                Text("· " + (wt.isBare ? "bare" : "detached @ \(wt.head.map { String($0.prefix(7)) } ?? "?")"))
            } else if !wt.isMain {
                tracking(wt)
            }
            if !brief, let age = wt.ageDescription { Text("· \(age)") }
            if stale { Text("· stale").foregroundStyle(DS.Status.needsYou) }
            if wt.isLocked { Text("· locked") }
            if wt.looksFinished && !wt.isMain && !stale {
                Text(wt.pullRequest?.state == .merged ? "· merged" : "· done?").foregroundStyle(DS.Status.review)
            }
        }
        .font(.system(size: DS.Size.subtitle))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func tracking(_ wt: WorktreeInfo) -> some View {
        if wt.upstreamGone {
            Text("· upstream deleted").help("The remote branch is gone — usually deleted after its PR merged")
        } else if wt.upstream == nil && wt.trackingKnown {
            Text("· not pushed").help("No upstream branch: commits here exist only locally")
        } else if wt.ahead > 0 || wt.behind > 0 {
            Text("·" + (wt.ahead > 0 ? " ↑\(wt.ahead)" : "") + (wt.behind > 0 ? " ↓\(wt.behind)" : ""))
                .help("\(wt.ahead) commit\(wt.ahead == 1 ? "" : "s") not pushed, \(wt.behind) behind \(wt.upstream ?? "upstream")")
        } else if wt.upstream != nil {
            Text("· pushed")
        }
    }

    private func actions(_ wt: WorktreeInfo, current: Bool) -> some View {
        HStack(spacing: 6) {
            if wt.exists {
                if let openTab = context.openTab {
                    Button { openTab(wt.path, nil) } label: { Text("New Tab") }
                        .buttonStyle(.labeled(.neutral, compact: true))
                    Button { openTab(wt.path, "claude") } label: { HStack(spacing: 3) { ClaudeMark(size: 9); Text("Claude") } }
                        .buttonStyle(.labeled(.claude, compact: true))
                }
                if let editor = ExternalEditor.preferred {
                    Button { editor.open([URL(fileURLWithPath: wt.path)]) } label: { Image(nsImage: editor.icon.resized(to: 12)) }
                        .buttonStyle(.labeled(.neutral, compact: true))
                        .help("Open in \(editor.name)")
                }
            }
            Spacer()
            if !wt.isMain {
                Button(role: .destructive) { pendingDelete = wt } label: { Image(systemName: "trash") }
                    .buttonStyle(.labeled(.destructive, compact: true))
                    .disabled(current)
                    .help(current ? "This pane is in this worktree" : wt.isPrunable ? "Prune (folder is already gone)" : "Delete worktree…")
                    .accessibilityLabel(wt.isPrunable ? "Prune" : "Delete worktree")
            }
        }
        .padding(.top, 3)
    }

    @ViewBuilder
    private func menu(_ wt: WorktreeInfo, current: Bool) -> some View {
        if wt.exists {
            if let switchTo = context.switchTo, !current {
                Button("Go to Tab") { switchTo(wt.path) }
            }
            if let openTab = context.openTab {
                Button("Open in New Tab") { openTab(wt.path, nil) }
                Button("Start Claude in New Tab") { openTab(wt.path, "claude") }
            }
            if let insert = context.insert, !context.isClaude {
                Button("Insert cd Command") { insert("cd " + ShellQuote.quote(wt.path)) }
            }
            ForEach(ExternalEditor.installed) { editor in
                Button("Open in \(editor.name)") { editor.open([URL(fileURLWithPath: wt.path)]) }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)]) }
            if wt.isMain && wt.behind > 0 {
                Button("Pull") { Task { await model.pull(wt) } }
            }
        }
        if let pr = wt.pullRequest {
            Button("Open PR #\(pr.number) on GitHub") { NSWorkspace.shared.open(pr.url) }
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
}
