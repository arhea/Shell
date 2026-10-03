import AppKit
import XCTest
@testable import Shell

// MARK: - Parsing

final class GitStatusParsingTests: XCTestCase {
    func testFileStatusKindsAndLetters() {
        let cases: [(Character, Character, GitFileStatus.Kind, String, Bool)] = [
            ("!", "!", .ignored, "!", false),
            ("?", "?", .untracked, "U", false),
            ("U", "U", .conflicted, "C", true),
            (" ", "U", .conflicted, "C", false),
            ("A", "A", .conflicted, "C", true),
            ("D", "D", .conflicted, "C", true),
            ("D", " ", .deleted, "D", true),
            (" ", "D", .deleted, "D", false),
            ("A", " ", .added, "A", true),
            ("R", " ", .renamed, "R", true),
            ("C", "M", .renamed, "R", true),
            ("M", " ", .modified, "M", true),
            (" ", "M", .modified, "M", false),
        ]
        for (i, w, kind, letter, staged) in cases {
            let s = GitFileStatus(index: i, worktree: w)
            XCTAssertEqual(s.kind, kind, "\(i)\(w)")
            XCTAssertEqual(s.letter, letter, "\(i)\(w)")
            XCTAssertEqual(s.isStaged, staged, "\(i)\(w)")
        }
        XCTAssertLessThan(GitFileStatus.Kind.ignored, .conflicted)
    }

    func testParsesBranchHeaderVariants() {
        let ahead = GitStatusSnapshot.parse("## main...origin/main [ahead 2, behind 3]\0 M a.txt\0R  new.txt\0old.txt\0?? x\0!! build/\0")
        XCTAssertEqual(ahead.branch, "main")
        XCTAssertEqual(ahead.upstream, "origin/main")
        XCTAssertEqual(ahead.ahead, 2)
        XCTAssertEqual(ahead.behind, 3)
        XCTAssertEqual(ahead.files.count, 4, "the rename's old path isn't an entry")
        XCTAssertEqual(ahead.changeCount, 3)
        XCTAssertEqual(ahead.changes.map(\.path), ["a.txt", "new.txt", "x"])

        let gone = GitStatusSnapshot.parse("## topic...origin/topic [gone]\0")
        XCTAssertEqual(gone.ahead, 0)
        XCTAssertEqual(gone.upstream, "origin/topic")

        let fresh = GitStatusSnapshot.parse("## No commits yet on trunk\0")
        XCTAssertEqual(fresh.branch, "trunk")
        XCTAssertNil(fresh.upstream)

        let detached = GitStatusSnapshot.parse("## HEAD (no branch)\0ab\0")
        XCTAssertTrue(detached.detached)
        XCTAssertNil(detached.branch)
        XCTAssertTrue(detached.files.isEmpty, "entries too short to be a status are skipped")
    }

    func testGitHubRemoteParsing() {
        let https = GitHubRemote.parse("https://github.com/acme/widgets.git\n")
        XCTAssertEqual(https, GitHubRemote(host: "github.com", owner: "acme", name: "widgets"))
        XCTAssertEqual(https?.slug, "acme/widgets")
        XCTAssertEqual(https?.url.absoluteString, "https://github.com/acme/widgets")
        XCTAssertEqual(https?.branchURL("feature/x").absoluteString, "https://github.com/acme/widgets/tree/feature/x")
        XCTAssertEqual(https?.compareURL("topic").absoluteString, "https://github.com/acme/widgets/compare/topic?expand=1")

        XCTAssertEqual(GitHubRemote.parse("git@github.com:acme/widgets.git")?.slug, "acme/widgets")
        XCTAssertEqual(GitHubRemote.parse("ssh://git@ssh.github.com:443/acme/widgets.git")?.host, "github.com")
        XCTAssertEqual(GitHubRemote.parse("https://GitHub.example.com/team/app")?.host, "github.example.com")
        XCTAssertEqual(GitHubRemote.parse("git@corp.github.com:a/b")?.host, "corp.github.com")
        XCTAssertNil(GitHubRemote.parse("https://gitlab.com/acme/widgets.git"))
        XCTAssertNil(GitHubRemote.parse("/local/path/repo.git"))
        XCTAssertNil(GitHubRemote.parse("https://github.com/acme"))
        XCTAssertNil(GitHubRemote.parse("https://github.com/acme/widgets/extra"))
    }
}

