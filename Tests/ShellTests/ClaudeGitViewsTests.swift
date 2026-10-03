import AppKit
import SwiftUI
import XCTest
@testable import Shell

// MARK: - Helpers

/// Runs git hermetically (no global or system config, temp HOME) in `dir`.
@discardableResult
private func git(_ args: [String], in dir: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "user.name=Shell Tests", "-c", "user.email=tests@example.com", "-c", "commit.gpgsign=false",
                   "-c", "init.defaultBranch=main", "-c", "core.hooksPath=/dev/null"] + args
    p.currentDirectoryURL = dir
    p.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": dir.path, "PATH": "/usr/bin:/bin",
                     "GIT_TERMINAL_PROMPT": "0"]
    let out = Pipe()
    p.standardOutput = out
    let err = Pipe()
    p.standardError = err
    try p.run()
    p.waitUntilExit()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if p.terminationStatus != 0 {
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTFail("git \(args.joined(separator: " ")) failed: \(message)", file: file, line: line)
    }
    return text
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A temp repository with a local bare "origin": committed, modified,
/// staged, deleted, untracked and ignored files, plus an unpushed commit.
private struct TempRepo {
    let root: URL
    let origin: URL

    init(in base: URL) throws {
        root = base.appendingPathComponent("project", isDirectory: true)
        origin = base.appendingPathComponent("origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--bare", origin.path], in: base)
        try git(["init"], in: root)
        try write("# Project\n", to: root.appendingPathComponent("README.md"))
        try write("let a = 1\n", to: root.appendingPathComponent("Sources/App/a.swift"))
        try write("let b = 2\n", to: root.appendingPathComponent("Sources/App/b.swift"))
        try write("gone\n", to: root.appendingPathComponent("old.txt"))
        try write("build/\n*.log\n", to: root.appendingPathComponent(".gitignore"))
        try git(["add", "-A"], in: root)
        try git(["commit", "-m", "Initial commit"], in: root)
        try git(["remote", "add", "origin", origin.path], in: root)
        try git(["push", "-u", "origin", "main"], in: root)
        try git(["branch", "feature/older"], in: root)
        try git(["push", "origin", "feature/older"], in: root)
        try git(["branch", "-D", "feature/older"], in: root) // remote-only now
        try git(["remote", "set-head", "origin", "main"], in: root)
        try write("let c = 3\n", to: root.appendingPathComponent("Sources/App/c.swift"))
        try git(["add", "-A"], in: root)
        try git(["commit", "-m", "Unpushed work"], in: root)
        try git(["branch", "topic"], in: root)
        // Working tree changes.
        try write("let a = 10\n", to: root.appendingPathComponent("Sources/App/a.swift"))
        try write("let b = 20\n", to: root.appendingPathComponent("Sources/App/b.swift"))
        try git(["add", "Sources/App/b.swift"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("old.txt"))
        try write("new\n", to: root.appendingPathComponent("notes/todo.md"))
        try write("artifact\n", to: root.appendingPathComponent("build/out.bin"))
        try write("log\n", to: root.appendingPathComponent("debug.log"))
        try write("x", to: root.appendingPathComponent("my file.txt"))
    }
}

@MainActor
private func discover(_ dir: URL) async throws -> GitRepository {
    let repo = await GitRepository.discover(from: dir.path, environment: ["PATH": "/usr/bin:/bin"])
    return try XCTUnwrap(repo)
}

// MARK: - File tree model

@MainActor
final class FileTreeModelTests: XCTestCase {
    func testListsFoldersFirstAndSkipsGitMetadata() throws {
        let dir = try makeTemporaryDirectory()
        try write("x", to: dir.appendingPathComponent("b.txt"))
        try write("x", to: dir.appendingPathComponent("A.txt"))
        try write("x", to: dir.appendingPathComponent("zdir/inner.txt"))
        try write("x", to: dir.appendingPathComponent(".git/HEAD"))
        try write("x", to: dir.appendingPathComponent(".DS_Store"))
        let tree = FileTreeModel(root: dir, expanded: [])
        XCTAssertEqual(tree.listing("").map(\.name), ["zdir", "A.txt", "b.txt"])
        XCTAssertEqual(tree.listing("zdir").map(\.path), ["zdir/inner.txt"])
        XCTAssertEqual(tree.listing("missing"), [])
    }

