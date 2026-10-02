import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// The right inspector's logic: numstat parsing and the Session tab's
/// changes, worktree grouping and filters, tab selection, and check wording.
final class InspectorLogicTests: XCTestCase {
    // MARK: numstat

    func testParsesNumstatIncludingRenamesAndBinaries() {
        let out = "12\t3\tSources/App.swift\0-\t-\tAssets/icon.png\0" + "4\t0\t\0old/Name.swift\0new/Name.swift\0" + "0\t9\tGone.swift\0"
        let stats = DiffStat.parse(numstat: out)
        XCTAssertEqual(stats, [
            DiffStat(path: "Sources/App.swift", additions: 12, deletions: 3),
            DiffStat(path: "Assets/icon.png", additions: nil, deletions: nil),
            DiffStat(path: "new/Name.swift", additions: 4, deletions: 0, oldPath: "old/Name.swift"),
            DiffStat(path: "Gone.swift", additions: 0, deletions: 9),
        ])
        XCTAssertEqual(DiffStat.parse(numstat: ""), [])
        XCTAssertEqual(DiffStat.parse(numstat: "garbage\0"), [])
        // A truncated rename stops parsing instead of misreading paths.
        XCTAssertEqual(DiffStat.parse(numstat: "1\t1\t\0only-old\0"), [])
        // Tabs in a path survive (maxSplits).
        XCTAssertEqual(DiffStat.parse(numstat: "1\t2\ta\tb.txt\0").first?.path, "a\tb.txt")
    }

    func testBuildsChangesFromStatusAndCounts() {
        var status = GitStatusSnapshot()
        status.files = [
            "Sources/App/AppDelegate.swift": GitFileStatus(index: " ", worktree: "M"),
            "Tests/BrokenPipeTests.swift": GitFileStatus(index: "?", worktree: "?"),
            "Staged.swift": GitFileStatus(index: "A", worktree: " "),
            "Old.swift": GitFileStatus(index: "D", worktree: " "),
            "Renamed.swift": GitFileStatus(index: "R", worktree: " "),
            "Both.swift": GitFileStatus(index: "U", worktree: "U"),
            "build/": GitFileStatus(index: "!", worktree: "!"),
            "newdir/": GitFileStatus(index: "?", worktree: "?"),
        ]
        let changes = InspectorChange.build(
            status: status,
            stats: [DiffStat(path: "Sources/App/AppDelegate.swift", additions: 4, deletions: 1),
                    DiffStat(path: "Staged.swift", additions: 10, deletions: 0),
                    DiffStat(path: "Old.swift", additions: 0, deletions: 7)],
            untrackedLines: ["Tests/BrokenPipeTests.swift": 64])
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        XCTAssertNil(byPath["build/"], "ignored entries are left out")
        XCTAssertEqual(byPath["Sources/App/AppDelegate.swift"]?.letter, "M")
        XCTAssertEqual(byPath["Sources/App/AppDelegate.swift"]?.fileName, "AppDelegate.swift")
        XCTAssertEqual(byPath["Sources/App/AppDelegate.swift"]?.folder, "App")
        XCTAssertEqual(byPath["Tests/BrokenPipeTests.swift"]?.kind, .added)
        XCTAssertEqual(byPath["Tests/BrokenPipeTests.swift"]?.isUntracked, true)
        XCTAssertEqual(byPath["Tests/BrokenPipeTests.swift"]?.additions, 64)
        XCTAssertEqual(byPath["Staged.swift"]?.letter, "A")
        XCTAssertNil(byPath["Staged.swift"]?.folder)
        XCTAssertEqual(byPath["Old.swift"]?.letter, "D")
        XCTAssertEqual(byPath["Renamed.swift"]?.letter, "R")
        XCTAssertEqual(byPath["Both.swift"]?.letter, "C")
        XCTAssertEqual(byPath["newdir/"]?.fileName, "newdir")
        XCTAssertNil(byPath["newdir/"]?.additions, "folders have no counts")

        let totals = InspectorChangeTotals(changes)
        XCTAssertEqual(totals.files, 7)
        XCTAssertEqual(totals.additions, 78)
        XCTAssertEqual(totals.deletions, 8)
    }

