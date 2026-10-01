import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// The sidebar's GitHub tab: header and current branch, Pull Requests and Actions.
final class GitHubSidebarViewsTests: GitAreaTestCase {
    private var savedEditors: [ExternalEditor] = []

    override func setUp() async throws {
        try await super.setUp()
        savedEditors = ExternalEditor.installed
        ExternalEditor.installed = []
    }

    override func tearDown() async throws {
        ExternalEditor.installed = savedEditors
        try await super.tearDown()
    }

    private let remote = GitHubRemote(host: "github.com", owner: "acme", name: "widgets")

    func testHeaderShowsTheBranchsPullRequestOrALinkToOpenOne() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let worktrees = try await f.worktrees(test: self)
        let prs = try await f.pullRequests(test: self)
        let actions = try await f.actions(test: self)

        // main: published, the default branch: a plain branch link.
        let main = try await f.repository(test: self)
        XCTAssertEqual(main.defaultBranch, "main")
        SettingsStore.shared.settings.githubSection = .prs
        render(GitHubView(repo: main, github: remote, pullRequests: prs, actions: actions, worktrees: worktrees, context: f.context()),
               size: CGSize(width: 380, height: 900))
        XCTAssertEqual(actions.branch, "main", "set when the view appears")

        // The section picker switches to Actions.
        let w = claudeWindow(GitHubView(repo: main, github: remote, pullRequests: prs, actions: actions, worktrees: worktrees,
                                        context: f.context()), width: 380, height: 700)
        gitClickSegment(w, 1, segments: 2)
        XCTAssertEqual(SettingsStore.shared.settings.githubSection, .actions)
        gitClickSegment(w, 0, segments: 2)
        XCTAssertEqual(SettingsStore.shared.settings.githubSection, .prs)

        // A published feature branch without a PR: "Create PR".
        try f.gh.reset()
        try f.gh.on("pr view *", status: 1)
        let draftRepo = try await f.repository(test: self, in: f.paths["draft"])
        XCTAssertTrue(draftRepo.isBranchPublished)
        render(GitHubView(repo: draftRepo, github: remote, pullRequests: prs, actions: actions, worktrees: worktrees,
                          context: f.context(withActions: false)), size: CGSize(width: 380, height: 600))

