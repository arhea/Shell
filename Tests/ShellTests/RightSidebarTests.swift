import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// A repository with a GitHub remote and worktrees in every state the
/// sidebar draws, a fake `gh` answering for its PRs and Actions runs, and the
/// sidebar's models loaded from them.
@MainActor
final class GitSidebarFixture {
    let dir: URL
    let repo: GitFixtureRepo
    let gh: FakeGH
    var env: [String: String] { gh.environment(home: dir) }
    private(set) var paths: [String: URL] = [:]
    var opened: [(String, String?)] = []
    var switched: [String] = []
    var inserted: [String] = []
    var openedGitHub = 0

    static var prList: [[String: Any]] {
        func pr(_ n: Int, _ head: String, author: String = "hubot", draft: Bool = false, decision: String = "",
                checks: [[String: Any]] = [], requested: [String] = [], labels: [[String: Any]] = [], bot: Bool = false) -> [String: Any] {
            ["number": n, "title": "Sidebar PR \(n)", "url": "https://github.com/acme/widgets/pull/\(n)", "isDraft": draft,
             "headRefName": head, "baseRefName": "main", "author": ["login": author, "is_bot": bot], "reviewDecision": decision,
             "updatedAt": "2026-09-30T1\(n % 10):00:00Z", "additions": n * 3, "deletions": n,
             "statusCheckRollup": checks, "reviewRequests": requested.map { ["login": $0] }, "labels": labels]
        }
        return [
            pr(1, "dirty-wt", author: "octocat", decision: "CHANGES_REQUESTED", checks: [["status": "COMPLETED", "conclusion": "FAILURE"]],
               labels: [["name": "bug", "color": "d73a4a"], ["name": "odd", "color": "zz"], ["name": "third", "color": "000000"]]),
            pr(2, "remote-only", decision: "APPROVED", checks: [["status": "COMPLETED", "conclusion": "SUCCESS"]], requested: ["octocat"]),
            pr(3, "draft-wt", draft: true, decision: "REVIEW_REQUIRED", checks: [["status": "IN_PROGRESS"]]),
            pr(4, "bot-branch", bot: true),
        ]
    }

    static var worktreePRs: [[String: Any]] { [] }

    init(in parent: URL) throws {
        dir = parent
        repo = try GitFixtureRepo(in: parent)
        try repo.fakeGitHubOrigin()
        let base = try repo.head()
        gh = try FakeGH(in: parent)

        // Merged and clean, HEAD == the PR's head.
        let merged = try repo.addWorktree("merged-wt", branch: "merged-wt")
        try repo.commit("merged", in: merged)
        // Dirty, one commit ahead of its upstream, changes requested.
        let dirty = try repo.addWorktree("dirty-wt", branch: "dirty-wt")
        try repo.commit("ahead", in: dirty)
        try repo.track("dirty-wt", at: base)
        try repo.write("dirty\n", "README.md", in: dirty)
        // Draft PR, one commit behind its upstream.
        let draft = try repo.addWorktree("draft-wt", branch: "draft-wt")
        try repo.commit("pushed", in: draft)
        try repo.track("draft-wt", at: try repo.head(in: draft))
        try repo.git(["reset", "-q", "--hard", "HEAD~1"], in: draft)
        // Approved, never pushed.
        let approved = try repo.addWorktree("approved-wt", branch: "approved-wt")
        // Closed PR, upstream deleted.
        let closed = try repo.addWorktree("closed-wt", branch: "closed-wt")
        try repo.track("closed-wt", at: nil)
        // Stale: clean and idle for a year.
        let stale = try repo.addWorktree("stale-wt", branch: "stale-wt")
        try repo.commit("old", in: stale, date: "2020-01-01T00:00:00Z")
        try repo.backdateGitFiles(of: stale, by: 400)
        // Locked, missing and detached.
        let locked = try repo.addWorktree("locked-wt", branch: "locked-wt")
        try repo.git(["worktree", "lock", "--reason", "on a USB drive", locked.path])
        let gone = try repo.addWorktree("gone-wt", branch: "gone-wt")
        try FileManager.default.removeItem(at: gone)
        let detached = try repo.addWorktree("detached-wt")
        paths = ["merged": merged, "dirty": dirty, "draft": draft, "approved": approved, "closed": closed, "stale": stale,
                 "locked": locked, "gone": gone, "detached": detached]

        try gh.on("pr list --state all *", json: [
            GitFixturePR.listEntry(11, branch: "merged-wt", state: "MERGED", oid: try repo.head(in: merged)),
            GitFixturePR.listEntry(1, branch: "dirty-wt", state: "OPEN", review: "CHANGES_REQUESTED"),
            GitFixturePR.listEntry(3, branch: "draft-wt", state: "OPEN", draft: true, review: "REVIEW_REQUIRED"),
            GitFixturePR.listEntry(12, branch: "approved-wt", state: "OPEN", review: "APPROVED"),
            GitFixturePR.listEntry(13, branch: "closed-wt", state: "CLOSED"),
            GitFixturePR.listEntry(14, branch: "main", state: "MERGED"),
        ])
        try gh.on("pr list --state open *", json: Self.prList)
        try gh.on("api user *", stdout: "octocat")
        try gh.on("run list *", json: [
            GitFixtureRuns.run(101, status: "in_progress", conclusion: "", title: "Running build", attempt: 2),
            GitFixtureRuns.run(102, status: "queued", conclusion: "", title: "Queued build"),
            GitFixtureRuns.run(103, conclusion: "failure", title: "Broken build", event: "push"),
            GitFixtureRuns.run(104, conclusion: "cancelled"),
            GitFixtureRuns.run(105, conclusion: "skipped"),
            GitFixtureRuns.run(106, conclusion: "neutral"),
            GitFixtureRuns.run(107),
        ])
        try gh.on("run view *", json: GitFixtureRuns.jobs)
        try gh.on("pr view *", status: 1)
    }

