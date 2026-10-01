import AppKit
import Observation

/// One entry of `git worktree list --porcelain`, plus what Shell learned about it.
struct WorktreeInfo: Identifiable, Equatable {
    var path: String
    /// Short HEAD commit, for display.
    var head: String?
    /// Full HEAD commit.
    var headOID: String?
    var branch: String?
    var isMain = false
    var isBare = false
    var isDetached = false
    var lockReason: String?
    var isLocked = false
    var prunableReason: String?

    // Filled in by `inspect`.
    /// Uncommitted entries in `git status` (staged, unstaged or untracked); nil = not checked.
    var changes: Int?
    /// Latest of the last commit on HEAD and the worktree's index/HEAD file changes.
    var lastActivity: Date?
    var sizeBytes: Int64?
    // Filled in from the repository's branches and GitHub.
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// The upstream branch was deleted (usually after its PR merged).
    var upstreamGone = false
    /// Set once branch tracking has loaded (so "not pushed" isn't shown prematurely).
    var trackingKnown = false
    var pullRequest: PullRequestInfo?

    var id: String { path }

    /// Merged PR or deleted upstream: the work landed, so the worktree is likely done.
    var looksFinished: Bool { pullRequest?.state == .merged || (upstreamGone && pullRequest?.state != .open) }
    /// Clean, removable, and its branch's PR has merged.
    var isMergedAndClean: Bool {
        !isMain && !isBare && !isLocked && changes == 0 && pullRequest?.state == .merged
    }
    /// HEAD is exactly the merged PR's head, so the branch holds nothing that didn't merge.
    /// (Squash merges make `git branch -d` refuse, so this is what makes `-D` safe.)
    var headMatchesMergedPR: Bool {
        guard let pr = pullRequest, pr.state == .merged, let oid = headOID, let prOID = pr.headOID else { return false }
        return oid == prOID
    }
    var name: String { (path as NSString).lastPathComponent }
    var isPrunable: Bool { prunableReason != nil }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Clean, idle for `days`, and removable (not the main checkout, not locked).
    func isStale(days: Int, now: Date = Date()) -> Bool {
        guard !isMain, !isBare, !isLocked, !isPrunable, changes == 0, let last = lastActivity else { return false }
        return now.timeIntervalSince(last) >= Double(days) * 86400
    }

    var ageDescription: String? {
        guard let last = lastActivity else { return nil }
        let days = Int(Date().timeIntervalSince(last) / 86400)
        if days <= 0 { return "today" }
        if days == 1 { return "1 day ago" }
        if days < 60 { return "\(days) days ago" }
        return "\(days / 30) months ago"
    }

    static func parse(porcelain: String) -> [WorktreeInfo] {
        var out: [WorktreeInfo] = []
        var cur: WorktreeInfo?
        func flush() {
            if var c = cur {
                c.isMain = out.isEmpty // git lists the main worktree first
                out.append(c)
            }
            cur = nil
        }
        for raw in porcelain.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { flush(); continue }
            let (key, value): (String, String?) = {
                guard let sp = line.firstIndex(of: " ") else { return (line, nil) }
                return (String(line[..<sp]), String(line[line.index(after: sp)...]))
            }()
            switch key {
            case "worktree":
                flush()
                cur = WorktreeInfo(path: value ?? "")
            case "HEAD":
                cur?.headOID = value
                cur?.head = value.map { String($0.prefix(8)) }
            case "branch": cur?.branch = value.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
            case "bare": cur?.isBare = true
            case "detached": cur?.isDetached = true
            case "locked":
                cur?.isLocked = true
                cur?.lockReason = value
            case "prunable": cur?.prunableReason = value ?? "missing"
            default: break
            }
        }
        flush()
        return out
    }
}

enum WorktreeService {
    @MainActor static func git() -> String { GitRepository.findGit(environment: MCPManager.defaultEnvironment()) }

    static func list(repo: String, git: String) async -> [WorktreeInfo] {
        guard let out = await GitRepository.run(git, ["worktree", "list", "--porcelain"], in: repo) else { return [] }
        return WorktreeInfo.parse(porcelain: out)
    }

