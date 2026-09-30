import AppKit
import Observation

/// An open pull request, as `gh pr list` reports it.
struct OpenPullRequest: Identifiable, Equatable {
    enum Checks: Equatable { case none, passing, failing, pending }

    var number: Int
    var title: String
    var url: URL
    var isDraft: Bool
    var head: String
    var base: String
    var author: String
    var authorIsBot: Bool
    var reviewDecision: String?
    var updatedAt: Date?
    var additions: Int
    var deletions: Int
    var isCrossRepository: Bool
    var labels: [(name: String, color: String)]
    var checks: Checks
    var checksSummary: String
    var reviewRequestedLogins: [String]

    var id: Int { number }

    static func == (a: OpenPullRequest, b: OpenPullRequest) -> Bool {
        a.number == b.number && a.title == b.title && a.updatedAt == b.updatedAt && a.checks == b.checks
            && a.reviewDecision == b.reviewDecision && a.isDraft == b.isDraft && a.head == b.head
    }

    static func parse(_ o: [String: Any]) -> OpenPullRequest? {
        guard let number = o["number"] as? Int, let url = (o["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let author = o["author"] as? [String: Any] ?? [:]
        let (checks, summary) = Self.rollup(o["statusCheckRollup"] as? [[String: Any]] ?? [])
        let iso = ISO8601DateFormatter()
        return OpenPullRequest(
            number: number, title: o["title"] as? String ?? "", url: url,
            isDraft: o["isDraft"] as? Bool ?? false,
            head: o["headRefName"] as? String ?? "", base: o["baseRefName"] as? String ?? "",
            author: author["login"] as? String ?? "", authorIsBot: author["is_bot"] as? Bool ?? false,
            reviewDecision: (o["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            updatedAt: (o["updatedAt"] as? String).flatMap { iso.date(from: $0) },
            additions: o["additions"] as? Int ?? 0, deletions: o["deletions"] as? Int ?? 0,
            isCrossRepository: o["isCrossRepository"] as? Bool ?? false,
            labels: (o["labels"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0["color"] as? String ?? "888888") },
            checks: checks, checksSummary: summary,
            reviewRequestedLogins: (o["reviewRequests"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String })
    }

    /// Collapses check runs and commit statuses into one state.
    static func rollup(_ items: [[String: Any]]) -> (Checks, String) {
        guard !items.isEmpty else { return (.none, "No checks") }
        var failing = 0, pending = 0, passing = 0
        for c in items {
            let status = (c["status"] as? String ?? "").uppercased()
            let conclusion = (c["conclusion"] as? String ?? "").uppercased()
            let state = (c["state"] as? String ?? "").uppercased()
            if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) || ["FAILURE", "ERROR"].contains(state) {
                failing += 1
            } else if (!status.isEmpty && status != "COMPLETED") || ["PENDING", "EXPECTED"].contains(state) {
                pending += 1
            } else {
                passing += 1
            }
        }
        let summary = [failing > 0 ? "\(failing) failing" : nil, pending > 0 ? "\(pending) pending" : nil, passing > 0 ? "\(passing) passing" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        return (failing > 0 ? .failing : pending > 0 ? .pending : .passing, summary)
    }
}

/// Open PRs for the sidebar's repository, from `gh`.
@MainActor
@Observable
final class PullRequestsModel {
    enum Filter: String, CaseIterable { case all, review, mine }

    let repoRoot: String
    private(set) var pullRequests: [OpenPullRequest] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var login: String?
    /// PR numbers being checked out into a worktree.
    private(set) var creating: Set<Int> = []
    var lastMessage: String?

    @ObservationIgnored let environment: [String: String]
    @ObservationIgnored private var loadedAt: Date?
    /// Set while the window can't be seen; the periodic refresh skips then.
    @ObservationIgnored var isPaused = false {
        didSet { if oldValue && !isPaused { refreshIfNeeded() } }
    }
    @ObservationIgnored private static var cachedLogin: String?

    init(repoRoot: String, environment: [String: String]) {
        self.repoRoot = repoRoot
        self.environment = environment
    }

    var filter: Filter {
        get { Filter(rawValue: SettingsStore.shared.settings.pullRequestFilter) ?? .all }
        set { SettingsStore.shared.settings.pullRequestFilter = newValue.rawValue }
    }

    func isReviewRequested(_ pr: OpenPullRequest) -> Bool { login.map { pr.reviewRequestedLogins.contains($0) } ?? false }
    func isMine(_ pr: OpenPullRequest) -> Bool { login != nil && pr.author == login }

    var reviewRequested: [OpenPullRequest] { pullRequests.filter(isReviewRequested) }

    var filtered: [OpenPullRequest] {
        switch filter {
        case .all: pullRequests
        case .review: reviewRequested
        case .mine: pullRequests.filter(isMine)
        }
    }

    func refreshIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 120 { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        guard let gh = GitRepository.findExecutable("gh", environment: environment) else {
            error = "Install the GitHub CLI (`brew install gh`) and run `gh auth login` to see pull requests."
            return
        }
        isLoading = true
        loadedAt = Date()
        let env = environment, repo = repoRoot
        Task {
            defer { isLoading = false }
            if login == nil {
                if Self.cachedLogin == nil {
                    Self.cachedLogin = await GitRepository.run(gh, ["api", "user", "-q", ".login"], in: repo, environment: env)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                login = Self.cachedLogin
            }
            let fields = "number,title,url,isDraft,headRefName,baseRefName,author,reviewDecision,updatedAt,statusCheckRollup,additions,deletions,isCrossRepository,reviewRequests,labels"
            guard let out = await GitRepository.run(gh, ["pr", "list", "--state", "open", "--limit", "100", "--json", fields], in: repo, environment: env),
                  let data = out.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                let err = await WorktreeService.runReportingError(gh, ["auth", "status"], in: repo)
                error = err != nil ? "Run `gh auth login` to see pull requests." : "Couldn't load pull requests from GitHub."
                return
            }
            error = nil
            let prs = list.compactMap(OpenPullRequest.parse)
                .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            if prs != pullRequests { pullRequests = prs }
        }
    }

    /// Creates a worktree for the PR (`git worktree add` + `gh pr checkout`),
    /// following the `$WORKTREES_HOME/<repo>/<branch>` layout. Returns its path.
    func createWorktree(for pr: OpenPullRequest, repoName: String) async -> String? {
        creating.insert(pr.number)
        defer { creating.remove(pr.number) }
        lastMessage = nil
        let git = GitRepository.findGit(environment: environment)
        guard let gh = GitRepository.findExecutable("gh", environment: environment) else {
            lastMessage = "The GitHub CLI isn't installed."
            return nil
        }
        let root = WorktreeService.worktreeRoot(environment: environment)
        let slug = pr.head.replacingOccurrences(of: "/", with: "-")
        var path = "\(root)/\(repoName)/\(slug)"
        if FileManager.default.fileExists(atPath: path) { path += "-pr\(pr.number)" }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let err = await WorktreeService.runReportingError(git, ["worktree", "add", "--detach", path], in: repoRoot) {
            lastMessage = "Couldn't create the worktree: \(err)"
            return nil
        }
        if let err = await WorktreeService.runReportingError(gh, ["pr", "checkout", "\(pr.number)"], in: path, environment: environment) {
            _ = await WorktreeService.runReportingError(git, ["worktree", "remove", "--force", path], in: repoRoot)
            lastMessage = "Couldn't check out #\(pr.number): \(err)"
            return nil
        }
        return path
    }
}