    func testLineCounts() throws {
        let dir = try makeTemporaryDirectory()
        func file(_ name: String, _ data: Data) -> URL {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: data)
            return url
        }
        XCTAssertEqual(InspectorChange.lineCount(of: file("a.txt", Data("one\ntwo\n".utf8))), 2)
        XCTAssertEqual(InspectorChange.lineCount(of: file("b.txt", Data("one\ntwo".utf8))), 2)
        XCTAssertEqual(InspectorChange.lineCount(of: file("empty.txt", Data())), 0)
        XCTAssertNil(InspectorChange.lineCount(of: file("bin", Data([0x89, 0x50, 0x00, 0x01]))))
        XCTAssertNil(InspectorChange.lineCount(of: file("big.txt", Data("x\n".utf8)), limit: 1))
        XCTAssertNil(InspectorChange.lineCount(of: dir), "folders aren't counted")
        XCTAssertNil(InspectorChange.lineCount(of: dir.appendingPathComponent("missing")))
    }

    // MARK: Worktrees

    private func wt(_ name: String, main: Bool = false, branch: String? = nil, changes: Int? = 0, upstream: String? = nil,
                    ahead: Int = 0, tracking: Bool = true, days: Double = 0, size: Int64? = nil, root: String = "/w") -> WorktreeInfo {
        var w = WorktreeInfo(path: main ? root : "\(root)/.claude/worktrees/\(name)", branch: branch ?? name)
        w.isMain = main
        w.changes = changes
        w.upstream = upstream
        w.ahead = ahead
        w.trackingKnown = tracking
        w.lastActivity = Date().addingTimeInterval(-days * 86400)
        w.sizeBytes = size
        return w
    }

    func testFiltersAndCounts() {
        let list = [
            wt("main", main: true, upstream: "origin/main"),
            wt("dirty", changes: 3, upstream: "origin/dirty"),
            wt("local", tracking: true),
            wt("ahead", upstream: "origin/ahead", ahead: 2),
            wt("old", upstream: "origin/old", days: 30),
            wt("unknown", tracking: false),
        ]
        let counts = WorktreeFilter.counts(list, staleDays: 7)
        XCTAssertEqual(counts[.all], 6)
        XCTAssertEqual(counts[.changes], 1)
        XCTAssertEqual(counts[.notPushed], 2, "no upstream (once tracking is known), or ahead of it")
        XCTAssertEqual(counts[.stale], 1)
        XCTAssertEqual(WorktreeFilter.allCases.map(\.title), ["All", "Changes", "Not pushed", "Stale"])

        var gone = wt("gone")
        gone.upstreamGone = true
        XCTAssertFalse(gone.isNotPushed, "a deleted upstream usually means it merged")
        var detached = wt("d")
        detached.branch = nil
        XCTAssertFalse(detached.isNotPushed)
    }

    func testGroupsOpenMainAndOthers() {
        let main = wt("main", main: true)
        let open = wt("open", days: 1)
        let recent = wt("recent", days: 0)
        let older = wt("older", days: 3)
        let groups = WorktreeGroups.group([main, older, open, recent],
                                          openPaths: ["/w/.claude/worktrees/open/Sources", "/w", "/elsewhere"])
        XCTAssertEqual(groups.main?.path, "/w")
        XCTAssertEqual(groups.open.map(\.path), [open.path], "a nested worktree belongs to itself, not the main checkout")
        XCTAssertEqual(groups.others.map(\.path), [recent.path, older.path], "most recent first")

        XCTAssertEqual(WorktreeGroups.owner(of: "/w/Sources", in: [main, open]), "/w")
        XCTAssertEqual(WorktreeGroups.owner(of: "/w/.claude/worktrees/open", in: [main, open]), open.path)
        XCTAssertNil(WorktreeGroups.owner(of: "/w2", in: [main]), "a sibling with a shared prefix isn't inside")
        XCTAssertEqual(WorktreeGroups.owner(of: "/w/./x/..", in: [main]), "/w")
    }

    @MainActor
    func testStaleSize() {
        let model = WorktreesModel(repoRoot: "/nonexistent", environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(model.staleSize, 0)
    }

    @MainActor
    func testTabStateLabels() {
        XCTAssertEqual(WorktreeTabState(.needsInput(.claude, "Bash")).text, "Claude needs approval")
        XCTAssertEqual(WorktreeTabState(.working(.codex)).text, "Codex working")
        XCTAssertEqual(WorktreeTabState(.finished(.claude, "")).agent, .done)
        XCTAssertNil(WorktreeTabState(nil).text)
        XCTAssertEqual(WorktreeTabState(agent: .working).text, "Agent working")
        XCTAssertEqual(WorktreeTabState(agent: .needsYou, label: "Custom").text, "Custom")
        for kind in [StatusKind.needsYou, .done, .failed] { XCTAssertNotNil(WorktreeTabState(agent: kind).text) }
    }

    // MARK: Tabs

    func testTabsAndSelection() {
        XCTAssertEqual(InspectorTab.available(isClaude: true, hasGitHub: true), [.session, .worktrees, .checks, .files])
        XCTAssertEqual(InspectorTab.available(isClaude: false, hasGitHub: true), [.worktrees, .checks, .files])
        XCTAssertEqual(InspectorTab.available(isClaude: false, hasGitHub: false), [.worktrees, .files])
        XCTAssertEqual(InspectorTab.resolve(preferred: .checks, available: [.worktrees, .files]), .files)
        XCTAssertEqual(InspectorTab.resolve(preferred: .checks, available: [.session, .worktrees, .files]), .session)
        XCTAssertEqual(InspectorTab.resolve(preferred: .worktrees, available: [.worktrees, .files]), .worktrees)
        for tab in InspectorTab.allCases {
            if let stored = tab.storedTab { XCTAssertEqual(InspectorTab(stored), tab) } else { XCTAssertEqual(tab, .session) }
            XCTAssertFalse(tab.title.isEmpty)
        }
    }

    // MARK: Formatting and checks

    func testFormatting() {
        XCTAssertEqual(InspectorFormat.duration(41), "41s")
        XCTAssertEqual(InspectorFormat.duration(242), "4m 02s")
        XCTAssertEqual(InspectorFormat.duration(3720), "1h 02m")
        XCTAssertEqual(InspectorFormat.duration(-5), "0s")
        let now = Date()
        XCTAssertEqual(InspectorFormat.ago(now, now: now), "just now")
        XCTAssertEqual(InspectorFormat.ago(now.addingTimeInterval(-360), now: now), "6 min ago")
        XCTAssertEqual(InspectorFormat.ago(now.addingTimeInterval(-7300), now: now), "2 h ago")
        XCTAssertEqual(InspectorFormat.ago(now.addingTimeInterval(-90000), now: now), "1 day ago")
        XCTAssertEqual(InspectorFormat.ago(now.addingTimeInterval(-300000), now: now), "3 days ago")
    }

    @MainActor
    func testCheckWording() {
        var job = CheckJob(id: "1", name: "Build and test", workflow: "Test · test.yml", state: .failed, duration: 242)
        XCTAssertEqual(ChecksText.duration(job), "4m 02s")
        XCTAssertEqual(ChecksText.title(job), "Test / Build and test")
        XCTAssertEqual(ChecksText.workflowFile(job), "test.yml")
        XCTAssertEqual(ChecksText.title(CheckJob(id: "2", name: "swiftlint", state: .passed)), "swiftlint")
        XCTAssertEqual(ChecksText.title(CheckJob(id: "3", name: "Lint", workflow: "Lint", state: .passed)), "Lint")
        XCTAssertEqual(ChecksText.title(CheckJob(id: "4", name: "Lint / swiftlint", workflow: "Lint", state: .passed)), "Lint / swiftlint")
        XCTAssertNil(ChecksText.workflowFile(CheckJob(id: "5", name: "x", workflow: "Test", state: .passed)))
        job.state = .skipped
        XCTAssertEqual(ChecksText.duration(job), "skipped")
        job.state = .queued
        XCTAssertEqual(ChecksText.duration(job), "queued")
        job.state = .cancelled
        XCTAssertEqual(ChecksText.duration(job), "cancelled")
        XCTAssertEqual(ChecksText.duration(CheckJob.Step(name: "Run tests", state: .failed, duration: 41)), "41s")
        XCTAssertEqual(ChecksText.duration(CheckJob.Step(name: "Upload", state: .skipped)), "skipped")

        let now = Date()
        let snap = BranchChecksSnapshot(branch: "bug/38", prNumber: 39, headSHA: "74c838fabc", updatedAt: now.addingTimeInterval(-360), jobs: [])
        XCTAssertEqual(ChecksText.subtitle(snap, now: now), "PR #39 · 74c838f · 6 min ago")
    }

    @MainActor
    func testFixPromptAndLogPath() {
        let a = CheckJob(id: "123", name: "Build and test", workflow: "Test · test.yml", state: .failed)
        let b = CheckJob(id: "lint/swift", name: "swiftlint", state: .failed)
        XCTAssertEqual(ChecksFix.prompt(for: [a], logPaths: ["/tmp/a.log"], prNumber: 39),
                       "Fix the failing CI check Test / Build and test on PR #39. The failing log is in /tmp/a.log."
                       + " Find the cause, fix it, and run the relevant tests locally.")
        let two = ChecksFix.prompt(for: [a, b], logPaths: ["/a", "/b"], prNumber: nil)
        XCTAssertTrue(two.hasPrefix("Fix the failing CI checks Test / Build and test, swiftlint. The failing logs are in /a, /b."), two)
        XCTAssertFalse(ChecksFix.prompt(for: [b], logPaths: [], prNumber: nil).contains("log"))
        XCTAssertEqual(ChecksFix.logURL(for: b).lastPathComponent, "lint-swift.log")
    }
}

