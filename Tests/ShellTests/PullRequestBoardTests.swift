import XCTest
@testable import Shell

final class PullRequestBoardTests: XCTestCase {
    private func pr(_ number: Int, head: String? = nil, base: String = "main", author: String = "me", draft: Bool = false,
                    decision: String? = nil, checks: OpenPullRequest.Checks = .passing, requested: [String] = [],
                    reviews: [OpenPullRequest.Review] = [], unresolved: Int = 0, fork: Bool = false,
                    updated: TimeInterval = 0, assignees: [String] = [], title: String? = nil) -> OpenPullRequest {
        OpenPullRequest(
            number: number, title: title ?? "PR \(number)", url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            isDraft: draft, head: head ?? "branch-\(number)", base: base, author: author, authorIsBot: false,
            reviewDecision: decision, updatedAt: Date(timeIntervalSince1970: updated), additions: 1, deletions: 1,
            isCrossRepository: fork, labels: [], checks: checks, checksSummary: "", reviewRequestedLogins: requested,
            reviews: reviews, unresolvedThreads: unresolved, assignees: assignees)
    }

    // MARK: Columns

    func testDraftWinsOverEverything() {
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, draft: true, decision: "APPROVED")), .draft)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, draft: true, decision: "CHANGES_REQUESTED")), .draft)
    }

    func testChangesRequested() {
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "CHANGES_REQUESTED")), .changesRequested)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "CHANGES_REQUESTED", checks: .failing)), .changesRequested)
    }

    func testApprovedIsReadyOnlyWithGreenChecks() {
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "APPROVED")), .ready)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "APPROVED", checks: .none)), .ready)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "APPROVED", checks: .failing)), .hasFeedback)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "APPROVED", checks: .pending)), .hasFeedback)
    }

    func testReviewRequiredWaitsUntilSomeoneReviews() {
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "REVIEW_REQUIRED", requested: ["alice"])), .waitingForReview)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "REVIEW_REQUIRED",
                                                       reviews: [.init(login: "alice", state: "COMMENTED")])), .hasFeedback)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "REVIEW_REQUIRED", unresolved: 2)), .hasFeedback)
        // The author's own comments aren't feedback.
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, decision: "REVIEW_REQUIRED",
                                                       reviews: [.init(login: "me", state: "COMMENTED")])), .waitingForReview)
    }

    func testNoReviewRequired() {
        // Nothing asked, nothing open, green: ready to merge.
        XCTAssertEqual(PullRequestBoard.column(for: pr(1)), .ready)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, checks: .failing)), .waitingForReview)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, requested: ["alice"])), .waitingForReview)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, requested: ["alice"], reviews: [.init(login: "bob", state: "COMMENTED")])), .hasFeedback)
        XCTAssertEqual(PullRequestBoard.column(for: pr(1, unresolved: 1)), .hasFeedback)
    }

    // MARK: Stacks

    func testLinearStackIsOrderedBottomToTop() {
        let prs = [pr(3, head: "c", base: "b"), pr(1, head: "a", base: "main"), pr(2, head: "b", base: "a"), pr(9, head: "x")]
        let stacks = PullRequestBoard.stacks(prs)
        XCTAssertEqual(stacks.count, 2)
        let stack = stacks.first { $0.layers.count > 1 }!
        XCTAssertEqual(stack.pullRequests.map(\.number), [1, 2, 3])
        XCTAssertEqual(stack.layers.map(\.depth), [0, 1, 2])
        XCTAssertFalse(stack.isBranching)
        XCTAssertEqual(stacks.first { $0.layers.count == 1 }?.bottom.number, 9)
    }

    func testBranchingStackListsEachBranchDepthFirst() {
        // 1 ← 2 ← 4, and 1 ← 3
        let prs = [pr(1, head: "a"), pr(2, head: "b", base: "a"), pr(3, head: "c", base: "a"), pr(4, head: "d", base: "b")]
        let stacks = PullRequestBoard.stacks(prs)
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks[0].pullRequests.map(\.number), [1, 2, 4, 3])
        XCTAssertEqual(stacks[0].layers.map(\.depth), [0, 1, 2, 1])
        XCTAssertTrue(stacks[0].isBranching)
    }

    func testPullRequestWhoseBasePRClosedStartsItsOwnStack() {
        // #1 (head "a") merged or closed: #2 still targets "a", but no open PR has that head.
        let prs = [pr(2, head: "b", base: "a"), pr(3, head: "c", base: "b")]
        let stacks = PullRequestBoard.stacks(prs)
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks[0].pullRequests.map(\.number), [2, 3])
        XCTAssertEqual(stacks[0].bottom.base, "a")
    }

    func testForkPullRequestsDontParentStacks() {
        // A fork's "feature" branch isn't this repo's "feature" branch.
        let prs = [pr(1, head: "feature", fork: true), pr(2, head: "next", base: "feature")]
        let stacks = PullRequestBoard.stacks(prs)
        XCTAssertEqual(stacks.count, 2)
        XCTAssertTrue(stacks.allSatisfy { $0.layers.count == 1 })
    }

    func testCycleDoesntHangOrDropPullRequests() {
        let prs = [pr(1, head: "a", base: "b"), pr(2, head: "b", base: "a")]
        let stacks = PullRequestBoard.stacks(prs)
        XCTAssertEqual(stacks.flatMap(\.pullRequests).map(\.number).sorted(), [1, 2])
        XCTAssertEqual(stacks.count, 1)
    }

    func testStackSitsInItsLeastReadyColumn() {
        let prs = [pr(1, head: "a", decision: "APPROVED"), pr(2, head: "b", base: "a", draft: true), pr(3, head: "c", base: "b", decision: "CHANGES_REQUESTED")]
        XCTAssertEqual(PullRequestBoard.stacks(prs)[0].column, .draft)
        let ready = [pr(1, head: "a", decision: "APPROVED"), pr(2, head: "b", base: "a", decision: "CHANGES_REQUESTED")]
        XCTAssertEqual(PullRequestBoard.stacks(ready)[0].column, .changesRequested)
    }

    // MARK: Filter

    func testMineKeepsWholeStacksContainingYourPullRequest() {
        let prs = [pr(1, head: "a", author: "alice"), pr(2, head: "b", base: "a", author: "me"), pr(5, head: "e", author: "bob")]
        let mine = PullRequestBoard.columns(prs, filter: .mine, login: "me").values.flatMap { $0 }
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine[0].pullRequests.map(\.number), [1, 2])
        let all = PullRequestBoard.columns(prs, filter: .all, login: "me").values.flatMap { $0 }
        XCTAssertEqual(all.flatMap(\.pullRequests).count, 3)
        // Unknown login: Mine shows nothing rather than everything.
        XCTAssertTrue(PullRequestBoard.columns(prs, filter: .mine, login: nil).isEmpty)
    }

    func testColumnsSortByMostRecentUpdate() {
        let prs = [pr(1, updated: 100), pr(2, updated: 300), pr(3, updated: 200)]
        let ready = PullRequestBoard.columns(prs, filter: .all, login: nil)[.ready] ?? []
        XCTAssertEqual(ready.map(\.bottom.number), [2, 3, 1])
    }

    // MARK: For you

    /// 1 ← 2 ← 3 is a stack; 2 waits on my review. 4 is assigned to me, 5 is
    /// someone else's with nothing for me, 6 is mine.
    private var forYouBoard: [OpenPullRequest] {
        [pr(1, head: "a", author: "alice"), pr(2, head: "b", base: "a", author: "alice", requested: ["me"]),
         pr(3, head: "c", base: "b", author: "alice", draft: true),
         pr(4, head: "d", author: "bob", assignees: ["me", "carol"]),
         pr(5, head: "e", author: "bob", requested: ["carol"]),
         pr(6, head: "f", author: "me")]
    }

    private func numbers(_ columns: [PullRequestBoard.Column: [PullRequestBoard.Stack]]) -> [Int] {
        columns.values.flatMap { $0 }.flatMap(\.pullRequests).map(\.number).sorted()
    }

    func testForYouIsReviewRequestsAndAssignmentsPlusTheRestOfTheirStacks() {
        let cols = PullRequestBoard.columns(forYouBoard, filter: .forYou, login: "me")
        XCTAssertEqual(numbers(cols), [1, 2, 3, 4], "the whole stack around #2 comes along; #5 and my own #6 don't")
        XCTAssertEqual(cols.values.flatMap { $0 }.count, 2, "a stack is one card")
        XCTAssertTrue(PullRequestBoard.columns(forYouBoard, filter: .forYou, login: nil).isEmpty, "no login, nothing for you")
    }

    func testReasons() {
        let prs = forYouBoard
        XCTAssertEqual(PullRequestBoard.reasons(prs[1], login: "me"), .reviewRequested)
        XCTAssertEqual(PullRequestBoard.reasons(prs[3], login: "me"), .assigned)
        XCTAssertEqual(PullRequestBoard.reasons(pr(9, requested: ["me"], assignees: ["me"]), login: "me"), .any)
        XCTAssertEqual(PullRequestBoard.reasons(prs[4], login: "me"), [])
        XCTAssertEqual(PullRequestBoard.reasons(prs[1], login: nil), [])
    }

    func testNarrowingChipsKeepOnlyThatReason() {
        let prs = forYouBoard
        XCTAssertEqual(numbers(PullRequestBoard.columns(prs, filter: .forYou, narrowing: .reviewRequested, login: "me")), [1, 2, 3])
        XCTAssertEqual(numbers(PullRequestBoard.columns(prs, filter: .forYou, narrowing: .assigned, login: "me")), [4])
        XCTAssertEqual(numbers(PullRequestBoard.columns(prs, filter: .forYou, narrowing: .any, login: "me")), [1, 2, 3, 4])
        // Under All the chips narrow the same way; under Mine they combine with authorship.
        XCTAssertEqual(numbers(PullRequestBoard.columns(prs, filter: .all, narrowing: .assigned, login: "me")), [4])
        XCTAssertEqual(numbers(PullRequestBoard.columns(prs, filter: .mine, narrowing: .assigned, login: "me")), [])
    }

    func testCountsForSegmentsAndChips() {
        let c = PullRequestBoard.counts(forYouBoard, login: "me")
        XCTAssertEqual(c, .init(forYou: 2, mine: 1, all: 6, reviewRequested: 1, assigned: 1),
                       "segments count PRs that match directly, not the stack layers kept for context")
        XCTAssertEqual(c.count(.forYou), 2)
        XCTAssertEqual(c.count(.mine), 1)
        XCTAssertEqual(c.count(.all), 6)
        XCTAssertEqual(PullRequestBoard.counts(forYouBoard, login: nil), .init(all: 6))
        let layout = PullRequestBoard.layout(forYouBoard, filter: .forYou, login: "me")
        XCTAssertEqual(layout.counts, c)
        XCTAssertEqual(layout.cardCount(.draft), 1, "the stack sits in Draft, its least-ready layer (#3)")
        XCTAssertEqual(layout.cardCount(.ready), 1)
    }

    func testStackColumnIsItsLeastReadyLayerOnTheForYouBoard() {
        let prs = [pr(1, head: "a", author: "x", decision: "APPROVED"),
                   pr(2, head: "b", base: "a", author: "x", decision: "REVIEW_REQUIRED", requested: ["me"]),
                   pr(3, head: "c", base: "b", author: "x", decision: "CHANGES_REQUESTED")]
        let cols = PullRequestBoard.columns(prs, filter: .forYou, login: "me")
        // Waiting for review is left of (less ready than) Changes requested and Ready.
        XCTAssertEqual(cols[.waitingForReview]?.first?.pullRequests.map(\.number), [1, 2, 3])
        XCTAssertNil(cols[.changesRequested])
        XCTAssertNil(cols[.ready])
    }

    func testSearchMatchesTitleBranchAuthorLabelAndNumber() {
        var p = pr(45, head: "perf/simd-search", author: "jlin", title: "Faster scrollback search")
        p.labels = [("performance", "ff0000")]
        p.authorName = "Jane Lin"
        for q in ["", "  ", "faster", "SIMD", "jlin", "jane", "perform", "#45", "45", "faster simd"] {
            XCTAssertTrue(PullRequestBoard.matches(p, query: q), q)
        }
        for q in ["slower", "#46", "faster nope"] { XCTAssertFalse(PullRequestBoard.matches(p, query: q), q) }
        // A stack shows when any layer matches.
        let prs = [pr(1, head: "a", title: "Model"), pr(2, head: "b", base: "a", title: "Settings UI"), pr(3, head: "z", title: "Other")]
        XCTAssertEqual(numbers(PullRequestBoard.columns(prs, filter: .all, query: "settings", login: nil)), [1, 2])
    }

    func testExplanation() {
        XCTAssertEqual(PullRequestBoard.explanation(filter: .forYou, narrowing: [], query: "", slug: "o/r"),
                       "Assigned to you or waiting on your review, plus the rest of their stacks")
        XCTAssertEqual(PullRequestBoard.explanation(filter: .forYou, narrowing: .reviewRequested, query: "", slug: "o/r"),
                       "Waiting on your review, plus the rest of their stacks")
        XCTAssertEqual(PullRequestBoard.explanation(filter: .all, narrowing: .assigned, query: "", slug: "o/r"),
                       "Assigned to you, plus the rest of their stacks")
        XCTAssertEqual(PullRequestBoard.explanation(filter: .all, narrowing: [], query: " ui ", slug: "o/r"),
                       "Every open pull request in o/r · matching “ui”")
        XCTAssertEqual(PullRequestBoard.explanation(filter: .mine, narrowing: [], query: "", slug: "o/r"),
                       "Opened by you, plus the rest of their stacks")
        XCTAssertEqual(PullRequestBoard.explanation(filter: .mine, narrowing: .assigned, query: "", slug: "o/r"),
                       "Opened by you and assigned to you, plus the rest of their stacks")
        XCTAssertEqual(PullRequestBoard.Filter.allCases.map(\.title), ["For you", "Mine", "All"])
    }

    // MARK: Card text

    func testStackNameIsTheSharedTitlePrefix() throws {
        let prs = [pr(41, head: "a", title: "Tab groups: Model and migration"), pr(42, head: "b", base: "a", title: "Tab groups: iCloud sync"),
                   pr(43, head: "c", base: "b", title: "tab groups: Settings UI")]
        let stack = try XCTUnwrap(PullRequestBoard.stacks(prs).first)
        XCTAssertEqual(stack.name, "Tab groups")
        XCTAssertEqual(stack.top.number, 43)
        XCTAssertEqual(stack.shortTitle(prs[1]), "iCloud sync")
        XCTAssertEqual(stack.additions, 3)
        XCTAssertEqual(stack.deletions, 3)
        // No shared prefix: the top PR's title, layers keep theirs.
        let plain = try XCTUnwrap(PullRequestBoard.stacks([pr(1, head: "a", title: "Model"), pr(2, head: "b", base: "a", title: "UI: views")]).first)
        XCTAssertEqual(plain.name, "UI: views")
        XCTAssertEqual(plain.shortTitle(plain.top), "UI: views")
        XCTAssertNil(PullRequestBoard.sharedTitlePrefix(["Only: one"]))
        XCTAssertNil(PullRequestBoard.sharedTitlePrefix([": a", ": b"]))
    }

    func testStackReviewAndCheckCounts() throws {
        let prs = [pr(1, head: "a", author: "x", checks: .failing, requested: ["me"]), pr(2, head: "b", base: "a", author: "x", checks: .pending),
                   pr(3, head: "c", base: "b", author: "x", checks: .pending, requested: ["me", "y"])]
        let stack = try XCTUnwrap(PullRequestBoard.stacks(prs).first)
        XCTAssertEqual(stack.toReview(login: "me"), 2)
        XCTAssertEqual(stack.toReview(login: nil), 0)
        XCTAssertEqual(stack.failingLayers, 1)
        XCTAssertEqual(stack.pendingLayers, 2)
    }

    func testInitialsCompactNumbersAndAges() {
        XCTAssertEqual(PullRequestBoard.initials(login: "jane-lin"), "JL")
        XCTAssertEqual(PullRequestBoard.initials(login: "arhea"), "AR")
        XCTAssertEqual(PullRequestBoard.initials(login: "x", name: "Mary Kate Olsen"), "MO")
        XCTAssertEqual(PullRequestBoard.initials(login: "x", name: "Cher"), "CH")
        XCTAssertEqual(PullRequestBoard.initials(login: "a_b", name: "  "), "AB")
        XCTAssertEqual(PullRequestBoard.initials(login: ""), "?")

        XCTAssertEqual(PullRequestBoard.compact(318), "318")
        XCTAssertEqual(PullRequestBoard.compact(1000), "1k")
        XCTAssertEqual(PullRequestBoard.compact(1400), "1.4k")
        XCTAssertEqual(PullRequestBoard.compact(12_400), "12k")

        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PullRequestBoard.shortAge(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(PullRequestBoard.shortAge(now.addingTimeInterval(-12 * 60), now: now), "12m")
        XCTAssertEqual(PullRequestBoard.shortAge(now.addingTimeInterval(-2 * 3600), now: now), "2h")
        XCTAssertEqual(PullRequestBoard.shortAge(now.addingTimeInterval(-86400 - 5), now: now), "1d")
        XCTAssertEqual(PullRequestBoard.shortAge(now.addingTimeInterval(60), now: now), "now")
    }

    func testPromptsAndWorktreePath() {
        let p = pr(33, head: "fix/icloud", author: "me", reviews: [.init(login: "jlin", state: "CHANGES_REQUESTED"), .init(login: "b", state: "APPROVED")],
                   title: "Settings: resolve conflicts")
        XCTAssertEqual(PullRequestBoard.changesRequestedBy(p), ["jlin"])
        let fix = PullRequestBoard.fixFeedbackPrompt(p, slug: "o/r")
        XCTAssertTrue(fix.contains("@jlin"))
        XCTAssertTrue(fix.contains("gh api repos/o/r/pulls/33/comments"))
        let review = PullRequestBoard.reviewPrompt(p)
        XCTAssertTrue(review.contains("#33"))
        XCTAssertTrue(review.contains("gh pr diff 33"))
        XCTAssertEqual(PullRequestBoard.worktreePath(root: "/w", repoName: "Shell", head: "fix/icloud"), "/w/Shell/fix-icloud")
    }

    // MARK: Parsing

    func testParsesAssigneesAuthorNameAndCheckCounts() throws {
        let node: [String: Any] = [
            "number": 8, "url": "https://github.com/o/r/pull/8", "title": "T", "headRefName": "h", "baseRefName": "main",
            "author": ["login": "jlin", "__typename": "User", "name": "Jane Lin"],
            "assignees": ["nodes": [["login": "me"], ["login": "carol"]]],
            "commits": ["nodes": [["commit": ["statusCheckRollup": ["contexts": ["nodes": [
                ["__typename": "CheckRun", "name": "a", "status": "COMPLETED", "conclusion": "SUCCESS"],
                ["__typename": "CheckRun", "name": "b", "status": "COMPLETED", "conclusion": "SKIPPED"],
                ["__typename": "CheckRun", "name": "c", "status": "IN_PROGRESS"],
                ["__typename": "CheckRun", "name": "d", "status": "COMPLETED", "conclusion": "FAILURE"],
            ]]]]]]],
        ]
        let p = try XCTUnwrap(PullRequestBoard.parsePullRequest(node))
        XCTAssertEqual(p.assignees, ["me", "carol"])
        XCTAssertEqual(p.authorName, "Jane Lin")
        XCTAssertEqual(p.checksTotal, 4)
        XCTAssertEqual(p.checksPassing, 2)
        XCTAssertEqual(p.checksFailing, 1)
        XCTAssertEqual(PullRequestBoard.reasons(p, login: "me"), .assigned)
        // Missing fields default to empty.
        let bare = try XCTUnwrap(PullRequestBoard.parsePullRequest(["number": 9, "url": "https://github.com/o/r/pull/9", "author": ["login": "x", "name": ""]]))
        XCTAssertEqual(bare.assignees, [])
        XCTAssertNil(bare.authorName)
        XCTAssertEqual(bare.checksTotal, 0)
        XCTAssertTrue(PullRequestBoard.query.contains("assignees(first: 10)"))
    }

    func testParsesGraphQLResponse() throws {
        let json = """
            {"data":{"viewer":{"login":"me"},"repository":{
              "mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":false,"viewerDefaultMergeMethod":"MERGE",
              "pullRequests":{"nodes":[{
                "number":7,"title":"Add board","url":"https://github.com/o/r/pull/7","isDraft":false,
                "headRefName":"feat/board","baseRefName":"main","isCrossRepository":false,
                "reviewDecision":"REVIEW_REQUIRED","updatedAt":"2026-09-30T12:00:00Z","additions":10,"deletions":2,
                "author":{"login":"dependabot","__typename":"Bot"},
                "labels":{"nodes":[{"name":"feature","color":"a2eeef"}]},
                "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"alice"}},{"requestedReviewer":{"__typename":"Team","slug":"core"}}]},
                "latestReviews":{"nodes":[{"author":{"login":"bob"},"state":"COMMENTED"}]},
                "reviewThreads":{"nodes":[{"isResolved":true},{"isResolved":false}]},
                "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
                  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/123/job/9"},
                  {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/123/job/10"},
                  {"__typename":"StatusContext","context":"ci/other","state":"SUCCESS","targetUrl":"https://ci.example.com"}
                ]}}}}]}
              }]}}}}
            """
        let snapshot = try XCTUnwrap(PullRequestBoard.parse(Data(json.utf8)))
        XCTAssertEqual(snapshot.login, "me")
        XCTAssertEqual(snapshot.mergeMethods, [.merge, .squash])
        let p = try XCTUnwrap(snapshot.pullRequests.first)
        XCTAssertEqual(p.number, 7)
        XCTAssertTrue(p.authorIsBot)
        XCTAssertEqual(p.reviewRequestedLogins, ["alice", "team:core"])
        XCTAssertEqual(p.reviews, [.init(login: "bob", state: "COMMENTED")])
        XCTAssertEqual(p.unresolvedThreads, 1)
        XCTAssertEqual(p.checks, .failing)
        XCTAssertEqual(p.failedRunIDs, [123])
        XCTAssertEqual(p.labels.first?.name, "feature")
        XCTAssertEqual(PullRequestBoard.column(for: p), .hasFeedback)
    }

    func testErrorPayloadDoesntParse() {
        XCTAssertNil(PullRequestBoard.parse(Data(#"{"errors":[{"message":"Could not resolve"}]}"#.utf8)))
    }

    func testRunIDFromDetailsURL() {
        XCTAssertEqual(PullRequestBoard.runID(in: "https://github.com/o/r/actions/runs/4567/job/1"), 4567)
        XCTAssertNil(PullRequestBoard.runID(in: "https://ci.example.com/build/1"))
    }

    func testParsesDetailConversation() throws {
        let view = """
            {"body":"Adds a board.","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
             "comments":[{"id":"c1","author":{"login":"alice"},"body":"Nice","createdAt":"2026-09-30T10:00:00Z","url":"https://github.com/o/r/pull/7#c1"}],
             "reviews":[{"id":"r1","author":{"login":"bob"},"state":"COMMENTED","body":"","submittedAt":"2026-09-30T11:00:00Z"},
                        {"id":"r2","author":{"login":"bob"},"state":"CHANGES_REQUESTED","body":"Fix this","submittedAt":"2026-09-30T12:00:00Z"}],
             "latestReviews":[{"author":{"login":"bob"},"state":"CHANGES_REQUESTED"}],
             "reviewRequests":[{"login":"carol"},{"slug":"core"}],
             "statusCheckRollup":[{"name":"test","workflowName":"CI","status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://x"}]}
            """
        let comments = #"[{"id":5,"user":{"login":"bob"},"body":"here","path":"a.swift","line":3,"created_at":"2026-09-30T11:00:01Z"}]"#
        let d = try XCTUnwrap(PullRequestDetail.parse(view: Data(view.utf8), reviewComments: Data(comments.utf8)))
        XCTAssertEqual(d.events.map(\.author), ["alice", "bob", "bob"])
        XCTAssertEqual(d.events[1].kind, .reviewComment(path: "a.swift", line: 3))
        XCTAssertEqual(d.events[2].kind, .review(state: "CHANGES_REQUESTED"))
        XCTAssertEqual(d.reviewers.map(\.login), ["bob", "carol", "team:core"])
        XCTAssertEqual(d.checks.first?.state, .pending)
        XCTAssertEqual(d.checks.first?.workflow, "CI")
        XCTAssertEqual(d.jobs.map(\.state), [.running], "the same checks as CI jobs for the shared rows")
        XCTAssertNil(d.changedFiles)
        XCTAssertNil(d.createdAt)
        XCTAssertTrue(PullRequestDetail.viewFields.contains("changedFiles"))

        let more = #"{"body":"","changedFiles":7,"createdAt":"2026-09-30T09:00:00Z"}"#
        let e = try XCTUnwrap(PullRequestDetail.parse(view: Data(more.utf8), reviewComments: nil))
        XCTAssertEqual(e.changedFiles, 7)
        XCTAssertNotNil(e.createdAt)
    }

    // MARK: Diff

    func testParsesUnifiedDiff() {
        let patch = """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -10,3 +10,4 @@ struct A {
                 let a = 1
            -    let b = 2
            +    let b = 3
            ++++ not a header
                 let c = 4
            diff --git a/old.txt b/new.txt
            similarity index 90%
            rename from old.txt
            rename to new.txt
            diff --git a/logo.png b/logo.png
            Binary files a/logo.png and b/logo.png differ
            """
        let files = PullRequestDiff.parse(patch)
        XCTAssertEqual(files.map(\.path), ["Sources/A.swift", "new.txt", "logo.png"])
        let a = files[0]
        XCTAssertEqual(a.additions, 2)
        XCTAssertEqual(a.deletions, 1)
        XCTAssertEqual(a.lines.map(\.kind), [.gap, .context, .removed, .added, .added, .context])
        XCTAssertEqual(a.lines[0].text, "struct A {")
        XCTAssertEqual(a.lines[2].oldNumber, 11)
        XCTAssertEqual(a.lines[3].newNumber, 11)
        XCTAssertEqual(a.lines[4].text, "+++ not a header")
        XCTAssertEqual(a.lines[5].oldNumber, 12)
        XCTAssertEqual(a.lines[5].newNumber, 13)
        XCTAssertEqual(files[1].oldPath, "old.txt")
        XCTAssertTrue(files[2].isBinary)
    }
}
