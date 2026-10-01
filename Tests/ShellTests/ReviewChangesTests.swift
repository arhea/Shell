import SwiftUI
import XCTest
@testable import Shell

@MainActor
final class ReviewRowsTests: XCTestCase {
    private func file(_ path: String = "a.swift", hunks: [UnifiedDiffHunk], staged: Bool = false) -> ReviewFile {
        let diff = UnifiedDiffFile(oldPath: path, newPath: path, hunks: hunks)
        return staged ? ReviewFile(path: path, staged: diff) : ReviewFile(path: path, unstaged: diff)
    }

    private let edit = UnifiedDiffHunk(oldStart: 40, oldCount: 3, newStart: 40, newCount: 3, section: "func write()", lines: [
        .init(kind: .context, text: "a", oldNumber: 40, newNumber: 40),
        .init(kind: .removed, text: "let n = 1", oldNumber: 41),
        .init(kind: .added, text: "let n = 2", newNumber: 41),
        .init(kind: .context, text: "b", oldNumber: 42, newNumber: 42),
    ])
    private let later = UnifiedDiffHunk(oldStart: 60, oldCount: 1, newStart: 60, newCount: 2, section: "", lines: [
        .init(kind: .context, text: "c", oldNumber: 60, newNumber: 60),
        .init(kind: .added, text: "d", newNumber: 61),
    ])