    func path(_ name: String) -> String { paths[name]!.path }

    func context(isClaude: Bool = false, withActions: Bool = true) -> SidebarContext {
        SidebarContext(directory: repo.root.path,
                       insert: withActions ? { [weak self] in self?.inserted.append($0) } : nil,
                       isClaude: isClaude,
                       openTab: withActions ? { [weak self] in self?.opened.append(($0, $1)) } : nil,
                       switchTo: withActions ? { [weak self] in self?.switched.append($0) } : nil,
                       openGitHub: withActions ? { [weak self] in self?.openedGitHub += 1 } : nil)
    }

    /// A loaded Worktrees model (sizes measured).
    func worktrees(test: GitAreaTestCase) async throws -> WorktreesModel {
        let m = WorktreesModel(repoRoot: repo.root.path, environment: env)
        m.refresh()
        try await test.eventually(timeout: 15, "worktrees") { !m.isLoading && !m.worktrees.isEmpty }
        try await test.eventually(timeout: 15, "sizes") { m.worktrees.filter { $0.exists }.allSatisfy { $0.sizeBytes != nil } }
        return m
    }

    func pullRequests(test: GitAreaTestCase) async throws -> PullRequestsModel {
        let m = PullRequestsModel(repoRoot: repo.root.path, environment: env)
        m.refresh()
        try await test.eventually("pull requests") { !m.isLoading && !m.pullRequests.isEmpty }
        return m
    }

    func actions(test: GitAreaTestCase, load: Bool = true) async throws -> ActionsModel {
        let m = ActionsModel(repoRoot: repo.root.path, environment: env)
        if load {
            m.refresh()
            try await test.eventually("runs") { m.runs.count == 7 }
        }
        return m
    }

    func repository(test: GitAreaTestCase, in dir: URL? = nil) async throws -> GitRepository {
        let found = await GitRepository.discover(from: (dir ?? repo.root).path, environment: env)
        let r = try XCTUnwrap(found)
        test.addTeardownBlock { @MainActor in r.stop() }
        return r
    }
}

// MARK: - Right sidebar

final class RightSidebarTests: GitAreaTestCase {
    private var savedEditors: [ExternalEditor] = []

    override func setUp() async throws {
        try await super.setUp()
        savedEditors = ExternalEditor.installed
        ExternalEditor.installed = [] // no "Open in editor" buttons to press by accident
    }

