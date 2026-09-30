import AppKit
import SwiftUI

struct NodePane: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let node = NodeService.shared
    @State private var installMajor: Int?

    var body: some View {
        Form {
            if !node.issues.isEmpty {
                Section("Health") {
                    ForEach(node.issues) { IssueRow(issue: $0, node: node) }
                }
            }

            managerSection

            if node.manager != nil {
                Section("Node.js") {
                    LabeledContent("Active") {
                        HStack(spacing: 6) {
                            Text(node.activeVersion?.tag ?? "none").font(.body.monospacedDigit())
                            if let v = node.activeVersion, let line = node.line(for: v) {
                                Badge(text: line.codename.map { "\($0) · \(line.status())" } ?? line.status(),
                                      color: line.status() == "End of life" ? .red : line.status() == "Current" ? .blue : .green)
                            }
                        }
                    }
                    Picker("Keep up to date with", selection: setting(\.nodeTrack)) {
                        Text("Latest LTS\(node.latestLTS.map { " (\($0.version.tag))" } ?? "")").tag("lts")
                        Text("Latest Current\(node.latestCurrent.map { " (\($0.version.tag))" } ?? "")").tag("current")
                        ForEach(node.supportedLines, id: \.line.major) { item in
                            Text("Node \(item.line.major)\(item.line.codename.map { " \($0)" } ?? "") (\(item.latest.version.tag))").tag("\(item.line.major)")
                        }
                        Text("Pinned — don't change versions").tag("pinned")
                    }
                    if let up = node.updateAvailable {
                        HStack {
                            Text("Node \(up.version.tag) is available\(up.security ? " (security release)" : "")")
                                .foregroundStyle(up.security ? .red : .primary)
                            Spacer()
                            Button("Update Now") { Task { await node.updateNode() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(node.busy != nil)
                        }
                    }
                    Toggle("Remove old versions after updating", isOn: setting(\.nodePruneOldVersions))
                }

                Section("Installed versions") {
                    ForEach(node.installed, id: \.self) { v in
                        HStack {
                            Text(v.tag).font(.body.monospacedDigit())
                            if v == node.activeVersion { Badge(text: "active", color: .accentColor) }
                            if let line = node.line(for: v), !line.isSupported() { Badge(text: "EOL", color: .red) }
                            Spacer()
                            if v != node.activeVersion {
                                Button("Use") { Task { await node.use(v) } }.disabled(node.busy != nil)
                                Button(role: .destructive) { Task { await node.uninstall(v) } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .disabled(node.busy != nil)
                            }
                        }
                    }
                    HStack {
                        Picker("Install another", selection: $installMajor) {
                            Text("Choose a version…").tag(Int?.none)
                            ForEach(node.supportedLines, id: \.line.major) { item in
                                Text("\(item.latest.version.tag) — Node \(item.line.major) \(item.line.status())").tag(Int?.some(item.line.major))
                            }
                        }
                        Button("Install & Use") {
                            if let m = installMajor, let r = node.supportedLines.first(where: { $0.line.major == m }) {
                                Task { await node.use(r.latest.version) }
                            }
                        }
                        .disabled(installMajor == nil || node.busy != nil)
                    }
                    if node.manager == .nvm {
                        Text("With nvm, switching sets the default for new tabs. Idle tabs are restarted to pick it up.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Package managers") {
                    ForEach(node.packageManagers) { pm in PackageManagerRow(pm: pm, node: node) }
                    Text("“Keep updated” managers are upgraded by auto-update and the Update buttons. pnpm and yarn from corepack are updated through corepack; otherwise through npm.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Automatic updates") {
                    AutoUpdateBar(maintenance: .node, schedule: \.nodeAutoUpdate)
                    Text("Follows your track above, updates the package managers you keep updated, then runs npm doctor. Runs in the background while Shell is open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let busy = node.busy {
                Section { HStack { ProgressView().controlSize(.small); Text(busy) } }
            }
            if let err = node.lastError {
                Section {
                    HStack {
                        Text(err).foregroundStyle(.red).font(.caption)
                        Spacer()
                        if let log = node.lastActionLog {
                            Button("View Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await node.refresh() }
        .toolbar {
            ToolbarItem {
                Button { Task { await node.refresh() } } label: {
                    if node.isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Refresh")
            }
        }
    }

    @ViewBuilder private var managerSection: some View {
        Section("Version manager") {
            if node.nBinary != nil && node.nvmVersion != nil {
                Picker("Manage Node with", selection: setting(\.nodeManager)) {
                    ForEach(NodeManagerKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            switch node.manager {
            case .n:
                LabeledContent("n", value: "\(node.nVersion ?? "?")\(node.nFromHomebrew ? " (Homebrew)" : "")")
                LabeledContent("Install prefix", value: node.nPrefix ?? "/usr/local (N_PREFIX not set)")
                Button("Update n") { Task { await node.updateManager() } }
            case .nvm:
                LabeledContent("nvm", value: node.nvmVersion ?? "?")
                LabeledContent("Directory", value: node.nvmDir ?? "~/.nvm")
                Button("Update nvm") { Task { await node.updateManager() } }
            case nil:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Install a version manager to get Node.js and switch versions.")
                    HStack(alignment: .top, spacing: 12) {
                        ManagerChoice(title: "n", badge: "Recommended",
                                      detail: "One global Node for all tabs. Tiny and fast; adds nothing to shell startup. Installs into ~/.n (no sudo).") {
                            node.installN()
                        }
                        ManagerChoice(title: "nvm", badge: "Most popular",
                                      detail: "Per-shell versions with `nvm use` and .nvmrc files. Loaded into every shell, which adds ~0.2–0.5 s to new tabs.") {
                            Task { await node.installNvm() }
                        }
                    }
                    Text("Installers run in a new tab so you can see what they do.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ManagerChoice: View {
    let title: String
    let badge: String
    let detail: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline.monospaced())
                Badge(text: badge, color: .accentColor)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Install \(title)", action: action)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

private struct IssueRow: View {
    let issue: NodeIssue
    let node: NodeService

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.system(size: 13, weight: .medium))
                if !issue.detail.isEmpty { Text(issue.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let fix = issue.fix {
                Button(fixTitle(fix)) { apply(fix) }.disabled(node.busy != nil)
            }
        }
    }

    private var icon: String {
        switch issue.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch issue.severity {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private func fixTitle(_ fix: NodeIssue.Fix) -> String {
        switch fix {
        case .update: "Update"
        case .prune: "Prune"
        case .setNPrefix: "Fix"
        case .useManagedNode: "Fix"
        case .installPackageManager(let name): "Reinstall \(name)"
        case .updatePackageManagers: "Update All"
        }
    }

    private func apply(_ fix: NodeIssue.Fix) {
        switch fix {
        case .update: Task { await node.updateNode() }
        case .prune: Task { await node.prune() }
        case .setNPrefix:
            node.ensureNPrefixInZshrc()
            Task { await node.refresh(fetchReleases: false) }
        case .useManagedNode: break
        case .installPackageManager(let name): node.installPackageManager(name)
        case .updatePackageManagers: Task { await node.updateAllPackageManagers() }
        }
    }
}

private struct PackageManagerRow: View {
    let pm: PackageManagerStatus
    let node: NodeService

    var body: some View {
        let wanted = SettingsStore.shared.settings.nodePackageManagers.contains(pm.name)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pm.name).font(.system(size: 13, weight: .medium, design: .monospaced))
                    if let src = pm.source { Text(src.rawValue).font(.caption).foregroundStyle(.secondary) }
                }
                if pm.isInstalled {
                    HStack(spacing: 4) {
                        Text(pm.version?.description ?? "?").font(.caption.monospacedDigit())
                        if pm.isOutdated, let latest = pm.latest {
                            Text("→ \(latest.description)").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text("Not installed\(pm.latest.map { " · latest \($0.description)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if pm.isInstalled {
                Toggle("Keep updated", isOn: Binding(
                    get: { wanted },
                    set: { on in
                        var list = SettingsStore.shared.settings.nodePackageManagers
                        if on { if !list.contains(pm.name) { list.append(pm.name) } } else { list.removeAll { $0 == pm.name } }
                        SettingsStore.shared.settings.nodePackageManagers = list
                        node.computeIssues()
                    }))
                    .toggleStyle(.checkbox)
                if pm.isOutdated {
                    Button("Update") { Task { await node.updatePackageManager(pm) } }.disabled(node.busy != nil)
                }
            } else if pm.name != "npm" {
                Button("Install") { node.installPackageManager(pm.name) }.disabled(node.busy != nil || node.manager == nil)
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

/// Schedule picker, status, Run Now/Stop and log for a `ScheduledMaintenance`.
struct AutoUpdateBar: View {
    let maintenance: ScheduledMaintenance
    let schedule: WritableKeyPath<AppSettings, AutoUpdateSchedule>

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.secondary)
            Text("Auto-update").font(.system(size: 12, weight: .medium))
            Picker("Auto-update", selection: setting(schedule)) {
                ForEach(AutoUpdateSchedule.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(maintenance.job.summary)

            status
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if maintenance.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop") { maintenance.cancel() }
            } else {
                Button("Run Now") { Task { await maintenance.run() } }
                    .disabled(!maintenance.job.isAvailable)
            }
            if let log = maintenance.lastRun?.logPath, FileManager.default.fileExists(atPath: log) {
                Button("View Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if maintenance.isRunning {
            Text("Running \(maintenance.currentStep ?? "")…")
        } else if let r = maintenance.lastRun {
            let when = RelativeDateTimeFormatter().localizedString(for: r.finishedAt, relativeTo: Date())
            let issues = r.warnings.isEmpty ? "" : " · \(r.warnings.count) issue\(r.warnings.count == 1 ? "" : "s")"
            switch r.outcome {
            case .success:
                let what = r.changes.isEmpty ? "everything up to date" : "\(r.changes.count) update\(r.changes.count == 1 ? "" : "s")"
                Text("Last run \(when): \(what)\(issues)\(nextText)")
                    .help(r.changes.joined(separator: "\n") + (r.warnings.isEmpty ? "" : "\n\n" + r.warnings.joined(separator: "\n")))
            case .failed:
                Text("Last run \(when): \(r.failedStep ?? "update") failed\(nextText)").foregroundStyle(.orange)
            case .cancelled:
                Text("Last run \(when): stopped\(nextText)")
            }
        } else if maintenance.schedule != .off {
            Text("First run within a few minutes")
        } else {
            Text("Off")
        }
    }

    private var nextText: String {
        guard let next = maintenance.nextRun, maintenance.schedule != .off else { return "" }
        if next <= Date() { return " · next: soon" }
        return " · next \(RelativeDateTimeFormatter().localizedString(for: next, relativeTo: Date()))"
    }
}
