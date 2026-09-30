import Foundation

/// The GitHub tab's kanban board: which column each open PR belongs in, how
/// stacked PRs group, and the `gh api graphql` query that feeds it. Pure
/// functions, so the rules are unit-tested without `gh`.
enum PullRequestBoard {
    /// Board columns, left to right.
    enum Column: String, CaseIterable, Identifiable {
        case draft, waitingForReview, hasFeedback, changesRequested, ready

        var id: String { rawValue }

        var title: String {
            switch self {
            case .draft: "Draft"
            case .waitingForReview: "Waiting for review"
            case .hasFeedback: "Has feedback"
            case .changesRequested: "Changes requested"
            case .ready: "Ready"
            }
        }
    }

    enum Filter: String, CaseIterable { case mine, all }

    // MARK: Classification

    /// The column a PR belongs in:
    ///
    /// - **Draft**: `isDraft`.
    /// - **Changes requested**: `reviewDecision == CHANGES_REQUESTED`.
    /// - **Ready**: approved (or no review required, with no outstanding
    ///   requests or unresolved threads) and checks passing or absent.
    /// - **Has feedback**: reviews or unresolved threads without approval or a
    ///   change request, and approved PRs whose checks are pending or failing
    ///   (someone still has to act before it can merge).
    /// - **Waiting for review**: everything else that's open.
    static func column(for pr: OpenPullRequest) -> Column {
        if pr.isDraft { return .draft }
        let checksOK = pr.checks == .passing || pr.checks == .none
        let otherReviews = pr.reviews.contains { $0.login != pr.author && $0.state != "PENDING" }
        switch pr.reviewDecision {
        case "CHANGES_REQUESTED":
            return .changesRequested
        case "APPROVED":
            return checksOK ? .ready : .hasFeedback
        case "REVIEW_REQUIRED":
            return otherReviews || pr.unresolvedThreads > 0 ? .hasFeedback : .waitingForReview
        default:
            // No review required by branch protection.
            if pr.unresolvedThreads > 0 { return .hasFeedback }
            if !pr.reviewRequestedLogins.isEmpty { return otherReviews ? .hasFeedback : .waitingForReview }
            return checksOK ? .ready : .waitingForReview
        }
    }

    // MARK: Stacks

    /// PRs chained base → head, bottom first. A branching stack (two PRs on
    /// the same parent) lists each branch depth-first.
    struct Stack: Identifiable, Equatable {
        struct Layer: Equatable {
            var pr: OpenPullRequest
            /// 0 for the bottom PR; children are one deeper than their parent.
            var depth: Int
        }

        var layers: [Layer]

        var id: Int { layers.first?.pr.number ?? 0 }
        var bottom: OpenPullRequest { layers[0].pr }
        var pullRequests: [OpenPullRequest] { layers.map(\.pr) }
        var isBranching: Bool { Set(layers.map(\.depth)).count < layers.count }

        /// The leftmost column any layer is in: the stack is only as far along
        /// as its least-ready PR.
        var column: Column {
            let order = Column.allCases
            return layers.map { PullRequestBoard.column(for: $0.pr) }.min { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } ?? .waitingForReview
        }
    }

    /// Groups PRs whose base branch is another open PR's head branch.
    /// Singletons come back as one-layer stacks. A PR whose base PR was merged
    /// or closed has no open parent, so it starts a stack of its own. Fork PRs
    /// never parent anything (their head names live in another repository).
    static func stacks(_ prs: [OpenPullRequest]) -> [Stack] {
        var byHead: [String: OpenPullRequest] = [:]
        for pr in prs where !pr.isCrossRepository {
            // Two open PRs from one branch (rare): the newest wins.
            if let existing = byHead[pr.head], existing.number > pr.number { continue }
            byHead[pr.head] = pr
        }
        func parent(of pr: OpenPullRequest) -> OpenPullRequest? {
            guard let p = byHead[pr.base], p.number != pr.number else { return nil }
            return p
        }
        var children: [Int: [OpenPullRequest]] = [:]
        for pr in prs { if let p = parent(of: pr) { children[p.number, default: []].append(pr) } }
        for key in children.keys { children[key]?.sort { $0.number < $1.number } }

        var placed = Set<Int>()
        var result: [Stack] = []
        func walk(_ pr: OpenPullRequest, depth: Int, into layers: inout [Stack.Layer]) {
            guard placed.insert(pr.number).inserted else { return }
            layers.append(.init(pr: pr, depth: depth))
            for child in children[pr.number] ?? [] { walk(child, depth: depth + 1, into: &layers) }
        }
        // Roots first (no open parent), oldest first so stacks read bottom-up.
        for pr in prs.sorted(by: { $0.number < $1.number }) where parent(of: pr) == nil {
            var layers: [Stack.Layer] = []
            walk(pr, depth: 0, into: &layers)
            result.append(Stack(layers: layers))
        }
        // Anything left is in a cycle (A → B → A); start it at its lowest number.
        for pr in prs.sorted(by: { $0.number < $1.number }) where !placed.contains(pr.number) {
            var layers: [Stack.Layer] = []
            walk(pr, depth: 0, into: &layers)
            result.append(Stack(layers: layers))
        }
        return result
    }