    func testRowsFollowExpansionAndInvalidation() throws {
        let dir = try makeTemporaryDirectory()
        try write("x", to: dir.appendingPathComponent("src/main.swift"))
        try write("x", to: dir.appendingPathComponent("top.txt"))
        let tree = FileTreeModel(root: dir, expanded: [])
        var reported: [Set<String>] = []
        tree.onExpandedChange = { reported.append($0) }
        XCTAssertEqual(tree.rows.map(\.id), ["src", "top.txt"])

        tree.toggle("src")
        XCTAssertEqual(tree.rows.map(\.id), ["src", "src/main.swift", "top.txt"])
        XCTAssertEqual(tree.rows[1].depth, 1)
        XCTAssertEqual(reported.last, ["src"])

        // Cached until invalidated.
        try write("x", to: dir.appendingPathComponent("src/new.swift"))
        XCTAssertEqual(tree.rows.count, 3)
        let revision = tree.revision
        tree.invalidate()
        XCTAssertEqual(tree.revision, revision + 1)
        XCTAssertEqual(tree.rows.count, 4)

        tree.toggle("src")
        XCTAssertEqual(reported.last, [])
        XCTAssertEqual(tree.rows.map(\.id), ["src", "top.txt"])
    }
}

// MARK: - File explorer view

@MainActor
final class FileExplorerViewTests: XCTestCase {
    private func explorer(_ repo: GitRepository, isClaude: Bool, directory: String? = nil, expanded: Set<String> = []) -> FileExplorerView {
        var inserted: [String] = []
        let context = SidebarContext(directory: directory ?? repo.root.path, insert: { inserted.append($0) }, isClaude: isClaude)
        return FileExplorerView(context: context, repo: repo, tree: FileTreeModel(root: repo.root, expanded: expanded), onClose: {})
    }

    func testRendersTreeAndChangesForARepository() async throws {
        let repo = try await discover(TempRepo(in: makeTemporaryDirectory()).root)
        defer { repo.stop() }
        XCTAssertEqual(repo.status.branch, "main")
        XCTAssertEqual(repo.status.ahead, 1)
        XCTAssertGreaterThan(repo.status.changeCount, 3)
        XCTAssertTrue(repo.isIgnored("build/out.bin", isDirectory: false))

        let expanded: Set = ["Sources", "Sources/App", "build", "notes"]
        for changedOnly in [false, true] {
            withSettings({ $0.claudeExplorerChangedOnly = changedOnly }) {
                for isClaude in [true, false] {
                    let host = render(explorer(repo, isClaude: isClaude, expanded: expanded), size: CGSize(width: 320, height: 700))
                    XCTAssertGreaterThan(host.fittingSize.height, 0)
                }
            }
        }
    }

