import XCTest
@testable import Shell

final class PullRequestBoardTests: XCTestCase {
    private func pr(_ number: Int, head: String? = nil, base: String = "main", author: String = "me", draft: Bool = false,
                    decision: String? = nil, checks: OpenPullRequest.Checks = .passing, requested: [String] = [],
                    reviews: [OpenPullRequest.Review] = [], unresolved: Int = 0, fork: Bool = false,
                    updated: TimeInterval = 0) -> OpenPullRequest {
        OpenPullRequest(
            number: number, title: "PR \(number)", url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            isDraft: draft, head: head ?? "branch-\(number)", base: base, author: author, authorIsBot: false,
            reviewDecision: decision, updatedAt: Date(timeIntervalSince1970: updated), additions: 1, deletions: 1,
            isCrossRepository: fork, labels: [], checks: checks, checksSummary: "", reviewRequestedLogins: requested,
            reviews: reviews, unresolvedThreads: unresolved)
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

    // MARK: Parsing

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