// MARK: - GitRepository

final class GitRepositoryCoverageTests: GitAreaTestCase {
    func testFindsTheGitHubRemoteDefaultBranchAndPullRequest() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        try repo.fakeGitHubOrigin()
        try repo.git(["checkout", "-q", "-b", "topic"])
        try repo.track("topic", at: try repo.head())
        let gh = try FakeGH(in: dir)
        try gh.on("pr view topic *", json: ["number": 42, "title": "Topic work", "url": "https://github.com/acme/widgets/pull/42",
                                            "state": "OPEN", "isDraft": true])
        try gh.on("pr view other *", json: ["number": 43, "title": "Other", "url": "https://github.com/acme/widgets/pull/43", "state": "MERGED"])

        let found = await GitRepository.discover(from: repo.root.path, environment: gh.environment(home: dir))
        let r = try XCTUnwrap(found)
        defer { r.stop() }
        XCTAssertEqual(r.name, "repo")
        XCTAssertEqual(r.github?.slug, "acme/widgets")
        XCTAssertEqual(r.defaultBranch, "main")
        XCTAssertEqual(r.branchLabel, "topic")
        XCTAssertTrue(r.isBranchPublished)
        XCTAssertFalse(r.isLinkedWorktree)
        XCTAssertNil(r.mainWorktree)
        XCTAssertNotNil(r.lastRefresh)
        try await eventually("PR lookup") { r.pullRequest != nil }
        XCTAssertEqual(r.pullRequest?.number, 42)
        XCTAssertEqual(r.pullRequest?.isDraft, true)

        // Not due again so soon, even when forced.
        r.refreshPullRequest(force: true)
        XCTAssertEqual(gh.calls(matching: "pr view").count, 1)

        // Switching branches looks the new one up.
        try repo.git(["checkout", "-q", "-b", "other"])
        r.refresh()
        try await eventually("branch switch") { r.status.branch == "other" }
        try await eventually("new PR") { r.pullRequest?.number == 43 }
        XCTAssertEqual(r.pullRequest?.state, .merged)
        XCTAssertFalse(r.isBranchPublished)