    override func tearDown() async throws {
        ExternalEditor.installed = savedEditors
        try await super.tearDown()
    }

    private func sidebar(_ f: GitSidebarFixture, repo: GitRepository, worktrees: WorktreesModel, prs: PullRequestsModel,
                         actions: ActionsModel, closed: @escaping () -> Void = {}) -> RightSidebarView {
        RightSidebarView(context: f.context(), repo: repo, tree: FileTreeModel(root: repo.root, expanded: []), worktrees: worktrees,
                         pullRequests: { _ in prs }, actions: { _ in actions }, onResize: { _ in }, onResizeEnded: {}, onClose: closed)
    }

    func testEveryTabRendersAndTheTabButtonsSwitch() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let repo = try await f.repository(test: self)
        let worktrees = try await f.worktrees(test: self)
        let prs = try await f.pullRequests(test: self)
        let actions = try await f.actions(test: self)
        SettingsStore.shared.settings.worktreeStaleDays = 30
        var closes = 0

        for tab in SidebarTab.allCases {
            SettingsStore.shared.settings.sidebarTab = tab
            let host = render(sidebar(f, repo: repo, worktrees: worktrees, prs: prs, actions: actions), size: CGSize(width: 380, height: 900))
            XCTAssertGreaterThan(host.fittingSize.height, 0, "\(tab)")
        }

        // With vertical tabs the window toolbar has the inspector toggle, so the
        // tab bar is just the tabs.
        SettingsStore.shared.settings.sidebarTab = .files
        SettingsStore.shared.settings.tabBarStyle = .vertical
        let vertical = claudeWindow(sidebar(f, repo: repo, worktrees: worktrees, prs: prs, actions: actions), width: 380, height: 700)
        XCTAssertEqual(vertical.controls().filter { $0.frame.minY < 40 }.count, 3)

        // With horizontal tabs, a terminal pane's tab bar: Worktrees, Checks, Files, then the close button.
        SettingsStore.shared.settings.tabBarStyle = .horizontal
        let w = claudeWindow(sidebar(f, repo: repo, worktrees: worktrees, prs: prs, actions: actions) { closes += 1 }, width: 380, height: 700)
        func bar() -> [NSView] { w.controls().filter { $0.frame.minY < 40 }.sorted { $0.frame.minX < $1.frame.minX } }
        XCTAssertEqual(bar().count, 4)
        w.press(w.controls().firstIndex(of: bar()[0])!)
        XCTAssertEqual(SettingsStore.shared.settings.sidebarTab, .worktrees)
        w.press(w.controls().firstIndex(of: bar()[1])!)
        XCTAssertEqual(SettingsStore.shared.settings.sidebarTab, .github)
        w.press(w.controls().firstIndex(of: bar()[2])!)
        XCTAssertEqual(SettingsStore.shared.settings.sidebarTab, .files)
        w.press(w.controls().firstIndex(of: bar().last!)!)
        XCTAssertEqual(closes, 1)
        w.hover(x: 0.5, y: 300) // the resize handle
        w.hover(x: 200, y: 300)
    }

    func testGitHubTabFallsBackToFilesWithoutARemote() async throws {
        let dir = try gitTempDirectory()
        let plain = try GitFixtureRepo(in: dir, name: "plain")
        let found = await GitRepository.discover(from: plain.root.path, environment: ["PATH": "/usr/bin:/bin"])
        let repo = try XCTUnwrap(found)
        defer { repo.stop() }
        let worktrees = WorktreesModel(repoRoot: plain.root.path, environment: ["PATH": "/usr/bin:/bin"])
        SettingsStore.shared.settings.sidebarTab = .github
        let view = RightSidebarView(context: SidebarContext(directory: plain.root.path, isClaude: true), repo: repo,
                                    tree: FileTreeModel(root: plain.root, expanded: []), worktrees: worktrees,
                                    pullRequests: { _ in XCTFail("no remote, no PRs"); return PullRequestsModel(repoRoot: "", environment: [:]) },
                                    actions: { _ in XCTFail("no remote, no Actions"); return ActionsModel(repoRoot: "", environment: [:]) },
                                    onResize: { _ in }, onResizeEnded: {}, onClose: {})
        render(view, size: CGSize(width: 360, height: 500))
    }

    func testBadgesForStaleWorktreesReviewRequestsAndRunningActions() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let repo = try await f.repository(test: self)
        let worktrees = try await f.worktrees(test: self)
        let prs = try await f.pullRequests(test: self)
        let actions = try await f.actions(test: self)
        SettingsStore.shared.settings.worktreeStaleDays = 30
        XCTAssertEqual(worktrees.stale.count, 1)
        XCTAssertEqual(prs.reviewRequested.count, 1)
        XCTAssertEqual(actions.activeCount, 2)
        SettingsStore.shared.settings.sidebarTab = .worktrees
        render(sidebar(f, repo: repo, worktrees: worktrees, prs: prs, actions: actions), size: CGSize(width: 380, height: 900))

        // No review requests: the running count shows instead.
        let quiet = PullRequestsModel(repoRoot: f.repo.root.path, environment: f.env)
        render(sidebar(f, repo: repo, worktrees: worktrees, prs: quiet, actions: actions), size: CGSize(width: 380, height: 300))
        let idle = try await f.actions(test: self, load: false)
        render(sidebar(f, repo: repo, worktrees: WorktreesModel(repoRoot: f.repo.root.path, environment: f.env), prs: quiet, actions: idle),
               size: CGSize(width: 380, height: 300))
    }
}

