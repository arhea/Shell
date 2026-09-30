import AppKit
import SwiftUI

/// Settings › Worktrees: what counts as stale, and scheduled cleanup.
struct WorktreesSettingsPane: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let store = SettingsStore.shared
    @State private var maintenance = ScheduledMaintenance.worktrees
    @State private var preview: [WorktreeCleanupJob.Candidate]?
    @State private var previewSizes: [String: Int64] = [:]
    @State private var previewing = false

    var body: some View {
        Form {
            Section {
                Stepper(value: setting(\.worktreeStaleDays), in: 1...365) {
                    HStack {
                        Text("Stale after")
                        Text("\(store.settings.worktreeStaleDays) day\(store.settings.worktreeStaleDays == 1 ? "" : "s")")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("A worktree is stale when it has no uncommitted changes (staged, unstaged or untracked) and no commits or checkouts in that time. The main checkout and locked worktrees never are. Stale worktrees are highlighted in the sidebar's Worktrees tab (⌃⌘B in a terminal, or the sidebar button in the Claude view).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Stale worktrees")
            }

            Section {
                TextField("New worktrees go in", text: setting(\.worktreeRoot),
                          prompt: Text(ClaudeToolFormat.shortPath(WorktreeService.worktreeRoot(environment: MCPManager.defaultEnvironment()))))
                Text("Worktrees Shell creates (for example to review a pull request) go in <folder>/<repo>/<branch>, like `gwt`. Empty uses $WORKTREES_HOME, else ~/code/worktrees.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("New worktrees")
            }

            Section {
                Picker("Clean up automatically", selection: setting(\.worktreeCleanupSchedule)) {
                    ForEach(AutoUpdateSchedule.allCases) { Text($0 == .off ? "Never" : $0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Repositories").font(.system(size: 12, weight: .medium))
                    if store.settings.worktreeCleanupPaths.isEmpty {
                        Text("Add a repository, or a folder of repositories (searched two levels deep).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.settings.worktreeCleanupPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: WorktreeService.repositories(in: path).count == 1 && FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath + "/.git")
                                  ? "shippingbox" : "folder")
                                .foregroundStyle(.secondary)
                            Text(ClaudeToolFormat.shortPath((path as NSString).expandingTildeInPath))
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text(repoCount(path)).font(.caption).foregroundStyle(.secondary)
                            Button {
                                store.settings.worktreeCleanupPaths.removeAll { $0 == path }
                                preview = nil
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Repositories…") { addPaths() }
                }
                Toggle("Also delete each worktree's branch when it's merged", isOn: setting(\.worktreeCleanupDeleteMergedBranches))
                Text("Cleanup runs `git worktree remove` without --force, so a worktree with uncommitted changes is never removed. Branches are kept unless you turn on the option above, which uses `git branch -d` (it refuses unmerged branches).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(previewing ? "Checking…" : "Preview") { runPreview() }
                        .disabled(previewing || store.settings.worktreeCleanupPaths.isEmpty)
                    if maintenance.isRunning {
                        ProgressView().controlSize(.small)
                        Text(maintenance.currentStep ?? "Running…").font(.caption).foregroundStyle(.secondary)
                        Button("Stop") { maintenance.cancel() }
                    } else {
                        Button("Clean Up Now") {
                            Task {
                                await maintenance.run()
                                preview = nil
                            }
                        }
                        .disabled(store.settings.worktreeCleanupPaths.isEmpty)
                    }
                    Spacer()
                    if let log = maintenance.lastRun?.logPath, FileManager.default.fileExists(atPath: log) {
                        Button("View Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                    }
                }
                status.font(.caption).foregroundStyle(.secondary)
                if let preview {
                    previewList(preview)
                }
            } header: {
                Text("Scheduled cleanup")
            } footer: {
                Text("Runs while Shell is open, like Homebrew and Node auto-update. Logs are in ~/Library/Logs/Shell.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func repoCount(_ path: String) -> String {
        let n = WorktreeService.repositories(in: path).count
        return n == 0 ? "no repositories found" : "\(n) repo\(n == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var status: some View {
        if let r = maintenance.lastRun, !maintenance.isRunning {
            let when = RelativeDateTimeFormatter().localizedString(for: r.finishedAt, relativeTo: Date())
            switch r.outcome {
            case .success:
                Text("Last run \(when): " + (r.changes.isEmpty ? "nothing to remove" : "removed \(r.changes.count)") + (r.summary.map { ", \($0)" } ?? "")
                     + (r.warnings.isEmpty ? "" : " · \(r.warnings.count) skipped") + nextText)
                    .help((r.changes + r.warnings).joined(separator: "\n"))
            case .failed: Text("Last run \(when) failed" + nextText).foregroundStyle(.orange)
            case .cancelled: Text("Last run \(when) was stopped" + nextText)
            }
        } else if maintenance.schedule != .off {
            Text("First run within a few minutes")
        }
    }

    private var nextText: String {
        guard maintenance.schedule != .off, let next = maintenance.nextRun else { return "" }
        return next <= Date() ? " · next: soon" : " · next \(RelativeDateTimeFormatter().localizedString(for: next, relativeTo: Date()))"
    }

    private func previewList(_ list: [WorktreeCleanupJob.Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if list.isEmpty {
                Text("Nothing is stale right now.").font(.caption).foregroundStyle(.secondary)
            } else {
                let total = list.compactMap { previewSizes[$0.id] }.reduce(0, +)
                Text("\(list.count) worktree\(list.count == 1 ? "" : "s") would be removed" + (total > 0 ? " · \(WorktreeService.formatBytes(total))" : ""))
                    .font(.system(size: 12, weight: .medium))
                ForEach(list) { c in
                    HStack {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\((c.repo as NSString).lastPathComponent) / \(c.worktree.name)").font(.system(size: 12))
                            Text([c.worktree.branch, c.worktree.ageDescription.map { "last activity \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(previewSizes[c.id].map(WorktreeService.formatBytes) ?? "…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func runPreview() {
        previewing = true
        Task {
            let list = await WorktreeCleanupJob.candidates()
            preview = list
            previewing = false
            for c in list {
                previewSizes[c.id] = await WorktreeService.size(of: c.worktree.path)
            }
        }
    }

    private func addPaths() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose repositories, or folders that contain repositories"
        guard panel.runModal() == .OK else { return }
        let home = NSHomeDirectory()
        var paths = store.settings.worktreeCleanupPaths
        for url in panel.urls {
            let p = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            if !paths.contains(p) { paths.append(p) }
        }
        store.settings.worktreeCleanupPaths = paths
        preview = nil
    }
}
