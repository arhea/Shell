import AppKit
import XCTest
@testable import Shell

/// `gh run list` JSON for the Actions sidebar.
enum GitFixtureRuns {
    static func run(_ id: Int, status: String = "completed", conclusion: String = "success", title: String? = nil,
                    attempt: Int = 1, event: String = "pull_request", branch: String = "main") -> [String: Any] {
        ["databaseId": id, "number": id, "displayTitle": title ?? "Run \(id)", "workflowName": "CI", "status": status,
         "conclusion": conclusion, "headBranch": branch, "event": event, "attempt": attempt,
         "url": "https://github.com/acme/widgets/actions/runs/\(id)",
         "createdAt": "2026-09-30T10:00:00Z", "startedAt": "2026-09-30T10:00:05Z", "updatedAt": "2026-09-30T10:03:00Z"]
    }

    static var jobs: [String: Any] { ["jobs": [
        // No job URLs: pressing a job row in a view test must not open a browser.
        ["name": "build", "status": "completed", "conclusion": "success",
         "startedAt": "2026-09-30T10:00:05Z", "completedAt": "2026-09-30T10:02:00Z"],
        ["name": "test", "status": "in_progress", "conclusion": "", "startedAt": "2026-09-30T10:00:05Z"],
    ]] }
}

// MARK: - Workflow runs

final class WorkflowRunTests: XCTestCase {
    func testStateMapping() {
        for s in ["queued", "waiting", "PENDING", "requested"] { XCTAssertEqual(WorkflowRun.state(status: s, conclusion: ""), .queued) }
        XCTAssertEqual(WorkflowRun.state(status: "in_progress", conclusion: ""), .running)
        XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: "success"), .success)
        for c in ["failure", "timed_out", "startup_failure", "action_required"] {
            XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: c), .failure)
        }
        XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: "cancelled"), .cancelled)
        XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: "skipped"), .skipped)
        XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: "neutral"), .neutral)
    }

    func testParseAndDuration() throws {
        let run = try XCTUnwrap(WorkflowRun.parse(GitFixtureRuns.run(7, attempt: 2)))
        XCTAssertEqual(run.id, 7)
        XCTAssertEqual(run.workflow, "CI")
        XCTAssertEqual(run.attempt, 2)
        XCTAssertEqual(run.state, .success)
        XCTAssertFalse(run.isActive)
        XCTAssertEqual(try XCTUnwrap(run.duration), 175, accuracy: 0.5)
        XCTAssertNil(WorkflowRun.parse(["databaseId": 1]))
        let bare = try XCTUnwrap(WorkflowRun.parse(["databaseId": 2, "url": "https://x.test/r"]))
        XCTAssertEqual(bare.attempt, 1)
        XCTAssertNil(bare.duration)
        var running = run
        running.status = "in_progress"
        XCTAssertTrue(running.isActive)
        XCTAssertGreaterThan(running.duration ?? 0, 1000, "elapsed time runs to now")
        var finished = run
        finished.updatedAt = nil
        XCTAssertNotNil(finished.duration)
    }

    func testJobIdentityAndState() {
        let job = WorkflowJob(name: "build", status: "completed", conclusion: "failure", url: URL(string: "https://x.test/j"))
        XCTAssertEqual(job.id, "buildhttps://x.test/j")
        XCTAssertEqual(job.state, .failure)
        XCTAssertEqual(WorkflowJob(name: "lint", status: "queued", conclusion: "").id, "lint")
    }
}

final class ActionsModelTests: GitAreaTestCase {
    private func model(_ gh: FakeGH, _ dir: URL) -> ActionsModel {
        ActionsModel(repoRoot: dir.path, environment: gh.environment(home: dir))
    }

    func testWithoutGhExplainsHowToInstallIt() async throws {
        let m = ActionsModel(repoRoot: NSTemporaryDirectory(), environment: ["PATH": "/nonexistent"])
        m.refresh()
        try await eventually { m.error != nil }
        XCTAssertTrue(m.error?.contains("brew install gh") == true)
        m.toggle(try XCTUnwrap(WorkflowRun.parse(GitFixtureRuns.run(1))))
        XCTAssertEqual(m.expanded, [1], "expands even without gh")
        m.perform(try XCTUnwrap(WorkflowRun.parse(GitFixtureRuns.run(1))), "cancel")
        XCTAssertTrue(m.busy.isEmpty, "nothing to run")
    }

