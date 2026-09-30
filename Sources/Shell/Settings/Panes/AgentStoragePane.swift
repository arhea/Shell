import AppKit
import SwiftUI

/// Settings › Agent Storage: what Claude Code and Codex keep on disk, and cleanup.
struct AgentStoragePane: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let model = AgentStorageModel.shared
    /// App-wide model (observed through property access; not state this view owns).
    private let store = SettingsStore.shared
    @State private var maintenance = ScheduledMaintenance.agentStorage
    @State private var confirm: StorageCategory?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.measured.isEmpty ? "Measuring…" : WorktreeService.formatBytes(model.total))
                            .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        Text("Claude Code \(WorktreeService.formatBytes(model.total(for: .claude))) · Codex \(WorktreeService.formatBytes(model.total(for: .codex)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isMeasuring { ProgressView().controlSize(.small) }
                    Button("Recalculate") { model.measure() }.disabled(model.isMeasuring)
                }
                Text("Caches and logs are rebuilt as needed, so clearing them is safe; anything touched in the last day is kept so running sessions aren't disturbed. History (transcripts, checkpoints, sessions) is only pruned by age, because --resume and rewind depend on it. Settings, credentials, plugins, skills and project memory are never touched.")
                    .font(.caption).foregroundStyle(.secondary)
                if let r = model.lastResult {
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach([StorageCategory.Agent.claude, .codex], id: \.rawValue) { agent in
                Section(agent.rawValue + (model.measured.isEmpty ? "" : " · " + WorktreeService.formatBytes(model.total(for: agent)))) {
                    ForEach(model.categories.filter { $0.agent == agent }) { c in
                        row(c)
                    }
                }
            }

            Section {
                Stepper(value: setting(\.agentHistoryDays), in: 1...365) {
                    HStack {
                        Text("Keep history for")
                        Text("\(store.settings.agentHistoryDays) days").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("Claude Code's own cleanupPeriodDays is \(AgentStorage.claudeCleanupDays()) days; it prunes transcripts only when it starts.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Clean up automatically", selection: setting(\.agentStorageSchedule)) {
                    ForEach(AutoUpdateSchedule.allCases) { Text($0 == .off ? "Never" : $0.title).tag($0) }
                }
                Toggle("Also prune history older than \(store.settings.agentHistoryDays) days", isOn: setting(\.agentPruneHistory))
                HStack {
                    if maintenance.isRunning {
                        ProgressView().controlSize(.small)
                        Text(maintenance.currentStep ?? "Cleaning…").font(.caption).foregroundStyle(.secondary)
                    } else if let r = maintenance.lastRun {
                        Text("Last run \(RelativeDateTimeFormatter().localizedString(for: r.finishedAt, relativeTo: Date()))" + (r.summary.map { ": \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clean Up Now") { Task { await maintenance.run() } }.disabled(maintenance.isRunning)
                    if let log = maintenance.lastRun?.logPath, FileManager.default.fileExists(atPath: log) {
                        Button("View Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                    }
                }
            } header: {
                Text("Scheduled cleanup")
            }
        }
        .formStyle(.grouped)
        .onAppear { if model.measured.isEmpty { model.measure() } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(c.kind == .history ? "Delete" : "Clear", role: .destructive) { Task { await model.clean(c) } }
        } message: { c in
            let items = model.removable(c)
            Text("\(items.count) item\(items.count == 1 ? "" : "s"), \(WorktreeService.formatBytes(items.map(\.bytes).reduce(0, +))). This permanently deletes them.")
        }
    }

    private var confirmTitle: String {
        guard let c = confirm else { return "" }
        return c.kind == .history ? "Delete \(c.agent.rawValue) \(c.title.lowercased()) older than \(model.historyDays) days?" : "Clear \(c.agent.rawValue) \(c.title.lowercased())?"
    }

    private func row(_ c: StorageCategory) -> some View {
        let m = model.measured[c.id]
        let removable = model.removable(c)
        let removableBytes = removable.map(\.bytes).reduce(0, +)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.kind == .history ? "clock.arrow.circlepath" : "shippingbox")
                .foregroundStyle(c.kind == .history ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(c.title).font(.system(size: 12.5, weight: .medium))
                    if c.kind == .history {
                        Text("history").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                            .padding(.horizontal, 4).background(Capsule().fill(.orange.opacity(0.15)))
                    }
                }
                Text(c.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if m != nil, removableBytes > 0 {
                    Text(c.kind == .history
                         ? "\(WorktreeService.formatBytes(removableBytes)) older than \(model.historyDays) days (\(removable.count) item\(removable.count == 1 ? "" : "s"))"
                         : "\(WorktreeService.formatBytes(removableBytes)) can be cleared")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(m.map { WorktreeService.formatBytes($0.total) } ?? "…")
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                HStack(spacing: 4) {
                    if model.busy.contains(c.id) { ProgressView().controlSize(.mini) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting(c.roots.filter { FileManager.default.fileExists(atPath: $0.path) }) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                    Button(c.kind == .history ? "Prune" : "Clear") { confirm = c }
                        .disabled(removable.isEmpty || model.busy.contains(c.id))
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
