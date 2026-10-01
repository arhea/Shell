import XCTest
@testable import Shell

final class WorkingTreeDiffParsingTests: XCTestCase {
    private let sample = """
    diff --git a/Sources/StreamWriter.swift b/Sources/StreamWriter.swift
    index 1111111..2222222 100644
    --- a/Sources/StreamWriter.swift
    +++ b/Sources/StreamWriter.swift
    @@ -40,4 +40,6 @@ func write(_ data: Data) throws {
     func write() {
    -    if n < 0 { throw StreamError.posix(errno) }
    +    if n < 0 {
    +        throw StreamError.closed
    +    }
     }
    @@ -61,2 +63,3 @@ func close()
     func close() {
    +    guard isOpen else { return }
         Darwin.close(fd)
    diff --git a/Tests/New Test.swift b/Tests/New Test.swift
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/Tests/New Test.swift\t
    @@ -0,0 +1,2 @@
    +import XCTest
    +-- not a header
    \\ No newline at end of file
    diff --git a/old.txt b/old.txt
    deleted file mode 100644
    index 4444444..0000000
    --- a/old.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/logo.png b/logo.png
    index 5555555..6666666 100644
    Binary files a/logo.png and b/logo.png differ

    """

    func testParsesFilesHunksAndLines() throws {
        let files = UnifiedDiffParser.parse(sample)
        XCTAssertEqual(files.map(\.path), ["Sources/StreamWriter.swift", "Tests/New Test.swift", "old.txt", "logo.png"])

        let modified = files[0]
        XCTAssertFalse(modified.isNew)
        XCTAssertEqual(modified.hunks.count, 2)
        XCTAssertEqual(modified.additions, 4)
        XCTAssertEqual(modified.deletions, 1)
        let h = modified.hunks[0]
        XCTAssertEqual([h.oldStart, h.oldCount, h.newStart, h.newCount], [40, 4, 40, 6])
        XCTAssertEqual(h.section, "func write(_ data: Data) throws {")
        XCTAssertEqual(h.lines.map(\.kind), [.context, .removed, .added, .added, .added, .context])
        XCTAssertEqual(h.lines[1].oldNumber, 41)
        XCTAssertNil(h.lines[1].newNumber)
        XCTAssertEqual(h.lines[4].newNumber, 43)
        XCTAssertEqual(h.lines[5].oldNumber, 42)
        XCTAssertEqual(h.lines[5].newNumber, 44)
        XCTAssertEqual(h.lines[2].text, "    if n < 0 {")
        XCTAssertEqual(modified.hunks[1].header, "@@ -61,2 +63,3 @@ func close()")

        let new = files[1]
        XCTAssertTrue(new.isNew)
        XCTAssertNil(new.oldPath)
        XCTAssertEqual(new.hunks[0].lines.map(\.text), ["import XCTest", "-- not a header"])
        XCTAssertTrue(new.hunks[0].lines[1].noNewline)

        XCTAssertTrue(files[2].isDeleted)
        XCTAssertEqual(files[2].hunks[0].header, "@@ -1 +0,0 @@")
        XCTAssertTrue(files[3].isBinary)
        XCTAssertTrue(files[3].hunks.isEmpty)
    }

    func testHunkTextRoundTrips() {
        let h = UnifiedDiffParser.parse(sample)[1].hunks[0]
        XCTAssertEqual(h.text, "@@ -0,0 +1,2 @@\n+import XCTest\n+-- not a header\n\\ No newline at end of file")
    }

    func testKeepsCarriageReturns() {
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-one\r\n+two\r\n"
        let line = UnifiedDiffParser.parse(diff)[0].hunks[0].lines[1]
        XCTAssertEqual(line.text, "two\r")
    }

    func testUnquotesPaths() {
        XCTAssertEqual(UnifiedDiffParser.unquote("\"a/caf\\303\\251.txt\""), "a/café.txt")
        XCTAssertEqual(UnifiedDiffParser.path("\"b/tab\\there\"", prefix: "b/"), "tab\there")
        XCTAssertNil(UnifiedDiffParser.path("/dev/null", prefix: "a/"))
        XCTAssertEqual(UnifiedDiffParser.pathsFromDiffGit("a/x y b/x y")?.0, "x y")
    }

    func testMergesStagedUnstagedAndUntracked() {
        let files = UnifiedDiffParser.parse(sample)
        let merged = ReviewFile.merge(staged: [files[0]], unstaged: [files[0], files[2]],
                                      untracked: [UnifiedDiffFile(newPath: "z.txt", isNew: true)])
        XCTAssertEqual(merged.map(\.path), ["old.txt", "Sources/StreamWriter.swift", "z.txt"])
        XCTAssertEqual(merged[0].status, .deleted)
        XCTAssertEqual(merged[0].stageState, .none)
        XCTAssertEqual(merged[1].stageState, .partial)
        XCTAssertEqual(merged[1].additions, 8)
        XCTAssertEqual(merged[2].letter, "A")
        XCTAssertTrue(merged[2].isUntracked)
    }

    // MARK: Patches

