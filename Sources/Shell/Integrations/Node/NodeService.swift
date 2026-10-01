import Foundation
import Observation

/// A dotted numeric version (1.2.3); tolerates a leading "v".
struct SemVer: Comparable, Hashable, CustomStringConvertible, Codable {
    var major: Int, minor: Int, patch: Int

    init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let parts = core.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        self.major = major
        minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        patch = parts.count > 2 ? (parts[2] ?? 0) : 0
    }

    static func < (a: SemVer, b: SemVer) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
    var description: String { "\(major).\(minor).\(patch)" }
    var tag: String { "v\(description)" }
}

enum NodeManagerKind: String, Codable, CaseIterable, Identifiable {
    case n, nvm
    var id: String { rawValue }
    var title: String { self == .n ? "n" : "nvm" }
}

/// Which Node release auto-update follows: "lts", "current", a major ("22"), or "pinned".
enum NodeTrack: Hashable {
    case lts, current, major(Int), pinned

    init(_ raw: String) {
        switch raw {
        case "current": self = .current
        case "pinned": self = .pinned
        default: self = Int(raw).map { .major($0) } ?? .lts
        }
    }

    var raw: String {
        switch self {
        case .lts: "lts"
        case .current: "current"
        case .major(let m): "\(m)"
        case .pinned: "pinned"
        }
    }
}

struct NodeRelease: Hashable {
    var version: SemVer
    var lts: String?
    var security: Bool
    var date: String
    var npm: String?
}

struct NodeLine: Hashable {
    var major: Int
    var codename: String?
    var start: Date?
    var ltsStart: Date?
    var maintenanceStart: Date?
    var end: Date?

    func status(on date: Date = Date()) -> String {
        if let end, date >= end { return "End of life" }
        if let m = maintenanceStart, date >= m { return "Maintenance LTS" }
        if let l = ltsStart, date >= l { return "Active LTS" }
        return "Current"
    }

    func isSupported(on date: Date = Date()) -> Bool { end.map { date < $0 } ?? true }
}

struct PackageManagerStatus: Identifiable, Hashable {
    enum Source: String { case bundled = "bundled with Node", corepack = "corepack", npm = "npm global", homebrew = "Homebrew", standalone = "standalone" }
    var name: String
    var path: String?
    var version: SemVer?
    var latest: SemVer?
    var source: Source?
    var id: String { name }
    var isInstalled: Bool { path != nil }
    var isOutdated: Bool {
        guard let version, let latest else { return false }
        return version < latest
    }
}

struct NodeIssue: Identifiable, Hashable {
    enum Severity: Int, Comparable {
        case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    enum Fix: Hashable { case update, prune, setNPrefix, useManagedNode, installPackageManager(String), updatePackageManagers }

    var severity: Severity
    var title: String
    var detail: String
    var fix: Fix?
    var id: String { title }
}

/// Everything about the user's Node.js toolchain: version manager (n or nvm),
/// installed and available Node versions, package managers, and health.
@MainActor
@Observable
final class NodeService {
    static let shared = NodeService()
    static let packageManagerNames = ["npm", "pnpm", "yarn", "bun"]

    // Login-shell environment (the app itself is launched without the user's PATH).
    private(set) var shellPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    private(set) var nPrefix: String?
    private(set) var nvmDir: String?
    private(set) var nodeOnPath: [String] = []

    private(set) var nBinary: String?
    private(set) var nVersion: String?
    private(set) var nFromHomebrew = false
    private(set) var nvmVersion: String?
    private(set) var otherManagers: [String] = []

    private(set) var activeVersion: SemVer?
    private(set) var installed: [SemVer] = []
    private(set) var releases: [NodeRelease] = []
    private(set) var lines: [Int: NodeLine] = [:]
    private(set) var packageManagers: [PackageManagerStatus] = []
    private(set) var issues: [NodeIssue] = []

    private(set) var isLoading = false
    private(set) var busy: String?
    private(set) var lastError: String?
    private(set) var lastActionLog: String?
    private var releasesFetchedAt: Date?

