import AppKit
import XCTest
@testable import Shell

// MARK: - WorktreeInfo

final class WorktreeInfoTests: XCTestCase {
    func testParsesPorcelainListing() {
        let porcelain = """
        worktree /repo
        HEAD 0123456789abcdef0123456789abcdef01234567
        branch refs/heads/main

        worktree /wt/feature
        HEAD fedcba9876543210fedcba9876543210fedcba98
        branch refs/heads/feature/x
        locked being reviewed

        worktree /wt/detached
        HEAD 1111111111111111111111111111111111111111
        detached
        prunable gitdir file points to non-existent location

        worktree /wt/bare
        bare

        worktree /wt/lockedbare
        locked
        prunable
        branch weird
        """
        let list = WorktreeInfo.parse(porcelain: porcelain + "\r\n")
        XCTAssertEqual(list.map(\.path), ["/repo", "/wt/feature", "/wt/detached", "/wt/bare", "/wt/lockedbare"])
        XCTAssertTrue(list[0].isMain)
        XCTAssertEqual(list[0].branch, "main")
        XCTAssertEqual(list[0].head, "01234567")
        XCTAssertEqual(list[0].headOID, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertFalse(list[1].isMain)
        XCTAssertEqual(list[1].branch, "feature/x")
        XCTAssertTrue(list[1].isLocked)
        XCTAssertEqual(list[1].lockReason, "being reviewed")
        XCTAssertTrue(list[2].isDetached)
        XCTAssertNil(list[2].branch)
        XCTAssertEqual(list[2].prunableReason, "gitdir file points to non-existent location")
        XCTAssertTrue(list[2].isPrunable)
        XCTAssertTrue(list[3].isBare)
        XCTAssertTrue(list[4].isLocked)
        XCTAssertNil(list[4].lockReason)
        XCTAssertEqual(list[4].prunableReason, "missing")
        XCTAssertEqual(list[4].branch, "weird", "a branch without refs/heads/ is kept as is")
        XCTAssertEqual(list[1].name, "feature")
        XCTAssertEqual(list[1].id, "/wt/feature")
        XCTAssertTrue(WorktreeInfo.parse(porcelain: "").isEmpty)
    }

    func testFinishedMergedAndHeadMatching() {
        var wt = WorktreeInfo(path: "/wt/a", headOID: "abc", branch: "a")
        XCTAssertFalse(wt.looksFinished)
        wt.upstreamGone = true
        XCTAssertTrue(wt.looksFinished, "a deleted upstream with no open PR looks done")
        wt.pullRequest = GitFixturePR.info(1, state: .open)
        XCTAssertFalse(wt.looksFinished, "an open PR keeps it going")
        wt.pullRequest = GitFixturePR.info(1, state: .merged, headOID: "abc")
        XCTAssertTrue(wt.looksFinished)
        XCTAssertFalse(wt.isMergedAndClean, "unknown changes aren't clean")
        wt.changes = 0
        XCTAssertTrue(wt.isMergedAndClean)
        XCTAssertTrue(wt.headMatchesMergedPR)
        wt.headOID = "def"
        XCTAssertFalse(wt.headMatchesMergedPR, "commits beyond the merged head")
        wt.pullRequest?.headOID = nil
        XCTAssertFalse(wt.headMatchesMergedPR)
        wt.pullRequest = GitFixturePR.info(1, state: .closed, headOID: "def")
        XCTAssertFalse(wt.headMatchesMergedPR)
        XCTAssertFalse(wt.isMergedAndClean)
        wt.pullRequest = GitFixturePR.info(1, state: .merged)
        wt.isLocked = true
        XCTAssertFalse(wt.isMergedAndClean, "locked worktrees stay")
        wt.isLocked = false
        wt.isMain = true
        XCTAssertFalse(wt.isMergedAndClean, "the main checkout stays")
    }

    func testStaleness() {
        let now = Date()
        var wt = WorktreeInfo(path: "/wt/a")
        wt.changes = 0
        XCTAssertFalse(wt.isStale(days: 7, now: now), "unknown activity isn't stale")
        wt.lastActivity = now.addingTimeInterval(-8 * 86400)
        XCTAssertTrue(wt.isStale(days: 7, now: now))
        XCTAssertFalse(wt.isStale(days: 9, now: now))
        wt.changes = 2
        XCTAssertFalse(wt.isStale(days: 7, now: now), "dirty worktrees aren't stale")
        wt.changes = 0
        wt.prunableReason = "missing"
        XCTAssertFalse(wt.isStale(days: 7, now: now))
        wt.prunableReason = nil
        wt.isBare = true
        XCTAssertFalse(wt.isStale(days: 7, now: now))
        wt.isBare = false
        wt.isMain = true
        XCTAssertFalse(wt.isStale(days: 7, now: now))
    }

    func testAgeDescription() {
        var wt = WorktreeInfo(path: "/x")
        XCTAssertNil(wt.ageDescription)
        wt.lastActivity = Date()
        XCTAssertEqual(wt.ageDescription, "today")
        wt.lastActivity = Date().addingTimeInterval(-1.5 * 86400)
        XCTAssertEqual(wt.ageDescription, "1 day ago")
        wt.lastActivity = Date().addingTimeInterval(-10.5 * 86400)
        XCTAssertEqual(wt.ageDescription, "10 days ago")
        wt.lastActivity = Date().addingTimeInterval(-95 * 86400)
        XCTAssertEqual(wt.ageDescription, "3 months ago")
    }

    func testExistsChecksTheFolder() {
        XCTAssertTrue(WorktreeInfo(path: NSTemporaryDirectory()).exists)
        XCTAssertFalse(WorktreeInfo(path: "/nonexistent-\(UUID().uuidString)").exists)
    }
}

// MARK: - WorktreeService

final class WorktreeServiceTests: GitAreaTestCase {
    private let git = "/usr/bin/git"

