import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// The GitHub tab: board, cards, stacks, badges, the detail pane and the tab
/// bar entries, over a board loaded from a fake `gh`.
final class GitHubTabViewsTests: GitAreaTestCase {
    private var controller: TerminalWindowController!

    override func setUp() async throws {
        try await super.setUp()
        controller = AppDelegate.shared.newWindowController()
    }

    override func tearDown() async throws {
        controller.workspace.githubBoard = nil
        controller.close()
        XCTAssertFalse(AppDelegate.shared.controllers.contains { $0 === controller }, "the window leaves the app delegate")
        controller = nil
        try await super.tearDown()
    }

    private func board(_ dir: URL, nodes: [[String: Any]]? = nil, merge: (Bool, Bool, Bool) = (true, true, false)) async throws -> GitHubBoardFixture {
        let f = try GitHubBoardFixture(in: dir, nodes: nodes, mergeMethods: merge)
        f.model.refresh()
        try await eventually("board") { !f.model.isLoading && f.model.lastUpdated != nil }
        return f
    }

    // MARK: Tab and board

    func testEmptyStateWithoutABoard() {
        let host = render(GitHubTabView(controller: controller, workspace: controller.workspace), size: CGSize(width: 900, height: 600))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertTrue(controller.githubRepositories.isEmpty)
    }

