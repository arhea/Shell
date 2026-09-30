import Foundation

/// Keeps Node on the chosen release track and package managers current.
@MainActor
final class NodeMaintenanceJob: MaintenanceJob {
    let id = "node"
    let title = "Node.js"
    let summary = "Updates Node along your release track, then npm/pnpm/yarn/bun, then runs npm doctor"

    var node: NodeService { .shared }
    var isAvailable: Bool { node.manager != nil || NodeService.managerLikelyInstalled }
    var schedule: AutoUpdateSchedule { SettingsStore.shared.settings.nodeAutoUpdate }

    func perform(_ run: MaintenanceRun) async -> MaintenanceOutcome {
        var out = MaintenanceOutcome()
        let settings = SettingsStore.shared.settings

        run.onStep?("checking Node.js releases")
        await node.refresh()
        guard node.manager != nil else { return MaintenanceOutcome(failedStep: "find n or nvm") }
        guard !node.releases.isEmpty else {
            run.note(node.lastError ?? "no release data")
            return MaintenanceOutcome(failedStep: "fetch Node.js releases")
        }
        run.note("manager: \(node.manager!.title) · active: \(node.activeVersion?.tag ?? "none") · track: \(settings.nodeTrack)")

        // 1. Node itself
        let before = node.activeVersion
        if node.track != .pinned, let target = node.updateAvailable {
            for step in node.switchCommand(to: target.version, from: before) {
                if await run.step(step.title, step.exe, step.args, env: node.toolEnvironment).status != 0 {
                    out.failedStep = step.title
                    return out
                }
            }
            out.changes.append("node \(before?.tag ?? "none") → \(target.version.tag)")

            if settings.nodePruneOldVersions {
                switch node.manager {
                case .n:
                    if let n = node.nBinary { _ = await run.step("n prune", n, ["prune"], env: node.toolEnvironment) }
                case .nvm:
                    if let old = before, let cmd = node.uninstallCommand(old) {
                        _ = await run.step(cmd.title, cmd.exe, cmd.args, env: node.toolEnvironment)
                    }
                case nil:
                    break
                }
            }
            if node.manager == .nvm {
                out.warnings.append("Open tabs keep the previous Node until restarted; new tabs use \(target.version.tag).")
            }
            await node.refresh(fetchReleases: false)
        }

        // 2. Package managers (failures are reported, not fatal)
        for pm in node.packageManagers where settings.nodePackageManagers.contains(pm.name) && pm.isInstalled && pm.isOutdated {
            guard let cmd = node.updateCommand(for: pm) else { continue }
            let r = await run.step(cmd.title, cmd.exe, cmd.args, env: node.toolEnvironment)
            if r.status == 0 {
                out.changes.append("\(pm.name) \(pm.version?.description ?? "?") → \(pm.latest?.description ?? "latest")")
            } else {
                out.warnings.append("Couldn't update \(pm.name) (\(cmd.title))")
            }
        }
        if !out.changes.isEmpty { await node.refresh(fetchReleases: false) }

        // 3. Health: npm doctor (skipping the slow cache check) + Shell's checks
        if let bin = node.nodeBinDirectory {
            let doctor = await run.step("npm doctor", "\(bin)/npm", ["doctor", "ping", "registry", "versions", "environment", "permissions"],
                                        env: node.toolEnvironment)
            for line in doctor.output.components(separatedBy: "\n") where line.contains("not ok") {
                out.warnings.append("npm doctor: " + line.replacingOccurrences(of: "not ok", with: "").trimmingCharacters(in: .whitespaces))
            }
        }
        for issue in node.issues where issue.severity >= .warning {
            out.warnings.append(issue.title)
            run.note("issue: \(issue.title) — \(issue.detail)")
        }
        return out
    }

    func notification(for r: MaintenanceRecord) -> (title: String, body: String)? {
        switch r.outcome {
        case .success where !r.changes.isEmpty:
            let issues = r.warnings.isEmpty ? "" : " · \(r.warnings.count) issue\(r.warnings.count == 1 ? "" : "s") to review"
            return ("Node.js toolchain updated", r.changes.joined(separator: ", ") + issues)
        case .failed:
            return ("Node.js auto-update failed", "\(r.failedStep ?? "update") didn't finish. Shell will retry in an hour — open the log for details.")
        default:
            return nil
        }
    }

    func didFinish() async {}
}