    func testListsAndInspectsWorktrees() async throws {
        let repo = try GitFixtureRepo(in: gitTempDirectory())
        let feature = try repo.addWorktree("feature", branch: "feature/a")
        try repo.write("dirty\n", "README.md", in: feature)
        try repo.write("new\n", "untracked.txt", in: feature)
        let detached = try repo.addWorktree("detached")

        let list = await WorktreeService.list(repo: repo.root.path, git: git)
        XCTAssertEqual(Set(list.map(\.path)), [repo.root.path, feature.path, detached.path])
        XCTAssertTrue(list[0].isMain)
        let featureWT = try XCTUnwrap(list.first { $0.path == feature.path })
        let detachedWT = try XCTUnwrap(list.first { $0.path == detached.path })
        XCTAssertEqual(featureWT.branch, "feature/a")
        XCTAssertTrue(detachedWT.isDetached)

        let inspected = await WorktreeService.inspect(featureWT, git: git)
        XCTAssertEqual(inspected.changes, 2)
        let activity = try XCTUnwrap(inspected.lastActivity)
        XCTAssertLessThan(Date().timeIntervalSince(activity), 600)
        let clean = await WorktreeService.inspect(detachedWT, git: git)
        XCTAssertEqual(clean.changes, 0)

        // Bare and missing worktrees are left alone.
        var bare = list[0]
        bare.isBare = true
        let skipped = await WorktreeService.inspect(bare, git: git)
        XCTAssertNil(skipped.changes)
        let missing = await WorktreeService.inspect(WorktreeInfo(path: repo.base.appendingPathComponent("nope").path), git: git)
        XCTAssertNil(missing.lastActivity)

        let none = await WorktreeService.list(repo: repo.base.path, git: git)
        XCTAssertTrue(none.isEmpty, "outside a repository there's nothing to list")
    }