    func testBoardRendersColumnsCardsAndStacks() async throws {
        let f = try await board(gitTempDirectory())
        let m = f.model
        f.controller(controller)
        for filter in PullRequestBoard.Filter.allCases {
            m.filter = filter
            let host = render(GitHubTabView(controller: controller, workspace: controller.workspace), size: CGSize(width: 1400, height: 900))
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
        m.filter = .all
        m.message = ("#4: Merged.", false)
        render(GitHubBoardView(model: m, controller: controller, showsHeader: true), size: CGSize(width: 900, height: 700)) // narrower: scrolls sideways
        m.message = ("not mergeable", true)
        m.collapseStacks = false
        render(GitHubBoardView(model: m, controller: controller, showsHeader: false), size: CGSize(width: 1400, height: 700))
        m.collapseStacks = true
        for column in PullRequestBoard.Column.allCases { _ = GitHubBoardView.color(column, .current) }
        // The toolbar's title and controls.
        render(GitHubToolbarTitle(model: m, controller: controller), size: CGSize(width: 300, height: 40))
        render(GitHubToolbarTitle(model: nil, controller: controller), size: CGSize(width: 300, height: 40))
        m.searchText = "feature"
        render(GitHubToolbarControls(model: m), size: CGSize(width: 700, height: 40))
        m.searchText = ""
    }

    func testHeaderFiltersChipsAndSelection() async throws {
        let f = try await board(gitTempDirectory())
        let m = f.model
        m.filter = .all
        let w = claudeWindow(GitHubBoardView(model: m, controller: controller, showsHeader: true), width: 1500, height: 900)
        // (SwiftUI tap gestures don't fire from synthesized clicks; select directly.)
        m.selection = .init(number: 4)
        try await eventually("detail") { m.details[4] != nil }
        w.layout(settle: 0.05)
        w.window.acceptsMouseMovedEvents = true
        for x in stride(from: 50.0, to: 1500.0, by: 100.0) { w.hover(x: x, y: 160) }

        // The header's For you / Mine / All.
        gitPress(w, at: 1) { $0.minY < 40 }
        XCTAssertEqual(m.filter, .mine)
        gitPress(w, at: 0) { $0.minY < 40 }
        XCTAssertEqual(m.filter, .forYou)
        gitPress(w, at: 2) { $0.minY < 40 }
        XCTAssertEqual(m.filter, .all)

        // The sub-header's chips narrow, and toggle back.
        gitPress(w, at: 0) { $0.minY > 48 && $0.minY < 86 }
        XCTAssertEqual(m.narrowing, .reviewRequested)
        XCTAssertEqual(m.columns.values.flatMap { $0 }.flatMap(\.pullRequests).map(\.number), [5])
        gitPress(w, at: 0) { $0.minY > 48 && $0.minY < 86 }
        XCTAssertEqual(m.narrowing, [])

        // Selecting a stack layer opens the stack.
        let stack = try XCTUnwrap(PullRequestBoard.stacks(m.pullRequests).first { $0.layers.count > 1 })
        XCTAssertFalse(m.isExpanded(stack))
        m.selection = .init(number: 2, stackID: 1)
        try await eventually("stack detail") { m.details[2] != nil }
        w.layout(settle: 0.05)
        XCTAssertEqual(m.selectedStack?.layers.count, 2)
        XCTAssertTrue(m.isExpanded(stack))

        // The PR disappearing from the board closes its detail.
        m.selection = .init(number: 3)
        try f.gh.reset()
        try f.gh.on("api*graphql*", json: GitFixturePR.board(nodes: Array(GitHubBoardFixture.nodes.prefix(2))))
        try f.gh.on("pr view *", status: 1)
        try f.gh.on("pr diff *", status: 1)
        m.refresh()
        try await eventually("removed") { m.pullRequests.count == 2 }
        w.layout(settle: 0.05)
        try await eventually("deselected") { m.selection == nil }
    }

    func testCardsAndBadgesInEveryState() async throws {
        let f = try await board(gitTempDirectory())
        let m = f.model
        let p = ClaudePalette.current
        let actions = PRActions(model: m, controller: controller)
        let prs = [
            GitFixturePR.open(1, draft: true, checks: .pending, labels: [("a", "ff0000"), ("b", "zz"), ("c", "00ff00"), ("d", "0000ff")]),
            GitFixturePR.open(2, bot: true, decision: "APPROVED", checks: .passing, unresolved: 2),
            GitFixturePR.open(3, decision: "CHANGES_REQUESTED", checks: .failing,
                              reviews: [.init(login: "jane-lin", state: "CHANGES_REQUESTED")], unresolved: 1),
            GitFixturePR.open(4, decision: "REVIEW_REQUIRED", checks: .none, requested: ["octocat"], updated: nil),
            GitFixturePR.open(5, decision: "REVIEW_REQUIRED", checks: .none, reviews: [.init(login: "a", state: "COMMENTED")], unresolved: 3),
        ]
        let match = BoardTabMatch(index: 3, withClaude: true) {}
        for pr in prs {
            render(PullRequestCard(pr: pr, model: m, palette: p), size: CGSize(width: 260, height: 200))
            render(PullRequestCard(pr: pr, model: m, palette: p, actions: actions, tabMatch: match), size: CGSize(width: 260, height: 260))
            render(PRBadges(pr: pr, palette: p), size: CGSize(width: 120, height: 100))
            render(HStack { PRBadges.checksIcon(pr, p) }, size: CGSize(width: 20, height: 20))
            render(LayerChecks(pr: pr, inverted: true), size: CGSize(width: 120, height: 20))
        }
        // A selected card shows its action row.
        let card = m.pullRequest(4)!
        let plain = claudeWindow(PullRequestCard(pr: card, model: m, palette: p, actions: actions), width: 260)
        let before = plain.controls().count
        m.selection = .init(number: 4)
        plain.layout(settle: 0.05)
        XCTAssertGreaterThan(plain.controls().count, before, "Review and ↗ appear")
        render(PRWorktreeMenuItems(pr: card, actions: actions), size: CGSize(width: 200, height: 200))
        render(AvatarCircle(login: "jane-lin", name: "Jane Lin"), size: CGSize(width: 20, height: 20))
        render(ReasonPill(reasons: .assigned), size: CGSize(width: 80, height: 20))
        XCTAssertTrue(PRActions.command(name: "Review #4", prompt: "look").hasSuffix(" look"))
        XCTAssertFalse(PRActions.command(name: "x", prompt: nil).contains("''"))
        m.selection = nil

        // Busy cards.
        try f.gh.on("pr ready *", sleep: 0.5)
        let busy = Task { await m.perform(.markReady, on: card) }
        try await eventually { m.busy[4] != nil }
        render(PullRequestCard(pr: card, model: m, palette: p), size: CGSize(width: 260, height: 200))
        _ = await busy.value
        XCTAssertFalse(PRBadges.relative(Date().addingTimeInterval(-7200)).isEmpty)
        render(FlowBadges { EmptyView() }, size: CGSize(width: 100, height: 20))
        render(PRContextMenu(pr: card, model: m), size: CGSize(width: 200, height: 100))

        // A stack card: collapsed (a button per layer, then Expand), then expanded.
        let stack = try XCTUnwrap(PullRequestBoard.stacks(m.pullRequests).first { $0.layers.count > 1 })
        render(StackCard(stack: stack, model: m, palette: p), size: CGSize(width: 260, height: 200))
        let w = claudeWindow(StackCard(stack: stack, model: m, palette: p, actions: actions), width: 260)
        XCTAssertEqual(w.controls().count, 3, "one button per layer, then Expand")
        w.press(0)
        XCTAssertEqual(m.selection, .init(number: stack.top.number, stackID: stack.id), "the top layer is listed first")
        XCTAssertTrue(m.isExpanded(stack))
        XCTAssertEqual(w.controls().count, 3, "Collapse, then a row per layer")
        w.press(2)
        XCTAssertEqual(m.selection?.number, stack.bottom.number)
        w.press(0)
        XCTAssertFalse(m.isExpanded(stack))
        w.window.acceptsMouseMovedEvents = true
        w.hover(x: 100, y: 10)
    }

    func testTabBarEntries() async throws {
        let f = try await board(gitTempDirectory())
        let palette = ChromePalette.current
        render(GitHubTabChip(controller: controller, workspace: controller.workspace, palette: palette), size: CGSize(width: 140, height: 30))
        render(GitHubSidebarRow(controller: controller, workspace: controller.workspace, palette: palette), size: CGSize(width: 220, height: 40))
        controller.workspace.githubBoard = f.model
        controller.workspace.showsGitHub = true
        render(GitHubTabChip(controller: controller, workspace: controller.workspace, palette: palette), size: CGSize(width: 140, height: 30))
        let row = claudeWindow(GitHubSidebarRow(controller: controller, workspace: controller.workspace, palette: palette), width: 220)
        row.hover(x: 100, y: 10)
        let chip = claudeWindow(GitHubTabChip(controller: controller, workspace: controller.workspace, palette: palette), width: 140)
        chip.hover(x: 40, y: 10)
        XCTAssertEqual(chip.controls().count, 1, "the close button shows while selected")
        chip.press(0)
        XCTAssertFalse(controller.workspace.showsGitHub, "closing the tab hides it")
        XCTAssertNil(controller.workspace.githubBoard)
    }

    // MARK: Detail pane

    func testDetailPaneSectionsAndStates() async throws {
        let f = try await board(gitTempDirectory())
        let m = f.model
        let pr = m.pullRequest(1)!
        // Loading, then loaded, in every section.
        for section in PullRequestDetailView.Section.allCases {
            render(PullRequestDetailView(model: m, controller: controller, pr: pr, stack: nil, section: section), size: CGSize(width: 440, height: 900))
        }
        m.selection = .init(number: 1)
        try await eventually { m.details[1] != nil }
        m.loadDiff(1)
        try await eventually { m.diffs[1] != nil }
        let stack = m.selectedStack ?? PullRequestBoard.stacks(m.pullRequests).first { $0.layers.count > 1 }
        for section in PullRequestDetailView.Section.allCases {
            render(PullRequestDetailView(model: m, controller: controller, pr: pr, stack: stack, section: section), size: CGSize(width: 440, height: 1000))
        }
        let w = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: pr, stack: stack), width: 520, height: 1000)
        XCTAssertGreaterThan(w.controls().count, 5)
        // The stack rows switch layers.
        let rows = gitControlFrames(w).filter { $0.width > 300 && $0.minY > 300 }
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        gitPress(w, at: rows.count - 2) { $0.width > 300 && $0.minY > 300 }
        XCTAssertEqual(m.selection?.number, 2)