    func testLoadsRunsAndJobsAndFiltersByBranch() async throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        try gh.on("run list *", json: [GitFixtureRuns.run(1, status: "in_progress", conclusion: ""), GitFixtureRuns.run(2, conclusion: "failure"),
                                       ["junk": true]])
        try gh.on("run view 1 *", json: GitFixtureRuns.jobs)
        try gh.on("run view 2 *", stdout: "oops")
        let m = model(gh, dir)
        m.attach()
        try await eventually("runs") { m.runs.count == 2 }
        XCTAssertNil(m.error)
        XCTAssertNotNil(m.lastUpdated)
        XCTAssertEqual(m.activeCount, 1)

        m.toggle(m.runs[0])
        try await eventually("jobs") { m.jobs[1]?.count == 2 }
        XCTAssertEqual(m.jobs[1]?.first?.name, "build")
        XCTAssertNotNil(m.jobs[1]?.first?.completedAt)
        m.toggle(m.runs[1])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(m.jobs[2], "unreadable jobs are skipped")
        m.toggle(m.runs[1])
        XCTAssertEqual(m.expanded, [1])

        // A refresh reloads jobs for an expanded running run.
        let before = gh.calls(matching: "run view 1").count
        try await eventually("job reload") {
            if !m.isLoading { m.refresh() }
            return gh.calls(matching: "run view 1").count > before
        }

        // This branch only.
        m.branch = "feature"
        m.scope = .branch
        XCTAssertEqual(m.scope, .branch)
        try await eventually("branch scope") {
            if !m.isLoading { m.refresh() }
            return gh.calls.contains { $0.contains("--branch feature") }
        }
        m.scope = .all

        // Pausing stops polling; resuming catches up.
        m.isPaused = true
        m.isPaused = true
        try await eventually("idle") { !m.isLoading }
        let calls = gh.calls(matching: "run list").count
        m.isPaused = false
        try await eventually("resume") { gh.calls(matching: "run list").count > calls }
        m.detach()
        m.detach()
        m.isPaused = true // no viewers: nothing to do
        m.isPaused = false
    }

    func testBadOutputIsAnError() async throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        try gh.on("run list *", stdout: "nope", status: 1)
        let m = model(gh, dir)
        m.refresh()
        try await eventually { m.error != nil }
        XCTAssertTrue(m.error?.hasPrefix("Couldn't load workflow runs") == true)
    }

    func testCancelAndRerun() async throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        try gh.on("run cancel 1", stderr: "already finished", status: 1)
        try gh.on("run rerun 2 --failed")
        try gh.on("run list *", json: [GitFixtureRuns.run(1), GitFixtureRuns.run(2, conclusion: "failure")])
        let m = model(gh, dir)
        let one = try XCTUnwrap(WorkflowRun.parse(GitFixtureRuns.run(1)))
        let two = try XCTUnwrap(WorkflowRun.parse(GitFixtureRuns.run(2, conclusion: "failure")))
        m.perform(one, "cancel")
        m.perform(two, "rerun")
        XCTAssertEqual(m.busy, [1, 2])
        try await eventually(timeout: 8, "actions finish") { m.busy.isEmpty }
        XCTAssertEqual(m.message, "already finished")
        XCTAssertTrue(gh.calls.contains("run rerun 2 --failed"))
        try await eventually("reload") { m.runs.count == 2 }
    }
}

// MARK: - Pull requests (sidebar)