    func testBranchTrackingReadsUpstreamAheadBehindAndGone() async throws {
        let repo = try GitFixtureRepo(in: gitTempDirectory())
        let first = try repo.head()
        try repo.git(["remote", "add", "origin", "git@github.com:acme/widgets.git"])
        try repo.commit("second")
        let second = try repo.head()
        try repo.track("main", at: first)                 // ahead 1
        try repo.git(["branch", "behind", first])
        try repo.track("behind", at: second)              // behind 1
        try repo.git(["branch", "gone"])
        try repo.track("gone", at: nil)                   // upstream deleted
        try repo.git(["branch", "local"])                 // no upstream

        let tracking = await WorktreeService.branchTracking(repo: repo.root.path, git: git)
        XCTAssertEqual(tracking["main"]?.upstream, "origin/main")
        XCTAssertEqual(tracking["main"]?.ahead, 1)
        XCTAssertEqual(tracking["main"]?.behind, 0)
        XCTAssertEqual(tracking["behind"]?.behind, 1)
        XCTAssertEqual(tracking["gone"]?.gone, true)
        XCTAssertNotNil(tracking["local"])
        XCTAssertNil(tracking["local"]?.upstream)
        let outside = await WorktreeService.branchTracking(repo: repo.base.path, git: git)
        XCTAssertTrue(outside.isEmpty)
    }

    func testPullRequestsByBranchPreferOpenOnes() async throws {
        let dir = try gitTempDirectory()
        let gh = try FakeGH(in: dir)
        try gh.on("pr list *", json: [
            GitFixturePR.listEntry(9, branch: "a", state: "MERGED", review: "APPROVED", oid: "abc"),
            GitFixturePR.listEntry(8, branch: "a", state: "OPEN", draft: true),
            GitFixturePR.listEntry(7, branch: "a", state: "CLOSED"),
            GitFixturePR.listEntry(6, branch: "b", state: "WEIRD"),
            ["number": 5, "title": "no branch"],
            ["number": 4, "headRefName": "c"],
        ])
        let prs = await WorktreeService.pullRequests(repo: dir.path, environment: gh.environment(home: dir))
        XCTAssertEqual(prs["a"]?.number, 8, "the open PR replaces the merged one")
        XCTAssertEqual(prs["a"]?.isDraft, true)
        XCTAssertNil(prs["a"]?.reviewDecision, "an empty review decision is nil")
        XCTAssertEqual(prs["b"]?.state, .open, "an unknown state reads as open")
        XCTAssertNil(prs["c"], "entries without a URL are skipped")
        XCTAssertEqual(prs.count, 2)
        XCTAssertTrue(gh.calls.first?.contains("headRefOid") == true)

        try gh.reset()
        try gh.on("pr list *", json: [GitFixturePR.listEntry(3, branch: "x", state: "MERGED", review: "APPROVED", oid: "f00")])
        let merged = await WorktreeService.pullRequests(repo: dir.path, environment: gh.environment(home: dir))
        XCTAssertEqual(merged["x"]?.state, .merged)
        XCTAssertEqual(merged["x"]?.reviewDecision, "APPROVED")
        XCTAssertEqual(merged["x"]?.headOID, "f00")

        try gh.reset()
        try gh.on("pr list *", stdout: "not json")
        let bad = await WorktreeService.pullRequests(repo: dir.path, environment: gh.environment(home: dir))
        XCTAssertTrue(bad.isEmpty)

        let noGH = await WorktreeService.pullRequests(repo: dir.path, environment: ["PATH": "/nonexistent"])
        XCTAssertTrue(noGH.isEmpty, "no gh, no PRs")
    }

