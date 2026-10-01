import AppKit
import XCTest
@testable import Shell

/// A board over a temp repository and a fake `gh` answering the GraphQL
/// query, `gh pr view`, the review comments API and `gh pr diff`.
@MainActor
struct GitHubBoardFixture {
    let dir: URL
    let repo: GitFixtureRepo
    let gh: FakeGH
    let model: GitHubBoardModel

    static let patch = """
    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -1,2 +1,2 @@ struct A
     let x = 1
    -let y = 2
    +let y = 3
    """

    static var detailJSON: [String: Any] {
        ["body": "## Summary\nDoes things.", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
         "comments": [["id": "c1", "author": ["login": "hubot"], "body": "Looks good", "createdAt": "2026-09-30T10:00:00Z",
                       "url": "https://github.com/acme/widgets/pull/1#c1"]],
         "reviews": [["id": "r1", "author": ["login": "amy"], "state": "CHANGES_REQUESTED", "body": "Fix it", "submittedAt": "2026-09-30T11:00:00Z"],
                     ["id": "r2", "author": ["login": "bob"], "state": "DISMISSED", "body": "old", "submittedAt": "2026-09-30T11:30:00Z"]],
         "latestReviews": [["author": ["login": "amy"], "state": "CHANGES_REQUESTED"], ["author": ["login": "cat"], "state": "APPROVED"],
                           ["author": ["login": "dan"], "state": "COMMENTED"]],
         "reviewRequests": [["login": "eve"]],
         "statusCheckRollup": [
            ["name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "workflowName": "CI", "detailsUrl": "https://x.test/1"],
            ["name": "test", "status": "COMPLETED", "conclusion": "FAILURE", "workflowName": "CI", "detailsUrl": "https://x.test/2"],
            ["name": "lint", "status": "IN_PROGRESS"],
            ["name": "docs", "status": "COMPLETED", "conclusion": "SKIPPED"],
         ]]
    }

    static var reviewComments: [[String: Any]] { [
        ["id": 9, "path": "a.swift", "line": 2, "user": ["login": "amy"], "body": "Why 3?", "created_at": "2026-09-30T11:10:00Z",
         "html_url": "https://github.com/acme/widgets/pull/1#r9"],
    ] }

    /// PR 1 (mine, failing checks, the base of a stack with 2), 2 (stacked on
    /// 1), 3 (draft), 4 (approved, someone else's, assigned to me), 5 (changes
    /// requested, waiting on my review).
    static var nodes: [[String: Any]] {
        [
            GitFixturePR.node(1, head: "feature-1", decision: "REVIEW_REQUIRED",
                              checks: [["__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "FAILURE",
                                        "detailsUrl": "https://github.com/acme/widgets/actions/runs/77/job/1"]],
                              reviews: [["author": ["login": "amy"], "state": "COMMENTED"]], threads: [false]),
            GitFixturePR.node(2, head: "feature-2", base: "feature-1", decision: "REVIEW_REQUIRED",
                              checks: [["__typename": "StatusContext", "context": "ci", "state": "PENDING"]]),
            GitFixturePR.node(3, head: "feature-3", draft: true),
            GitFixturePR.node(4, head: "feature-4", author: "hubot", decision: "APPROVED",
                              checks: [["__typename": "CheckRun", "name": "b", "status": "COMPLETED", "conclusion": "SUCCESS"]],
                              assignees: ["octocat"]),
            GitFixturePR.node(5, head: "feature-5", author: "hubot", decision: "CHANGES_REQUESTED",
                              requested: [["requestedReviewer": ["login": "octocat"]]]),
        ]
    }

    init(in parent: URL, host: String = "github.com", nodes: [[String: Any]]? = nil, mergeMethods: (Bool, Bool, Bool) = (true, true, false)) throws {
        dir = parent
        repo = try GitFixtureRepo(in: parent)
        gh = try FakeGH(in: parent)
        let board = GitFixturePR.board(nodes: nodes ?? Self.nodes, squash: mergeMethods.0, merge: mergeMethods.1, rebase: mergeMethods.2)
        try gh.on("api*graphql*", json: board)
        try gh.on("pr view * --json *", json: Self.detailJSON)
        try gh.on("api*pulls/*/comments*", json: Self.reviewComments)
        try gh.on("pr diff *", stdout: Self.patch)
        model = GitHubBoardModel(repoRoot: repo.root.path, remote: GitHubRemote(host: host, owner: "acme", name: "widgets"),
                                 environment: gh.environment(home: parent))
    }
}

final class GitHubBoardModelTests: GitAreaTestCase {
    private func loaded(_ f: GitHubBoardFixture) async throws {
        f.model.refresh()
        try await eventually("board") { !f.model.isLoading && f.model.lastUpdated != nil }
    }