    func testSplitRowsPairEditedLinesWithWordChanges() {
        let rows = ReviewRows.build(.init(files: [file(hunks: [edit])]))
        let lines = rows.compactMap { r -> (ReviewCell?, ReviewCell?)? in
            if case .line(_, let l, let rt) = r.kind { return (l, rt) } else { return nil }
        }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].0?.kind, .removed)
        XCTAssertEqual(lines[1].1?.kind, .added)
        XCTAssertEqual(lines[1].0?.change, 8..<9)
        XCTAssertEqual(lines[1].1?.number(left: false), 41)
    }

    func testUnifiedRowsKeepEveryLine() {
        let rows = ReviewRows.build(.init(files: [file(hunks: [edit])], split: false))
        let lines = rows.filter { if case .line(_, _, let r) = $0.kind { r == nil } else { false } }
        XCTAssertEqual(lines.count, 4)
    }

    func testGapsBetweenHunksAndExpansion() throws {
        let rows = ReviewRows.build(.init(files: [file(hunks: [edit, later])]))
        let gaps = rows.compactMap { r -> Int? in if case .gap(_, _, let n) = r.kind { n } else { nil } }
        XCTAssertEqual(gaps, [39, 17]) // lines 1–39, then 43–59

        let g = try XCTUnwrap(ReviewRows.gap(before: later, after: edit, ref: .init(path: "a.swift", staged: false, index: 1)))
        XCTAssertEqual(g.newStart, 43)
        let source = (1...70).map { "line \($0)" }
        let expanded = ReviewRows.build(.init(files: [file(hunks: [edit, later])], expandedGaps: [g.id: source]))
        let shown = expanded.compactMap { r -> ReviewCell? in
            if case .line(_, let l, _) = r.kind, r.id.hasPrefix(g.id) { l } else { nil }
        }
        XCTAssertEqual(shown.count, 17)
        XCTAssertEqual(shown.first?.text, "line 43")
        XCTAssertEqual(shown.first?.oldNumber, 43)
    }

    func testCollapsedFileShowsOnlyHeader() {
        let rows = ReviewRows.build(.init(files: [file(hunks: [edit])], collapsed: ["a.swift"]))
        XCTAssertEqual(rows.map(\.id), ["file|a.swift"])
    }

    func testLineCapAndFullDiff() {
        let big = UnifiedDiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 3100, section: "",
                                  lines: (1...3100).map { (n: Int) in UnifiedDiffLine(kind: .added, text: "x\(n)", newNumber: n) })
        let capped = ReviewRows.build(.init(files: [file(hunks: [big])], split: false))
        XCTAssertTrue(capped.contains { if case .truncated(_, let n) = $0.kind { n == 100 } else { false } })
        let full = ReviewRows.build(.init(files: [file(hunks: [big])], split: false, fullDiff: ["a.swift"]))
        XCTAssertFalse(full.contains { if case .truncated = $0.kind { true } else { false } })
    }

    func testCommentRowFollowsItsLine() throws {
        let rows = ReviewRows.build(.init(files: [file(hunks: [edit])]))
        let line = try XCTUnwrap(rows.first { if case .line = $0.kind { true } else { false } })
        let target = ReviewCommentTarget(rowID: line.id, hunk: .init(path: "a.swift", staged: false, index: 0), line: 40, isNew: true)
        let withComment = ReviewRows.build(.init(files: [file(hunks: [edit])], comment: target))
        let i = try XCTUnwrap(withComment.firstIndex { $0.id == line.id })
        guard case .comment(let c) = withComment[i + 1].kind else { return XCTFail("no comment row") }
        XCTAssertEqual(c.line, 40)
    }

    func testStagedAndUnstagedSectionsAndNotes() {
        var f = file(hunks: [edit], staged: true)
        f.unstaged = UnifiedDiffFile(oldPath: "a.swift", newPath: "a.swift", isBinary: true)
        let rows = ReviewRows.build(.init(files: [f]))
        XCTAssertTrue(rows.contains { $0.id == "label|a.swift|true" })
        XCTAssertTrue(rows.contains { if case .note(_, let t) = $0.kind { t == "Binary file" } else { false } })
        XCTAssertTrue(rows.contains { $0.id == ReviewRows.hunkID(.init(path: "a.swift", staged: true, index: 0)) })
    }

    func testRulerMarks() {
        let rows = ReviewRows.build(.init(files: [file(hunks: [edit, later])]))
        let marks = ReviewRows.rulerMarks(rows)
        XCTAssertEqual(marks.map(\.kind), [.modified, .added])
        XCTAssertTrue(marks.allSatisfy { $0.position >= 0 && $0.position < 1 })
    }

    func testCommentMessageCarriesPathLineHunkAndComment() {
        let msg = ReviewChangesModel.commentMessage(path: "Sources/a.swift", line: 41, isNew: true, staged: false, hunk: edit,
                                                    comment: "Why 2?")
        XCTAssertTrue(msg.contains("Sources/a.swift:41"))
        XCTAssertTrue(msg.contains("@@ -40,3 +40,3 @@ func write()"))
        XCTAssertTrue(msg.contains("+let n = 2"))
        XCTAssertTrue(msg.hasSuffix("Why 2?"))
    }

    func testCommitMessageFormatting() {
        XCTAssertEqual(CommitMessageDraft.format(subject: "\"Fix the thing.\"", body: " Because. "), "Fix the thing\n\nBecause.")
        XCTAssertEqual(CommitMessageDraft.format(subject: "fix: x", body: ""), "fix: x")
        XCTAssertNil(CommitMessageDraft.format(subject: "  ", body: "b"))
        XCTAssertTrue(CommitMessageDraft.prompt(diff: String(repeating: "x", count: 5000), recentSubjects: ["feat: a"])
            .contains("[diff truncated]"))
    }
}

