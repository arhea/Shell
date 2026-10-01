import Foundation
import Observation

/// The worktree a directory belongs to, with the same branch, tracking, PR
/// and changes the Worktrees sidebar shows. Used by the past sessions drawer,
/// where each card is a directory rather than a worktree of one repository.
///
/// Looked up lazily (only for cards on screen), at most every 30 seconds per
/// directory; branch tracking and PRs are fetched once per repository.
@MainActor
@Observable
final class DirectoryWorktreeStatus {
    static let shared = DirectoryWorktreeStatus()

    enum State: Equatable {
        case missing
        case notRepository
        /// `repo` is the main checkout's folder name, the same from any worktree.
        case worktree(WorktreeInfo, repo: String)
    }

    private var states: [String: State] = [:]
    @ObservationIgnored private var checkedAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var repoInfo: [String: (at: Date, task: Task<RepoBranchInfo, Never>)] = [:]

    struct RepoBranchInfo: Sendable {
        var tracking: [String: WorktreeService.BranchTracking]
        var pullRequests: [String: PullRequestInfo]
    }

    func state(for directory: String) -> State? { states[directory] }

    func refresh(_ directory: String) async {
        if let at = checkedAt[directory], Date().timeIntervalSince(at) < 30 { return }
        guard !inFlight.contains(directory) else { return }
        inFlight.insert(directory)
        defer { inFlight.remove(directory) }
        checkedAt[directory] = Date()

        guard FileManager.default.fileExists(atPath: directory) else {
            states[directory] = .missing
            return
        }
        let env = MCPManager.defaultEnvironment()
        let git = GitRepository.findGit(environment: env)
        func run(_ args: [String]) async -> String? {
            await GitRepository.run(git, args, in: directory, environment: env)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let out = await run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"]) else {
            states[directory] = .notRepository
            return
        }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else {
            states[directory] = .notRepository
            return
        }
        let toplevel = lines[0]
        let common = URL(fileURLWithPath: lines[1])
        let mainCheckout = common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : toplevel
        let repo = (mainCheckout as NSString).lastPathComponent
        let head = await run(["rev-parse", "--abbrev-ref", "HEAD"])

        var wt = WorktreeInfo(path: toplevel)
        wt.isMain = toplevel == mainCheckout
        if head == "HEAD" {
            wt.isDetached = true
            wt.head = await run(["rev-parse", "--short=8", "HEAD"])
        } else {
            wt.branch = head
        }
        // Show what's known right away; tracking and the PR fill in after.
        if case .worktree(let old, _)? = states[directory], old.path == wt.path, old.branch == wt.branch {
            wt.changes = old.changes; wt.lastActivity = old.lastActivity
            wt.upstream = old.upstream; wt.ahead = old.ahead; wt.behind = old.behind
            wt.upstreamGone = old.upstreamGone; wt.trackingKnown = old.trackingKnown; wt.pullRequest = old.pullRequest
        }
        states[directory] = .worktree(wt, repo: repo)

        let inspected = await WorktreeService.inspect(wt, git: git)
        wt.changes = inspected.changes
        wt.lastActivity = inspected.lastActivity
        states[directory] = .worktree(wt, repo: repo)

        let info = await branchInfo(repo: mainCheckout, git: git, environment: env)
        if let branch = wt.branch {
            wt.trackingKnown = !info.tracking.isEmpty
            if let t = info.tracking[branch] {
                wt.upstream = t.upstream; wt.ahead = t.ahead; wt.behind = t.behind; wt.upstreamGone = t.gone
            }
            wt.pullRequest = info.pullRequests[branch]
        }
        states[directory] = .worktree(wt, repo: repo)
    }

    /// Branch tracking and PRs for a repository, shared by every card in it
    /// and reused for a minute.
    private func branchInfo(repo: String, git: String, environment: [String: String]) async -> RepoBranchInfo {
        if let cached = repoInfo[repo], Date().timeIntervalSince(cached.at) < 60 { return await cached.task.value }
        let task = Task.detached(priority: .utility) {
            async let tracking = WorktreeService.branchTracking(repo: repo, git: git)
            async let prs = WorktreeService.pullRequests(repo: repo, environment: environment)
            return RepoBranchInfo(tracking: await tracking, pullRequests: await prs)
        }
        repoInfo[repo] = (Date(), task)
        return await task.value
    }

    /// Forces the next lookup (the drawer's refresh button).
    func invalidate() {
        checkedAt.removeAll()
        repoInfo.removeAll()
    }
}
