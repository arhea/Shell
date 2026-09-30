import AppKit
import SwiftUI

/// The sidebar's GitHub tab: links to the repository and the current
/// branch's PR, then open pull requests or Actions runs.
struct GitHubView: View {
    let repo: GitRepository
    let github: GitHubRemote
    let pullRequests: PullRequestsModel
    let actions: ActionsModel
    let worktrees: WorktreesModel
    let context: SidebarContext

    private var section: GitHubSection { SettingsStore.shared.settings.githubSection }

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            header(p)
            p.border.frame(height: 1)
            if section == .actions {
                ActionsView(model: actions, currentBranch: repo.status.branch)
            } else {
                PullRequestsView(model: pullRequests, worktrees: worktrees, context: context, repoName: github.name)
            }
        }
        .onAppear { actions.branch = repo.status.branch }
        .onChange(of: repo.status.branch) { _, b in actions.branch = b }
    }

    private func header(_ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Link(destination: github.url) {
                    HStack(spacing: 5) {
                        Image(systemName: "shippingbox").foregroundStyle(p.cyan)
                        Text(github.slug).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold)).foregroundStyle(p.dim)
                    }
                }
                .help("Open \(github.slug) on GitHub")
                Spacer()
                if let openGitHub = context.openGitHub {
                    Button(action: openGitHub) {
                        HStack(spacing: 3) {
                            Image(systemName: "rectangle.split.3x1")
                            Text("Board")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: false))
                    .help("Open the GitHub tab: a board of pull requests and stacks (\(ShortcutAction.github.shortcut?.displayString ?? "⌃⌘H"))")
                }
            }
            .foregroundStyle(p.foreground)
            currentBranch(p)
            Picker("", selection: Binding(get: { section }, set: { SettingsStore.shared.settings.githubSection = $0 })) {
                Text("Pull Requests" + (pullRequests.pullRequests.isEmpty ? "" : " (\(pullRequests.pullRequests.count))")).tag(GitHubSection.prs)
                Text("Actions" + (actions.activeCount > 0 ? " (\(actions.activeCount) running)" : "")).tag(GitHubSection.actions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// The branch this pane is on, with its PR (or a link to open one).
    @ViewBuilder
    private func currentBranch(_ p: ClaudePalette) -> some View {
        if let branch = repo.status.branch {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundStyle(p.magenta)
                Text(branch).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let pr = repo.pullRequest {
                    Link(destination: pr.url) {
                        HStack(spacing: 3) {
                            Text("PR #\(pr.number)").fontWeight(.semibold)
                            Text(pr.isDraft ? "draft" : pr.state.rawValue.lowercased())
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(pr.state == .merged ? p.magenta : pr.state == .closed ? p.red : pr.isDraft ? p.dim : p.green)
                    }
                    .help(pr.title)
                } else if repo.isBranchPublished, branch != repo.defaultBranch {
                    Link(destination: github.compareURL(branch)) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                            Text("Create PR")
                        }
                        .foregroundStyle(p.green)
                    }
                    .help("Open a pull request for \(branch)")
                } else {
                    Link(destination: github.branchURL(branch)) {
                        Image(systemName: "arrow.up.right.square").foregroundStyle(p.dim)
                    }
                    .help("Open \(branch) on GitHub")
                    .disabled(!repo.isBranchPublished)
                }
            }
            .font(.system(size: 11))
        }
    }
}

struct ActionsView: View {
    let model: ActionsModel
    let currentBranch: String?

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { model.scope }, set: { model.scope = $0 })) {
                    Text("All branches").tag(ActionsModel.Scope.all)
                    Text("This branch").tag(ActionsModel.Scope.branch)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
                if model.isLoading { ProgressView().controlSize(.mini) }
                if let updated = model.lastUpdated {
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        Text(model.activeCount > 0 ? "live · \(Self.ago(updated))" : Self.ago(updated))
                            .font(.system(size: 10)).foregroundStyle(model.activeCount > 0 ? p.yellow : p.dim)
                    }
                    .help(model.activeCount > 0 ? "Refreshing every 10 seconds while runs are active" : "Refreshing every minute")
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HeaderButtonStyle(palette: p, active: false))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            p.border.frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 5) {
                    if let err = model.error {
                        Text(err).font(.system(size: 11)).foregroundStyle(p.yellow).padding(8)
                    }
                    if let msg = model.message {
                        HStack {
                            Text(msg).font(.system(size: 11)).foregroundStyle(p.red)
                            Spacer()
                            Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }
                        .padding(8)
                    }
                    ForEach(model.runs) { run in
                        RunRow(run: run, model: model, palette: p)
                    }
                    if model.runs.isEmpty && !model.isLoading && model.error == nil {
                        Text(model.lastUpdated == nil ? "Loading…" : "No workflow runs.").font(.system(size: 12)).foregroundStyle(p.dim).padding(12)
                    }
                }
                .padding(8)
            }
        }
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        return s < 10 ? "just now" : s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }
}

