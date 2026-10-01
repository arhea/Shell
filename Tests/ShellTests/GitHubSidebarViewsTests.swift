import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// The workflow runs list under the inspector's Checks tab.
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
        // The inspector's Checks tab hosts the runs and points them at the branch.
        SettingsStore.shared.settings.sidebarTab = .github
        let host = render(RightSidebarView(context: f.context(), repo: repo, tree: FileTreeModel(root: repo.root, expanded: []),
                                           worktrees: worktrees, pullRequests: { _ in prs }, actions: { _ in actions },
                                           onResize: { _ in }, onResizeEnded: {}, onClose: {}),
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

}