    func testCleanLinkedWorktreeShowsNoChanges() async throws {
        let base = try makeTemporaryDirectory()
        let main = try TempRepo(in: base)
        let wt = base.appendingPathComponent("wt-topic")
        try git(["worktree", "add", wt.path, "topic"], in: main.root)
        let repo = try await discover(wt)
        defer { repo.stop() }
        XCTAssertTrue(repo.isLinkedWorktree)
        XCTAssertEqual(repo.mainWorktree?.standardizedFileURL.resolvingSymlinksInPath().path,
                       main.root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(repo.status.changeCount, 0)
        withSettings({ $0.claudeExplorerChangedOnly = true }) {
            render(explorer(repo, isClaude: true), size: CGSize(width: 320, height: 500))
        }
        render(explorer(repo, isClaude: true), size: CGSize(width: 320, height: 500))
    }

    func testMentionAndInsertPaths() async throws {
        let repo = try await discover(TempRepo(in: makeTemporaryDirectory()).root)
        defer { repo.stop() }
        let atRoot = explorer(repo, isClaude: true)
        XCTAssertEqual(atRoot.mentionPath("Sources/App/a.swift"), "Sources/App/a.swift")
        XCTAssertEqual(atRoot.mentionPath("my file.txt"), "\"my file.txt\"")
        XCTAssertEqual(atRoot.url("README.md").lastPathComponent, "README.md")
        // Relative to the session's directory when it's inside the repository.
        let inSources = explorer(repo, isClaude: true, directory: repo.root.appendingPathComponent("Sources").path)
        XCTAssertEqual(inSources.mentionPath("Sources/App/a.swift"), "App/a.swift")
        // Outside it, the absolute path.
        let elsewhere = explorer(repo, isClaude: false, directory: "/tmp/elsewhere")
        XCTAssertEqual(elsewhere.mentionPath("README.md"), repo.root.appendingPathComponent("README.md").standardizedFileURL.path)
        XCTAssertEqual(elsewhere.shellQuoted("\"my file.txt\""), ShellQuote.quote("my file.txt"))
        XCTAssertEqual(elsewhere.shellQuoted("plain.txt"), ShellQuote.quote("plain.txt"))
    }

    func testContextMenusBuildForFilesAndFolders() async throws {
        let repo = try await discover(TempRepo(in: makeTemporaryDirectory()).root)
        defer { repo.stop() }
        for isClaude in [true, false] {
            let view = explorer(repo, isClaude: isClaude)
            render(VStack { view.menu(for: "README.md", isDirectory: false) }, size: CGSize(width: 300, height: 400))
            render(VStack { view.menu(for: "Sources", isDirectory: true) }, size: CGSize(width: 300, height: 400))
        }
        // Without an insert action there's no mention item.
        let bare = FileExplorerView(context: SidebarContext(directory: repo.root.path, isClaude: true), repo: repo,
                                    tree: FileTreeModel(root: repo.root, expanded: []), onClose: {})
        render(VStack { bare.menu(for: "README.md", isDirectory: false) }, size: CGSize(width: 300, height: 400))
    }

    func testFileRowStates() {
        let p = ClaudePalette.current
        let kinds: [GitFileStatus.Kind?] = [nil, .modified, .added, .untracked, .deleted, .conflicted, .renamed, .ignored]
        for kind in kinds {
            for isDirectory in [false, true] {
                render(FileRow(name: "file.swift", detail: isDirectory ? nil : "Sources/App", depth: 2, isDirectory: isDirectory, expanded: isDirectory,
                               status: kind, letter: kind == nil ? nil : "M", dirKind: isDirectory ? kind : nil, selected: kind == .added,
                               palette: p, staged: kind == .modified),
                       size: CGSize(width: 300, height: 22))
            }
            _ = FileRow.color(kind, p)
        }
        render(FileRow(name: "folder", detail: nil, depth: 0, isDirectory: true, expanded: false, status: nil, letter: nil, dirKind: .ignored,
                       selected: false, palette: p), size: CGSize(width: 300, height: 22))
    }

    func testFileIcons() {
        XCTAssertEqual(FileRow.icon(for: "main.SWIFT"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(FileRow.icon(for: "README.md"), "doc.text")
        XCTAssertEqual(FileRow.icon(for: "config.yaml"), "curlybraces")
        XCTAssertEqual(FileRow.icon(for: "shot.png"), "photo")
        XCTAssertEqual(FileRow.icon(for: "Cargo.lock"), "lock")
        XCTAssertEqual(FileRow.icon(for: "Makefile"), "doc")
    }

    func testOpenInMenuWithAndWithoutGitHub() {
        let p = ClaudePalette.current
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        render(OpenInMenu(urls: [url], palette: p), size: CGSize(width: 120, height: 30))
        render(OpenInMenu(urls: [url], palette: p, github: GitHubRemote(host: "github.com", owner: "o", name: "r")), size: CGSize(width: 120, height: 30))
    }

    func testResizedImage() {
        let image = NSImage(size: NSSize(width: 64, height: 32))
        XCTAssertEqual(image.resized(to: 16).size, NSSize(width: 16, height: 16))
    }
}

// MARK: - Branch picker

final class BranchOptionTests: XCTestCase {
    func testParsesLocalAndRemoteOnlyBranchesNewestFirst() {
        let refs = """
        refs/heads/main\t300\tLatest on main
        refs/heads/feature\t100\tFeature work
        refs/remotes/origin/HEAD\t300\t
        refs/remotes/origin/main\t300\tLatest on main
        refs/remotes/origin/remote-only\t200\tSomeone else's branch
        refs/remotes/upstream/remote-only\t150\tDuplicate on another remote
        refs/remotes/noslash\t1\tmalformed
        refs/tags/v1\t50\tnot a branch
        bad line
        refs/heads/undated\tnot-a-number
        """
        let worktrees = [WorktreeInfo(path: "/wt/feature", branch: "feature"), WorktreeInfo(path: "/wt/detached")]
        let options = BranchOption.parse(refs: refs, worktrees: worktrees, defaultBranch: "main")
        XCTAssertEqual(options.map(\.id), ["main", "origin/remote-only", "feature", "undated"])
        XCTAssertTrue(options[0].isDefault)
        XCTAssertEqual(options[1].remote, "origin")
        XCTAssertEqual(options[1].subject, "Someone else's branch")
        XCTAssertEqual(options[2].worktreePath, "/wt/feature")
        XCTAssertNil(options[3].date)
        XCTAssertEqual(options[3].subject, "")
    }

    func testChoiceIDs() {
        let b = BranchOption(name: "x", remote: "origin", date: nil, subject: "")
        XCTAssertEqual(BranchChoice.create("new").id, "+create:new")
        XCTAssertEqual(BranchChoice.existing(b).id, "origin/x")
    }
}

@MainActor
final class BranchPickerTests: XCTestCase {
    func testLoadsBranchesAndFilters() async throws {
        let base = try makeTemporaryDirectory()
        let repo = try TempRepo(in: base)
        let worktrees = base.appendingPathComponent("worktrees")
        let original = SettingsStore.shared.settings
        defer { SettingsStore.shared.settings = original }
        SettingsStore.shared.settings.worktreeRoot = worktrees.path
        do {
            let model = BranchPickerModel(directory: repo.root.path)
            XCTAssertTrue(model.isLoading)
            XCTAssertEqual(model.worktreeRoot, worktrees.path)

            await model.load()
            XCTAssertFalse(model.isLoading)
            XCTAssertFalse(model.isFetching)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.info?.baseBranch, "main")
            XCTAssertEqual(model.info?.baseRemote, "origin")
            let ids = model.rows.map(\.id)
            XCTAssertTrue(ids.contains("main"))
            XCTAssertTrue(ids.contains("topic"))
            XCTAssertTrue(ids.contains("origin/feature/older"))
            XCTAssertNotNil(model.current)

            // The checked-out branch opens its existing worktree.
            let main = try XCTUnwrap(model.rows.first { $0.id == "main" })
            XCTAssertEqual(model.destination(for: main)?.exists, true)
            // Others get a new worktree under the root.
            let topic = try XCTUnwrap(model.rows.first { $0.id == "topic" })
            let dest = try XCTUnwrap(model.destination(for: topic))
            XCTAssertFalse(dest.exists)
            XCTAssertTrue(dest.path.hasPrefix(worktrees.path))

            // A new name offers to create the branch first.
            model.query = "fix/login-redirect"
            XCTAssertEqual(model.newBranchName, "fix/login-redirect")
            XCTAssertEqual(model.rows.first, .create("fix/login-redirect"))
            XCTAssertEqual(model.selected, 0)
            XCTAssertFalse(model.invalidName)
            XCTAssertFalse(model.isSuggested("fix/login-redirect"))
            XCTAssertEqual(model.destination(for: .create("fix/login-redirect"))?.exists, false)

            // An existing name matches instead of creating.
            model.query = "topic"
            XCTAssertNil(model.newBranchName)
            XCTAssertEqual(model.rows.first?.id, "topic")

            // Fuzzy search.
            model.query = "oldr"
            XCTAssertTrue(model.rows.contains { $0.id == "origin/feature/older" })

            // Invalid names.
            model.query = "bad name..lock~"
            XCTAssertTrue(model.invalidName)
            model.query = "@@@ no match ~~~"

            model.query = ""
            XCTAssertFalse(model.invalidName)
            XCTAssertEqual(model.rows.count, ids.count)
        }
    }

    /// Each render starts the view's own load, so every state gets a fresh
    /// model that isn't asserted on afterwards.
    func testRendersEachPickerState() async throws {
        let base = try makeTemporaryDirectory()
        let repo = try TempRepo(in: base)
        let original = SettingsStore.shared.settings
        defer { SettingsStore.shared.settings = original }
        SettingsStore.shared.settings.worktreeRoot = base.appendingPathComponent("worktrees").path

        let loading = BranchPickerModel(directory: repo.root.path)
        let host = render(BranchPickerView(model: loading, agent: .claude, onCancel: {}, onPick: { _ in }))
        XCTAssertGreaterThan(host.fittingSize.height, 0)

        for query in ["", "fix/login-redirect", "topic", "oldr", "@@@ no match ~~~", "zzzzzz"] {
            let model = BranchPickerModel(directory: repo.root.path)
            await model.load()
            model.query = query
            if query == "oldr" { model.selected = 0 }
            render(BranchPickerView(model: model, agent: .claude, onCancel: {}, onPick: { _ in }))
        }
    }

    func testOutsideARepositoryShowsTheError() async throws {
        let dir = try makeTemporaryDirectory()
        let model = BranchPickerModel(directory: dir.path)
        await model.load()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.destination(for: .create("x")))
        XCTAssertNil(model.current)
        render(BranchPickerView(model: model, agent: .claude, onCancel: {}, onPick: { _ in }))
    }

    func testEmptyRepositoryHasNoBranches() async throws {
        let dir = try makeTemporaryDirectory()
        try git(["init"], in: dir)
        let model = BranchPickerModel(directory: dir.path)
        await model.load()
        XCTAssertTrue(model.rows.isEmpty)
        render(BranchPickerView(model: model, agent: .claude, onCancel: {}, onPick: { _ in }))
    }
}

// MARK: - Dashboard repositories

@MainActor
final class DashboardReposTests: XCTestCase {
    func testDiscoversTheRepositoryOfATerminalSession() async throws {
        let repo = try TempRepo(in: makeTemporaryDirectory())
        let session = TerminalSession(workingDirectory: repo.root.appendingPathComponent("Sources").path)
        defer {
            DashboardRepos.shared.releaseAll()
            session.close()
        }
        XCTAssertNil(DashboardRepos.shared.repository(for: session))
        await DashboardRepos.shared.refresh(session)
        let found = try XCTUnwrap(DashboardRepos.shared.repository(for: session))
        XCTAssertEqual(found.root.resolvingSymlinksInPath().path, repo.root.resolvingSymlinksInPath().path)
        XCTAssertEqual(ClaudeDashboard.branch(for: session), "main")
        // Same directory: nothing to do.
        await DashboardRepos.shared.refresh(session)
        XCTAssertTrue(DashboardRepos.shared.repository(for: session) === found)

        DashboardRepos.shared.releaseAll()
        XCTAssertNil(DashboardRepos.shared.repository(for: session))
    }

    func testSessionTileShowsTheBranch() async throws {
        let repo = try TempRepo(in: makeTemporaryDirectory())
        let controller = AppDelegate.shared.newWindowController()
        defer {
            controller.close()
            DashboardRepos.shared.releaseAll()
        }
        let tab = controller.newTab(directory: repo.root.path)
        let session = try XCTUnwrap(tab.focusedSession)
        session.commandStarted("claude", directory: nil)
        await DashboardRepos.shared.refresh(session)
        // Another refresh may already be discovering, and status loads after
        // discovery, so wait for the branch rather than reading it once.
        let deadline = Date().addingTimeInterval(5)
        while ClaudeDashboard.branch(for: session) != "main", Date() < deadline {
            await DashboardRepos.shared.refresh(session)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ClaudeDashboard.branch(for: session), "main")
        let entry = ClaudeDashboard.Entry(session: session, tab: tab, controller: controller, location: "Tab 1")
        let host = render(ClaudeSessionTile(entry: entry, palette: ChromePalette.current) {}, size: CGSize(width: 420, height: 300))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