        // Branches with a PR in each state.
        for (state, draft) in [("OPEN", false), ("OPEN", true), ("MERGED", false), ("CLOSED", false)] {
            let sub = try gitTempDirectory()
            let r = try GitFixtureRepo(in: sub)
            try r.fakeGitHubOrigin()
            let gh = try FakeGH(in: sub)
            try gh.on("pr view main *", json: ["number": 9, "title": "Nine", "url": "https://github.com/acme/widgets/pull/9", "state": state, "isDraft": draft])
            let found = await GitRepository.discover(from: r.root.path, environment: gh.environment(home: sub))
            let repo = try XCTUnwrap(found)
            defer { repo.stop() }
            try await eventually("PR") { repo.pullRequest != nil }
            render(GitHubView(repo: repo, github: remote, pullRequests: prs, actions: actions, worktrees: worktrees, context: f.context()),
                   size: CGSize(width: 380, height: 400))
        }
    }

    func testActionsSectionAndRunRows() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let worktrees = WorktreesModel(repoRoot: f.repo.root.path, environment: f.env)
        let prs = PullRequestsModel(repoRoot: f.repo.root.path, environment: f.env)
        let actions = try await f.actions(test: self)
        let repo = try await f.repository(test: self)
        actions.expanded = [101, 103]
        actions.toggle(actions.runs[0])
        actions.toggle(actions.runs[0])
        try await eventually("jobs") { actions.jobs[101] != nil }
        actions.message = "Couldn't cancel"
        SettingsStore.shared.settings.githubSection = .actions
        let host = render(GitHubView(repo: repo, github: remote, pullRequests: prs, actions: actions, worktrees: worktrees, context: f.context()),
                          size: CGSize(width: 380, height: 1400))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        try await eventually { actions.branch == "main" }

        let w = claudeWindow(ActionsView(model: actions, currentBranch: "main"), width: 380, height: 1400)
        w.window.acceptsMouseMovedEvents = true
        for y in stride(from: 60.0, to: 1300.0, by: 40.0) { w.hover(x: 150, y: y) }
        // The message's dismiss button: right below the header.
        gitPress(w) { $0.minY > 34 && $0.minY < 80 && $0.minX > 300 }
        XCTAssertNil(actions.message, "the message's dismiss button clears it")

        // Expanded runs' buttons on the left: job rows (no URLs), Hide jobs,
        // Cancel and Re-run failed. (The right-hand button opens GitHub.)
        var pressed = 0
        for n in 0..<8 {
            let frames = gitControlFrames(w)
            let left = frames.indices.filter { frames[$0].minY > 60 && frames[$0].maxX < 300 }
            guard left.indices.contains(n) else { break }
            w.press(left[n])
            pressed += 1
            try await eventually(timeout: 8, "idle") { actions.busy.isEmpty }
        }
        XCTAssertGreaterThan(pressed, 0)
        XCTAssertTrue(f.gh.calls.contains { $0.hasPrefix("run cancel 101") || $0.hasPrefix("run rerun 103") }
                      || actions.expanded.count < 2, "a run button did something")

        // Scope: this branch only.
        gitClickSegment(w, 1, segments: 2)
        XCTAssertEqual(actions.scope, .branch)
        gitClickSegment(w, 0, segments: 2)

        // The header refresh button (rightmost on the top row).
        let calls = f.gh.calls(matching: "run list").count
        gitPress(w) { $0.minY < 34 && $0.minX > 300 }
        try await eventually("refresh") { f.gh.calls(matching: "run list").count > calls }
        XCTAssertEqual(ActionsView.ago(Date()), "just now")
        XCTAssertEqual(ActionsView.ago(Date().addingTimeInterval(-30)), "30s ago")
        XCTAssertEqual(ActionsView.ago(Date().addingTimeInterval(-180)), "3m ago")
    }

    func testActionsEmptyLoadingAndErrorStates() async throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        try gh.on("run list *", json: [Any]())
        let empty = ActionsModel(repoRoot: dir.path, environment: gh.environment(home: dir))
        render(ActionsView(model: empty, currentBranch: nil))
        try await eventually { empty.lastUpdated != nil }
        render(ActionsView(model: empty, currentBranch: nil))
        empty.detach()
        let broken = ActionsModel(repoRoot: dir.path, environment: ["PATH": "/nonexistent"])
        broken.refresh()
        try await eventually { broken.error != nil }
        render(ActionsView(model: broken, currentBranch: "x"))
        for state in [WorkflowRun.State.queued, .running, .success, .failure, .cancelled, .skipped, .neutral] {
            render(StateIcon(state: state, palette: .current, size: 10), size: CGSize(width: 20, height: 20))
        }
    }

    func testPullRequestsListFiltersAndWorktreeButtons() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let worktrees = try await f.worktrees(test: self)
        let prs = try await f.pullRequests(test: self)
        prs.lastMessage = "Couldn't create the worktree"
        for filter in PullRequestsModel.Filter.allCases {
            prs.filter = filter
            render(PullRequestsView(model: prs, worktrees: worktrees, context: f.context(), repoName: "widgets"),
                   size: CGSize(width: 380, height: 1200))
        }
        prs.filter = .all

        // PR 1's branch is checked out in dirty-wt: Switch and Review open it.
        let w = claudeWindow(PullRequestsView(model: prs, worktrees: worktrees, context: f.context(), repoName: "widgets"),
                             width: 380, height: 1200)
        w.window.acceptsMouseMovedEvents = true
        for y in stride(from: 80.0, to: 1100.0, by: 40.0) { w.hover(x: 150, y: y) }
        // The message's dismiss button is the first control under the header at the right.
        let header = try XCTUnwrap(gitControlFrames(w).first { $0.minY < 40 })
        gitPress(w) { $0.minY > header.maxY + 30 && $0.minY < header.maxY + 90 && $0.minX > 300 }
        XCTAssertNil(prs.lastMessage)

        // The filter picker: Review, then All.
        gitClickSegment(w, 1, segments: 3)
        XCTAssertEqual(prs.filter, .review)
        gitClickSegment(w, 0, segments: 3)
        XCTAssertEqual(prs.filter, .all)
    }

    func testPullRequestRowSwitchAndReview() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let worktrees = try await f.worktrees(test: self)
        let prs = try await f.pullRequests(test: self)
        prs.filter = .mine // just PR 1, checked out in dirty-wt
        XCTAssertEqual(prs.filtered.map(\.number), [1])
        let w = claudeWindow(PullRequestsView(model: prs, worktrees: worktrees, context: f.context(), repoName: "widgets"), width: 380, height: 500)
        // Row buttons, left to right: Switch, Review, (open on GitHub, not pressed).
        let row = w.controls().filter { $0.frame.minY > 80 }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertGreaterThanOrEqual(row.count, 3)
        w.press(w.controls().firstIndex(of: row[0])!)
        XCTAssertEqual(f.switched, [f.path("dirty")])
        w.press(w.controls().firstIndex(of: w.controls().filter { $0.frame.minY > 80 }.sorted { $0.frame.minX < $1.frame.minX }[1])!)
        XCTAssertEqual(f.opened.first?.0, f.path("dirty"))
        XCTAssertTrue(f.opened.first?.1?.hasPrefix("claude 'Review pull request #1") == true, f.opened.first?.1 ?? "nil")

        // The header's refresh button reloads both lists.
        let refresh = w.controls().filter { $0.frame.minY < 30 }.max { $0.frame.maxX < $1.frame.maxX }!
        let calls = f.gh.calls.count
        w.press(w.controls().firstIndex(of: refresh)!)
        try await eventually("refresh") { f.gh.calls.count > calls }
        try await eventually(timeout: 15) { !prs.isLoading && !worktrees.isLoading }
    }

    func testPullRequestRowCreatesAWorktree() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let worktrees = try await f.worktrees(test: self)
        let prs = try await f.pullRequests(test: self)
        SettingsStore.shared.settings.worktreeRoot = f.dir.appendingPathComponent("wts").path
        try f.gh.reset()
        try f.gh.on("pr checkout 2")
        try f.gh.on("pr list --state open *", json: GitSidebarFixture.prList)
        try f.gh.on("pr list *", json: [Any]())
        try f.gh.on("api user *", stdout: "octocat")
        prs.filter = .review // just PR 2, not checked out
        XCTAssertEqual(prs.filtered.map(\.number), [2])
        let w = claudeWindow(PullRequestsView(model: prs, worktrees: worktrees, context: f.context(), repoName: "widgets"), width: 380, height: 500)
        let row = w.controls().filter { $0.frame.minY > 80 }.sorted { $0.frame.minX < $1.frame.minX }
        w.press(w.controls().firstIndex(of: row[0])!) // Worktree
        try await eventually(timeout: 10, "switched") { !f.switched.isEmpty }
        XCTAssertEqual(f.switched, [f.dir.appendingPathComponent("wts/widgets/remote-only").path])

        // Review in a new worktree (the folder exists now, so it gets a -pr2 suffix).
        let again = claudeWindow(PullRequestsView(model: prs, worktrees: WorktreesModel(repoRoot: f.repo.root.path, environment: f.env),
                                                  context: f.context(), repoName: "widgets"), width: 380, height: 500)
        let row2 = again.controls().filter { $0.frame.minY > 80 }.sorted { $0.frame.minX < $1.frame.minX }
        again.press(again.controls().firstIndex(of: row2[1])!)
        try await eventually(timeout: 10, "review") { f.opened.contains { $0.0.hasSuffix("remote-only-pr2") } }
    }

    func testPullRequestsEmptyAndErrorStates() async throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        try gh.on("api user *", stdout: "octocat")
        try gh.on("pr list *", json: [Any]())
        let worktrees = WorktreesModel(repoRoot: dir.path, environment: gh.environment(home: dir))
        let empty = PullRequestsModel(repoRoot: dir.path, environment: gh.environment(home: dir))
        let context = SidebarContext(directory: dir.path, isClaude: true)
        render(PullRequestsView(model: empty, worktrees: worktrees, context: context, repoName: "w"))
        try await eventually { !empty.isLoading }
        for filter in PullRequestsModel.Filter.allCases {
            empty.filter = filter
            render(PullRequestsView(model: empty, worktrees: worktrees, context: context, repoName: "w"))
        }
        let broken = PullRequestsModel(repoRoot: dir.path, environment: ["PATH": "/nonexistent"])
        render(PullRequestsView(model: broken, worktrees: worktrees, context: context, repoName: "w"))
        XCTAssertNotNil(broken.error)
    }
}