final class OpenPullRequestParsingTests: XCTestCase {
    func testParsesGhPrListEntry() throws {
        let o: [String: Any] = [
            "number": 12, "title": "Add things", "url": "https://github.com/acme/widgets/pull/12", "isDraft": true,
            "headRefName": "feat", "baseRefName": "main", "author": ["login": "dependabot", "is_bot": true],
            "reviewDecision": "", "updatedAt": "2026-09-30T10:00:00Z", "additions": 5, "deletions": 2, "isCrossRepository": true,
            "labels": [["name": "deps", "color": "0366d6"], ["name": "nocolor"]],
            "reviewRequests": [["login": "octocat"], ["slug": "team"]],
            "statusCheckRollup": [["status": "COMPLETED", "conclusion": "SUCCESS"]],
        ]
        let pr = try XCTUnwrap(OpenPullRequest.parse(o))
        XCTAssertEqual(pr.id, 12)
        XCTAssertTrue(pr.isDraft)
        XCTAssertTrue(pr.authorIsBot)
        XCTAssertNil(pr.reviewDecision)
        XCTAssertNotNil(pr.updatedAt)
        XCTAssertTrue(pr.isCrossRepository)
        XCTAssertEqual(pr.labels.map(\.color), ["0366d6", "888888"])
        XCTAssertEqual(pr.reviewRequestedLogins, ["octocat"])
        XCTAssertEqual(pr.checks, .passing)
        XCTAssertNil(OpenPullRequest.parse(["number": 1]))
        let minimal = try XCTUnwrap(OpenPullRequest.parse(["number": 1, "url": "https://x.test/1"]))
        XCTAssertEqual(minimal.checks, .none)
        XCTAssertEqual(minimal.checksSummary, "No checks")
    }

    func testRollup() {
        XCTAssertEqual(OpenPullRequest.rollup([]).0, .none)
        let mixed = OpenPullRequest.rollup([
            ["status": "COMPLETED", "conclusion": "FAILURE"], ["state": "ERROR"], ["status": "IN_PROGRESS"], ["state": "EXPECTED"],
            ["status": "COMPLETED", "conclusion": "SUCCESS"], ["state": "SUCCESS"],
        ])
        XCTAssertEqual(mixed.0, .failing)
        XCTAssertEqual(mixed.1, "2 failing, 2 pending, 2 passing")
        XCTAssertEqual(OpenPullRequest.rollup([["state": "PENDING"], ["conclusion": "SUCCESS"]]).0, .pending)
        XCTAssertEqual(OpenPullRequest.rollup([["conclusion": "SUCCESS"]]).0, .passing)
        XCTAssertEqual(OpenPullRequest.rollup([["conclusion": "SUCCESS"]]).1, "1 passing")
    }

    func testEqualityIgnoresLabelsAndCounts() {
        let a = GitFixturePR.open(1, labels: [("x", "fff")])
        var b = a
        b.labels = []
        b.additions = 99
        XCTAssertEqual(a, b)
        b.title = "changed"
        XCTAssertNotEqual(a, b)
    }
}

final class PullRequestsModelTests: GitAreaTestCase {
    private var prList: [[String: Any]] {
        [
            ["number": 1, "title": "Mine", "url": "https://github.com/acme/widgets/pull/1", "headRefName": "mine", "baseRefName": "main",
             "author": ["login": "octocat"], "updatedAt": "2026-09-29T10:00:00Z"],
            ["number": 2, "title": "Review me", "url": "https://github.com/acme/widgets/pull/2", "headRefName": "theirs", "baseRefName": "main",
             "author": ["login": "hubot"], "updatedAt": "2026-09-30T10:00:00Z", "reviewRequests": [["login": "octocat"]]],
            ["number": 3, "title": "Old", "url": "https://github.com/acme/widgets/pull/3", "headRefName": "old", "baseRefName": "main",
             "author": ["login": "hubot"]],
        ]
    }