// MARK: - Worktrees tab

final class WorktreesViewTests: GitAreaTestCase {
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

    func testRendersEveryWorktreeState() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let model = try await f.worktrees(test: self)
        SettingsStore.shared.settings.worktreeStaleDays = 30
        let byName = Dictionary(uniqueKeysWithValues: model.worktrees.map { ($0.name, $0) })
        XCTAssertEqual(byName["merged-wt"]?.isMergedAndClean, true)
        XCTAssertEqual(byName["dirty-wt"]?.ahead, 1)
        XCTAssertEqual(byName["draft-wt"]?.behind, 1)
        XCTAssertEqual(byName["approved-wt"]?.upstream, nil)
        XCTAssertEqual(byName["closed-wt"]?.upstreamGone, true)
        XCTAssertEqual(byName["locked-wt"]?.lockReason, "on a USB drive")
        XCTAssertEqual(byName["gone-wt"]?.isPrunable, true)
        XCTAssertEqual(byName["detached-wt"]?.isDetached, true)
        XCTAssertEqual(model.stale.map(\.name), ["stale-wt"])
        XCTAssertEqual(model.merged(excluding: f.repo.root.path).map(\.name), ["merged-wt"])

        for current in [f.repo.root.path, f.path("dirty")] {
            let host = render(WorktreesView(model: model, context: f.context(), currentPath: current), size: CGSize(width: 380, height: 1600))
            XCTAssertGreaterThan(host.fittingSize.height, 200)
        }
        model.lastError = "Couldn't remove: busy"
        let w = claudeWindow(WorktreesView(model: model, context: f.context(), currentPath: f.path("dirty")), width: 380, height: 1600)
        w.window.acceptsMouseMovedEvents = true
        for y in stride(from: 120.0, to: 1500.0, by: 30.0) { w.hover(x: 190, y: y) }
        XCTAssertGreaterThan(w.controls().count, 3)
    }

    func testHeaderRefreshAndErrorDismiss() async throws {
        let f = try GitSidebarFixture(in: gitTempDirectory())
        let model = try await f.worktrees(test: self)
        model.lastError = "Something failed"
        let w = claudeWindow(WorktreesView(model: model, context: f.context(), currentPath: f.repo.root.path), width: 380, height: 1600)
        // Header: refresh (top right); the filter chips; the error's dismiss
        // button at the right; then the merged cleanup bar (full width). Only
        // refresh and dismiss are pressed: the others open a confirmation or
        // the Settings window, and rows' PR links open GitHub.
        let mergedBar = try XCTUnwrap(gitControlFrames(w).first { $0.width > 300 })
        gitPress(w) { $0.minY > 50 && $0.maxY <= mergedBar.minY && $0.minX > 300 }
        try await eventually("dismissed") { model.lastError == nil }

        gitPress(w) { $0.minY < 40 && $0.minX > 300 }
        XCTAssertTrue(model.isLoading)
        try await eventually(timeout: 15) { !model.isLoading }
    }

    func testEmptyAndLoadingStates() async throws {
        let dir = try gitTempDirectory()
        let model = WorktreesModel(repoRoot: dir.path, environment: ["PATH": "/usr/bin:/bin"])
        render(WorktreesView(model: model, context: SidebarContext(directory: dir.path, isClaude: true), currentPath: dir.path))
        try await eventually { !model.isLoading }
        render(WorktreesView(model: model, context: SidebarContext(directory: dir.path, isClaude: true), currentPath: dir.path))
        XCTAssertTrue(model.worktrees.isEmpty)
    }

    func testLabels() {
        let p = ClaudePalette.current
        var wt = WorktreeInfo(path: "/x", branch: "b")
        let variants: [(inout WorktreeInfo) -> Void] = [
            { $0.upstreamGone = true },
            { $0.trackingKnown = true },
            { $0.upstream = "origin/b"; $0.ahead = 2; $0.behind = 1 },
            { $0.upstream = "origin/b"; $0.ahead = 1 },
            { $0.upstream = "origin/b"; $0.behind = 3 },
            { $0.upstream = "origin/b" },
        ]
        for change in variants {
            var v = wt
            change(&v)
            render(VStack { WorktreeLabels.tracking(v, p) }, size: CGSize(width: 300, height: 40))
        }
        for n in [nil, 0, 1, 5] as [Int?] {
            wt.changes = n
            render(VStack { WorktreeLabels.changes(wt, p) }, size: CGSize(width: 300, height: 40))
        }
        wt.changes = nil
        wt.prunableReason = "missing"
        render(VStack { WorktreeLabels.changes(wt, p) }, size: CGSize(width: 300, height: 40))
        for pr in [GitFixturePR.info(1, state: .merged), GitFixturePR.info(2, state: .closed), GitFixturePR.info(3, draft: true),
                   GitFixturePR.info(4, review: "APPROVED"), GitFixturePR.info(5, review: "CHANGES_REQUESTED"),
                   GitFixturePR.info(6, review: "REVIEW_REQUIRED"), GitFixturePR.info(7)] {
            render(WorktreeLabels.pullRequest(pr, p), size: CGSize(width: 300, height: 40))
        }
        render(WorktreeLabels.badge("main", p.cyan), size: CGSize(width: 100, height: 20))
    }

    func testDeleteSheet() throws {
        let dir = try gitTempDirectory()
        let p = ClaudePalette.current
        var calls: [(Bool, Bool)] = []

        // Dirty: Delete stays disabled until "discard" is on.
        var dirty = WorktreeInfo(path: dir.path, branch: "topic")
        dirty.changes = 2
        SettingsStore.shared.settings.worktreeCleanupDeleteMergedBranches = false
        let w = claudeWindow(DeleteWorktreeSheet(worktree: dirty, palette: p) { calls.append(($0, $1)) }, width: 460)
        XCTAssertEqual(w.controls().count, 3, "two toggles and Cancel; Delete is disabled")
        w.press(0) // discard
        w.press(1) // delete branch
        let controls = w.controls()
        XCTAssertEqual(controls.count, 4)
        w.press(controls.indices.max { controls[$0].frame.maxX < controls[$1].frame.maxX }!) // Delete
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].0)
        XCTAssertTrue(calls[0].1)
        w.press(2) // Cancel: nothing to dismiss outside a sheet

        // One change, no branch; prunable.
        var one = WorktreeInfo(path: dir.path)
        one.changes = 1
        render(DeleteWorktreeSheet(worktree: one, palette: p) { _, _ in })
        var gone = WorktreeInfo(path: dir.path, branch: "gone")
        gone.prunableReason = "missing"
        let g = claudeWindow(DeleteWorktreeSheet(worktree: gone, palette: p) { calls.append(($0, $1)) }, width: 460)
        let gc = g.controls()
        g.press(gc.indices.max { gc[$0].frame.maxX < gc[$1].frame.maxX }!)
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[1].0)
    }
}