    func testForwardPatchRebasesNewStart() {
        let file = UnifiedDiffParser.parse(sample)[0]
        let patch = GitPatch.patch(file: file, hunk: file.hunks[1])
        XCTAssertEqual(patch, """
        diff --git a/Sources/StreamWriter.swift b/Sources/StreamWriter.swift
        --- a/Sources/StreamWriter.swift
        +++ b/Sources/StreamWriter.swift
        @@ -61,2 +61,3 @@ func close()
         func close() {
        +    guard isOpen else { return }
             Darwin.close(fd)

        """)
    }

    func testReversePatchRebasesOldStart() {
        let file = UnifiedDiffParser.parse(sample)[0]
        let patch = GitPatch.patch(file: file, hunk: file.hunks[1], reverse: true)
        XCTAssertTrue(patch.contains("@@ -63,2 +63,3 @@ func close()"), patch)
    }

    func testPureInsertionAndDeletionStarts() {
        let ins = UnifiedDiffHunk(oldStart: 5, oldCount: 0, newStart: 9, newCount: 2, section: "",
                                  lines: [.init(kind: .added, text: "a"), .init(kind: .added, text: "b")])
        let file = UnifiedDiffFile(oldPath: "f", newPath: "f", hunks: [ins])
        XCTAssertTrue(GitPatch.patch(file: file, hunk: ins).contains("@@ -5,0 +6,2 @@"))
        XCTAssertTrue(GitPatch.patch(file: file, hunk: ins, reverse: true).contains("@@ -8,0 +9,2 @@"))
        let del = UnifiedDiffHunk(oldStart: 6, oldCount: 1, newStart: 9, newCount: 0, section: "",
                                  lines: [.init(kind: .removed, text: "x")])
        XCTAssertTrue(GitPatch.patch(file: file, hunk: del).contains("@@ -6 +5,0 @@"))
        XCTAssertTrue(GitPatch.patch(file: file, hunk: del, reverse: true).contains("@@ -10 +9,0 @@"))
    }
}

/// Stages, unstages and reverts hunks in a real throwaway repository.
final class GitStagingTests: GitAreaTestCase {
    private var repo: GitFixtureRepo!
    private var staging: GitStaging!