    func testRefreshLoadsSortsAndFilters() async throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        try gh.on("api user *", stdout: "octocat\n")
        try gh.on("pr list *", json: prList)
        let m = PullRequestsModel(repoRoot: dir.path, environment: gh.environment(home: dir))
        m.refreshIfNeeded()
        XCTAssertTrue(m.isLoading)
        m.refresh() // ignored while loading
        try await eventually { !m.isLoading }
        XCTAssertNil(m.error)
        XCTAssertEqual(m.pullRequests.map(\.number), [2, 1, 3], "most recently updated first")
        XCTAssertEqual(m.login, "octocat")
        XCTAssertEqual(m.reviewRequested.map(\.number), [2])
        XCTAssertTrue(m.isMine(m.pullRequests[1]))
        XCTAssertFalse(m.isMine(m.pullRequests[0]))
        m.filter = .review
        XCTAssertEqual(m.filtered.map(\.number), [2])
        m.filter = .mine
        XCTAssertEqual(m.filtered.map(\.number), [1])
        m.filter = .all
        XCTAssertEqual(m.filtered.count, 3)

        let calls = gh.calls.count
        m.refreshIfNeeded()
        XCTAssertFalse(m.isLoading, "fresh enough")
        m.isPaused = true
        m.isPaused = false // resuming checks again, still fresh
        XCTAssertEqual(gh.calls.count, calls)
    }

    func testErrorsDistinguishSignedOutFromOtherFailures() async throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        try gh.on("api user *", stdout: "octocat")
        try gh.on("pr list *", status: 1)
        try gh.on("auth status", status: 1)
        let m = PullRequestsModel(repoRoot: dir.path, environment: gh.environment(home: dir))
        m.refresh()
        try await eventually { !m.isLoading && m.error != nil }
        XCTAssertEqual(m.error, "Run `gh auth login` to see pull requests.")

        try gh.reset()
        try gh.on("pr list *", stdout: "[")
        try gh.on("auth status")
        m.refresh()
        try await eventually { !m.isLoading && m.error == "Couldn't load pull requests from GitHub." }

        let none = PullRequestsModel(repoRoot: dir.path, environment: ["PATH": "/nonexistent"])
        none.refresh()
        XCTAssertTrue(none.error?.contains("brew install gh") == true)
    }

    func testCreateWorktreeChecksOutThePullRequest() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        let gh = try FakeGH(in: dir)
        try gh.on("pr checkout 2")
        try gh.on("pr checkout 3", stderr: "no such PR", status: 1)
        let root = dir.appendingPathComponent("worktrees")
        SettingsStore.shared.settings.worktreeRoot = root.path
        let m = PullRequestsModel(repoRoot: repo.root.path, environment: gh.environment(home: dir))

        let path = await m.createWorktree(for: GitFixturePR.open(2, head: "feature/two"), repoName: "widgets")
        XCTAssertEqual(path, root.appendingPathComponent("widgets/feature-two").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path ?? ""))
        XCTAssertNil(m.lastMessage)
        XCTAssertTrue(m.creating.isEmpty)

        // Same branch again: a -prN suffix avoids the existing folder.
        let again = await PullRequestsModel.makeWorktree(number: 2, head: "feature/two", repoRoot: repo.root.path, repoName: "widgets",
                                                         environment: gh.environment(home: dir))
        XCTAssertEqual(try again.get(), root.appendingPathComponent("widgets/feature-two-pr2").path)

        // A failed checkout removes the worktree it made.
        let failed = await m.createWorktree(for: GitFixturePR.open(3, head: "three"), repoName: "widgets")
        XCTAssertNil(failed)
        XCTAssertEqual(m.lastMessage, "Couldn't check out #3: no such PR")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("widgets/three").path))
    }

    func testMakeWorktreeFailures() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        let gh = try FakeGH(in: dir)
        let noGH = await PullRequestsModel.makeWorktree(number: 1, head: "x", repoRoot: repo.root.path, repoName: "w", environment: ["PATH": "/nonexistent"])
        XCTAssertEqual(noGH.failureMessage, "The GitHub CLI isn't installed.")

        // The worktree root is a file: its folder can't be created.
        let file = dir.appendingPathComponent("blocker")
        try Data().write(to: file)
        SettingsStore.shared.settings.worktreeRoot = file.path
        let blocked = await PullRequestsModel.makeWorktree(number: 1, head: "x", repoRoot: repo.root.path, repoName: "w",
                                                           environment: gh.environment(home: dir))
        XCTAssertTrue(blocked.failureMessage?.hasPrefix("Couldn't create ") == true, blocked.failureMessage ?? "nil")

        // Not a repository: git worktree add fails.
        SettingsStore.shared.settings.worktreeRoot = dir.appendingPathComponent("wt").path
        let notRepo = await PullRequestsModel.makeWorktree(number: 1, head: "x", repoRoot: dir.path, repoName: "w",
                                                           environment: gh.environment(home: dir))
        XCTAssertTrue(notRepo.failureMessage?.hasPrefix("Couldn't create the worktree: ") == true, notRepo.failureMessage ?? "nil")
    }
}