    /// Adds changes and last-activity to a worktree.
    static func inspect(_ wt: WorktreeInfo, git: String) async -> WorktreeInfo {
        var w = wt
        guard !w.isBare, w.exists else { return w }
        if let status = await GitRepository.run(git, ["status", "--porcelain", "-z", "--untracked-files=normal"], in: w.path) {
            w.changes = status.split(separator: "\0").filter { !$0.hasPrefix("!!") && $0.count > 3 }.count
                // Renames print the old path as an extra entry; close enough for a count.
        }
        var dates: [Date] = []
        if let ct = await GitRepository.run(git, ["log", "-1", "--format=%ct"], in: w.path),
           let secs = TimeInterval(ct.trimmingCharacters(in: .whitespacesAndNewlines)) {
            dates.append(Date(timeIntervalSince1970: secs))
        }
        if let gitDir = await GitRepository.run(git, ["rev-parse", "--absolute-git-dir"], in: w.path)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            for f in ["index", "HEAD"] {
                if let d = (try? FileManager.default.attributesOfItem(atPath: gitDir + "/" + f))?[.modificationDate] as? Date { dates.append(d) }
            }
        }
        w.lastActivity = dates.max()
        return w
    }

    struct BranchTracking {
        var upstream: String?
        var ahead = 0
        var behind = 0
        var gone = false
    }

    /// Upstream and ahead/behind for every local branch, in one call.
    static func branchTracking(repo: String, git: String) async -> [String: BranchTracking] {
        guard let out = await GitRepository.run(git, ["for-each-ref", "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)", "refs/heads"], in: repo) else { return [:] }
        var result: [String: BranchTracking] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            var t = BranchTracking(upstream: f[1].isEmpty ? nil : f[1])
            let track = f[2]
            if track.contains("gone") { t.gone = true }
            for part in track.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: ", ") {
                let bits = part.split(separator: " ")
                guard bits.count == 2, let n = Int(bits[1]) else { continue }
                if bits[0] == "ahead" { t.ahead = n } else if bits[0] == "behind" { t.behind = n }
            }
            result[f[0]] = t
        }
        return result
    }

    /// Recent PRs by head branch (open ones win), from one `gh pr list`.
    static func pullRequests(repo: String, environment: [String: String]) async -> [String: PullRequestInfo] {
        guard let gh = GitRepository.findExecutable("gh", environment: environment),
              let out = await GitRepository.run(gh, ["pr", "list", "--state", "all", "--limit", "200",
                                                     "--json", "number,title,url,state,isDraft,headRefName,headRefOid,reviewDecision"],
                                                in: repo, environment: environment),
              let data = out.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var result: [String: PullRequestInfo] = [:]
        for obj in list {
            guard let branch = obj["headRefName"] as? String, let number = obj["number"] as? Int,
                  let url = (obj["url"] as? String).flatMap(URL.init(string:)) else { continue }
            let pr = PullRequestInfo(number: number, title: obj["title"] as? String ?? "", url: url,
                                     state: PullRequestInfo.State(rawValue: obj["state"] as? String ?? "") ?? .open,
                                     isDraft: obj["isDraft"] as? Bool ?? false,
                                     reviewDecision: (obj["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                     headOID: obj["headRefOid"] as? String)
            // Newest first; an open PR replaces older merged/closed ones.
            if let existing = result[branch], existing.state == .open || pr.state != .open { continue }
            result[branch] = pr
        }
        return result
    }

    /// Disk usage in bytes (`du -sk`).
    static func size(of path: String) async -> Int64? {
        let r = await ProcessRunner.run("/usr/bin/du", ["-sk", path], timeout: 300)
        guard !r.timedOut else { return nil }
        let kb = String(data: r.stdout, encoding: .utf8)?.split(separator: "\t").first.flatMap { Int64($0) }
        return kb.map { $0 * 1024 }
    }

    /// `git worktree remove` (refuses dirty worktrees unless `force`), then
    /// optionally `git branch -d` (refuses unmerged branches), or `-D` with
    /// `forceDeleteBranch`. Returns an error or nil.
    static func remove(_ wt: WorktreeInfo, repo: String, git: String, force: Bool, deleteBranch: Bool,
                       forceDeleteBranch: Bool = false) async -> String? {
        guard !wt.isMain else { return "The main worktree can't be removed." }
        if wt.isPrunable || !wt.exists {
            _ = await GitRepository.run(git, ["worktree", "prune"], in: repo)
            return nil
        }
        let args = ["worktree", "remove"] + (force ? ["--force"] : []) + [wt.path]
        if let err = await runReportingError(git, args, in: repo) { return err }
        if deleteBranch, let branch = wt.branch,
           let err = await runReportingError(git, ["branch", forceDeleteBranch ? "-D" : "-d", branch], in: repo) {
            return "Removed the worktree, but kept branch \(branch): \(err)"
        }
        return nil
    }

    /// Runs git and returns stderr on failure.
    static func runReportingError(_ git: String, _ args: [String], in dir: String, environment: [String: String]? = nil) async -> String? {
        var env = environment ?? [:]
        if environment != nil { env["GH_PROMPT_DISABLED"] = "1" }
        // Removing a worktree deletes its files (node_modules and all), so allow time.
        let r = await ProcessRunner.run(git, args, environment: env, directory: dir, timeout: 600)
        if r.succeeded { return nil }
        if r.timedOut { return "git timed out" }
        let text = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git exited with \(r.status)" : text
    }

    /// Where new worktrees go: Settings, else $WORKTREES_HOME (gwt), else ~/code/worktrees.
    @MainActor static func worktreeRoot(environment: [String: String]) -> String {
        let configured = SettingsStore.shared.settings.worktreeRoot
        let root = !configured.isEmpty ? configured : environment["WORKTREES_HOME"] ?? "~/code/worktrees"
        return (root as NSString).expandingTildeInPath
    }

    /// Git repositories at `path`: the repo itself, or repos up to two levels below it.
    static func repositories(in path: String) -> [String] {
        let fm = FileManager.default
        let root = (path as NSString).expandingTildeInPath
        func isRepo(_ p: String) -> Bool { fm.fileExists(atPath: p + "/.git") }
        if isRepo(root) { return [root] }
        var found: [String] = []
        func scan(_ dir: String, depth: Int) {
            guard depth > 0, let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for item in items where !item.hasPrefix(".") && item != "node_modules" {
                let p = dir + "/" + item
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                if isRepo(p) { found.append(p) } else { scan(p, depth: depth - 1) }
            }
        }
        scan(root, depth: 2)
        return found.sorted()
    }

    static func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

/// Worktrees of one repository, for the sidebar.
@MainActor
@Observable
final class WorktreesModel {
    let repoRoot: String
    private(set) var worktrees: [WorktreeInfo] = []
    private(set) var isLoading = false
    private(set) var busy: Set<String> = []
    var lastError: String?
    @ObservationIgnored private let git: String
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var loadedAt: Date?

    init(repoRoot: String, environment: [String: String]) {
        self.repoRoot = repoRoot
        self.environment = environment
        git = GitRepository.findGit(environment: environment)
    }

    var staleDays: Int { max(1, SettingsStore.shared.settings.worktreeStaleDays) }
    var stale: [WorktreeInfo] { worktrees.filter { $0.isStale(days: staleDays) } }
    var totalSize: Int64 { worktrees.compactMap(\.sizeBytes).reduce(0, +) }
    /// Disk used by the stale worktrees (measured ones only).
    var staleSize: Int64 { stale.compactMap(\.sizeBytes).reduce(0, +) }

    /// `git pull --ff-only` in a worktree (the main checkout's Pull button).
    func pull(_ wt: WorktreeInfo) async {
        busy.insert(wt.path)
        defer { busy.remove(wt.path) }
        if let err = await WorktreeService.runReportingError(git, ["pull", "--ff-only"], in: wt.path, environment: environment) {
            lastError = "Couldn't pull \(wt.branch ?? wt.name): \(err)"
        }
        loadedAt = nil
        refresh()
    }

    func refreshIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 20 { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        loadedAt = Date()
        Task {
            let listed = await WorktreeService.list(repo: repoRoot, git: git)
            // Keep sizes we already measured.
            let previous = Dictionary(worktrees.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            // Keep what we knew until the refresh fills it in again (no flicker).
            worktrees = listed.map { w in
                var w = w
                if let old = previous[w.path] {
                    w.sizeBytes = old.sizeBytes
                    w.upstream = old.upstream; w.ahead = old.ahead; w.behind = old.behind
                    w.upstreamGone = old.upstreamGone; w.trackingKnown = old.trackingKnown; w.pullRequest = old.pullRequest
                    w.changes = old.changes; w.lastActivity = old.lastActivity
                }
                return w
            }
            let git = self.git, env = self.environment, repo = self.repoRoot
            // Branch tracking and PRs load alongside the per-worktree checks.
            async let tracking = WorktreeService.branchTracking(repo: repo, git: git)
            async let prs = WorktreeService.pullRequests(repo: repo, environment: env)
            await withTaskGroup(of: WorktreeInfo.self) { group in
                for w in listed { group.addTask { await WorktreeService.inspect(w, git: git) } }
                for await w in group {
                    if let i = worktrees.firstIndex(where: { $0.path == w.path }) {
                        worktrees[i].changes = w.changes
                        worktrees[i].lastActivity = w.lastActivity
                    }
                }
            }
            let t = await tracking
            applyBranchInfo(tracking: t, prs: [:])
            let p = await prs
            applyBranchInfo(tracking: t, prs: p)
            isLoading = false
            measureSizes()
        }
    }

    private func applyBranchInfo(tracking: [String: WorktreeService.BranchTracking], prs: [String: PullRequestInfo]) {
        for i in worktrees.indices {
            guard let branch = worktrees[i].branch else { continue }
            worktrees[i].trackingKnown = !tracking.isEmpty
            if let t = tracking[branch] {
                worktrees[i].upstream = t.upstream
                worktrees[i].ahead = t.ahead
                worktrees[i].behind = t.behind
                worktrees[i].upstreamGone = t.gone
            }
            if !prs.isEmpty { worktrees[i].pullRequest = prs[branch] }
        }
    }

    private func measureSizes() {
        for w in worktrees where w.sizeBytes == nil && w.exists && !w.isBare {
            Task {
                let size = await WorktreeService.size(of: w.path)
                if let i = worktrees.firstIndex(where: { $0.path == w.path }) { worktrees[i].sizeBytes = size }
            }
        }
    }

    func remove(_ wt: WorktreeInfo, force: Bool, deleteBranch: Bool) async {
        busy.insert(wt.path)
        defer { busy.remove(wt.path) }
        if let err = await WorktreeService.remove(wt, repo: repoRoot, git: git, force: force, deleteBranch: deleteBranch) {
            lastError = err
        } else {
            worktrees.removeAll { $0.path == wt.path }
        }
        loadedAt = nil
        refresh()
    }

    func removeStale(deleteBranch: Bool) async {
        for wt in stale { await remove(wt, force: false, deleteBranch: deleteBranch) }
    }

    /// Merged and clean worktrees, excluding the one at `currentPath` (a pane is in it).
    func merged(excluding currentPath: String) -> [WorktreeInfo] {
        let current = URL(fileURLWithPath: currentPath).standardizedFileURL.path
        return worktrees.filter { $0.isMergedAndClean && URL(fileURLWithPath: $0.path).standardizedFileURL.path != current }
    }

    /// Removes each worktree (never forced). Deletes its branch only when HEAD is
    /// the merged PR's head; otherwise the branch is kept.
    func removeMerged(_ list: [WorktreeInfo]) async {
        var errors: [String] = []
        for wt in list {
            busy.insert(wt.path)
            let match = wt.headMatchesMergedPR
            if let err = await WorktreeService.remove(wt, repo: repoRoot, git: git, force: false,
                                                      deleteBranch: match, forceDeleteBranch: match) {
                errors.append("\(wt.name): \(err)")
            } else {
                worktrees.removeAll { $0.path == wt.path }
            }
            busy.remove(wt.path)
        }
        if !errors.isEmpty { lastError = errors.joined(separator: "\n") }
        loadedAt = nil
        refresh()
    }
}

// MARK: - Scheduled cleanup

/// Removes stale worktrees (clean, idle for the configured days) from the
/// repositories listed in Settings › Worktrees.
@MainActor
final class WorktreeCleanupJob: MaintenanceJob {
    let id = "worktrees"
    let title = "Worktree cleanup"
    let summary = "Removes worktrees with no uncommitted changes that have been idle, from the repositories you list"
    /// Debug hook (`shellctl debug worktree-cleanup PATH`): run against these paths instead of Settings.
    static var pathsOverride: [String]?
    static var paths: [String] { pathsOverride ?? SettingsStore.shared.settings.worktreeCleanupPaths }
    var isAvailable: Bool { !Self.paths.isEmpty }
    var schedule: AutoUpdateSchedule { SettingsStore.shared.settings.worktreeCleanupSchedule }

    struct Candidate: Identifiable {
        var repo: String
        var worktree: WorktreeInfo
        var id: String { worktree.path }
    }

    /// The worktrees a run would remove right now.
    static func candidates() async -> [Candidate] {
        let s = SettingsStore.shared.settings
        let git = WorktreeService.git()
        var seen = Set<String>()
        var out: [Candidate] = []
        for path in paths {
            for repo in WorktreeService.repositories(in: path) {
                let list = await WorktreeService.list(repo: repo, git: git)
                // Several paths can point into the same repository; count each worktree once.
                for wt in list where !wt.isMain && seen.insert(wt.path).inserted {
                    let inspected = await WorktreeService.inspect(wt, git: git)
                    if inspected.isStale(days: max(1, s.worktreeStaleDays)) {
                        out.append(Candidate(repo: list.first?.path ?? repo, worktree: inspected))
                    }
                }
            }
        }
        return out
    }

    func perform(_ run: MaintenanceRun) async -> MaintenanceOutcome {
        let s = SettingsStore.shared.settings
        var out = MaintenanceOutcome()
        let git = WorktreeService.git()
        let list = await Self.candidates()
        run.note("Stale threshold: \(s.worktreeStaleDays) days · \(list.count) candidate(s)")
        var freed: Int64 = 0
        for c in list {
            guard !run.cancelled else { break }
            let size = await WorktreeService.size(of: c.worktree.path) ?? 0
            run.onStep?("Removing \(c.worktree.name)")
            if MaintenanceRun.dryRun {
                run.note("[dry run] would remove \(c.worktree.path)")
                continue
            }
            if let err = await WorktreeService.remove(c.worktree, repo: c.repo, git: git, force: false,
                                                      deleteBranch: s.worktreeCleanupDeleteMergedBranches) {
                run.note("✗ \(c.worktree.path): \(err)")
                out.warnings.append("\(c.worktree.name): \(err)")
            } else {
                run.note("✓ removed \(c.worktree.path) (\(WorktreeService.formatBytes(size)))")
                freed += size
                out.changes.append("\((c.repo as NSString).lastPathComponent)/\(c.worktree.name)")
            }
        }
        if freed > 0 { out.summary = "freed \(WorktreeService.formatBytes(freed))" }
        return out
    }

    func notification(for r: MaintenanceRecord) -> (title: String, body: String)? {
        switch r.outcome {
        case .success where !r.changes.isEmpty:
            let freed = r.summary.map { " · \($0)" } ?? ""
            let list = r.changes.prefix(5).joined(separator: ", ") + (r.changes.count > 5 ? " +\(r.changes.count - 5) more" : "")
            return ("Removed \(r.changes.count) stale worktree\(r.changes.count == 1 ? "" : "s")\(freed)", list)
        case .failed:
            return ("Worktree cleanup failed", "Open Settings › Worktrees for the log.")
        default:
            return nil
        }
    }

    func didFinish() async {}
}

// MARK: - Inspector grouping and filters

/// The Worktrees inspector's filter chips.
enum WorktreeFilter: String, CaseIterable, Identifiable, Sendable {
    case all, changes, notPushed, stale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .changes: "Changes"
        case .notPushed: "Not pushed"
        case .stale: "Stale"
        }
    }

    func matches(_ wt: WorktreeInfo, staleDays: Int, now: Date = Date()) -> Bool {
        switch self {
        case .all: true
        case .changes: (wt.changes ?? 0) > 0
        case .notPushed: wt.isNotPushed
        case .stale: wt.isStale(days: staleDays, now: now)
        }
    }

    /// How many worktrees each chip matches.
    static func counts(_ worktrees: [WorktreeInfo], staleDays: Int, now: Date = Date()) -> [WorktreeFilter: Int] {
        Dictionary(uniqueKeysWithValues: allCases.map { f in (f, worktrees.filter { f.matches($0, staleDays: staleDays, now: now) }.count) })
    }
}

extension WorktreeInfo {
    /// A branch with commits that exist only locally: no upstream, or ahead of it.
    var isNotPushed: Bool {
        guard branch != nil, !isBare, !isPrunable else { return false }
        if upstream == nil { return trackingKnown && !upstreamGone }
        return ahead > 0
    }
}

/// Worktrees split the way the inspector shows them: those open in a tab,
/// the main checkout, and the rest.
struct WorktreeGroups: Equatable {
    var open: [WorktreeInfo] = []
    var main: WorktreeInfo?
    var others: [WorktreeInfo] = []

    /// `openPaths` are tabs' working directories. Each belongs to the
    /// worktree with the longest path containing it, so a worktree nested
    /// inside the main checkout (`.claude/worktrees/…`) isn't taken for the main one.
    static func group(_ worktrees: [WorktreeInfo], openPaths: some Sequence<String>) -> WorktreeGroups {
        let open = Set(openPaths.compactMap { owner(of: $0, in: worktrees) })
        var g = WorktreeGroups()
        for wt in worktrees {
            if wt.isMain { g.main = wt } else if open.contains(wt.path) { g.open.append(wt) } else { g.others.append(wt) }
        }
        // Most recent activity first among the rest.
        g.others.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        return g
    }

    /// The path of the worktree containing `directory`, or nil.
    static func owner(of directory: String, in worktrees: [WorktreeInfo]) -> String? {
        let dir = standardized(directory)
        return worktrees
            .map { ($0.path, standardized($0.path)) }
            .filter { dir == $0.1 || dir.hasPrefix($0.1.hasSuffix("/") ? $0.1 : $0.1 + "/") }
            .max { $0.1.count < $1.1.count }?.0
    }

    static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
}