struct RunRow: View {
    let run: WorkflowRun
    let model: ActionsModel
    let palette: ClaudePalette
    @State private var hovered = false

    var body: some View {
        let p = palette
        let expanded = model.expanded.contains(run.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 7) {
                StateIcon(state: run.state, palette: p).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                    Text("\(run.workflow) #\(run.number)" + (run.attempt > 1 ? " · attempt \(run.attempt)" : "")
                         + " · " + run.event.replacingOccurrences(of: "_", with: " "))
                        .lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 10.5)).foregroundStyle(p.dim)
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8)).foregroundStyle(p.magenta)
                        Text(run.branch).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        if run.isActive {
                            // Only running jobs have a ticking duration.
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(timing).monospacedDigit().foregroundStyle(p.yellow).lineLimit(1).fixedSize()
                            }
                        } else {
                            Text(timing).monospacedDigit().foregroundStyle(p.dim).lineLimit(1).fixedSize()
                        }
                    }
                    .font(.system(size: 10.5))
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.jobs[run.id] ?? []) { job in
                        Button { if let u = job.url { NSWorkspace.shared.open(u) } } label: {
                            HStack(spacing: 6) {
                                StateIcon(state: job.state, palette: p, size: 10)
                                Text(job.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let s = job.startedAt {
                                    Text(TerminalSession.format(duration: (job.completedAt ?? Date()).timeIntervalSince(s)))
                                        .monospacedDigit().foregroundStyle(p.dim)
                                }
                            }
                            .font(.system(size: 10.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open job log on GitHub")
                    }
                    if model.jobs[run.id] == nil { ProgressView().controlSize(.mini) }
                }
                .padding(.leading, 20)
            }
            if hovered || expanded {
                HStack(spacing: 6) {
                    Button { model.toggle(run) } label: { Label(expanded ? "Hide jobs" : "Jobs", systemImage: expanded ? "chevron.up" : "chevron.down") }
                    if run.isActive {
                        Button { model.perform(run, "cancel") } label: { Label("Cancel", systemImage: "stop.circle") }
                    } else if run.state == .failure || run.state == .cancelled {
                        Button { model.perform(run, "rerun") } label: { Label("Re-run failed", systemImage: "arrow.clockwise") }
                    }
                    Spacer()
                    if model.busy.contains(run.id) { ProgressView().controlSize(.mini) }
                    Button { NSWorkspace.shared.open(run.url) } label: { Image(systemName: "arrow.up.right.square") }
                        .help("Open run on GitHub")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 10.5))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovered ? p.raised : p.background.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(run.state == .failure ? p.red.opacity(0.35) : run.isActive ? p.yellow.opacity(0.4) : p.border, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(run.url) }
        .contextMenu {
            Button("Open on GitHub") { NSWorkspace.shared.open(run.url) }
            Button(expanded ? "Hide Jobs" : "Show Jobs") { model.toggle(run) }
            if run.isActive { Button("Cancel Run") { model.perform(run, "cancel") } }
            if run.state == .failure || run.state == .cancelled { Button("Re-run Failed Jobs") { model.perform(run, "rerun") } }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.url.absoluteString, forType: .string)
            }
        }
    }

    private var timing: String {
        let d = run.duration.map { TerminalSession.format(duration: $0) } ?? ""
        if run.isActive { return run.state == .queued ? "queued \(d)" : d }
        guard let updated = run.updatedAt else { return d }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "\(d) · \(f.localizedString(for: updated, relativeTo: Date()))"
    }
}

struct StateIcon: View {
    let state: WorkflowRun.State
    let palette: ClaudePalette
    var size: CGFloat = 12
    @State private var spin = false

    var body: some View {
        let p = palette
        Group {
            switch state {
            case .running:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(p.yellow)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            case .queued: Image(systemName: "clock").foregroundStyle(p.yellow)
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(p.green)
            case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(p.red)
            case .cancelled: Image(systemName: "slash.circle").foregroundStyle(p.dim)
            case .skipped: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(p.dim)
            case .neutral: Image(systemName: "circle").foregroundStyle(p.dim)
            }
        }
        .font(.system(size: size))
        .frame(width: size + 2)
    }
}