private extension Result where Failure == PullRequestsModel.WorktreeError {
    var failureMessage: String? {
        if case .failure(let e) = self { return e.message }
        return nil
    }
}

// MARK: - PR detail and diff parsing

final class PullRequestDetailParsingTests: XCTestCase {
    func testParsesReviewersChecksAndEvents() throws {
        let view: [String: Any] = [
            "body": "Description", "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
            "comments": [["author": ["login": "a"], "body": "first", "createdAt": "2026-09-30T10:00:00Z", "url": "https://x.test/c1"],
                         ["body": "no author or id"]],
            "reviews": [["id": "r1", "author": ["login": "b"], "state": "APPROVED", "body": "", "submittedAt": "2026-09-30T11:00:00Z"],
                        ["author": ["login": "c"], "state": "COMMENTED", "body": ""],
                        ["author": ["login": "d"], "body": "general thoughts"]],
            "latestReviews": [["author": ["login": "b"], "state": "APPROVED"], ["author": ["login": "x"]]],
            "reviewRequests": [["login": "b"], ["login": "e"], ["slug": "core"], ["name": "Named"], [:]],
            "statusCheckRollup": [
                ["name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "workflowName": "CI", "detailsUrl": "https://x.test/1"],
                ["name": "lint", "status": "COMPLETED", "conclusion": "SKIPPED", "workflowName": ""],
                ["context": "ci/legacy", "state": "PENDING", "targetUrl": "https://x.test/2"],
                ["context": "deploy", "state": "ERROR"],
                [:],
            ],
        ]
        let comments: [[String: Any]] = [
            ["id": 5, "path": "a.swift", "line": 3, "user": ["login": "f"], "body": "nit", "created_at": "2026-09-30T12:00:00Z",
             "html_url": "https://x.test/rc5"],
            ["path": "b.swift", "original_line": 9, "body": "outdated"],
        ]
        let detail = try XCTUnwrap(PullRequestDetail.parse(view: try JSONSerialization.data(withJSONObject: view),
                                                           reviewComments: try JSONSerialization.data(withJSONObject: comments)))
        XCTAssertEqual(detail.body, "Description")
        XCTAssertEqual(detail.mergeable, "MERGEABLE")
        XCTAssertEqual(detail.reviewers.map(\.login), ["b", "x", "e", "team:core", "Named"])
        XCTAssertEqual(detail.reviewers[1].state, "COMMENTED")
        XCTAssertEqual(detail.reviewers[2].state, "REQUESTED")
        XCTAssertEqual(detail.checks.map(\.state), [.passing, .skipped, .pending, .failing, .passing])
        XCTAssertEqual(detail.checks[0].id, "CI/build")
        XCTAssertNil(detail.checks[1].workflow)
        XCTAssertEqual(detail.checks[2].name, "ci/legacy")
        XCTAssertEqual(detail.checks[2].url?.absoluteString, "https://x.test/2")
        XCTAssertEqual(detail.checks[4].name, "check")
        XCTAssertEqual(detail.events.count, 6, "the bare COMMENTED review wrapper is skipped")
        let kinds = detail.events.map(\.kind)
        XCTAssertTrue(kinds.contains(.reviewComment(path: "a.swift", line: 3)))
        XCTAssertTrue(kinds.contains(.reviewComment(path: "b.swift", line: 9)))
        XCTAssertTrue(kinds.contains(.review(state: "COMMENTED")))
        XCTAssertTrue(detail.events.contains { $0.author == "ghost" && $0.id == "comment-1" })
        XCTAssertEqual(detail.events.last?.id, "rc-5", "sorted by date")

        let bare = try XCTUnwrap(PullRequestDetail.parse(view: Data("{}".utf8), reviewComments: Data("nope".utf8)))
        XCTAssertEqual(bare.mergeable, "UNKNOWN")
        XCTAssertEqual(bare.mergeStateStatus, "UNKNOWN")
        XCTAssertNil(PullRequestDetail.parse(view: Data("[]".utf8), reviewComments: nil))
    }

    func testDiffRenamesBinariesAndEdgeLines() {
        let patch = """
        preamble ignored
        diff --git a/old.swift b/new.swift
        similarity index 90%
        rename from old.swift
        rename to new.swift
        --- a/old.swift
        +++ b/new.swift
        @@ -1,3 +1,3 @@
         keep
        -gone
        +++plus
        \\ No newline at end of file
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ
        diff --git a/deleted.txt b/deleted.txt
        --- a/deleted.txt
        +++ /dev/null
        @@ -5 +0,0 @@ func x()
        -bye
        diff --git a/plain b/plain
        +++ plain
        @@ bad
        """
        let files = PullRequestDiff.parse(patch)
        XCTAssertEqual(files.map(\.path), ["new.swift", "img.png", "deleted.txt", "plain"])
        XCTAssertEqual(files[0].oldPath, "old.swift")
        XCTAssertEqual(files[0].additions, 1)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[0].lines.first?.text, "Line 1", "a hunk without context gets a line label")
        XCTAssertEqual(files[0].lines.last?.text, "++plus", "inside a hunk +++ is an added line")
        XCTAssertTrue(files[1].isBinary)
        XCTAssertEqual(files[1].id, "img.png")
        XCTAssertEqual(files[2].lines.first?.text, "func x()")
        XCTAssertEqual(files[2].lines.last?.oldNumber, 5)
        XCTAssertEqual(files[3].lines.count, 1)
        XCTAssertTrue(PullRequestDiff.parse("").isEmpty)
    }
}

