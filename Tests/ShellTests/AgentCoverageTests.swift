import XCTest
@testable import Shell

// MARK: - Storage

@MainActor
final class AgentStorageModelTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = try makeTemporaryDirectory()
    }

    /// Like `waitUntil`, for async tests: a nested run loop can't run main-actor
    /// work while an async test is itself running on the main actor.
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// A file of `bytes` bytes, last modified `age` seconds ago.
    @discardableResult
    private func file(_ path: String, bytes: Int = 4096, age: TimeInterval = 0) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func category(_ id: String, agent: StorageCategory.Agent = .claude, kind: StorageCategory.Kind,
                          folder: String, requiresClosed: String? = nil) -> StorageCategory {
        let dir = root.appendingPathComponent(folder)
        return StorageCategory(id: id, agent: agent, kind: kind, title: "Things \(id)", detail: "", roots: [dir],
                               requiresClosed: requiresClosed, items: { AgentStorage.children(dir) })
    }

    func testMeasuresTotalsAndCleansOnlyOldItems() async throws {
        let day: TimeInterval = 86400
        try file("cache/old.log", age: 3 * day)
        try file("cache/new.log", age: 60)
        try file("history/ancient.jsonl", age: 90 * day)
        try file("history/recent.jsonl", age: 2 * day)
        try file("codex/old.tmp", age: 3 * day)
        let cache = category("cache", kind: .cache, folder: "cache")
        let history = category("history", kind: .history, folder: "history")
        let codex = category("codex", agent: .codex, kind: .cache, folder: "codex")
        let model = AgentStorageModel(categories: [cache, history, codex])
        XCTAssertTrue(model.removable(cache).isEmpty, "nothing is removable before measuring")

        model.measure()
        XCTAssertTrue(model.isMeasuring)
        model.measure() // already measuring
        let measured = await eventually { !model.isMeasuring }
        XCTAssertTrue(measured)
        XCTAssertEqual(model.measured.count, 3)
        XCTAssertEqual(model.measured["cache"]?.items.count, 2)
        XCTAssertGreaterThan(model.total, 0)
        XCTAssertEqual(model.total(for: .claude) + model.total(for: .codex), model.total)
        XCTAssertEqual(model.removable(cache).map(\.url.lastPathComponent), ["old.log"], "caches keep the last day")

        let saved = SettingsStore.shared.settings
        defer { SettingsStore.shared.settings = saved }
        SettingsStore.shared.settings.agentHistoryDays = 30
        XCTAssertEqual(model.removable(history).map(\.url.lastPathComponent), ["ancient.jsonl"])
        SettingsStore.shared.settings.agentHistoryDays = 0
        XCTAssertEqual(model.historyDays, 1, "at least a day of history is kept")
        XCTAssertEqual(model.removable(history).count, 2)
        SettingsStore.shared.settings.agentHistoryDays = 30

        let message = await model.clean(cache)
        XCTAssertTrue(message.hasPrefix("Claude Code things cache: freed "), message)
        XCTAssertFalse(message.contains("couldn't be removed"))
        XCTAssertEqual(model.lastResult, message)
        XCTAssertTrue(model.busy.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache/old.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache/new.log").path))
        XCTAssertEqual(model.measured["cache"]?.items.map(\.url.lastPathComponent), ["new.log"], "remeasured after cleaning")
    }

    func testCleaningReportsItemsThatCouldntBeRemoved() async throws {
        try file("cache/old.log", age: 3 * 86400)
        let cache = category("cache", kind: .cache, folder: "cache")
        let model = AgentStorageModel(categories: [cache])
        model.measure()
        let measured = await eventually { !model.isMeasuring }
        XCTAssertTrue(measured)
        try FileManager.default.removeItem(at: root.appendingPathComponent("cache/old.log")) // gone before cleaning
        let message = await model.clean(cache)
        XCTAssertTrue(message.hasSuffix("(1 couldn't be removed)"), message)
    }

    func testAppsThatMustBeClosedBlockCleaning() async throws {
        try file("cache/old.log", age: 3 * 86400)
        // The test host is Shell itself, so "shell" is always running.
        let blocked = category("blocked", agent: .codex, kind: .cache, folder: "cache", requiresClosed: "shell")
        let model = AgentStorageModel(categories: [blocked])
        let message = await model.clean(blocked)
        XCTAssertEqual(message, "Quit Codex first — things blocked are in use while it runs.")
        XCTAssertEqual(model.lastResult, message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache/old.log").path))
        XCTAssertTrue(AgentStorage.isRunning("shell"))
        XCTAssertFalse(AgentStorage.isRunning("shell-tests-no-such-process"))
        XCTAssertFalse(ProcessRunnerLite.pgrep("shell-tests-no-such-process"))
    }

    func testMeasureAndRemove() throws {
        let folder = root.appendingPathComponent("tree")
        try file("tree/a", bytes: 10_000, age: 5000)
        try file("tree/sub/b", bytes: 10_000, age: 10)
        let measured = AgentStorage.measure(folder)
        XCTAssertGreaterThanOrEqual(measured.bytes, 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(measured.lastModified), 1000, "a folder is as new as its newest file")
        let single = AgentStorage.measure(root.appendingPathComponent("tree/a"))
        XCTAssertGreaterThanOrEqual(single.bytes, 10_000)

        let missing = AgentStorage.Item(url: root.appendingPathComponent("nope"), bytes: 5, lastModified: .distantPast)
        let result = AgentStorage.remove([measured, missing])
        XCTAssertEqual(result.freed, measured.bytes)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].hasPrefix("nope: "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testClaudeCleanupDaysFromSettings() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let settings = root.appendingPathComponent(".claude/settings.json")
        try Data(#"{"cleanupPeriodDays": 14}"#.utf8).write(to: settings)
        XCTAssertEqual(AgentStorage.claudeCleanupDays(home: root), 14)
        try Data(#"{"cleanupPeriodDays": 0}"#.utf8).write(to: settings)
        XCTAssertEqual(AgentStorage.claudeCleanupDays(home: root), 30)
        XCTAssertEqual(AgentStorage.home, FileManager.default.homeDirectoryForCurrentUser)
    }

    func testCleanupJobDescribesItselfAndItsResults() {
        let job = AgentStorageCleanupJob(categories: { [] }, model: { AgentStorageModel(categories: []) })
        XCTAssertEqual(job.id, "agentStorage")
        XCTAssertEqual(job.title, "Claude & Codex storage")
        XCTAssertFalse(job.summary.isEmpty)
        XCTAssertTrue(job.isAvailable)
        XCTAssertEqual(job.schedule, SettingsStore.shared.settings.agentStorageSchedule)

        func record(_ outcome: MaintenanceRecord.Outcome, changes: [String], summary: String?) -> MaintenanceRecord {
            MaintenanceRecord(startedAt: Date(), finishedAt: Date(), outcome: outcome, changes: changes, warnings: [], logPath: "/tmp/x.log",
                              summary: summary)
        }
        let note = job.notification(for: record(.success, changes: ["Claude Code session transcripts", "Codex logs"], summary: "freed 2 GB"))
        XCTAssertEqual(note?.title, "Cleaned up Claude & Codex storage")
        XCTAssertEqual(note?.body, "Freed 2 GB · Claude Code session transcripts, Codex logs")
        XCTAssertEqual(job.notification(for: record(.success, changes: ["x"], summary: nil))?.body, " · x")
        XCTAssertNil(job.notification(for: record(.success, changes: [], summary: "freed 0 bytes")))
        XCTAssertNil(job.notification(for: record(.failed, changes: ["x"], summary: nil)))
    }

    func testCleanupJobDidFinishIsANoOp() async {
        await AgentStorageCleanupJob(categories: { [] }).didFinish()
    }
}

// MARK: - Launcher

@MainActor
final class AgentLauncherRepositoryTests: XCTestCase {
    private let env = ["PATH": "/usr/bin:/bin"]

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                       "-c", "init.defaultBranch=main"] + args
        p.currentDirectoryURL = dir
        p.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin", "HOME": dir.path]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    /// A repository with one commit on `branch`.
    private func repo(_ name: String, branch: String = "main") throws -> URL {
        let dir = try makeTemporaryDirectory().appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", branch], in: dir)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: dir)
        return dir
    }

    func testDefaultBranchFromOriginHEAD() async throws {
        let dir = try repo("app")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: dir)
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: dir)
        let (info, worktrees) = try await AgentLauncher.inspect(directory: dir.path, environment: env)
        XCTAssertEqual(info.repoName, "app")
        XCTAssertEqual(info.baseRemote, "origin")
        XCTAssertEqual(info.baseBranch, "main")
        XCTAssertTrue(info.toplevel.hasSuffix("/app"))
        XCTAssertEqual(worktrees.count, 1)
    }

    func testDefaultBranchFromConventionalNames() async throws {
        let remote = try repo("remote-master", branch: "work")
        try git(["update-ref", "refs/remotes/origin/master", "HEAD"], in: remote)
        let (r, _) = try await AgentLauncher.inspect(directory: remote.path, environment: env)
        XCTAssertEqual(r.baseRemote, "origin")
        XCTAssertEqual(r.baseBranch, "master")

        let local = try repo("local-develop", branch: "develop")
        let (l, _) = try await AgentLauncher.inspect(directory: local.path, environment: env)
        XCTAssertNil(l.baseRemote)
        XCTAssertEqual(l.baseBranch, "develop")

        let other = try repo("trunk-only", branch: "trunk")
        let (t, _) = try await AgentLauncher.inspect(directory: other.path, environment: env)
        XCTAssertNil(t.baseRemote)
        XCTAssertEqual(t.baseBranch, "trunk", "falls back to the current branch")
    }

    func testInspectFailsOutsideARepositoryOrWithoutABranch() async throws {
        let plain = try makeTemporaryDirectory()
        do {
            _ = try await AgentLauncher.inspect(directory: plain.path, environment: env)
            XCTFail("expected notARepository")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Worktrees need a git repository")
        }

        let detached = try repo("detached", branch: "trunk")
        let head = try git(["rev-parse", "HEAD"], in: detached).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["checkout", "-q", head], in: detached)
        do {
            _ = try await AgentLauncher.inspect(directory: detached.path, environment: env)
            XCTFail("expected a missing default branch")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Couldn't find the default branch")
        }
    }

    func testWorktreePlansForNewExistingAndCheckedOutBranches() async throws {
        let saved = SettingsStore.shared.settings
        defer { SettingsStore.shared.settings = saved }
        SettingsStore.shared.settings.claudePermissionMode = ""
        let dir = try repo("svc")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: dir)
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: dir)
        try git(["branch", "existing"], in: dir)
        let root = try makeTemporaryDirectory().path
        let checkedOut = try makeTemporaryDirectory().appendingPathComponent("busy").path
        try git(["worktree", "add", "-q", "-b", "busy", checkedOut], in: dir)

        let random = try await AgentLauncher.worktreePlan(directory: dir.path, branch: nil, name: nil, trackRemote: nil,
                                                          agent: .claude, worktreeRoot: root, environment: env)
        XCTAssertTrue(random.command.hasPrefix("git fetch origin main; git worktree add --no-track -b \(random.name) "), random.command)
        XCTAssertTrue(random.command.hasSuffix("&& claude -n \(random.name)"), random.command)
        XCTAssertTrue(random.directory.hasSuffix("/svc"))
        XCTAssertNotNil(random.name.wholeMatch(of: /[a-z]+-[a-z]+/))

        let existing = try await AgentLauncher.worktreePlan(directory: dir.path, branch: "existing", name: "existing", trackRemote: nil,
                                                            agent: .claude, worktreeRoot: root, environment: env)
        XCTAssertTrue(existing.command.hasPrefix("git worktree add \(ShellQuote.path(root + "/svc/existing")) existing && cd "), existing.command)

        let busy = try await AgentLauncher.worktreePlan(directory: dir.path, branch: "busy", name: "busy", trackRemote: nil,
                                                        agent: .claude, worktreeRoot: root, environment: env)
        XCTAssertEqual(busy.command, "claude -n busy")
        XCTAssertTrue(busy.directory.hasSuffix("/busy"), "an existing worktree is reused")

        let tracked = try await AgentLauncher.worktreePlan(directory: dir.path, branch: "feature/remote", name: "feature/remote",
                                                           trackRemote: "upstream", agent: .claude, worktreeRoot: root, environment: env)
        XCTAssertTrue(tracked.command.contains("git worktree add --track -b feature/remote "), tracked.command)
        XCTAssertTrue(tracked.command.contains(" upstream/feature/remote && cd "), tracked.command)

        // From inside the linked worktree, the repository is still named after the main checkout.
        let (info, worktrees) = try await AgentLauncher.inspect(directory: checkedOut, environment: env)
        XCTAssertEqual(info.repoName, "svc")
        XCTAssertEqual(worktrees.count, 2)
    }

    func testAgentNamesAndErrors() {
        XCTAssertEqual(CodingAgent.claude.id, "claude")
        XCTAssertEqual(CodingAgent.claude.displayName, "Claude Code")
        XCTAssertEqual(CodingAgent.claude.shortName, "Claude")
        XCTAssertEqual(CodingAgent.claude.command(name: "x", permissionMode: ""), "claude -n x")
        XCTAssertEqual(AgentLauncher.LaunchError.invalidBranch("a b").localizedDescription, "\"a b\" isn't a valid branch name")
        XCTAssertEqual(AgentLauncher.LaunchError.git("boom").localizedDescription, "boom")
    }

    func testStartingHereRunsTheAgentInThePane() throws {
        let terminal = TerminalSession(workingDirectory: try makeTemporaryDirectory().path)
        defer { terminal.close() }
        var opened: [AgentLauncher.Plan] = []
        withSettings({ $0.claudePermissionMode = "plan" }) {
            AgentLauncher.start(.here, from: terminal, report: { _, _ in XCTFail("nothing to report") }, open: { opened.append($0) })
        }
        XCTAssertTrue(opened.isEmpty, "no new tab")
        if terminal.state == .starting {
            XCTAssertEqual(terminal.pendingCommand?.hasPrefix("claude -n "), true, "queued until the prompt is ready")
            XCTAssertEqual(terminal.pendingCommand?.hasSuffix(" --permission-mode plan"), true)
        }
    }

    func testStartingInANewWorktreeOpensATabWithThePlan() throws {
        let dir = try repo("web")
        let root = try makeTemporaryDirectory().path
        let terminal = TerminalSession(workingDirectory: dir.path)
        defer { terminal.close() }
        var reports: [(String, Bool)] = []
        var opened: [AgentLauncher.Plan] = []
        withSettings({ $0.worktreeRoot = root; $0.claudePermissionMode = "" }) {
            AgentLauncher.start(.newBranch("bad..name"), from: terminal, report: { reports.append(($0, $1)) }, open: { opened.append($0) })
            XCTAssertEqual(reports.map(\.0), ["\"bad..name\" isn't a valid branch name"])
            XCTAssertEqual(reports.last?.1, false)

            AgentLauncher.start(.newBranch("fix login"), from: terminal, report: { reports.append(($0, $1)) }, open: { opened.append($0) })
            XCTAssertEqual(reports.last?.0, "Preparing worktree…")
            XCTAssertTrue(waitUntil(timeout: 5) { !opened.isEmpty })
        }
        XCTAssertEqual(opened.first?.name, "fix-login")
        XCTAssertEqual(opened.first?.command.hasPrefix("git worktree add -b fix-login \(ShellQuote.path(root + "/web/fix-login")) main"), true,
                       opened.first?.command ?? "")

        // An existing branch, and a failure (not a repository) reported back to the pane.
        withSettings({ $0.worktreeRoot = root; $0.claudePermissionMode = "" }) {
            AgentLauncher.start(.existingBranch(name: "main", remote: nil), from: terminal, report: { reports.append(($0, $1)) },
                                open: { opened.append($0) })
            XCTAssertTrue(waitUntil(timeout: 5) { opened.count == 2 })
        }
        XCTAssertEqual(opened.last?.command, "claude -n main", "main is already checked out in the repository")

        let elsewhere = TerminalSession(workingDirectory: try makeTemporaryDirectory().path)
        defer { elsewhere.close() }
        AgentLauncher.start(.worktree, from: elsewhere, report: { reports.append(($0, $1)) }, open: { opened.append($0) })
        XCTAssertTrue(waitUntil(timeout: 5) { reports.last?.1 == false })
        XCTAssertEqual(reports.last?.0, "Worktrees need a git repository")
        XCTAssertEqual(opened.count, 2)
    }

    func testStartingFromAPaneOutsideAWindowDoesNothing() throws {
        let terminal = TerminalSession(workingDirectory: try makeTemporaryDirectory().path)
        defer { terminal.close() }
        var reports: [String] = []
        AgentLauncher.start(.newBranch("x"), from: terminal) { message, _ in reports.append(message) }
        XCTAssertNil(AgentLauncher.controller(for: terminal))
        XCTAssertTrue(reports.isEmpty)
        XCTAssertNil(terminal.pendingCommand)
    }
}