    func testSizeAndFormatting() async throws {
        let dir = try gitTempDirectory()
        try Data(count: 64 * 1024).write(to: dir.appendingPathComponent("blob"))
        let size = await WorktreeService.size(of: dir.path)
        XCTAssertGreaterThanOrEqual(size ?? 0, 64 * 1024)
        XCTAssertEqual(WorktreeService.formatBytes(0), ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        XCTAssertFalse(WorktreeService.formatBytes(5_000_000).isEmpty)
    }

    func testRemoveRefusesTheMainWorktreeAndPrunesMissingOnes() async throws {
        let repo = try GitFixtureRepo(in: gitTempDirectory())
        let gone = try repo.addWorktree("gone", branch: "gone")
        try FileManager.default.removeItem(at: gone)
        var list = await WorktreeService.list(repo: repo.root.path, git: git)
        let mainError = await WorktreeService.remove(list[0], repo: repo.root.path, git: git, force: false, deleteBranch: false)
        XCTAssertEqual(mainError, "The main worktree can't be removed.")
        XCTAssertTrue(list[1].isPrunable)
        let pruned = await WorktreeService.remove(list[1], repo: repo.root.path, git: git, force: false, deleteBranch: true)
        XCTAssertNil(pruned)
        list = await WorktreeService.list(repo: repo.root.path, git: git)
        XCTAssertEqual(list.count, 1)
    }

    func testRemoveDirtyNeedsForceAndUnmergedBranchesNeedForceDelete() async throws {
        let repo = try GitFixtureRepo(in: gitTempDirectory())
        let path = try repo.addWorktree("topic", branch: "topic")
        try repo.commit("topic work", in: path)
        try repo.write("dirty\n", "README.md", in: path)
        let wt = await WorktreeService.list(repo: repo.root.path, git: git)[1]

        let refused = await WorktreeService.remove(wt, repo: repo.root.path, git: git, force: false, deleteBranch: false)
        XCTAssertNotNil(refused, "git refuses a dirty worktree")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        let kept = await WorktreeService.remove(wt, repo: repo.root.path, git: git, force: true, deleteBranch: true)
        XCTAssertTrue(kept?.hasPrefix("Removed the worktree, but kept branch topic:") == true, kept ?? "nil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(try repo.git(["branch", "--list", "topic"]).contains("topic"))

        // Same again, with -D.
        let path2 = try repo.addWorktree("topic2", branch: "topic2")
        try repo.commit("more", in: path2)
        let wt2 = await WorktreeService.list(repo: repo.root.path, git: git).first { $0.branch == "topic2" }!
        let ok = await WorktreeService.remove(wt2, repo: repo.root.path, git: git, force: false, deleteBranch: true, forceDeleteBranch: true)
        XCTAssertNil(ok)
        XCTAssertFalse(try repo.git(["branch", "--list", "topic2"]).contains("topic2"))
    }

    func testRunReportingError() async throws {
        let dir = try gitTempDirectory()
        let ok = await WorktreeService.runReportingError("/usr/bin/true", [], in: dir.path)
        XCTAssertNil(ok)
        let silent = await WorktreeService.runReportingError("/usr/bin/false", [], in: dir.path, environment: ["X": "1"])
        XCTAssertEqual(silent, "git exited with 1")
        let loud = await WorktreeService.runReportingError(git, ["not-a-command"], in: dir.path)
        XCTAssertTrue(loud?.contains("not-a-command") == true)
    }

    func testWorktreeRootPrefersSettingsThenWorktreesHome() {
        withSettings({ $0.worktreeRoot = "/custom/root" }) {
            XCTAssertEqual(WorktreeService.worktreeRoot(environment: ["WORKTREES_HOME": "/gwt"]), "/custom/root")
        }
        withSettings({ $0.worktreeRoot = "" }) {
            XCTAssertEqual(WorktreeService.worktreeRoot(environment: ["WORKTREES_HOME": "/gwt"]), "/gwt")
            XCTAssertEqual(WorktreeService.worktreeRoot(environment: [:]), ("~/code/worktrees" as NSString).expandingTildeInPath)
        }
    }

    func testRepositoriesFindsReposUpToTwoLevelsDown() throws {
        let dir = try gitTempDirectory()
        let fm = FileManager.default
        for p in ["a/.git", "group/b/.git", "group/deep/c/d/.git", ".hidden/e/.git", "node_modules/f/.git"] {
            try fm.createDirectory(at: dir.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        try Data().write(to: dir.appendingPathComponent("file.txt"))
        XCTAssertEqual(WorktreeService.repositories(in: dir.path), [dir.appendingPathComponent("a").path, dir.appendingPathComponent("group/b").path])
        XCTAssertEqual(WorktreeService.repositories(in: dir.appendingPathComponent("a").path), [dir.appendingPathComponent("a").path])
        XCTAssertTrue(WorktreeService.repositories(in: dir.appendingPathComponent("missing").path).isEmpty)
    }

    func testGitUsesTheDefaultEnvironment() {
        XCTAssertTrue(WorktreeService.git().hasSuffix("/git"))
    }
}

// MARK: - WorktreesModel

final class WorktreesModelTests: GitAreaTestCase {
    /// main, a merged & clean worktree whose HEAD is the PR's head, a dirty
    /// one, and a stale one.
    private func fixture() throws -> (GitFixtureRepo, FakeGH, URL, URL, URL) {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        try repo.git(["remote", "add", "origin", "git@github.com:acme/widgets.git"])
        let merged = try repo.addWorktree("merged", branch: "merged")
        try repo.commit("merged work", in: merged)
        let dirty = try repo.addWorktree("dirty", branch: "dirty")
        try repo.write("change\n", "README.md", in: dirty)
        try repo.track("dirty", at: try repo.head())
        let stale = try repo.addWorktree("stale", branch: "stale")
        try repo.commit("old", in: stale, date: "2020-01-01T00:00:00Z")
        try repo.backdateGitFiles(of: stale, by: 400)
        let gh = try FakeGH(in: dir)
        try gh.on("pr list *", json: [
            GitFixturePR.listEntry(1, branch: "merged", state: "MERGED", oid: try repo.head(in: merged)),
            GitFixturePR.listEntry(2, branch: "dirty", state: "OPEN", review: "CHANGES_REQUESTED"),
        ])
        return (repo, gh, merged, dirty, stale)
    }

    func testRefreshFillsInChangesTrackingPullRequestsAndSizes() async throws {
        let (repo, gh, merged, dirty, stale) = try fixture()
        let model = WorktreesModel(repoRoot: repo.root.path, environment: gh.environment(home: repo.base))
        SettingsStore.shared.settings.worktreeStaleDays = 30
        model.refreshIfNeeded()
        XCTAssertTrue(model.isLoading)
        model.refresh() // ignored while loading
        try await eventually("load") { !model.isLoading }
        try await eventually("sizes") { model.worktrees.allSatisfy { $0.sizeBytes != nil } }

        XCTAssertEqual(model.worktrees.count, 4)
        let byPath = Dictionary(uniqueKeysWithValues: model.worktrees.map { ($0.path, $0) })
        XCTAssertEqual(byPath[merged.path]?.pullRequest?.state, .merged)
        XCTAssertEqual(byPath[merged.path]?.changes, 0)
        XCTAssertTrue(byPath[merged.path]?.trackingKnown == true)
        XCTAssertEqual(byPath[dirty.path]?.changes, 1)
        XCTAssertEqual(byPath[dirty.path]?.upstream, "origin/dirty")
        XCTAssertEqual(byPath[dirty.path]?.pullRequest?.number, 2)
        XCTAssertEqual(model.stale.map(\.path), [stale.path])
        XCTAssertGreaterThan(model.totalSize, 0)
        XCTAssertEqual(model.staleDays, 30)
        SettingsStore.shared.settings.worktreeStaleDays = 0
        XCTAssertEqual(model.staleDays, 1, "at least a day")

        // Merged-and-clean worktrees, except the one a pane is in.
        XCTAssertEqual(model.merged(excluding: repo.root.path).map(\.path), [merged.path])
        XCTAssertTrue(model.merged(excluding: merged.path + "/").isEmpty)

        // A second refresh keeps what's known.
        let calls = gh.calls.count
        model.refreshIfNeeded()
        XCTAssertFalse(model.isLoading, "recent data isn't reloaded")
        model.refresh()
        try await eventually("reload") { !model.isLoading }
        XCTAssertGreaterThan(gh.calls.count, calls)
        XCTAssertNotNil(model.worktrees.first { $0.path == merged.path }?.sizeBytes)
    }

    func testRemoveMergedDeletesBranchesOnlyWhenHeadMatches() async throws {
        let (repo, gh, merged, _, _) = try fixture()
        let model = WorktreesModel(repoRoot: repo.root.path, environment: gh.environment(home: repo.base))
        model.refresh()
        try await eventually { !model.isLoading }
        let list = model.merged(excluding: repo.root.path)
        XCTAssertEqual(list.count, 1)
        await model.removeMerged(list)
        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.path))
        XCTAssertFalse(try repo.git(["branch", "--list", "merged"]).contains("merged"), "squash-safe -D for an exact match")
        XCTAssertNil(model.lastError)
        try await eventually { !model.isLoading }

        // A failing removal reports per worktree.
        var ghost = list[0]
        ghost.path = repo.base.appendingPathComponent("other").path
        try FileManager.default.createDirectory(atPath: ghost.path, withIntermediateDirectories: true)
        await model.removeMerged([ghost])
        XCTAssertTrue(model.lastError?.hasPrefix("other: ") == true, model.lastError ?? "nil")
        try await eventually { !model.isLoading }
    }

    func testRemoveAndRemoveStale() async throws {
        let (repo, gh, _, dirty, stale) = try fixture()
        SettingsStore.shared.settings.worktreeStaleDays = 30
        let model = WorktreesModel(repoRoot: repo.root.path, environment: gh.environment(home: repo.base))
        model.refresh()
        try await eventually { !model.isLoading }

        let dirtyWT = try XCTUnwrap(model.worktrees.first { $0.path == dirty.path })
        await model.remove(dirtyWT, force: false, deleteBranch: false)
        XCTAssertNotNil(model.lastError, "dirty worktrees need force")
        XCTAssertTrue(model.busy.isEmpty)
        try await eventually { !model.isLoading }
        model.lastError = nil

        await model.removeStale(deleteBranch: false)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        try await eventually { !model.isLoading }
        XCTAssertFalse(model.worktrees.contains { $0.path == stale.path })
    }
}

// MARK: - Scheduled cleanup

final class WorktreeCleanupJobTests: GitAreaTestCase {
    override func tearDown() async throws {
        WorktreeCleanupJob.pathsOverride = nil
        try await super.tearDown()
    }

    func testAvailabilityFollowsThePaths() {
        let job = WorktreeCleanupJob()
        XCTAssertEqual(job.id, "worktrees")
        XCTAssertFalse(job.title.isEmpty)
        XCTAssertFalse(job.summary.isEmpty)
        WorktreeCleanupJob.pathsOverride = []
        XCTAssertFalse(job.isAvailable)
        WorktreeCleanupJob.pathsOverride = ["/tmp"]
        XCTAssertTrue(job.isAvailable)
        XCTAssertEqual(job.schedule, SettingsStore.shared.settings.worktreeCleanupSchedule)
        WorktreeCleanupJob.pathsOverride = nil
        SettingsStore.shared.settings.worktreeCleanupPaths = ["/a"]
        XCTAssertEqual(WorktreeCleanupJob.paths, ["/a"])
    }

    func testFindsAndRemovesStaleWorktreesOnce() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        let stale = try repo.addWorktree("stale", branch: "stale")
        try repo.commit("old", in: stale, date: "2020-01-01T00:00:00Z")
        try repo.backdateGitFiles(of: stale, by: 400)
        let fresh = try repo.addWorktree("fresh", branch: "fresh")
        SettingsStore.shared.settings.worktreeStaleDays = 30
        SettingsStore.shared.settings.worktreeCleanupDeleteMergedBranches = false
        // The repository twice (directly and via its parent): each worktree counts once.
        WorktreeCleanupJob.pathsOverride = [repo.root.path, dir.path]

        let candidates = await WorktreeCleanupJob.candidates()
        XCTAssertEqual(candidates.map(\.worktree.path), [stale.path])
        XCTAssertEqual(candidates.first?.repo, repo.root.path)
        XCTAssertEqual(candidates.first?.id, stale.path)

        let job = WorktreeCleanupJob()
        let run = MaintenanceRun(jobID: "worktrees-test-\(UUID().uuidString.prefix(6))")
        defer {
            run.close()
            try? FileManager.default.removeItem(at: run.logURL)
        }
        var steps: [String] = []
        run.onStep = { steps.append($0) }
        let outcome = await job.perform(run)
        XCTAssertEqual(outcome.changes, ["repo/stale"])
        XCTAssertTrue(outcome.warnings.isEmpty)
        XCTAssertTrue(outcome.summary?.hasPrefix("freed ") == true)
        XCTAssertEqual(steps, ["Removing stale"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        await job.didFinish()
    }

    func testFailedRemovalBecomesAWarning() async throws {
        let dir = try gitTempDirectory()
        let repo = try GitFixtureRepo(in: dir)
        let stale = try repo.addWorktree("stale", branch: "stale")
        try repo.commit("old", in: stale, date: "2020-01-01T00:00:00Z")
        try repo.backdateGitFiles(of: stale, by: 400)
        SettingsStore.shared.settings.worktreeStaleDays = 30
        WorktreeCleanupJob.pathsOverride = [repo.root.path]
        // Locked worktrees aren't stale.
        try repo.git(["worktree", "lock", stale.path])
        let none = await WorktreeCleanupJob.candidates()
        XCTAssertTrue(none.isEmpty)
        try repo.git(["worktree", "unlock", stale.path])

        // A read-only folder inside makes `git worktree remove` fail.
        let sub = stale.appendingPathComponent("sealed")
        try repo.write("x\n", "sealed/f.txt", in: stale)
        try repo.git(["add", "-A"], in: stale)
        try repo.git(["commit", "-q", "-m", "sealed"], in: stale, env: ["GIT_COMMITTER_DATE": "2020-01-02T00:00:00Z", "GIT_AUTHOR_DATE": "2020-01-02T00:00:00Z"])
        try repo.backdateGitFiles(of: stale, by: 400)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path) }

        let run = MaintenanceRun(jobID: "worktrees-test-\(UUID().uuidString.prefix(6))")
        defer {
            run.close()
            try? FileManager.default.removeItem(at: run.logURL)
        }
        let outcome = await WorktreeCleanupJob().perform(run)
        XCTAssertTrue(outcome.changes.isEmpty)
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings.first?.hasPrefix("stale: ") == true, outcome.warnings.first ?? "nil")
        XCTAssertNil(outcome.summary)
    }

    func testNotifications() {
        let job = WorktreeCleanupJob()
        func record(_ outcome: MaintenanceRecord.Outcome, _ changes: [String], summary: String? = nil) -> MaintenanceRecord {
            MaintenanceRecord(startedAt: Date(), finishedAt: Date(), outcome: outcome, changes: changes, warnings: [], logPath: "", summary: summary)
        }
        let one = job.notification(for: record(.success, ["r/a"], summary: "freed 1 MB"))
        XCTAssertEqual(one?.title, "Removed 1 stale worktree · freed 1 MB")
        XCTAssertEqual(one?.body, "r/a")
        let many = job.notification(for: record(.success, (1...7).map { "r/\($0)" }))
        XCTAssertEqual(many?.title, "Removed 7 stale worktrees")
        XCTAssertEqual(many?.body, "r/1, r/2, r/3, r/4, r/5 +2 more")
        XCTAssertNil(job.notification(for: record(.success, [])))
        XCTAssertEqual(job.notification(for: record(.failed, []))?.title, "Worktree cleanup failed")
        XCTAssertNil(job.notification(for: record(.cancelled, [])))
    }
}