/// The inspector's views render in each state and their buttons call back.
final class InspectorViewTests: GitAreaTestCase {
    func testSessionViewSectionsAndCallbacks() {
        var opened: [String] = []
        var stopped: [String] = []
        var transcripts: [String] = []
        var reviews = 0
        let changes = [InspectorChange(path: "Sources/App/AppDelegate.swift", kind: .modified, additions: 4, deletions: 1),
                       InspectorChange(path: "Tests/BrokenPipeTests.swift", kind: .added, additions: 64, deletions: 0, isUntracked: true),
                       InspectorChange(path: "Old.swift", kind: .deleted, additions: 0, deletions: 9)]
        let todos = [InspectorTodo(title: "Reproduce", state: .completed), InspectorTodo(title: "File the PR", state: .inProgress),
                     InspectorTodo(title: "Watch CI", state: .pending)]
        let background = [
            InspectorBackgroundItem(id: "a", name: "code-reviewer", kind: .subagent, startedAt: Date().addingTimeInterval(-38),
                                    detail: "Reading StreamWriter.swift · Read 4"),
            InspectorBackgroundItem(id: "b", name: "CI · PR #39", kind: .backgroundTask, startedAt: nil,
                                    detail: "gh pr checks 39 --watch", detailIsCommand: true,
                                    jobs: [.init(name: "lint", state: .passed, detail: "32s"), .init(name: "Build", state: .running, detail: "3m 12s"),
                                           .init(name: "Notarize", state: .queued, detail: "queued")]),
            InspectorBackgroundItem(id: "c", name: "done-task", kind: .backgroundTask, isRunning: false),
        ]
        let view = InspectorSessionView(changes: changes, todos: todos, background: background, onReview: { reviews += 1 },
                                        onOpenFile: { opened.append($0.path) }, onStop: { stopped.append($0.id) },
                                        onViewTranscript: { transcripts.append($0.id) })
        let w = claudeWindow(view, width: 340, height: 900)
        w.pressAll()
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(opened, changes.map(\.path))
        XCTAssertEqual(Set(stopped), ["a", "b"], "finished items have no Stop")
        XCTAssertEqual(Set(transcripts), ["a", "b", "c"])

        // Nothing changed yet: no Review, an empty line instead of rows.
        render(InspectorSessionView(changes: [], todos: [], background: [], onOpenFile: { _ in }, onStop: { _ in }, onViewTranscript: { _ in }),
               size: CGSize(width: 340, height: 300))
        for state in [CheckJob.State.queued, .running, .passed, .failed, .skipped, .cancelled] {
            render(CheckStateMark(state: state), size: CGSize(width: 20, height: 20))
        }
    }

