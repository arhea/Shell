import AppKit
import Observation

/// The GitHub tab for one repository: the PR board, the selected PR's detail
/// and the actions on it, all through the user's `gh`. Cached per repository
/// and shared by every window, so switching windows doesn't refetch.
@MainActor
@Observable
final class GitHubBoardModel {
    /// Where the selection came from: a single card, or a stack card (the
    /// detail pane then lists the stack's layers to switch between).
    struct Selection: Equatable {
        var number: Int
        var stackID: Int?
    }

    let repoRoot: String
    let remote: GitHubRemote
    private(set) var pullRequests: [OpenPullRequest] = []
    private(set) var mergeMethods: [PullRequestBoard.MergeMethod] = []
    private(set) var login: String?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    var selection: Selection? {
        didSet { if selection?.number != oldValue?.number { loadDetail() } }
    }
    private(set) var details: [Int: PullRequestDetail] = [:]
    private(set) var diffs: [Int: [PullRequestDiff.File]] = [:]
    private(set) var loadingDetail: Set<Int> = []
    private(set) var loadingDiff: Set<Int> = []
    /// PR number → the action running on it ("Merging…").
    private(set) var busy: [Int: String] = [:]
    var message: (text: String, isError: Bool)?

    @ObservationIgnored let environment: [String: String]
    /// Set while the showing window is fully covered; the periodic refresh skips then.
    @ObservationIgnored var isPaused = false {
        didSet { if oldValue && !isPaused { refreshIfNeeded() } }
    }
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Windows showing the tab; polling runs only while there's one.
    @ObservationIgnored private var viewers = 0

    /// Background refresh interval. One GraphQL request per refresh keeps this
    /// well inside GitHub's rate limits.
    static let interval: Duration = .seconds(120)
    /// Coming back to the tab refreshes when the board is older than this.
    static let staleAfter: TimeInterval = 30

    private static var cache: [String: GitHubBoardModel] = [:]

    static func model(repoRoot: String, remote: GitHubRemote) -> GitHubBoardModel {
        if let m = cache[repoRoot], m.remote == remote { return m }
        let m = GitHubBoardModel(repoRoot: repoRoot, remote: remote, environment: MCPManager.defaultEnvironment())
        cache[repoRoot] = m
        return m
    }

    /// Internal (not private) so tests can give a board its own environment; the app uses `model(repoRoot:remote:)`.
    init(repoRoot: String, remote: GitHubRemote, environment: [String: String]) {
        self.repoRoot = repoRoot
        self.remote = remote
        self.environment = environment
    }

    /// For you / Mine / All, remembered in Settings.
    var filter: PullRequestBoard.Filter = GitHubBoardModel.savedFilter {
        didSet {
            guard filter != oldValue else { return }
            SettingsStore.shared.settings.githubBoardFilter = filter.rawValue
            relayout()
        }
    }

    static var savedFilter: PullRequestBoard.Filter {
        PullRequestBoard.Filter(rawValue: SettingsStore.shared.settings.githubBoardFilter) ?? .forYou
    }

    /// The toolbar's search field (title, branch, author, label).
    var searchText = "" {
        didSet { if searchText != oldValue { relayout() } }
    }

    /// The sub-header's "Review requested" / "Assigned" chips.
    var narrowing: PullRequestBoard.Reasons = [] {
        didSet { if narrowing != oldValue { relayout() } }
    }

    /// "Collapse stacks": stacks draw as one compact card until expanded.
    var collapseStacks = true {
        didSet { if collapseStacks != oldValue { toggledStacks = [] } }
    }
    /// Stacks flipped from the default by their own Expand / Collapse.
    private(set) var toggledStacks: Set<Int> = []

    func isExpanded(_ stack: PullRequestBoard.Stack) -> Bool {
        collapseStacks == toggledStacks.contains(stack.id)
    }

    func setExpanded(_ stack: PullRequestBoard.Stack, _ expanded: Bool) {
        guard isExpanded(stack) != expanded else { return }
        if toggledStacks.contains(stack.id) { toggledStacks.remove(stack.id) } else { toggledStacks.insert(stack.id) }
    }