    /// Where NodeService looks and how it reaches the outside world.
    /// Injectable for unit tests; the defaults are the user's real setup.
    struct System {
        var zsh = "/bin/zsh"
        var home = NSHomeDirectory()
        /// Standard n locations, checked when n isn't on PATH.
        var nLocations = ["/opt/homebrew/bin/n", "/usr/local/bin/n"]
        /// n's install prefix when N_PREFIX isn't set.
        var defaultNPrefix = "/usr/local"
        var fetch: @Sendable (String) async -> Data? = { await NodeService.fetch($0) }
        var zshrcURL: @MainActor () -> URL = { ZshService.shared.zshrcURL }
        var terminal: @MainActor (_ command: String, _ title: String) -> Void = { AppDelegate.shared.runInTerminal($0, title: $1) }
        var brew: @MainActor () -> BrewService = { BrewService.shared }
    }

    @ObservationIgnored private let system: System
    private var home: String { system.home }

    init(system: System = System()) { self.system = system }

    // MARK: Derived

    /// The manager Shell drives: the user's choice when both exist, else whichever is installed.
    var manager: NodeManagerKind? {
        let hasN = nBinary != nil, hasNvm = nvmVersion != nil
        switch (hasN, hasNvm) {
        case (true, true): return SettingsStore.shared.settings.nodeManager
        case (true, false): return .n
        case (false, true): return .nvm
        default: return nil
        }
    }

    var track: NodeTrack { NodeTrack(SettingsStore.shared.settings.nodeTrack) }

    var nodeBinDirectory: String? {
        switch manager {
        case .n: return "\(nPrefix ?? system.defaultNPrefix)/bin"
        case .nvm: return activeVersion.map { "\(nvmDir ?? home + "/.nvm")/versions/node/\($0.tag)/bin" }
        case nil: return nodeOnPath.first.map { ($0 as NSString).deletingLastPathComponent }
        }
    }

    /// PATH for running node/npm/pnpm with the managed Node first.
    var toolPath: String { [nodeBinDirectory, shellPath].compactMap { $0 }.joined(separator: ":") }

    var toolEnvironment: [String: String] {
        var env = ["PATH": toolPath, "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0", "NO_UPDATE_NOTIFIER": "1", "npm_config_fund": "false",
                   "npm_config_audit": "false", "npm_config_update_notifier": "false"]
        if let nPrefix { env["N_PREFIX"] = nPrefix }
        if let nvmDir { env["NVM_DIR"] = nvmDir }
        return env
    }

    func line(for v: SemVer) -> NodeLine? { lines[v.major] }

    var latestLTS: NodeRelease? { releases.first { $0.lts != nil } }
    var latestCurrent: NodeRelease? { releases.first }

    /// The release the chosen track points at.
    func target(for track: NodeTrack) -> NodeRelease? {
        switch track {
        case .lts: return latestLTS
        case .current: return latestCurrent
        case .major(let m): return releases.first { $0.version.major == m }
        case .pinned: return nil
        }
    }

    /// The release to move to for the current track. LTS/Current only ever
    /// move forward; an explicit major pin also switches across majors.
    var updateAvailable: NodeRelease? {
        guard let target = target(for: track) else { return nil }
        guard let active = activeVersion else { return target }
        if case .major(let m) = track, active.major != m { return target }
        return active < target.version ? target : nil
    }

    /// Latest release of each supported major line, newest first.
    var supportedLines: [(line: NodeLine, latest: NodeRelease)] {
        let majors = Set(releases.map(\.version.major))
        return majors.sorted(by: >).compactMap { m -> (NodeLine, NodeRelease)? in
            guard let latest = releases.first(where: { $0.version.major == m }) else { return nil }
            let line = lines[m] ?? NodeLine(major: m)
            guard line.isSupported() else { return nil }
            return (line, latest)
        }
    }

    var debugSummary: String {
        "manager=\(manager?.title ?? "none") n=\(nVersion ?? "-") nvm=\(nvmVersion ?? "-") prefix=\(nPrefix ?? "-") active=\(activeVersion?.tag ?? "-") " +
            "installed=\(installed.count) releases=\(releases.count) lts=\(latestLTS?.version.tag ?? "-") current=\(latestCurrent?.version.tag ?? "-") " +
            "update=\(updateAvailable?.version.tag ?? "-") pms=[\(packageManagers.map { "\($0.name):\($0.version?.description ?? "-")/\($0.latest?.description ?? "-")/\($0.source?.rawValue ?? "-")" }.joined(separator: ", "))] " +
            "issues=[\(issues.map { "\($0.severity):\($0.title)" }.joined(separator: " | "))] nodeOnPath=\(nodeOnPath)"
    }