    func testChangesModelReadsLineCountsFromGit() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        try repo.write("one\ntwo\nthree\n", "file.txt")
        try repo.commit("base", file: "notes.txt") // commits file.txt too (add -A)
        try repo.write("one\nTWO\nthree\nfour\n", "file.txt")
        try repo.write("a\nb\n", "Tests/New.swift")
        let env = ["PATH": "/usr/bin:/bin"]
        let found = await GitRepository.discover(from: repo.root.path, environment: env)
        let git = try XCTUnwrap(found)
        defer { git.stop() }
        let model = WorkingChangesModel(repository: git, environment: env)
        model.refresh()
        model.refresh() // coalesced
        try await eventually("changes") { !model.isLoading && model.changes.count == 2 }
        let byPath = Dictionary(uniqueKeysWithValues: model.changes.map { ($0.path, $0) })
        XCTAssertEqual(byPath["file.txt"]?.additions, 2)
        XCTAssertEqual(byPath["file.txt"]?.deletions, 1)
        XCTAssertEqual(byPath["Tests/New.swift"]?.additions, 2)
        XCTAssertEqual(model.totals.files, 2)
        XCTAssertTrue(WorkingChangesModel.shared(for: git, environment: env) === WorkingChangesModel.shared(for: git, environment: env))
    }

    func testChecksViewsEmptyStates() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        try repo.fakeGitHubOrigin()
        let found = await GitRepository.discover(from: repo.root.path, environment: ["PATH": "/usr/bin:/bin"])
        let git = try XCTUnwrap(found)
        defer { git.stop() }
        let model = BranchChecksModel(repository: git)
        XCTAssertEqual(ChecksText.emptyState(model)?.title, "No checks yet")
        var fixed = 0
        render(InspectorChecksView(model: model, fixing: ["x"], extra: AnyView(Text("extra"))) { _ in fixed += 1 },
               size: CGSize(width: 340, height: 700))
        render(InspectorChecksView(model: model, showsAutoFix: false) { _ in }, size: CGSize(width: 340, height: 400))
        let w = claudeWindow(ChecksPopoverView(model: model, onFix: { _ in fixed += 1 }, onFixAll: { _ in fixed += 1 }), width: 460)
        XCTAssertGreaterThan(w.size.height, 0)
        XCTAssertEqual(fixed, 0)
        // The auto-fix switch is shown for Claude panes, reflecting the model.
        model.sendFailuresToClaude = true
        let toggled = claudeWindow(InspectorChecksView(model: model) { _ in }, width: 340, height: 600)
        XCTAssertEqual(try XCTUnwrap(toggled.subview(NSSwitch.self)).state, .on)
    }
}