    func testRefreshLoadsTheBoard() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory())
        let m = f.model
        XCTAssertEqual(m.filter, PullRequestBoard.Filter(rawValue: SettingsStore.shared.settings.githubBoardFilter) ?? .all)
        m.refreshIfNeeded()
        m.refresh() // already loading
        try await eventually("board") { !m.isLoading && m.lastUpdated != nil }
        XCTAssertNil(m.error)
        XCTAssertEqual(m.login, "octocat")
        XCTAssertEqual(m.mergeMethods, [.merge, .squash], "the viewer's default first")
        XCTAssertEqual(m.pullRequests.count, 5)
        XCTAssertEqual(m.pullRequest(1)?.failedRunIDs, [77])
        XCTAssertNil(m.pullRequest(99))
        XCTAssertTrue(m.isMine(m.pullRequest(1)!))
        XCTAssertFalse(m.isMine(m.pullRequest(4)!))
        XCTAssertEqual(f.gh.calls(matching: "api graphql").count, 1)
        XCTAssertTrue(f.gh.calls.contains { $0.contains("owner=acme") }, "the query spans lines; its variables follow")

        m.filter = .all
        let all = m.columns
        XCTAssertEqual(all[.draft]?.count, 1)
        XCTAssertEqual(all[.ready]?.first?.bottom.number, 4)
        XCTAssertEqual(all[.changesRequested]?.first?.bottom.number, 5)
        m.filter = .mine
        XCTAssertEqual(m.columns.values.flatMap { $0 }.flatMap(\.pullRequests).map(\.number).sorted(), [1, 2, 3])