    private let original = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitFixtureRepo(in: try gitTempDirectory())
        try repo.write(original, "code.txt")
        try repo.git(["add", "-A"])
        try repo.git(["commit", "-q", "-m", "code"])
        let env = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": repo.base.path,
                   "GIT_AUTHOR_NAME": "Shell Tests", "GIT_AUTHOR_EMAIL": "tests@example.com",
                   "GIT_COMMITTER_NAME": "Shell Tests", "GIT_COMMITTER_EMAIL": "tests@example.com"]
        staging = GitStaging(git: "/usr/bin/git", root: repo.root.path, environment: env)
    }

    /// Two separate changes: line 3 edited, two lines added after line 25.
    private func makeTwoHunks() throws -> String {
        var lines = (1...30).map { "line \($0)" }
        lines[2] = "line three"
        lines.insert(contentsOf: ["new a", "new b"], at: 25)
        let text = lines.joined(separator: "\n") + "\n"
        try repo.write(text, "code.txt")
        return text
    }

    private func load(_ ignoreWhitespace: Bool = false) async -> [ReviewFile] {
        await WorkingTreeDiff.load(git: "/usr/bin/git", root: repo.root.path, environment: staging.environment,
                                   ignoreWhitespace: ignoreWhitespace).files
    }

    private func index(_ path: String = "code.txt") throws -> String {
        try repo.git(["show", ":\(path)"])
    }

    func testLoadsUnstagedStagedAndUntracked() async throws {
        _ = try makeTwoHunks()
        try repo.write("hello\n", "notes/new.txt")
        try repo.write("staged\n", "staged.txt")
        try repo.git(["add", "staged.txt"])
        let files = await load()
        XCTAssertEqual(files.map(\.path), ["code.txt", "notes/new.txt", "staged.txt"])
        XCTAssertEqual(files[0].unstaged?.hunks.count, 2)
        XCTAssertTrue(files[1].isUntracked)
        XCTAssertEqual(files[1].unstaged?.hunks.first?.lines.map(\.text), ["hello"])
        XCTAssertEqual(files[2].stageState, .full)
        XCTAssertEqual(files[2].status, .added)
    }

    func testStagingOneHunkMatchesApplyingThatHunk() async throws {
        let edited = try makeTwoHunks()
        let loaded_file = await load()
        let file = try XCTUnwrap(loaded_file.first?.unstaged)
        XCTAssertEqual(file.hunks.count, 2)
        let second = file.hunks[1]

        let err = await staging.stageHunk(second, of: file)
        XCTAssertNil(err)

        // Expected index: HEAD plus only the second change.
        var expected = (1...30).map { "line \($0)" }
        expected.insert(contentsOf: ["new a", "new b"], at: 25)
        XCTAssertEqual(try index(), expected.joined(separator: "\n") + "\n")

        // git itself sees only the second change as staged.
        let viaGit = try repo.git(["diff", "--cached"])
        XCTAssertTrue(viaGit.contains("+new a"))
        XCTAssertFalse(viaGit.contains("line three"))

        // The worktree is untouched and the first hunk is still unstaged.
        XCTAssertEqual(try String(contentsOf: repo.root.appendingPathComponent("code.txt"), encoding: .utf8), edited)
        let loaded_after = await load()
        let after = try XCTUnwrap(loaded_after.first)
        XCTAssertEqual(after.stageState, .partial)
        XCTAssertEqual(after.unstaged?.hunks.count, 1)
        XCTAssertEqual(after.staged?.hunks.count, 1)
    }

    func testStagingEachHunkInTurnStagesTheWholeFile() async throws {
        let edited = try makeTwoHunks()
        let loaded_file = await load()
        let file = try XCTUnwrap(loaded_file.first?.unstaged)
        // Stage the first hunk; the second hunk object (from the old diff) must still apply.
        let first = await staging.stageHunk(file.hunks[0], of: file)
        XCTAssertNil(first)
        let second = await staging.stageHunk(file.hunks[1], of: file)
        XCTAssertNil(second)
        XCTAssertEqual(try index(), edited)
    }

    func testUnstageHunk() async throws {
        _ = try makeTwoHunks()
        try repo.git(["add", "code.txt"])
        let loaded_staged = await load()
        let staged = try XCTUnwrap(loaded_staged.first?.staged)
        let err = await staging.unstageHunk(staged.hunks[0], of: staged)
        XCTAssertNil(err)
        var expected = (1...30).map { "line \($0)" }
        expected.insert(contentsOf: ["new a", "new b"], at: 25)
        XCTAssertEqual(try index(), expected.joined(separator: "\n") + "\n")
    }

    func testRevertHunkInWorkingTree() async throws {
        _ = try makeTwoHunks()
        let loaded_file = await load()
        let file = try XCTUnwrap(loaded_file.first?.unstaged)
        let err = await staging.revertHunk(file.hunks[0], of: file, untracked: false)
        XCTAssertNil(err)
        let text = try String(contentsOf: repo.root.appendingPathComponent("code.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("line 3\n"))
        XCTAssertTrue(text.contains("new a"))
        XCTAssertEqual(try index(), original)
    }

    func testNewFilesStageAndUnstageWhole() async throws {
        try repo.write("one\ntwo\n", "fresh.txt")
        let loaded_file = await load()
        let file = try XCTUnwrap(loaded_file.first { $0.path == "fresh.txt" })
        let unstaged = try XCTUnwrap(file.unstaged)
        let err = await staging.stageHunk(unstaged.hunks[0], of: unstaged)
        XCTAssertNil(err)
        XCTAssertEqual(try index("fresh.txt"), "one\ntwo\n")
        let loaded_staged = await load()
        let staged = try XCTUnwrap(loaded_staged.first { $0.path == "fresh.txt" }?.staged)
        XCTAssertTrue(staged.isNew)
        let unstageErr = await staging.unstageHunk(staged.hunks[0], of: staged)
        XCTAssertNil(unstageErr)
        let back = await load().first { $0.path == "fresh.txt" }
        XCTAssertEqual(back?.isUntracked, true)
    }

    func testDeletedFileStagesWhole() async throws {
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("code.txt"))
        let loaded_file = await load()
        let file = try XCTUnwrap(loaded_file.first?.unstaged)
        XCTAssertTrue(file.isDeleted)
        let err = await staging.stageHunk(file.hunks[0], of: file)
        XCTAssertNil(err)
        let staged = await load().first
        XCTAssertEqual(staged?.status, .deleted)
        XCTAssertEqual(staged?.stageState, .full)
    }

    func testCommitAndReportsNothingStaged() async throws {
        let empty = await staging.commit(message: "nothing")
        XCTAssertNotNil(empty)
        _ = try makeTwoHunks()
        let stageErr = await staging.stageAll()
        XCTAssertNil(stageErr)
        let err = await staging.commit(message: "fix: edit lines\n\nBody text.")
        XCTAssertNil(err)
        XCTAssertEqual(try repo.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines), "fix: edit lines")
        let files = await load()
        XCTAssertTrue(files.isEmpty)
    }

    func testRevertFileRestoresHead() async throws {
        _ = try makeTwoHunks()
        try repo.git(["add", "code.txt"])
        let loaded_file = await load()
        let file = try XCTUnwrap(loaded_file.first)
        let err = await staging.revertFile(file)
        XCTAssertNil(err)
        XCTAssertEqual(try String(contentsOf: repo.root.appendingPathComponent("code.txt"), encoding: .utf8), original)
        let files = await load()
        XCTAssertTrue(files.isEmpty)
    }

    func testIgnoreWhitespaceHidesWhitespaceOnlyChanges() async throws {
        try repo.write(original.replacingOccurrences(of: "line 5\n", with: "line 5   \n"), "code.txt")
        let hidden = await load(true)
        XCTAssertTrue(hidden.first?.unstaged?.hunks.isEmpty ?? true)
        let shown = await load(false)
        XCTAssertEqual(shown.first?.unstaged?.hunks.count, 1)
    }
}
