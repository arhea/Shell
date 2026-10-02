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

    /// Which PRs the board shows. "For you" (the default) is PRs assigned to
    /// the viewer or waiting on their review; "Mine" is PRs they opened. Both
    /// keep the rest of each matching PR's stack, for context.
    enum Filter: String, CaseIterable, Identifiable {
        case forYou, mine, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .forYou: "For you"
            case .mine: "Mine"
            case .all: "All"
            }
        }
    }

    /// Why a PR is the viewer's business; also the sub-header's narrowing chips.
    struct Reasons: OptionSet, Hashable {
        let rawValue: Int
        static let reviewRequested = Reasons(rawValue: 1)
        static let assigned = Reasons(rawValue: 2)
        static let any: Reasons = [.reviewRequested, .assigned]
    }

    static func reasons(_ pr: OpenPullRequest, login: String?) -> Reasons {
        guard let login else { return [] }
        var r: Reasons = []
        if pr.reviewRequestedLogins.contains(login) { r.insert(.reviewRequested) }
        if pr.assignees.contains(login) { r.insert(.assigned) }
        return r
    }

    /// Counts for the toolbar's segments and the sub-header's chips. Segment
    /// counts are PRs that match directly (not the stack layers kept for context).
    struct Counts: Equatable {
        var forYou = 0, mine = 0, all = 0, reviewRequested = 0, assigned = 0

        func count(_ filter: Filter) -> Int {
            switch filter {
            case .forYou: forYou
            case .mine: mine
            case .all: all
            }
        }
    }

    static func counts(_ prs: [OpenPullRequest], login: String?) -> Counts {
        var c = Counts(all: prs.count)
        for pr in prs {
            let r = reasons(pr, login: login)
            if !r.isEmpty { c.forYou += 1 }
            if r.contains(.reviewRequested) { c.reviewRequested += 1 }
            if r.contains(.assigned) { c.assigned += 1 }
            if login != nil && pr.author == login { c.mine += 1 }
        }
        return c
    }

    /// The search field: every word must appear in the title, branch, author,
    /// a label, or the number ("#45" or "45").
    static func matches(_ pr: OpenPullRequest, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = [pr.title, pr.head, pr.author, pr.authorName ?? "", "#\(pr.number)"] + pr.labels.map(\.name)
        let haystack = fields.joined(separator: "\n").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// The sub-header's explanation of what the board is showing.
    static func explanation(filter: Filter, narrowing: Reasons, query: String, slug: String) -> String {
        var text: String
        let reasons = narrowing.isEmpty ? (filter == .forYou ? Reasons.any : []) : narrowing
        switch (filter, reasons) {
        case (.mine, []): text = "Opened by you, plus the rest of their stacks"
        case (.all, []): text = "Every open pull request in \(slug)"
        case (_, .reviewRequested): text = "Waiting on your review, plus the rest of their stacks"
        case (_, .assigned): text = "Assigned to you, plus the rest of their stacks"
        default: text = "Assigned to you or waiting on your review, plus the rest of their stacks"
        }
        if filter == .mine, !narrowing.isEmpty { text = "Opened by you and " + text.prefix(1).lowercased() + text.dropFirst() }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { text += " · matching “\(q)”" }
        return text
    }

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

        /// The last layer: the top of the stack.
        var top: OpenPullRequest { layers[layers.count - 1].pr }

        /// The stack's name: the "Prefix:" every layer's title shares
        /// ("Tab groups: iCloud sync", "Tab groups: Settings UI" → "Tab
        /// groups"), else the top PR's title.
        var name: String { PullRequestBoard.sharedTitlePrefix(pullRequests.map(\.title)) ?? top.title }

        /// A layer's title without the shared prefix ("iCloud sync").
        func shortTitle(_ pr: OpenPullRequest) -> String {
            guard let prefix = PullRequestBoard.sharedTitlePrefix(pullRequests.map(\.title)) else { return pr.title }
            let rest = pr.title.dropFirst(prefix.count).drop { $0 == ":" || $0 == " " }
            return rest.isEmpty ? pr.title : String(rest)
        }

        var additions: Int { pullRequests.reduce(0) { $0 + $1.additions } }
        var deletions: Int { pullRequests.reduce(0) { $0 + $1.deletions } }

        /// Layers waiting on the viewer's review.
        func toReview(login: String?) -> Int {
            pullRequests.filter { PullRequestBoard.reasons($0, login: login).contains(.reviewRequested) }.count
        }

        /// Failing and running layers (by check rollup), for the collapsed card's footer.
        var failingLayers: Int { pullRequests.filter { $0.checks == .failing }.count }
        var pendingLayers: Int { pullRequests.filter { $0.checks == .pending }.count }
    }

    /// The "Prefix" before a colon that every title shares, when there are at
    /// least two titles and they all have one.
    static func sharedTitlePrefix(_ titles: [String]) -> String? {
        guard titles.count > 1 else { return nil }
        let prefixes = titles.map { t -> String? in
            guard let colon = t.firstIndex(of: ":") else { return nil }
            let p = t[..<colon].trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? nil : p
        }
        guard let first = prefixes[0], prefixes.allSatisfy({ $0?.lowercased() == first.lowercased() }) else { return nil }
        return first
    }

    // MARK: Card text

    /// Two-letter initials for an avatar: from the display name's first and
    /// last words, else the login's parts ("jane-lin" → "JL") or first letters.
    static func initials(login: String, name: String? = nil) -> String {
        func two(_ words: [Substring]) -> String? {
            let w = words.filter { !$0.isEmpty }
            if w.count >= 2, let a = w.first?.first, let b = w.last?.first { return String([a, b]).uppercased() }
            if let only = w.first { return String(only.prefix(2)).uppercased() }
            return nil
        }
        if let name, let s = two(name.split(whereSeparator: \.isWhitespace)) { return s }
        return two(login.split { $0 == "-" || $0 == "_" || $0 == "." }) ?? "?"
    }

    /// "318", "1.4k", "12k".
    static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return k < 10 ? String(format: "%.1fk", k).replacingOccurrences(of: ".0k", with: "k") : "\(Int(k.rounded()))k"
    }

    /// "now", "12m", "2h", "1d".
    static func shortAge(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// Reviewers whose latest review requests changes.
    static func changesRequestedBy(_ pr: OpenPullRequest) -> [String] {
        pr.reviews.filter { $0.state == "CHANGES_REQUESTED" }.map(\.login)
    }

    /// Where "Check out into a new worktree" puts the PR (the layout
    /// `PullRequestsModel.makeWorktree` uses, before any `-pr<n>` suffix).
    static func worktreePath(root: String, repoName: String, head: String) -> String {
        "\(root)/\(repoName)/\(head.replacingOccurrences(of: "/", with: "-"))"
    }

    /// The prompt "Review with Claude" starts Claude with, in the PR's worktree.
    static func reviewPrompt(_ pr: OpenPullRequest) -> String {
        "Review pull request #\(pr.number) (\(pr.title)), checked out here from \(pr.head) into \(pr.base). "
            + "Read the description with `gh pr view \(pr.number)` and the changes with `gh pr diff \(pr.number)`. "
            + "Look for bugs, missing tests and anything that doesn't match the description, and summarize what you find "
            + "with file and line references. Don't push or post comments without asking."
    }

    /// The prompt "Fix with Claude" starts Claude with on a PR with requested changes.
    static func fixFeedbackPrompt(_ pr: OpenPullRequest, slug: String) -> String {
        let who = changesRequestedBy(pr)
        return "Address the changes requested" + (who.isEmpty ? "" : " by " + who.map { "@" + $0 }.joined(separator: ", "))
            + " on pull request #\(pr.number) (\(pr.title)). Read the reviews with `gh pr view \(pr.number) --comments` and the inline "
            + "comments with `gh api repos/\(slug)/pulls/\(pr.number)/comments`, make the fixes, and run the relevant tests. "
            + "Don't push without asking."
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

    /// What the board draws: each column's cards and the counts around them.
    /// Computed once per change (in the model), never in a view body.
    struct Layout: Equatable {
        var columns: [Column: [Stack]] = [:]
        var counts = Counts()

        /// Cards (a stack is one card) in a column.
        func cardCount(_ column: Column) -> Int { columns[column]?.count ?? 0 }
    }

    static func layout(_ prs: [OpenPullRequest], filter: Filter, narrowing: Reasons = [], query: String = "",
                       login: String?) -> Layout {
        Layout(columns: columns(prs, filter: filter, narrowing: narrowing, query: query, login: login),
               counts: counts(prs, login: login))
    }

    /// The board: each column's cards, most recently updated first. A stack
    /// shows when any of its layers passes the filter, the narrowing chips and
    /// the search, so the layers around it keep their context.
    static func columns(_ prs: [OpenPullRequest], filter: Filter, narrowing: Reasons = [], query: String = "",
                        login: String?) -> [Column: [Stack]] {
        var result: [Column: [Stack]] = [:]
        let wanted: Reasons = narrowing.isEmpty && filter == .forYou ? .any : narrowing
        for stack in stacks(prs) {
            let layers = stack.pullRequests
            if filter == .mine, !layers.contains(where: { login != nil && $0.author == login }) { continue }
            if !wanted.isEmpty, !layers.contains(where: { !reasons($0, login: login).isDisjoint(with: wanted) }) { continue }
            if !query.isEmpty, !layers.contains(where: { matches($0, query: query) }) { continue }
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
                author { login __typename ... on User { name } }
                assignees(first: 10) { nodes { login } }
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
        let counts = checkCounts(contexts)
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
            failedRunIDs: failedRunIDs(contexts),
            assignees: nodes("assignees").compactMap { $0["login"] as? String },
            authorName: (author["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            checksTotal: counts.total, checksPassing: counts.passing, checksFailing: counts.failing)
    }

    /// Check contexts by outcome, with the same rules as `OpenPullRequest.rollup`.
    static func checkCounts(_ contexts: [[String: Any]]) -> (total: Int, passing: Int, failing: Int) {
        var passing = 0, failing = 0
        for c in contexts {
            let (state, _) = OpenPullRequest.rollup([c])
            if state == .passing { passing += 1 } else if state == .failing { failing += 1 }
        }
        return (contexts.count, passing, failing)
    }

    /// Actions run IDs (`…/actions/runs/<id>/…`) of failing check runs.
    static func failedRunIDs(_ contexts: [[String: Any]]) -> [Int] {
        let failing: Set = ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE"]
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