    /// Cheap check (no shell) used before the first full refresh.
    static var managerLikelyInstalled: Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/n", "/usr/local/bin/n", "\(home)/.n/bin/n"].contains { fm.isExecutableFile(atPath: $0) }
            || fm.fileExists(atPath: "\(home)/.nvm/nvm.sh")
    }

    // MARK: Refresh

    func refresh(fetchReleases: Bool = true) async {
        isLoading = true
        defer { isLoading = false }
        await captureShellEnvironment()
        await detectManagers()
        await detectVersions()
        if fetchReleases, releasesFetchedAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            await loadReleases()
        }
        await detectPackageManagers()
        computeIssues()
    }

    /// Reads PATH, N_PREFIX and NVM_DIR from an interactive login zsh, the
    /// way a new terminal tab would see them.
    private func captureShellEnvironment() async {
        let script = #"print -r -- "__SHELLAPP_BEGIN__"; print -r -- "PATH=$PATH"; print -r -- "N_PREFIX=${N_PREFIX:-}"; print -r -- "NVM_DIR=${NVM_DIR:-}"; print -r -- "NODE=${(j.:.)${(f)$(whence -ap node 2>/dev/null)}}"; print -r -- "__SHELLAPP_END__""#
        let r = await ProcessRunner.run(system.zsh, ["-lic", script], environment: ["TERM": "dumb"])
        let text = String(decoding: r.stdout, as: UTF8.self)
        guard let begin = text.range(of: "__SHELLAPP_BEGIN__"), let end = text.range(of: "__SHELLAPP_END__") else { return }
        for line in text[begin.upperBound..<end.lowerBound].split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 || (parts.count == 1 && line.hasSuffix("=")) else { continue }
            let value = parts.count == 2 ? parts[1] : ""
            switch parts[0] {
            case "PATH" where !value.isEmpty: shellPath = value
            case "N_PREFIX": nPrefix = value.isEmpty ? nil : value
            case "NVM_DIR": nvmDir = value.isEmpty ? nil : value
            case "NODE": nodeOnPath = value.split(separator: ":").map(String.init)
            default: break
            }
        }
    }

    private func which(_ name: String) -> String? {
        for dir in shellPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func detectManagers() async {
        let fm = FileManager.default
        nBinary = which("n") ?? (system.nLocations + ["\(nPrefix ?? home + "/.n")/bin/n"]).first { fm.isExecutableFile(atPath: $0) }
        nFromHomebrew = nBinary.map { ($0 as NSString).resolvingSymlinksInPath.contains("/Cellar/") || $0.hasPrefix("/opt/homebrew/") } ?? false
        if let n = nBinary {
            let r = await ProcessRunner.run(n, ["--version"])
            nVersion = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            nVersion = nil
        }

        let dir = nvmDir ?? "\(home)/.nvm"
        if fm.fileExists(atPath: "\(dir)/nvm.sh") {
            if nvmDir == nil { nvmDir = dir }
            let r = await ProcessRunner.run(system.zsh, ["-c", "source \"$NVM_DIR/nvm.sh\" --no-use && nvm --version"], environment: ["NVM_DIR": dir])
            nvmVersion = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if nvmVersion?.isEmpty ?? true { nvmVersion = "?" }
        } else {
            nvmVersion = nil
        }

        var others: [String] = []
        for tool in ["fnm", "volta", "mise", "asdf", "nodenv"] where which(tool) != nil { others.append(tool) }
        if fm.fileExists(atPath: "/opt/homebrew/opt/node/bin/node") || fm.fileExists(atPath: "/usr/local/opt/node/bin/node") {
            others.append("Homebrew node")
        }
        otherManagers = others
    }

    private func detectVersions() async {
        let fm = FileManager.default
        switch manager {
        case .n:
            let prefix = nPrefix ?? system.defaultNPrefix
            let cache = "\(prefix)/n/versions/node"
            installed = ((try? fm.contentsOfDirectory(atPath: cache)) ?? []).compactMap(SemVer.init).sorted(by: >)
            activeVersion = await nodeVersion(at: "\(prefix)/bin/node")
        case .nvm:
            let dir = nvmDir ?? "\(home)/.nvm"
            installed = ((try? fm.contentsOfDirectory(atPath: "\(dir)/versions/node")) ?? []).compactMap(SemVer.init).sorted(by: >)
            let r = await ProcessRunner.run(system.zsh, ["-c", "source \"$NVM_DIR/nvm.sh\" --no-use && nvm version default"], environment: ["NVM_DIR": dir])
            activeVersion = SemVer(String(decoding: r.stdout, as: UTF8.self))
        case nil:
            installed = []
            if let path = nodeOnPath.first { activeVersion = await nodeVersion(at: path) } else { activeVersion = nil }
        }
    }

    private func nodeVersion(at path: String) async -> SemVer? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let r = await ProcessRunner.run(path, ["--version"])
        return SemVer(String(decoding: r.stdout, as: UTF8.self))
    }

    private func loadReleases() async {
        // Download concurrently (Data is Sendable), then decode here.
        let fetch = system.fetch
        async let indexData = fetch("https://nodejs.org/dist/index.json")
        async let scheduleData = fetch("https://raw.githubusercontent.com/nodejs/Release/main/schedule.json")
        let index = await indexData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let schedule = await scheduleData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        if let list = index as? [[String: Any]] {
            releases = list.compactMap { item in
                guard let v = (item["version"] as? String).flatMap(SemVer.init) else { return nil }
                return NodeRelease(version: v, lts: item["lts"] as? String, security: item["security"] as? Bool ?? false,
                                   date: item["date"] as? String ?? "", npm: item["npm"] as? String)
            }
            releasesFetchedAt = Date()
            lastError = nil
        } else {
            lastError = "Couldn't reach nodejs.org to check for releases."
        }
        if let sched = schedule as? [String: [String: Any]] {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            var result: [Int: NodeLine] = [:]
            for (key, value) in sched {
                guard let m = Int(key.dropFirst()) else { continue }
                result[m] = NodeLine(major: m, codename: value["codename"] as? String,
                                     start: (value["start"] as? String).flatMap(f.date),
                                     ltsStart: (value["lts"] as? String).flatMap(f.date),
                                     maintenanceStart: (value["maintenance"] as? String).flatMap(f.date),
                                     end: (value["end"] as? String).flatMap(f.date))
            }
            lines = result
        }
    }

    private nonisolated static func fetch(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.setValue("Shell.app", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func latestFromRegistry(_ package: String) async -> SemVer? {
        let obj = await system.fetch("https://registry.npmjs.org/\(package)/latest").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return (obj?["version"] as? String).flatMap(SemVer.init)
    }

    private func detectPackageManagers() async {
        var result: [PackageManagerStatus] = []
        let env = toolEnvironment
        let bin = nodeBinDirectory
        for name in Self.packageManagerNames {
            var s = PackageManagerStatus(name: name)
            let candidates = [bin.map { "\($0)/\(name)" }, which(name)].compactMap { $0 }
            s.path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            if let path = s.path {
                let resolved = (path as NSString).resolvingSymlinksInPath
                if name == "npm" { s.source = .bundled }
                else if resolved.contains("corepack") { s.source = .corepack }
                else if resolved.contains("/Cellar/") { s.source = .homebrew }
                else if resolved.contains("node_modules") { s.source = .npm }
                else { s.source = .standalone }
                let r = await ProcessRunner.run(path, ["--version"], environment: env, timeout: 20)
                s.version = SemVer(String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "")
            }
            let registryName = (name == "yarn" && (s.version?.major ?? 1) >= 2) ? "@yarnpkg/cli-dist" : name
            s.latest = await latestFromRegistry(registryName)
            result.append(s)
        }
        packageManagers = result
    }

    // MARK: Health

    func computeIssues() {
        var list: [NodeIssue] = []
        let now = Date()

        if manager == nil {
            if nodeOnPath.isEmpty {
                list.append(NodeIssue(severity: .info, title: "Node.js isn't installed",
                                      detail: "Install n or nvm below to get Node and switch versions easily."))
            } else {
                list.append(NodeIssue(severity: .warning, title: "Node isn't managed by a version manager",
                                      detail: "node comes from \(nodeOnPath[0]). Install n or nvm to switch versions and keep Node updated."))
            }
        }
        if nBinary != nil && nvmVersion != nil {
            list.append(NodeIssue(severity: .warning, title: "Both n and nvm are installed",
                                  detail: "They fight over which node runs. Shell manages \(manager?.title ?? "n"); consider removing the other."))
        }
        let conflicting = otherManagers.filter { $0 != "Homebrew node" }
        if manager != nil, !conflicting.isEmpty {
            list.append(NodeIssue(severity: .warning, title: "Other Node managers found: \(conflicting.joined(separator: ", "))",
                                  detail: "Multiple managers can shadow each other on PATH."))
        }
        if let bin = nodeBinDirectory, let first = nodeOnPath.first, manager != nil,
           (first as NSString).deletingLastPathComponent != bin {
            list.append(NodeIssue(severity: .error, title: "Another node comes first on PATH",
                                  detail: "New shells run \(first) instead of \(bin)/node. Put the \(manager!.title) directory earlier in PATH in ~/.zshrc.",
                                  fix: nil))
        }
        if nodeOnPath.count > 1, manager != nil {
            let extras = nodeOnPath.dropFirst().joined(separator: ", ")
            list.append(NodeIssue(severity: .info, title: "Other node binaries on PATH",
                                  detail: "\(extras) \(nodeOnPath.count == 2 ? "is" : "are") shadowed by \(nodeOnPath[0]) today, but will take over if PATH order changes. Remove \(nodeOnPath.count == 2 ? "it" : "them") if unused."))
        }
        if manager == .n, nPrefix == nil, !FileManager.default.isWritableFile(atPath: "/usr/local/bin") {
            list.append(NodeIssue(severity: .warning, title: "n needs sudo without N_PREFIX",
                                  detail: "Set N_PREFIX=$HOME/.n so n can install Node without admin rights (and in the background).",
                                  fix: .setNPrefix))
        }

        if let active = activeVersion {
            if let line = line(for: active) {
                let status = line.status(on: now)
                if status == "End of life" {
                    list.append(NodeIssue(severity: .error, title: "Node \(active.major) is end-of-life",
                                          detail: "It no longer gets security fixes. Switch to Node \(latestLTS?.version.major ?? 24) LTS.", fix: nil))
                } else if status == "Current", active.major % 2 == 1, let end = line.end, end.timeIntervalSince(now) < 90 * 86400 {
                    list.append(NodeIssue(severity: .warning, title: "Node \(active.major) support ends soon",
                                          detail: "Odd-numbered releases are short-lived. Consider the LTS line."))
                }
            }
            let newerSecurity = releases.first { $0.version.major == active.major && $0.version > active && $0.security }
            if let sec = newerSecurity {
                list.append(NodeIssue(severity: .error, title: "Security update available: Node \(sec.version.tag)",
                                      detail: "You're on \(active.tag), which has known vulnerabilities.", fix: .update))
            } else if let up = updateAvailable {
                list.append(NodeIssue(severity: .info, title: "Node \(up.version.tag) is available",
                                      detail: "You're on \(active.tag).", fix: .update))
            }
        }

        if manager == .n, installed.count > 5 {
            let size = cacheSize()
            list.append(NodeIssue(severity: .info, title: "\(installed.count) cached Node versions",
                                  detail: "About \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) of old versions. Prune keeps only the active one.",
                                  fix: .prune))
        }

        let corepackPMs = packageManagers.filter { $0.source == .corepack }.map(\.name)
        if !corepackPMs.isEmpty, let active = activeVersion, active.major >= 25 {
            list.append(NodeIssue(severity: .warning, title: "Corepack isn't bundled with Node \(active.major)",
                                  detail: "\(corepackPMs.joined(separator: " and ")) came from corepack. Reinstall with npm so they keep working after updates.",
                                  fix: .installPackageManager(corepackPMs[0])))
        }
        let wanted = SettingsStore.shared.settings.nodePackageManagers
        let outdated = packageManagers.filter { wanted.contains($0.name) && $0.isOutdated }
        if !outdated.isEmpty {
            list.append(NodeIssue(severity: .info, title: "Package manager updates: " + outdated.map { "\($0.name) \($0.latest!.description)" }.joined(separator: ", "),
                                  detail: "", fix: .updatePackageManagers))
        }
        if let npmPrefix = nodeBinDirectory.map({ ($0 as NSString).deletingLastPathComponent + "/lib/node_modules" }),
           manager != nil, FileManager.default.fileExists(atPath: npmPrefix), !FileManager.default.isWritableFile(atPath: npmPrefix) {
            list.append(NodeIssue(severity: .warning, title: "Global npm packages need sudo",
                                  detail: "\(npmPrefix) isn't writable, so `npm install -g` and background updates will fail."))
        }
        issues = list.sorted { $0.severity > $1.severity }
    }

    private func cacheSize() -> Int64 {
        guard let prefix = nPrefix else { return 0 }
        let url = URL(fileURLWithPath: "\(prefix)/n/versions/node")
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
            }
        }
        return total
    }

    // MARK: Commands (shared by the UI and the background job)

    /// Installs (if needed) and activates a Node version.
    func switchCommand(to version: SemVer, from current: SemVer?) -> [(title: String, exe: String, args: [String])] {
        switch manager {
        case .n:
            guard let n = nBinary else { return [] }
            return [("n \(version.description)", n, [version.description])]
        case .nvm:
            var cmd = "nvm install \(version.description)"
            if let current, current != version { cmd += " --reinstall-packages-from=\(current.description)" }
            cmd += " && nvm alias default \(version.description)"
            return [(cmd, system.zsh, ["-c", "source \"$NVM_DIR/nvm.sh\" --no-use && \(cmd)"])]
        case nil:
            return []
        }
    }

    func uninstallCommand(_ version: SemVer) -> (title: String, exe: String, args: [String])? {
        switch manager {
        case .n: nBinary.map { ("n rm \(version.description)", $0, ["rm", version.description]) }
        case .nvm: ("nvm uninstall \(version.description)", system.zsh, ["-c", "source \"$NVM_DIR/nvm.sh\" --no-use && nvm uninstall \(version.description)"])
        case nil: nil
        }
    }

    /// Command that brings a package manager to its latest version.
    func updateCommand(for pm: PackageManagerStatus) -> (title: String, exe: String, args: [String])? {
        guard let bin = nodeBinDirectory else { return nil }
        let npm = "\(bin)/npm"
        switch (pm.name, pm.source) {
        case ("npm", _):
            return ("npm install -g npm@latest", npm, ["install", "-g", "npm@latest"])
        case ("bun", .homebrew?):
            return system.brew().brewPath.map { ("brew upgrade bun", $0, ["upgrade", "oven-sh/bun/bun"]) }
        case ("bun", _):
            return pm.path.map { ("bun upgrade", $0, ["upgrade"]) }
        case (let name, .corepack?) where (activeVersion?.major ?? 0) < 25:
            let spec = name == "yarn" && (pm.version?.major ?? 1) >= 2 ? "yarn@stable" : "\(name)@latest"
            return ("corepack install -g \(spec)", "\(bin)/corepack", ["install", "-g", spec])
        case (let name, _):
            let spec = name == "yarn" && (pm.version?.major ?? 1) >= 2 ? "@yarnpkg/cli-dist@latest" : "\(name)@latest"
            return ("npm install -g \(spec)", npm, ["install", "-g", spec])
        }
    }

    // MARK: Interactive actions (background, with a log)

    private func perform(_ label: String, _ steps: [(title: String, exe: String, args: [String])]) async {
        guard busy == nil, !steps.isEmpty else { return }
        busy = label
        defer { busy = nil }
        let run = MaintenanceRun(jobID: "node-action")
        lastActionLog = run.logURL.path
        for s in steps {
            let r = await run.step(s.title, s.exe, s.args, env: toolEnvironment)
            if r.status != 0 {
                lastError = "\(s.title) failed — see the log."
                run.close()
                await refresh(fetchReleases: false)
                return
            }
        }
        run.close()
        lastError = nil
        await refresh(fetchReleases: false)
    }

    func use(_ version: SemVer) async {
        await perform("Switching to Node \(version.tag)…", switchCommand(to: version, from: activeVersion))
        if manager == .nvm { ZshService.shared.reloadOpenShells() }
    }

    func uninstall(_ version: SemVer) async {
        guard let cmd = uninstallCommand(version) else { return }
        await perform("Removing Node \(version.tag)…", [cmd])
    }

    func updateNode() async {
        guard let target = updateAvailable ?? target(for: track) else { return }
        await use(target.version)
    }

    func prune() async {
        guard manager == .n, let n = nBinary else { return }
        await perform("Removing old Node versions…", [("n prune", n, ["prune"])])
    }

    func updatePackageManager(_ pm: PackageManagerStatus) async {
        guard let cmd = updateCommand(for: pm) else { return }
        await perform("Updating \(pm.name)…", [cmd])
    }

    func updateAllPackageManagers() async {
        let wanted = SettingsStore.shared.settings.nodePackageManagers
        let steps = packageManagers.filter { wanted.contains($0.name) && $0.isInstalled && $0.isOutdated }.compactMap(updateCommand(for:))
        await perform("Updating package managers…", steps)
    }

    /// Installs pnpm/yarn with npm (works on every Node version); bun via Homebrew or its installer.
    func installPackageManager(_ name: String) {
        var wanted = SettingsStore.shared.settings.nodePackageManagers
        if !wanted.contains(name) { wanted.append(name) }
        SettingsStore.shared.settings.nodePackageManagers = wanted
        if name == "bun" {
            let cmd = system.brew().isInstalled ? "brew install oven-sh/bun/bun" : #"curl -fsSL https://bun.sh/install | bash"#
            system.terminal(cmd, "Install bun")
            return
        }
        guard let bin = nodeBinDirectory else { return }
        let spec = name == "yarn" ? "yarn@latest" : "\(name)@latest"
        Task { await perform("Installing \(name)…", [("npm install -g \(spec)", "\(bin)/npm", ["install", "-g", spec])]) }
    }

    // MARK: Installing / updating the version manager (visible, may need input)

    static let nInstallViaBrew = "brew install n"
    static let nPrefixSnippet = """
    # Added by Shell.app: n (Node version manager) installs into your home folder
    export N_PREFIX="$HOME/.n"
    export PATH="$N_PREFIX/bin:$PATH"
    """

    func installN() {
        ensureNPrefixInZshrc()
        let install = system.brew().isInstalled
            ? "brew install n && N_PREFIX=\"$HOME/.n\" n lts"
            : #"curl -fsSL https://raw.githubusercontent.com/tj/n/master/bin/n | N_PREFIX="$HOME/.n" bash -s lts && N_PREFIX="$HOME/.n" "$HOME/.n/bin/npm" install -g n"#
        system.terminal(install, "Install n")
    }

    func installNvm() async {
        let tag = await latestNvmTag() ?? "v0.40.3"
        let cmd = #"curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/\#(tag)/install.sh | bash && export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh" && nvm install --lts && nvm alias default 'lts/*'"#
        system.terminal(cmd, "Install nvm")
    }

    func updateManager() async {
        switch manager {
        case .n:
            if nFromHomebrew {
                system.terminal("brew upgrade n", "Update n")
            } else if let bin = nodeBinDirectory {
                await perform("Updating n…", [("npm install -g n@latest", "\(bin)/npm", ["install", "-g", "n@latest"])])
            }
        case .nvm:
            let tag = await latestNvmTag() ?? "v0.40.3"
            system.terminal("curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/\(tag)/install.sh | bash", "Update nvm")
        case nil:
            break
        }
    }

    private func latestNvmTag() async -> String? {
        let obj = await system.fetch("https://api.github.com/repos/nvm-sh/nvm/releases/latest").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return obj?["tag_name"] as? String
    }

    /// Adds N_PREFIX to ~/.zshrc (once, with a backup) so n works without sudo.
    func ensureNPrefixInZshrc() {
        let url = system.zshrcURL()
        let rc = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !rc.contains("N_PREFIX") else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent(".zshrc.shell-backup")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
        let updated = rc + (rc.hasSuffix("\n") || rc.isEmpty ? "" : "\n") + "\n" + Self.nPrefixSnippet + "\n"
        try? updated.write(to: url, atomically: true, encoding: .utf8)
        nPrefix = nPrefix ?? "\(home)/.n"
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