    func toggleNarrowing(_ reason: PullRequestBoard.Reasons) {
        if narrowing.isSuperset(of: reason) { narrowing.subtract(reason) } else { narrowing.formUnion(reason) }
    }

    /// Columns and counts, recomputed when the PRs, filter, chips or search
    /// change rather than on every view update.
    private(set) var layout = PullRequestBoard.Layout()

    var columns: [PullRequestBoard.Column: [PullRequestBoard.Stack]] { layout.columns }

    private func relayout() {
        let next = PullRequestBoard.layout(pullRequests, filter: filter, narrowing: narrowing,
                                           query: searchText.trimmingCharacters(in: .whitespaces), login: login)
        if next != layout { layout = next }
    }

    func reasons(_ pr: OpenPullRequest) -> PullRequestBoard.Reasons { PullRequestBoard.reasons(pr, login: login) }

    func pullRequest(_ number: Int) -> OpenPullRequest? { pullRequests.first { $0.number == number } }

    /// The stack the selection was opened from, rebuilt from current data.
    var selectedStack: PullRequestBoard.Stack? {
        guard let id = selection?.stackID else { return nil }
        return PullRequestBoard.stacks(pullRequests).first { $0.pullRequests.contains { $0.number == id } && $0.layers.count > 1 }
    }

    func isMine(_ pr: OpenPullRequest) -> Bool { login != nil && pr.author == login }

    // MARK: Loading