/// The model and view against a real throwaway repository.
final class ReviewChangesModelTests: GitAreaTestCase {
    private var repo: GitFixtureRepo!
    private var git: GitRepository!

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitFixtureRepo(in: try gitTempDirectory())
        try repo.write((1...30).map { "line \($0)" }.joined(separator: "\n") + "\n", "code.txt")
        try repo.git(["add", "-A"])
        try repo.git(["commit", "-q", "-m", "code"])
        let env = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": repo.base.path, "PATH": "/usr/bin:/bin",
                   "GIT_AUTHOR_NAME": "Shell Tests", "GIT_AUTHOR_EMAIL": "tests@example.com",
                   "GIT_COMMITTER_NAME": "Shell Tests", "GIT_COMMITTER_EMAIL": "tests@example.com"]
        let discovered = await GitRepository.discover(from: repo.root.path, environment: env)
        git = try XCTUnwrap(discovered)
    }

    override func tearDown() async throws {
        git?.stop()
        try await super.tearDown()
    }

    private func edit() throws {
        var lines = (1...30).map { "line \($0)" }
        lines[2] = "line three"
        lines[25] = "line twenty-six"
        try repo.write(lines.joined(separator: "\n") + "\n", "code.txt")
        try repo.write("new\n", "added.txt")
    }

    func testLoadsStagesCommitsAndViews() async throws {
        try edit()
        let model = ReviewChangesModel(repository: git)
        model.refresh()
        try await eventually { model.hasLoaded && !model.isLoading }
        XCTAssertEqual(model.files.map(\.path), ["added.txt", "code.txt"])
        XCTAssertEqual(model.selectedPath, "added.txt")
        XCTAssertEqual(model.totalAdditions, 3)

        // Stage one hunk of code.txt.
        let ref = ReviewHunkRef(path: "code.txt", staged: false, index: 0)
        model.stageHunk(ref)
        try await eventually { model.file("code.txt")?.stageState == .partial && !model.isLoading }
        XCTAssertEqual(model.stagedCount, 1)

        // Viewed collapses the file and survives a reload with the same content.
        let added = try XCTUnwrap(model.file("added.txt"))
        model.setViewed(added, true)
        XCTAssertEqual(model.rows.filter { $0.id.contains("added.txt") }.map(\.id), ["file|added.txt"])
        XCTAssertEqual(model.viewedCount, 1)

        // Navigation.
        model.nextFile()
        XCTAssertEqual(model.selectedPath, "code.txt")
        let token = model.scrollToken
        model.nextChange()
        XCTAssertEqual(model.scrollToken, token + 1)
        XCTAssertTrue(model.scrollTarget?.hasPrefix("hunk|") ?? false)

        // Nothing to commit without a message.
        model.commit()
        XCTAssertEqual(model.error, "Write a commit message first.")
        model.commitMessage = "fix: line three"
        model.commit()
        try await eventually { !model.isCommitting && model.commitMessage.isEmpty }
        XCTAssertNil(model.error)
        XCTAssertEqual(try repo.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines), "fix: line three")
    }

    func testCommentFlow() async throws {
        try edit()
        let model = ReviewChangesModel(repository: git)
        model.refresh()
        try await eventually { model.hasLoaded && !model.isLoading }
        let line = try XCTUnwrap(model.rows.first { $0.id.hasPrefix("line|code.txt") })
        model.beginComment(rowID: line.id, ref: .init(path: "code.txt", staged: false, index: 0), line: 3, isNew: true)
        XCTAssertTrue(model.rows.contains { $0.id == "comment|\(line.id)" })
        XCTAssertNil(model.commentMessage())
        model.commentText = "Name this better"
        let message = try XCTUnwrap(model.commentMessage())
        XCTAssertTrue(message.contains("code.txt:3"))
        XCTAssertTrue(message.contains("+line three"))
        model.cancelComment()
        XCTAssertFalse(model.rows.contains { $0.id.hasPrefix("comment|") })
        XCTAssertTrue(model.reviewPrompt.contains("code.txt"))
    }

    func testViewRendersAndBackButtonWorks() async throws {
        try edit()
        var backs = 0
        var sent: [String] = []
        let model = ReviewChangesModel(repository: git)
        model.refresh()
        try await eventually { model.hasLoaded && !model.isLoading }
        for split in [true, false] {
            model.split = split
            let w = ClaudeViewWindow(ReviewChangesView(model: model, onBack: { backs += 1 }, onSendToClaude: { sent.append($0) }),
                                     width: 1200, height: 700)
            w.layout(settle: 0.05)
            XCTAssertFalse(w.controls().isEmpty)
            // The top-left control is "‹ Chat".
            gitPress(w) { $0.minY < 40 && $0.minX < 120 }
            w.window.close()
        }
        XCTAssertEqual(backs, 2)
        model.stop()
    }
}