        // Fresh boards don't refetch.
        m.refreshIfNeeded()
        XCTAssertFalse(m.isLoading)
    }

    func testForYouSearchChipsAndStackExpansion() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory())
        let m = f.model
        try await loaded(f)
        func shown() -> [Int] { m.columns.values.flatMap { $0 }.flatMap(\.pullRequests).map(\.number).sorted() }

        m.filter = .forYou
        XCTAssertEqual(SettingsStore.shared.settings.githubBoardFilter, "forYou", "the filter is remembered")
        XCTAssertEqual(shown(), [4, 5])
        XCTAssertEqual(m.layout.counts, .init(forYou: 2, mine: 3, all: 5, reviewRequested: 1, assigned: 1))
        XCTAssertEqual(m.reasons(m.pullRequest(5)!), .reviewRequested)

        m.toggleNarrowing(.assigned)
        XCTAssertEqual(m.narrowing, .assigned)
        XCTAssertEqual(shown(), [4])
        m.toggleNarrowing(.assigned)
        XCTAssertEqual(m.narrowing, [])
        XCTAssertEqual(shown(), [4, 5])

        m.filter = .all
        m.searchText = "feature-2"
        XCTAssertEqual(shown(), [1, 2], "the search keeps the matching PR's stack")
        m.searchText = ""
        XCTAssertEqual(shown(), [1, 2, 3, 4, 5])

        // Stacks start collapsed; Expand flips one, unchecking "Collapse stacks" flips them all.
        let stack = try XCTUnwrap(m.columns.values.flatMap { $0 }.first { $0.layers.count > 1 })
        XCTAssertFalse(m.isExpanded(stack))
        m.setExpanded(stack, true)
        XCTAssertTrue(m.isExpanded(stack))
        m.setExpanded(stack, true)
        XCTAssertTrue(m.isExpanded(stack))
        m.collapseStacks = false
        XCTAssertTrue(m.isExpanded(stack), "every stack expanded")
        m.setExpanded(stack, false)
        XCTAssertFalse(m.isExpanded(stack))
        m.collapseStacks = true
        XCTAssertFalse(m.isExpanded(stack))

        // Where a checkout goes, and an existing worktree wins.
        let pr = m.pullRequest(4)!
        XCTAssertTrue(m.plannedWorktreePath(for: pr).hasSuffix("/widgets/feature-4"))
    }

    func testCachedModelPerRepository() {
        let remote = GitHubRemote(host: "github.com", owner: "acme", name: "cache-\(UUID().uuidString.prefix(6))")
        let root = "/tmp/board-cache-\(UUID().uuidString)"
        let a = GitHubBoardModel.model(repoRoot: root, remote: remote)
        XCTAssertTrue(GitHubBoardModel.model(repoRoot: root, remote: remote) === a)
        let other = GitHubRemote(host: "github.com", owner: "acme", name: "renamed")
        XCTAssertFalse(GitHubBoardModel.model(repoRoot: root, remote: other) === a, "a changed remote gets a new board")
        XCTAssertEqual(GitHubBoardModel.interval, .seconds(120))
        XCTAssertEqual(GitHubBoardModel.staleAfter, 30)
    }

    func testErrorsAndMissingGh() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory())
        try f.gh.reset()
        try f.gh.on("api*graphql*", stdout: "{\"errors\":[]}")
        try f.gh.on("auth status", status: 1)
        f.model.refresh()
        try await eventually { !f.model.isLoading && f.model.error != nil }
        XCTAssertEqual(f.model.error, "Run `gh auth login` to see pull requests.")

        try f.gh.reset()
        try f.gh.on("api*graphql*", stderr: "boom", status: 1)
        try f.gh.on("auth status")
        f.model.refresh()
        try await eventually { !f.model.isLoading && f.model.error == "Couldn't load pull requests from GitHub." }

        let none = GitHubBoardModel(repoRoot: f.repo.root.path, remote: f.model.remote, environment: ["PATH": "/nonexistent"])
        none.refresh()
        XCTAssertTrue(none.error?.contains("brew install gh") == true)
        let ok = await none.perform(.markReady, on: GitFixturePR.open(1))
        XCTAssertFalse(ok)
        XCTAssertEqual(none.message?.text, "The GitHub CLI isn't installed.")
        none.loadDiff(1)
        XCTAssertTrue(none.loadingDiff.isEmpty)
    }

    func testEnterpriseHostsPassTheHostname() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory(), host: "github.corp.example")
        try await loaded(f)
        XCTAssertTrue(f.gh.calls.contains { $0.hasPrefix("api --hostname github.corp.example graphql") })
        f.model.selection = .init(number: 4)
        try await eventually("detail") { f.model.details[4] != nil }
        XCTAssertTrue(f.gh.calls.contains { $0.contains("pr view 4 --repo github.corp.example/acme/widgets") })
        XCTAssertTrue(f.gh.calls.contains { $0.hasPrefix("api --hostname github.corp.example repos/acme/widgets/pulls/4/comments") })
    }

    func testSelectionLoadsDetailAndDiff() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory())
        let m = f.model
        try await loaded(f)
        m.selection = .init(number: 1)
        XCTAssertTrue(m.loadingDetail.contains(1))
        try await eventually("detail") { m.details[1] != nil }
        let detail = try XCTUnwrap(m.details[1])
        XCTAssertEqual(detail.checks.count, 4)
        XCTAssertEqual(detail.events.count, 4)
        m.loadDetail() // cached
        XCTAssertFalse(m.loadingDetail.contains(1))

        m.loadDiff(1)
        m.loadDiff(1) // already loading
        try await eventually("diff") { m.diffs[1] != nil }
        XCTAssertEqual(m.diffs[1]?.first?.path, "a.swift")
        XCTAssertEqual(f.gh.calls(matching: "pr diff").count, 1)

        // Same number again: no reload. A stack selection keeps the number.
        m.selection = .init(number: 1, stackID: 1)
        XCTAssertEqual(m.selectedStack?.layers.count, 2)
        m.selection = .init(number: 4, stackID: 4)
        XCTAssertNil(m.selectedStack, "a single PR isn't a stack")
        m.selection = .init(number: 4)
        XCTAssertNil(m.selectedStack)
        m.selection = nil
        m.loadDetail()
    }

    func testChangedPullRequestReloadsTheOpenDetailAndDiff() async throws {
        let dir = try gitTempDirectory()
        let f = try GitHubBoardFixture(in: dir)
        let m = f.model
        try await loaded(f)
        m.selection = .init(number: 1)
        try await eventually { m.details[1] != nil }
        m.loadDiff(1)
        try await eventually { m.diffs[1] != nil }
        let views = f.gh.calls(matching: "pr view 1").count
        let diffs = f.gh.calls(matching: "pr diff 1").count

        // PR 1 updated on GitHub.
        var nodes = GitHubBoardFixture.nodes
        nodes[0]["updatedAt"] = "2026-10-01T09:00:00Z"
        try f.gh.reset()
        try f.gh.on("api*graphql*", json: GitFixturePR.board(nodes: nodes))
        try f.gh.on("pr view * --json *", json: GitHubBoardFixture.detailJSON)
        try f.gh.on("api*pulls/*/comments*", status: 1)
        try f.gh.on("pr diff *", stderr: "diff too large", status: 1)
        m.refresh()
        try await eventually("detail reload") { f.gh.calls(matching: "pr view 1").count > views }
        try await eventually("diff reload") { f.gh.calls(matching: "pr diff 1").count > diffs }
        try await eventually("diff error") { m.message?.text == "Couldn't load the diff: diff too large" }
        XCTAssertEqual(m.message?.isError, true)

        // A failing `gh pr view` keeps the old detail.
        try f.gh.reset()
        try f.gh.on("pr view *", status: 1)
        m.selection = .init(number: 4)
        try await eventually("view attempt") { !m.loadingDetail.contains(4) && f.gh.calls(matching: "pr view 4").count == 1 }
        XCTAssertNil(m.details[4])
    }

    func testActionsRunTheRightCommands() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory())
        let m = f.model
        try await loaded(f)
        try f.gh.on("pr *")
        try f.gh.on("run rerun *")
        let pr = { (n: Int) in m.pullRequest(n) ?? GitFixturePR.open(n) }
        // Different PRs run side by side (each sleeps a second before refreshing).
        let jobs: [(GitHubBoardModel.Action, OpenPullRequest)] = [
            (.comment("hi"), pr(1)), (.approve(""), pr(2)), (.approve("ship it"), pr(3)), (.requestChanges("please"), pr(4)),
            (.markReady, pr(5)), (.convertToDraft, GitFixturePR.open(6)), (.rerunFailedChecks, pr(1).withNumber(7)),
        ]
        let tasks = jobs.map { job in Task { await m.perform(job.0, on: job.1) } }
        var results: [Bool] = []
        for t in tasks { results.append(await t.value) }
        XCTAssertEqual(results, [true, true, true, true, true, true, true])
        let calls = f.gh.calls
        XCTAssertTrue(calls.contains("pr comment 1 --body hi --repo acme/widgets"))
        XCTAssertTrue(calls.contains("pr review 2 --approve --repo acme/widgets"))
        XCTAssertTrue(calls.contains("pr review 3 --approve --body ship it --repo acme/widgets"))
        XCTAssertTrue(calls.contains("pr review 4 --request-changes --body please --repo acme/widgets"))
        XCTAssertTrue(calls.contains("pr ready 5 --repo acme/widgets"))
        XCTAssertTrue(calls.contains("pr ready 6 --undo --repo acme/widgets"))
        XCTAssertTrue(calls.contains("run rerun 77 --failed --repo acme/widgets"))
        XCTAssertTrue(m.busy.isEmpty)

        m.selection = .init(number: 4)
        let merge = Task { await m.perform(.merge(.squash), on: pr(4)) }
        let close = Task { await m.perform(.close, on: pr(5)) }
        let merged = await merge.value, closed = await close.value
        XCTAssertTrue(merged && closed)
        XCTAssertTrue(f.gh.calls.contains("pr merge 4 --squash --repo acme/widgets"))
        XCTAssertTrue(f.gh.calls.contains("pr close 5 --repo acme/widgets"))
        XCTAssertNil(m.selection, "merging or closing closes the detail")
        XCTAssertTrue(m.message?.text.hasPrefix("#") == true)
        XCTAssertEqual(m.message?.isError, false)
    }

    func testActionFailuresAndGuards() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory())
        let m = f.model
        try await loaded(f)
        try f.gh.on("pr merge *", stderr: "not mergeable", status: 1)
        let failed = await m.perform(.merge(.merge), on: m.pullRequest(4)!)
        XCTAssertFalse(failed)
        XCTAssertEqual(m.message?.text, "not mergeable")
        XCTAssertEqual(m.message?.isError, true)

        let none = await m.perform(.rerunFailedChecks, on: GitFixturePR.open(9, checks: .failing))
        XCTAssertFalse(none)
        XCTAssertTrue(m.message?.text.hasPrefix("No failed GitHub Actions runs") == true)

        // One action per PR at a time.
        try f.gh.on("pr comment *", sleep: 0.5)
        let first = Task { await m.perform(.comment("a"), on: m.pullRequest(1)!) }
        try await eventually { m.busy[1] != nil }
        XCTAssertEqual(m.busy[1], "Commenting…")
        let second = await m.perform(.comment("b"), on: m.pullRequest(1)!)
        XCTAssertFalse(second)
        _ = await first.value
    }

    func testActionStrings() {
        let actions: [GitHubBoardModel.Action] = [.comment(""), .approve(""), .requestChanges(""), .markReady, .convertToDraft,
                                                  .rerunFailedChecks, .merge(.squash), .close]
        XCTAssertEqual(Set(actions.map(\.progress)).count, actions.count)
        XCTAssertEqual(Set(actions.map(\.done)).count, actions.count)
        XCTAssertTrue(actions.allSatisfy { $0.progress.hasSuffix("…") && $0.done.hasSuffix(".") })
        let env = GitHubBoardModel.ghEnvironment(["A": "1"])
        XCTAssertEqual(env["GH_PROMPT_DISABLED"], "1")
        XCTAssertEqual(env["GH_PAGER"], "cat")
        XCTAssertEqual(env["NO_COLOR"], "1")
        XCTAssertEqual(env["A"], "1")
    }

    func testAttachPollsAndDetachStops() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory())
        let m = f.model
        m.attach()
        m.attach()
        try await eventually { m.lastUpdated != nil && !m.isLoading }
        m.isPaused = true
        m.isPaused = false // fresh: no refetch
        m.detach()
        m.detach()
        m.detach()
        XCTAssertEqual(f.gh.calls(matching: "api graphql").count, 1)
    }

    func testWorktreesForPullRequests() async throws {
        let f = try GitHubBoardFixture(in: gitTempDirectory())
        let m = f.model
        let wt = try f.repo.addWorktree("feature-4", branch: "feature-4")
        try f.repo.addWorktree("gone", branch: "gone")
        try FileManager.default.removeItem(at: f.dir.appendingPathComponent("gone"))
        try await loaded(f)
        try await eventually("worktrees") { m.worktree(for: m.pullRequest(4)!) != nil }
        XCTAssertEqual(m.worktree(for: m.pullRequest(4)!), wt.path)
        XCTAssertNil(m.worktree(for: m.pullRequest(1)!))

        SettingsStore.shared.settings.worktreeRoot = f.dir.appendingPathComponent("wts").path
        try f.gh.on("pr checkout 1")
        try f.gh.on("pr checkout 5", stderr: "nope", status: 1)
        let path = await m.createWorktree(for: m.pullRequest(1)!)
        XCTAssertEqual(path, f.dir.appendingPathComponent("wts/widgets/feature-1").path)
        XCTAssertEqual(m.worktree(for: m.pullRequest(1)!), path)
        XCTAssertTrue(m.creatingWorktree.isEmpty)
        let failed = await m.createWorktree(for: m.pullRequest(5)!)
        XCTAssertNil(failed)
        XCTAssertEqual(m.message?.text, "Couldn't check out #5: nope")
    }

    func testResolveFindsTheMainCheckoutAndRemote() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        try repo.fakeGitHubOrigin("https://github.com/acme/widgets.git")
        let wt = try repo.addWorktree("linked", branch: "linked")
        let resolved = await GitHubBoardModel.resolve(directory: wt.path)
        XCTAssertEqual(resolved?.root, repo.root.path)
        XCTAssertEqual(resolved?.remote.slug, "acme/widgets")
        let fromMain = await GitHubBoardModel.resolve(directory: repo.root.path)
        XCTAssertEqual(fromMain?.remote.slug, "acme/widgets", "via the upstream's remote")

        let plain = try GitFixtureRepo(in: dir, name: "plain")
        try plain.git(["remote", "add", "origin", "https://gitlab.com/a/b.git"])
        let notGitHub = await GitHubBoardModel.resolve(directory: plain.root.path)
        XCTAssertNil(notGitHub)
        let outside = await GitHubBoardModel.resolve(directory: dir.path)
        XCTAssertNil(outside)
    }
}

fileprivate extension OpenPullRequest {
    /// The same PR under another number (so tests can run actions side by side).
    func withNumber(_ n: Int) -> OpenPullRequest {
        var copy = self
        copy.number = n
        return copy
    }
}
