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
        render(GitHubBoardView(model: m, controller: controller), size: CGSize(width: 900, height: 700)) // narrower: scrolls sideways
        m.message = ("not mergeable", true)
        render(GitHubBoardView(model: m, controller: controller), size: CGSize(width: 1400, height: 700))
        for column in PullRequestBoard.Column.allCases { _ = GitHubBoardView.color(column, .current) }
    }

    func testCardTapsSelectAndTheDetailPaneOpens() async throws {
        let f = try await board(gitTempDirectory())
        let m = f.model
        m.filter = .all
        let w = claudeWindow(GitHubBoardView(model: m, controller: controller), width: 1500, height: 900)
        // (SwiftUI tap gestures don't fire from synthesized clicks; select directly.)
        m.selection = .init(number: 4)
        try await eventually("detail") { m.details[4] != nil }
        w.layout(settle: 0.05)
        w.window.acceptsMouseMovedEvents = true
        for x in stride(from: 50.0, to: 1500.0, by: 100.0) { w.hover(x: x, y: 120) }

        // The stack card's layer buttons select within the stack (top layer listed first).
        let layers = gitControlFrames(w).filter { $0.width > 200 && $0.minY > 60 }
        XCTAssertEqual(layers.count, 2)
        gitPress(w) { $0.width > 200 && $0.minY > 60 && $0.maxX < 980 }
        XCTAssertEqual(m.selection, .init(number: 2, stackID: 1))
        try await eventually("stack detail") { m.details[2] != nil }
        w.layout(settle: 0.05)
        XCTAssertEqual(m.selectedStack?.layers.count, 2)

        // The filter picker: Mine, then All.
        gitClickSegment(w, 0, segments: 2) { $0.minY < 40 }
        XCTAssertEqual(m.filter, .mine)
        gitClickSegment(w, 1, segments: 2) { $0.minY < 40 }
        XCTAssertEqual(m.filter, .all)
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
        let prs = [
            GitFixturePR.open(1, draft: true, checks: .pending, labels: [("a", "ff0000"), ("b", "zz"), ("c", "00ff00"), ("d", "0000ff")]),
            GitFixturePR.open(2, bot: true, decision: "APPROVED", checks: .passing, unresolved: 2),
            GitFixturePR.open(3, decision: "CHANGES_REQUESTED", checks: .failing),
            GitFixturePR.open(4, decision: "REVIEW_REQUIRED", checks: .none, updated: nil),
        ]
        for pr in prs {
            render(PullRequestCard(pr: pr, model: m, palette: p), size: CGSize(width: 260, height: 200))
            render(PRBadges(pr: pr, palette: p), size: CGSize(width: 120, height: 100))
            render(HStack { PRBadges.checksIcon(pr, p) }, size: CGSize(width: 20, height: 20))
        }
        // Busy and checked-out cards.
        try f.gh.on("pr ready *", sleep: 0.5)
        let card = m.pullRequest(4)!
        let busy = Task { await m.perform(.markReady, on: card) }
        try await eventually { m.busy[4] != nil }
        render(PullRequestCard(pr: card, model: m, palette: p), size: CGSize(width: 260, height: 200))
        _ = await busy.value
        XCTAssertFalse(PRBadges.relative(Date().addingTimeInterval(-7200)).isEmpty)
        render(FlowBadges { EmptyView() }, size: CGSize(width: 100, height: 20))
        render(PRContextMenu(pr: card, model: m), size: CGSize(width: 200, height: 100))

        // A stack card, selected and not.
        let stack = try XCTUnwrap(PullRequestBoard.stacks(m.pullRequests).first { $0.layers.count > 1 })
        render(StackCard(stack: stack, model: m, palette: p), size: CGSize(width: 260, height: 200))
        m.selection = .init(number: stack.bottom.number, stackID: stack.id)
        let w = claudeWindow(StackCard(stack: stack, model: m, palette: p), width: 260)
        XCTAssertEqual(w.controls().count, 2, "one button per layer")
        w.press(0)
        XCTAssertEqual(m.selection?.stackID, stack.id)
        XCTAssertEqual(m.selection?.number, stack.layers.last?.pr.number, "the top layer is listed first")
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
        // Loading, then loaded.
        render(PullRequestDetailView(model: m, controller: controller, pr: pr, stack: nil), size: CGSize(width: 520, height: 900))
        m.selection = .init(number: 1)
        try await eventually { m.details[1] != nil }
        m.loadDiff(1)
        try await eventually { m.diffs[1] != nil }
        let stack = m.selectedStack ?? PullRequestBoard.stacks(m.pullRequests).first { $0.layers.count > 1 }
        let w = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: pr, stack: stack), width: 520, height: 1000)
        XCTAssertGreaterThan(w.controls().count, 5)
        gitClickSegment(w, 1, segments: 3)
        w.layout(settle: 0.05)
        gitClickSegment(w, 2, segments: 3)
        w.layout(settle: 0.05)
        gitClickSegment(w, 0, segments: 3)
        w.layout(settle: 0.05)

        // Someone else's PR (approve and request changes show), approved and green.
        let theirs = m.pullRequest(4)!
        m.selection = .init(number: 4)
        try await eventually { m.details[4] != nil }
        render(PullRequestDetailView(model: m, controller: controller, pr: theirs, stack: nil), size: CGSize(width: 520, height: 900))
        // A draft, with a single merge method.
        let single = try await board(gitTempDirectory(), merge: (false, true, false))
        render(PullRequestDetailView(model: single.model, controller: controller, pr: single.model.pullRequest(3)!, stack: nil),
               size: CGSize(width: 520, height: 900))
        render(PullRequestDetailView(model: single.model, controller: controller, pr: single.model.pullRequest(4)!, stack: nil),
               size: CGSize(width: 520, height: 900))
        let none = try await board(gitTempDirectory(), merge: (false, false, false))
        render(PullRequestDetailView(model: none.model, controller: controller, pr: none.model.pullRequest(4)!, stack: nil),
               size: CGSize(width: 520, height: 900))
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
        let w = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: m.pullRequest(4)!, stack: nil), width: 520, height: 800)
        gitClickSegment(w, 1, segments: 3) // checks: loading
        m.selection = .init(number: 4)
        try await eventually { m.details[4] != nil }
        w.layout(settle: 0.05)
        gitClickSegment(w, 2, segments: 3) // files: loads an empty diff
        try await eventually { m.diffs[4] != nil }
        w.layout(settle: 0.05)
        XCTAssertEqual(m.diffs[4]?.isEmpty, true)
    }

    func testDetailButtonsRunActions() async throws {
        let f = try await board(gitTempDirectory())
        let m = f.model
        try f.gh.on("pr *")
        try f.gh.on("run rerun *")
        // A draft with failing checks: Ready for Review and Re-run Failed come first.
        var pr = m.pullRequest(1)!
        pr.isDraft = true
        m.selection = .init(number: 1)
        try await eventually { m.details[1] != nil }
        let w = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: pr, stack: nil), width: 620, height: 900)
        let bar = w.controls().filter { $0.frame.minY > 60 && $0.frame.minY < 110 }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertGreaterThanOrEqual(bar.count, 3)
        w.press(w.controls().firstIndex(of: bar[0])!)
        try await eventually(timeout: 5, "ready") { f.gh.calls.contains("pr ready 1 --repo acme/widgets") }
        try await eventually(timeout: 5) { m.busy.isEmpty }
        let bar2 = w.controls().filter { $0.frame.minY > 60 && $0.frame.minY < 110 }.sorted { $0.frame.minX < $1.frame.minX }
        w.press(w.controls().firstIndex(of: bar2[1])!)
        try await eventually(timeout: 5, "rerun") { f.gh.calls.contains("run rerun 77 --failed --repo acme/widgets") }
        try await eventually(timeout: 5) { m.busy.isEmpty }

        // Someone else's PR: the composer's Approve (enabled with an empty draft).
        let theirs = m.pullRequest(4)!
        m.selection = .init(number: 4)
        try await eventually { m.details[4] != nil }
        let d = claudeWindow(PullRequestDetailView(model: m, controller: controller, pr: theirs, stack: nil), width: 620, height: 900)
        let bottom = d.controls().filter { $0.frame.minY > 820 }.sorted { $0.frame.minX < $1.frame.minX }
        if let approve = bottom.last {
            d.press(d.controls().firstIndex(of: approve)!)
            try await eventually(timeout: 5, "approve") { f.gh.calls.contains("pr review 4 --approve --repo acme/widgets") }
        } else {
            XCTFail("no composer buttons")
        }
        try await eventually(timeout: 5) { m.busy.isEmpty }

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