        // Someone else's PR (approve and request changes show), approved and green.
        let theirs = m.pullRequest(4)!
        m.selection = .init(number: 4)
        try await eventually { m.details[4] != nil }
        render(PullRequestDetailView(model: m, controller: controller, pr: theirs, stack: nil), size: CGSize(width: 440, height: 900))
        // A draft, with a single merge method.
        let single = try await board(gitTempDirectory(), merge: (false, true, false))
        render(PullRequestDetailView(model: single.model, controller: controller, pr: single.model.pullRequest(3)!, stack: nil),
               size: CGSize(width: 440, height: 900))
        render(PullRequestDetailView(model: single.model, controller: controller, pr: single.model.pullRequest(4)!, stack: nil),
               size: CGSize(width: 440, height: 900))
        let none = try await board(gitTempDirectory(), merge: (false, false, false))
        render(PullRequestDetailView(model: none.model, controller: controller, pr: none.model.pullRequest(4)!, stack: nil),
               size: CGSize(width: 440, height: 900))
    }

    func testDetailChecksAndFilesTabsWithEmptyData() async throws {
        let dir = try gitTempDirectory()
        let f = try GitHubBoardFixture(in: dir)
        try f.gh.reset()
        try f.gh.on("api*graphql*", json: GitFixturePR.board(nodes: GitHubBoardFixture.nodes))
        try f.gh.on("pr view * --json *", json: ["body": "", "statusCheckRollup": [Any]()])
        try f.gh.on("api*pulls/*/comments*", json: [Any]())
        try f.gh.on("pr diff *", stdout: "")
        let m = f.model
        m.refresh()
        try await eventually { m.lastUpdated != nil && !m.isLoading }
        let checks = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: m.pullRequest(4)!, stack: nil, section: .checks),
                                  width: 520, height: 800)
        m.selection = .init(number: 4)
        try await eventually { m.details[4] != nil }
        checks.layout(settle: 0.05)
        let files = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: m.pullRequest(4)!, stack: nil, section: .files),
                                 width: 520, height: 800)
        try await eventually { m.diffs[4] != nil }
        files.layout(settle: 0.05)
        XCTAssertEqual(m.diffs[4]?.isEmpty, true)
        render(PullRequestDetailView(model: m, controller: controller, pr: m.pullRequest(4)!, stack: nil), size: CGSize(width: 440, height: 800))
    }

    func testDetailButtonsRunActions() async throws {
        let f = try await board(gitTempDirectory())
        let m = f.model
        try f.gh.on("pr *")
        try f.gh.on("run rerun *")
        // A draft with failing checks: the Overview's Ready for Review banner and Re-run failed.
        var pr = m.pullRequest(1)!
        pr.isDraft = true
        m.selection = .init(number: 1)
        try await eventually { m.details[1] != nil }
        let w = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: pr, stack: nil), width: 620, height: 900)
        // Below the tab bar (y > 140), the first control is the draft banner's button.
        gitPress(w) { $0.minY > 140 && $0.minY < 820 }
        try await eventually(timeout: 5, "ready") { f.gh.calls.contains("pr ready 1 --repo acme/widgets") }
        try await eventually(timeout: 5) { m.busy.isEmpty }
        w.layout(settle: 0.05)
        gitPress(w, at: 1) { $0.minY > 140 && $0.minY < 820 }
        try await eventually(timeout: 5, "rerun") { f.gh.calls.contains("run rerun 77 --failed --repo acme/widgets") }
        try await eventually(timeout: 5) { m.busy.isEmpty }

        // Someone else's PR: Approve is last along the bottom.
        let theirs = m.pullRequest(4)!
        m.selection = .init(number: 4)
        try await eventually { m.details[4] != nil }
        let d = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: theirs, stack: nil), width: 620, height: 900)
        let bottom = d.controls().filter { $0.frame.minY > 840 }.sorted { $0.frame.minX < $1.frame.minX }
        if let approve = bottom.last {
            d.press(d.controls().firstIndex(of: approve)!)
            try await eventually(timeout: 5, "approve") { f.gh.calls.contains("pr review 4 --approve --repo acme/widgets") }
        } else {
            XCTFail("no bottom bar buttons")
        }
        try await eventually(timeout: 5) { m.busy.isEmpty }

        // Comment…: the composer opens, and Cancel closes it.
        let comment = d.controls().filter { $0.frame.minY > 840 }.min { $0.frame.minX < $1.frame.minX }!
        d.press(d.controls().firstIndex(of: comment)!)
        d.layout(settle: 0.05)
        let cancel = d.controls().filter { $0.frame.minY > 840 }.min { $0.frame.minX < $1.frame.minX }!
        d.press(d.controls().firstIndex(of: cancel)!)

        // Close details (top right of the header).
        let close = d.controls().filter { $0.frame.minY < 40 }.max { $0.frame.maxX < $1.frame.maxX }!
        d.press(d.controls().firstIndex(of: close)!)
        XCTAssertNil(m.selection)
    }

    func testFileDiffExpandsAndShowsAll() {
        let p = ClaudePalette.current
        let lines = (0..<450).map { ClaudeDiff.Line(kind: $0 % 2 == 0 ? .added : .context, text: "line \($0)", newNumber: $0) }
        let big = PullRequestDiff.File(path: "big.swift", oldPath: "old.swift", lines: lines, additions: 225, deletions: 0)
        let w = claudeWindow(PullRequestFileDiff(file: big, palette: p, startExpanded: true), width: 600)
        // The header toggles; "Show all" is a link-style button outside the key-view loop.
        XCTAssertEqual(w.controls().count, 1)
        let tall = w.host.fittingSize.height
        w.press(0) // collapse
        XCTAssertLessThan(w.host.fittingSize.height, tall)
        w.press(0) // expand again
        XCTAssertEqual(w.host.fittingSize.height, tall, accuracy: 1)

        let binary = PullRequestDiff.File(path: "img.png", lines: [], additions: 0, deletions: 0, isBinary: true)
        render(PullRequestFileDiff(file: binary, palette: p, startExpanded: true), size: CGSize(width: 400, height: 100))
        let huge = PullRequestDiff.File(path: "gen.swift", lines: Array(repeating: lines[0], count: 1600), additions: 1600, deletions: 0)
        render(PullRequestFileDiff(file: huge, palette: p, startExpanded: true), size: CGSize(width: 400, height: 100))
        let empty = PullRequestDiff.File(path: "empty", lines: [], additions: 0, deletions: 0)
        render(PullRequestFileDiff(file: empty, palette: p, startExpanded: true), size: CGSize(width: 400, height: 100))
    }

    func testReviewStateHelpers() {
        let p = ClaudePalette.current
        for state in ["APPROVED", "CHANGES_REQUESTED", "DISMISSED", "REQUESTED", "COMMENTED"] {
            XCTAssertFalse(PullRequestDetailView.reviewTitle(state).isEmpty)
            XCTAssertFalse(PullRequestDetailView.reviewIcon(state).isEmpty)
            _ = PullRequestDetailView.reviewColor(state, p)
        }
        XCTAssertEqual(PullRequestDetailView.reviewTitle("COMMENTED"), "Reviewed")
    }

    func testFlowLayoutWrapsBadges() {
        let host = render(FlowBadges {
            ForEach(0..<12) { i in PRBadges.badge("badge number \(i)", .red) }
        }.frame(width: 160), size: CGSize(width: 160, height: 400))
        XCTAssertGreaterThan(host.fittingSize.height, 30)
    }
}

private extension GitHubBoardFixture {
    /// Shows this board in the controller's GitHub tab.
    func controller(_ c: TerminalWindowController) {
        c.workspace.githubBoard = model
    }
}