        // Detached: no PR.
        try repo.git(["checkout", "-q", "--detach"])
        r.refresh()
        try await eventually("detached") { r.status.detached }
        try await eventually("head") { r.headCommit != nil }
        XCTAssertNil(r.pullRequest)
        XCTAssertTrue(r.branchLabel.hasPrefix("detached @ "))
    }

    func testLinkedWorktreeKnowsItsMainCheckout() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        let wt = try repo.addWorktree("linked", branch: "linked")
        let found = await GitRepository.discover(from: wt.path, environment: ["PATH": "/usr/bin:/bin"])
        let r = try XCTUnwrap(found)
        defer { r.stop() }
        XCTAssertTrue(r.isLinkedWorktree)
        XCTAssertEqual(r.mainWorktree?.standardizedFileURL.path, repo.root.standardizedFileURL.path)
        XCTAssertNil(r.github, "no origin")
        XCTAssertNil(r.pullRequest)
    }

    func testDiscoverOutsideARepositoryIsNil() async throws {
        let dir = try gitTempDirectory()
        let found = await GitRepository.discover(from: dir.path, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertNil(found)
    }

    func testStatusLookupsDirectoriesAndIgnoredPaths() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        try repo.write("build/\n", ".gitignore")
        try repo.write("let a = 1\n", "Sources/App/a.swift")
        try repo.git(["add", "-A"])
        try repo.git(["commit", "-q", "-m", "more"])
        try repo.write("let a = 2\n", "Sources/App/a.swift")
        try repo.write("new\n", "Sources/App/Deep/n.swift")
        try repo.write("bin\n", "build/out/x.bin")
        try repo.write("conflict?\n", "README.md")
        try repo.git(["add", "README.md"])
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(".gitignore"))

        let found = await GitRepository.discover(from: repo.root.path, environment: ["PATH": "/usr/bin:/bin"])
        let r = try XCTUnwrap(found)
        defer { r.stop() }
        XCTAssertEqual(r.status(for: "Sources/App/a.swift")?.kind, .modified)
        XCTAssertEqual(r.directoryStatus(for: "Sources"), .modified, "the most significant change beneath wins")
        XCTAssertEqual(r.directoryStatus(for: "Sources/App/Deep"), .untracked)
        XCTAssertEqual(r.directoryStatus(for: ""), .deleted)
        XCTAssertNil(r.directoryStatus(for: "Nothing"))
        // .gitignore is deleted from the work tree, so build/ isn't ignored any more.
        XCTAssertFalse(r.isIgnored("build/out/x.bin", isDirectory: false))

        try repo.git(["checkout", "--", ".gitignore"])
        r.refresh()
        r.refresh() // coalesced into the running one
        try await eventually("ignored") { r.isIgnored("build", isDirectory: true) }
        XCTAssertTrue(r.isIgnored("build/out/x.bin", isDirectory: false))
        XCTAssertEqual(r.directoryStatus(for: "build"), .ignored)
        XCTAssertFalse(r.isIgnored("Sources/App/a.swift", isDirectory: false))
    }

    func testWatcherRefreshesOnFileChanges() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        let found = await GitRepository.discover(from: repo.root.path, environment: ["PATH": "/usr/bin:/bin"])
        let r = try XCTUnwrap(found)
        defer { r.stop() }
        XCTAssertEqual(r.status.changeCount, 0)
        // FSEvents only reports writes made after its stream is running, so
        // rewrite the file every quarter second until one is seen.
        var polls = 0
        try await eventually(timeout: 10, "FSEvents refresh") {
            if polls % 25 == 0 { try? repo.write("hello \(polls)\n", "watched.txt") }
            polls += 1
            return r.status.changeCount == 1
        }
    }

    func testLookUpPullRequestHandlesMissingGhAndBadOutput() async throws {
        let dir = try gitTempDirectory()
        let none = await GitRepository.lookUpPullRequest(branch: "x", in: dir.path, environment: ["PATH": "/nonexistent"])
        XCTAssertNil(none)
        let gh = try FakeGH(in: dir)
        try gh.on("pr view bad *", stdout: "{}")
        try gh.on("pr view weird *", json: ["number": 1, "url": "https://github.com/a/b/pull/1", "state": "NOPE"])
        let bad = await GitRepository.lookUpPullRequest(branch: "bad", in: dir.path, environment: gh.environment(home: dir))
        XCTAssertNil(bad)
        let weird = await GitRepository.lookUpPullRequest(branch: "weird", in: dir.path, environment: gh.environment(home: dir))
        XCTAssertEqual(weird?.state, .open)
        XCTAssertEqual(weird?.title, "")
        XCTAssertEqual(weird?.isDraft, false)
        let failed = await GitRepository.lookUpPullRequest(branch: "unknown", in: dir.path, environment: gh.environment(home: dir))
        XCTAssertNil(failed)
    }

    func testFindExecutableSearchesPathThenFallbacks() throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        XCTAssertEqual(GitRepository.findExecutable("gh", environment: ["PATH": gh.dir.path]), gh.path)
        XCTAssertNil(GitRepository.findExecutable("gh", environment: [:]), "the test fallbacks don't include Homebrew")
        XCTAssertEqual(GitRepository.findExecutable("git", environment: [:]), "/usr/bin/git")
        GitRepository.fallbackSearchDirectories = []
        XCTAssertEqual(GitRepository.findGit(environment: [:]), "/usr/bin/git", "git falls back to /usr/bin/git")
    }
}

// MARK: - External editors

@MainActor
final class ExternalEditorTests: XCTestCase {
    func testDetectionAndPreference() {
        let detected = ExternalEditor.detect()
        XCTAssertEqual(Set(detected.map(\.name)).count, detected.count, "one entry per editor name")
        let saved = ExternalEditor.installed
        defer { ExternalEditor.installed = saved }
        let a = ExternalEditor(bundleID: "test.a", name: "A", appURL: URL(fileURLWithPath: "/Applications"))
        let b = ExternalEditor(bundleID: "test.b", name: "B", appURL: URL(fileURLWithPath: "/Applications"))
        ExternalEditor.installed = [a, b]
        withSettings({ $0.claudePreferredEditor = "test.b" }) {
            XCTAssertEqual(ExternalEditor.preferred, b)
        }
        withSettings({ $0.claudePreferredEditor = "missing" }) {
            XCTAssertEqual(ExternalEditor.preferred, a)
        }
        ExternalEditor.installed = []
        XCTAssertNil(ExternalEditor.preferred)
        XCTAssertEqual(a.id, "test.a")
        XCTAssertGreaterThan(a.icon.size.width, 0)
    }
}