// MARK: - Board extras

final class PullRequestBoardExtraTests: XCTestCase {
    func testTitlesAndStackProperties() {
        XCTAssertEqual(PullRequestBoard.Column.allCases.map(\.title),
                       ["Draft", "Waiting for review", "Has feedback", "Changes requested", "Ready"])
        XCTAssertEqual(PullRequestBoard.Column.ready.id, "ready")
        XCTAssertEqual(PullRequestBoard.MergeMethod.allCases.map(\.title), ["Squash and Merge", "Create a Merge Commit", "Rebase and Merge"])
        XCTAssertEqual(PullRequestBoard.MergeMethod.rebase.id, "rebase")
        let stacks = PullRequestBoard.stacks([GitFixturePR.open(1, head: "a"), GitFixturePR.open(2, head: "b", base: "a"),
                                              GitFixturePR.open(3, head: "c", base: "a")])
        XCTAssertEqual(stacks.count, 1)
        XCTAssertTrue(stacks[0].isBranching)
        XCTAssertEqual(stacks[0].id, 1)
        XCTAssertEqual(PullRequestBoard.Stack(layers: []).id, 0)
        XCTAssertEqual(PullRequestBoard.Stack(layers: []).column, .waitingForReview)
    }

    func testParsesPreferredMergeMethodTeamsAndBots() throws {
        let json = GitFixturePR.board(nodes: [
            GitFixturePR.node(5, head: "x", requested: [["requestedReviewer": ["slug": "core"]], ["requestedReviewer": ["login": "amy"]], [:]],
                              threads: [false, true, false], typename: "Bot"),
            ["number": 6],
        ], squash: true, merge: true, rebase: true, preferred: "REBASE")
        let snap = try XCTUnwrap(PullRequestBoard.parse(try JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(snap.mergeMethods, [.rebase, .squash, .merge])
        XCTAssertEqual(snap.pullRequests.count, 1)
        let pr = snap.pullRequests[0]
        XCTAssertTrue(pr.authorIsBot)
        XCTAssertEqual(pr.reviewRequestedLogins, ["team:core", "amy"])
        XCTAssertEqual(pr.unresolvedThreads, 2)
        XCTAssertEqual(PullRequestBoard.failedRunIDs([
            ["conclusion": "FAILURE", "detailsUrl": "https://github.com/a/b/actions/runs/11/job/2"],
            ["conclusion": "TIMED_OUT", "detailsUrl": "https://github.com/a/b/actions/runs/11/job/3"],
            ["conclusion": "FAILURE", "detailsUrl": "https://ci.example.com/build/1"],
            ["conclusion": "SUCCESS", "detailsUrl": "https://github.com/a/b/actions/runs/12/job/1"],
        ]), [11])
    }
}

// MARK: - A directory's worktree

final class DirectoryWorktreeStatusTests: GitAreaTestCase {
    func testMissingAndNonRepositoryDirectories() async throws {
        let dir = try gitTempDirectory()
        let status = DirectoryWorktreeStatus(environment: ["PATH": "/usr/bin:/bin"])
        let missing = dir.appendingPathComponent("gone").path
        await status.refresh(missing)
        XCTAssertEqual(status.state(for: missing), .missing)
        await status.refresh(dir.path)
        XCTAssertEqual(status.state(for: dir.path), .notRepository)
        XCTAssertNil(status.state(for: "/elsewhere"))
    }

    func testWorktreeBranchTrackingAndPullRequest() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        try repo.fakeGitHubOrigin()
        try repo.write("dirty\n", "README.md")
        let linked = try repo.addWorktree("linked")
        let gh = try FakeGH(in: dir)
        try gh.on("pr list *", json: [GitFixturePR.listEntry(4, branch: "main", state: "OPEN")])
        let status = DirectoryWorktreeStatus(environment: gh.environment(home: dir))

        await status.refresh(repo.root.path)
        guard case .worktree(let wt, let name)? = status.state(for: repo.root.path) else { return XCTFail("not a worktree") }
        XCTAssertEqual(name, "repo")
        XCTAssertTrue(wt.isMain)
        XCTAssertEqual(wt.branch, "main")
        XCTAssertEqual(wt.changes, 1)
        XCTAssertNotNil(wt.lastActivity)
        XCTAssertTrue(wt.trackingKnown)
        XCTAssertEqual(wt.upstream, "origin/main")
        XCTAssertEqual(wt.pullRequest?.number, 4)

        await status.refresh(linked.path)
        guard case .worktree(let l, let lname)? = status.state(for: linked.path) else { return XCTFail("not a worktree") }
        XCTAssertEqual(lname, "repo", "named for the main checkout")
        XCTAssertFalse(l.isMain)
        XCTAssertTrue(l.isDetached)
        XCTAssertEqual(l.head?.count, 8)
        XCTAssertEqual(gh.calls(matching: "pr list").count, 1, "branch info is shared per repository")

        // Within 30 seconds a directory isn't looked up again.
        try repo.write("clean\n", "README.md")
        try repo.git(["commit", "-qam", "clean"])
        await status.refresh(repo.root.path)
        if case .worktree(let same, _)? = status.state(for: repo.root.path) { XCTAssertEqual(same.changes, 1) }

        // Invalidating forces a fresh lookup that keeps the known values first.
        status.invalidate()
        await status.refresh(repo.root.path)
        if case .worktree(let fresh, _)? = status.state(for: repo.root.path) {
            XCTAssertEqual(fresh.changes, 0)
            XCTAssertEqual(fresh.pullRequest?.number, 4)
        }
        XCTAssertEqual(gh.calls(matching: "pr list").count, 2)
    }

    func testSharedInstanceUsesTheDefaultEnvironment() async throws {
        let missing = try gitTempDirectory().appendingPathComponent("missing").path
        await DirectoryWorktreeStatus.shared.refresh(missing)
        XCTAssertEqual(DirectoryWorktreeStatus.shared.state(for: missing), .missing)
    }
}