    /// The board: each column's cards, most recently updated first.
    static func columns(_ prs: [OpenPullRequest], filter: Filter, login: String?) -> [Column: [Stack]] {
        var result: [Column: [Stack]] = [:]
        for stack in stacks(prs) {
            // A stack shows under Mine when any layer is yours, so the layers around it keep their context.
            if filter == .mine, !stack.pullRequests.contains(where: { login != nil && $0.author == login }) { continue }
            result[stack.column, default: []].append(stack)
        }
        for key in result.keys {
            result[key]?.sort { a, b in
                let da = a.pullRequests.compactMap(\.updatedAt).max() ?? .distantPast
                let db = b.pullRequests.compactMap(\.updatedAt).max() ?? .distantPast
                return da > db
            }
        }
        return result
    }

    // MARK: GraphQL

    /// One request for the board: viewer, merge methods and every open PR
    /// with its reviews, unresolved threads and check rollup.
    static let query = """
        query($owner: String!, $name: String!) {
          viewer { login }
          repository(owner: $owner, name: $name) {
            mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerDefaultMergeMethod
            pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url isDraft headRefName baseRefName isCrossRepository
                reviewDecision updatedAt additions deletions
                author { login __typename }
                labels(first: 10) { nodes { name color } }
                reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } ... on Bot { login } } } }
                latestReviews(first: 20) { nodes { author { login } state } }
                reviewThreads(first: 100) { nodes { isResolved } }
                commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
                  __typename
                  ... on CheckRun { name status conclusion detailsUrl }
                  ... on StatusContext { context state targetUrl }
                } } } } } }
              }
            }
          }
        }
        """

    enum MergeMethod: String, CaseIterable, Identifiable {
        case squash, merge, rebase
        var id: String { rawValue }
        var title: String {
            switch self {
            case .squash: "Squash and Merge"
            case .merge: "Create a Merge Commit"
            case .rebase: "Rebase and Merge"
            }
        }
    }

    struct Snapshot {
        var login: String?
        var pullRequests: [OpenPullRequest]
        /// Allowed by the repository, the viewer's default first.
        var mergeMethods: [MergeMethod]
    }

    /// Parses the GraphQL response. Nil when it isn't one (an error payload).
    static func parse(_ data: Data) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any], let repo = d["repository"] as? [String: Any] else { return nil }
        let login = (d["viewer"] as? [String: Any])?["login"] as? String
        var methods: [MergeMethod] = []
        if repo["squashMergeAllowed"] as? Bool == true { methods.append(.squash) }
        if repo["mergeCommitAllowed"] as? Bool == true { methods.append(.merge) }
        if repo["rebaseMergeAllowed"] as? Bool == true { methods.append(.rebase) }
        if let preferred = (repo["viewerDefaultMergeMethod"] as? String).flatMap({ MergeMethod(rawValue: $0.lowercased()) }),
           let i = methods.firstIndex(of: preferred) {
            methods.insert(methods.remove(at: i), at: 0)
        }
        let nodes = (repo["pullRequests"] as? [String: Any]).flatMap { $0["nodes"] as? [[String: Any]] } ?? []
        return Snapshot(login: login, pullRequests: nodes.compactMap(parsePullRequest), mergeMethods: methods)
    }

    static func parsePullRequest(_ o: [String: Any]) -> OpenPullRequest? {
        guard let number = o["number"] as? Int, let url = (o["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        func nodes(_ key: String) -> [[String: Any]] { (o[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] }
        let author = o["author"] as? [String: Any] ?? [:]
        let commit = nodes("commits").first?["commit"] as? [String: Any]
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let contexts = (rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let (checks, summary) = OpenPullRequest.rollup(contexts)
        let requested = nodes("reviewRequests").compactMap { r -> String? in
            let who = r["requestedReviewer"] as? [String: Any]
            return who?["login"] as? String ?? (who?["slug"] as? String).map { "team:" + $0 }
        }
        let reviews = nodes("latestReviews").compactMap { r -> OpenPullRequest.Review? in
            guard let login = (r["author"] as? [String: Any])?["login"] as? String, let state = r["state"] as? String else { return nil }
            return .init(login: login, state: state)
        }
        return OpenPullRequest(
            number: number, title: o["title"] as? String ?? "", url: url,
            isDraft: o["isDraft"] as? Bool ?? false,
            head: o["headRefName"] as? String ?? "", base: o["baseRefName"] as? String ?? "",
            author: author["login"] as? String ?? "", authorIsBot: author["__typename"] as? String == "Bot",
            reviewDecision: (o["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            updatedAt: (o["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            additions: o["additions"] as? Int ?? 0, deletions: o["deletions"] as? Int ?? 0,
            isCrossRepository: o["isCrossRepository"] as? Bool ?? false,
            labels: nodes("labels").map { ($0["name"] as? String ?? "", $0["color"] as? String ?? "888888") },
            checks: checks, checksSummary: summary,
            reviewRequestedLogins: requested,
            reviews: reviews,
            unresolvedThreads: nodes("reviewThreads").filter { $0["isResolved"] as? Bool == false }.count,
            failedRunIDs: failedRunIDs(contexts))
    }

    /// Actions run IDs (`…/actions/runs/<id>/…`) of failing check runs.
    static func failedRunIDs(_ contexts: [[String: Any]]) -> [Int] {
        let failing: Set<String> = ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE"]
        var ids: [Int] = []
        for c in contexts where failing.contains((c["conclusion"] as? String ?? "").uppercased()) {
            guard let url = c["detailsUrl"] as? String, let id = runID(in: url), !ids.contains(id) else { continue }
            ids.append(id)
        }
        return ids
    }

    static func runID(in url: String) -> Int? {
        guard let r = url.range(of: "/actions/runs/") else { return nil }
        return Int(url[r.upperBound...].prefix { $0.isNumber })
    }
}