    /// Starts the periodic refresh while the tab is on screen.
    func attach() {
        viewers += 1
        refreshIfNeeded()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, !Task.isCancelled else { return }
                if !isPaused { refresh() }
            }
        }
    }

    func detach() {
        viewers = max(viewers - 1, 0)
        guard viewers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshIfNeeded() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.staleAfter { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        guard let gh = GitRepository.findExecutable("gh", environment: environment) else {
            error = "Install the GitHub CLI (`brew install gh`) and run `gh auth login` to see pull requests."
            return
        }
        isLoading = true
        let args = hostArgs + ["graphql", "-f", "query=\(PullRequestBoard.query)", "-f", "owner=\(remote.owner)", "-f", "name=\(remote.name)"]
        let env = environment, repo = repoRoot
        Task {
            defer { isLoading = false }
            let r = await ProcessRunner.run(gh, args, environment: Self.ghEnvironment(env), directory: repo, timeout: 60)
            guard r.succeeded, let snapshot = PullRequestBoard.parse(r.stdout) else {
                let auth = await WorktreeService.runReportingError(gh, ["auth", "status"], in: repo, environment: env)
                if auth != nil {
                    error = "Run `gh auth login` to see pull requests."
                } else {
                    Log.git.error("GitHub board query failed: \(r.stderr, privacy: .public)")
                    error = "Couldn't load pull requests from GitHub."
                }
                return
            }
            error = nil
            lastUpdated = Date()
            refreshWorktrees()
            login = snapshot.login
            mergeMethods = snapshot.mergeMethods
            let previous = selection.flatMap { pullRequest($0.number) }
            if snapshot.pullRequests != pullRequests { pullRequests = snapshot.pullRequests }
            relayout()
            // Refresh the open detail when its PR changed, so the pane follows the board.
            if let n = selection?.number, let now = pullRequest(n), now != previous || now.updatedAt != previous?.updatedAt {
                loadDetail(n, force: true)
            }
        }
    }

    func loadDetail() {
        guard let n = selection?.number else { return }
        loadDetail(n, force: false)
    }

    private func loadDetail(_ number: Int, force: Bool) {
        guard force || details[number] == nil, !loadingDetail.contains(number),
              let gh = GitRepository.findExecutable("gh", environment: environment) else { return }
        loadingDetail.insert(number)
        let env = Self.ghEnvironment(environment), repo = repoRoot
        let viewArgs = ["pr", "view", "\(number)", "--repo", remote.slug.withHost(remote.host), "--json", PullRequestDetail.viewFields]
        let commentArgs = hostArgs + ["repos/\(remote.slug)/pulls/\(number)/comments?per_page=100"]
        Task {
            defer { loadingDetail.remove(number) }
            async let view = ProcessRunner.run(gh, viewArgs, environment: env, directory: repo, timeout: 60)
            async let comments = ProcessRunner.run(gh, commentArgs, environment: env, directory: repo, timeout: 60)
            let (v, c) = await (view, comments)
            guard v.succeeded, let detail = PullRequestDetail.parse(view: v.stdout, reviewComments: c.succeeded ? c.stdout : nil) else {
                Log.git.error("gh pr view \(number) failed: \(v.stderr, privacy: .public)")
                return
            }
            if details[number] != detail { details[number] = detail }
            // A loaded diff is stale once the PR changes.
            if force, diffs[number] != nil { loadDiff(number, force: true) }
        }
    }

    func loadDiff(_ number: Int, force: Bool = false) {
        guard force || diffs[number] == nil, !loadingDiff.contains(number),
              let gh = GitRepository.findExecutable("gh", environment: environment) else { return }
        loadingDiff.insert(number)
        let env = Self.ghEnvironment(environment), repo = repoRoot
        let args = ["pr", "diff", "\(number)", "--repo", remote.slug.withHost(remote.host)]
        Task {
            defer { loadingDiff.remove(number) }
            let r = await ProcessRunner.run(gh, args, environment: env, directory: repo, timeout: 60)
            guard r.succeeded else {
                message = ("Couldn't load the diff: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))", true)
                return
            }
            let patch = String(decoding: r.stdout, as: UTF8.self)
            diffs[number] = await Task.detached { PullRequestDiff.parse(patch) }.value
        }
    }

    // MARK: Actions

    enum Action {
        case comment(String)
        case approve(String)
        case requestChanges(String)
        case markReady
        case convertToDraft
        case rerunFailedChecks
        case merge(PullRequestBoard.MergeMethod)
        case close

        var progress: String {
            switch self {
            case .comment: "Commenting…"
            case .approve: "Approving…"
            case .requestChanges: "Requesting changes…"
            case .markReady: "Marking ready…"
            case .convertToDraft: "Converting to draft…"
            case .rerunFailedChecks: "Re-running failed checks…"
            case .merge: "Merging…"
            case .close: "Closing…"
            }
        }

        var done: String {
            switch self {
            case .comment: "Comment posted."
            case .approve: "Approved."
            case .requestChanges: "Requested changes."
            case .markReady: "Marked ready for review."
            case .convertToDraft: "Converted to draft."
            case .rerunFailedChecks: "Re-running failed checks."
            case .merge: "Merged."
            case .close: "Closed."
            }
        }
    }

    /// Runs `action` through `gh`, then refreshes the board. Returns whether it succeeded.
    @discardableResult
    func perform(_ action: Action, on pr: OpenPullRequest) async -> Bool {
        guard busy[pr.number] == nil else { return false }
        guard let gh = GitRepository.findExecutable("gh", environment: environment) else {
            message = ("The GitHub CLI isn't installed.", true)
            return false
        }
        busy[pr.number] = action.progress
        defer { busy[pr.number] = nil }
        message = nil
        let repo = ["--repo", remote.slug.withHost(remote.host)]
        let n = "\(pr.number)"
        var commands: [[String]]
        switch action {
        case .comment(let body): commands = [["pr", "comment", n, "--body", body] + repo]
        case .approve(let body): commands = [["pr", "review", n, "--approve"] + (body.isEmpty ? [] : ["--body", body]) + repo]
        case .requestChanges(let body): commands = [["pr", "review", n, "--request-changes", "--body", body] + repo]
        case .markReady: commands = [["pr", "ready", n] + repo]
        case .convertToDraft: commands = [["pr", "ready", n, "--undo"] + repo]
        case .rerunFailedChecks:
            guard !pr.failedRunIDs.isEmpty else {
                message = ("No failed GitHub Actions runs to re-run. Other checks re-run from their own service.", true)
                return false
            }
            commands = pr.failedRunIDs.map { ["run", "rerun", "\($0)", "--failed"] + repo }
        case .merge(let method): commands = [["pr", "merge", n, "--\(method.rawValue)"] + repo]
        case .close: commands = [["pr", "close", n] + repo]
        }
        for args in commands {
            if let err = await WorktreeService.runReportingError(gh, args, in: repoRoot, environment: environment) {
                message = (err, true)
                refresh()
                return false
            }
        }
        message = ("#\(pr.number): \(action.done)", false)
        if case .merge = action { selection = nil } else if case .close = action { selection = nil }
        // GitHub takes a moment to recompute review state and checks.
        try? await Task.sleep(for: AppEnvironment.wait(.seconds(1)))
        refresh()
        return true
    }

    // MARK: Worktrees

    private(set) var creatingWorktree: Set<Int> = []
    /// Branch → checkout path, for PRs already checked out locally.
    private(set) var worktreePaths: [String: String] = [:]

    func worktree(for pr: OpenPullRequest) -> String? { worktreePaths[pr.head] }

    /// The PR's worktree, or where "Check out into a new worktree" will put it.
    func plannedWorktreePath(for pr: OpenPullRequest) -> String {
        worktree(for: pr) ?? PullRequestBoard.worktreePath(root: WorktreeService.worktreeRoot(environment: environment),
                                                            repoName: remote.name, head: pr.head)
    }

    /// The PR's existing worktree, else a new one. Nil (with a message) when checkout fails.
    func ensureWorktree(for pr: OpenPullRequest) async -> String? {
        if let path = worktree(for: pr) { return path }
        return await createWorktree(for: pr)
    }

    func refreshWorktrees() {
        let repo = repoRoot, git = GitRepository.findGit(environment: environment)
        Task {
            var paths: [String: String] = [:]
            for wt in await WorktreeService.list(repo: repo, git: git) where wt.exists {
                if let branch = wt.branch, paths[branch] == nil { paths[branch] = wt.path }
            }
            if paths != worktreePaths { worktreePaths = paths }
        }
    }

    /// Checks the PR out into a new worktree (the sidebar's layout). Returns its path.
    func createWorktree(for pr: OpenPullRequest) async -> String? {
        creatingWorktree.insert(pr.number)
        defer { creatingWorktree.remove(pr.number) }
        switch await PullRequestsModel.makeWorktree(number: pr.number, head: pr.head, repoRoot: repoRoot,
                                                    repoName: remote.name, environment: environment) {
        case .success(let path):
            worktreePaths[pr.head] = path
            return path
        case .failure(let err):
            message = (err.message, true)
            return nil
        }
    }

    /// The main checkout and GitHub remote for a directory, without starting
    /// a repository watcher (for opening the tab before the pane's repo is known).
    static func resolve(directory: String) async -> (root: String, remote: GitHubRemote)? {
        let git = GitRepository.findGit(environment: MCPManager.defaultEnvironment())
        guard let common = await GitRepository.run(git, ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty else { return nil }
        // The common dir is the main checkout's .git (a bare repo has no checkout).
        let root = common.hasSuffix("/.git") ? String(common.dropLast(5)) : directory
        let upstream = await GitRepository.run(git, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: directory)?
            .split(separator: "/").first.map(String.init)
        var url: String?
        if let upstream { url = await GitRepository.run(git, ["remote", "get-url", upstream], in: directory) }
        if url == nil { url = await GitRepository.run(git, ["remote", "get-url", "origin"], in: directory) }
        guard let remote = url.flatMap(GitHubRemote.parse) else { return nil }
        return (root, remote)
    }

    // MARK: gh

    /// `--hostname` for GitHub Enterprise remotes.
    private var hostArgs: [String] {
        remote.host == "github.com" ? ["api"] : ["api", "--hostname", remote.host]
    }

    nonisolated static func ghEnvironment(_ env: [String: String]) -> [String: String] {
        var e = env
        e["GH_PROMPT_DISABLED"] = "1"
        e["NO_COLOR"] = "1"
        e["GH_PAGER"] = "cat"
        return e
    }
}

private extension String {
    /// `owner/repo`, or `host/owner/repo` for GitHub Enterprise (as `--repo` expects).
    func withHost(_ host: String) -> String { host == "github.com" ? self : "\(host)/\(self)" }
}
