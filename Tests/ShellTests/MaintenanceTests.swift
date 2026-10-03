import XCTest
@testable import Shell

/// Writes an executable `#!/bin/sh` script into `dir`.
@discardableResult
private func script(_ dir: URL, _ name: String, _ body: String) throws -> String {
    try writeExecutable("#!/bin/sh\n" + body + "\n", to: dir.appendingPathComponent(name))
}

/// A maintenance job whose behavior each test sets.
@MainActor
private final class FakeJob: MaintenanceJob {
    let id: String
    let title = "Fake"
    let summary = "A fake job"
    var isAvailable = true
    var schedule: AutoUpdateSchedule = .daily
    var outcome = MaintenanceOutcome()
    var action: ((MaintenanceRun) async -> Void)?
    var notificationResult: (title: String, body: String)? = ("Fake finished", "body")
    private(set) var performed = 0
    private(set) var finished = 0
    private(set) var records: [MaintenanceRecord] = []

    init(id: String = "fake-\(UUID().uuidString.prefix(8))") { self.id = id }

    func perform(_ run: MaintenanceRun) async -> MaintenanceOutcome {
        performed += 1
        await action?(run)
        return outcome
    }

    func notification(for record: MaintenanceRecord) -> (title: String, body: String)? {
        records.append(record)
        return notificationResult
    }

    func didFinish() async { finished += 1 }
}

// MARK: - MaintenanceRun

@MainActor
final class MaintenanceRunTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = try makeTemporaryDirectory()
    }

    func testLogsGoToTheTestSupportFolderNotTheRealLibrary() throws {
        let logs = ScheduledMaintenance.logDirectory
        XCTAssertEqual(logs.standardizedFileURL.path,
                       SettingsStore.supportDirectory.appendingPathComponent("Logs").standardizedFileURL.path)
        XCTAssertFalse(logs.path.contains("/Library/Logs/Shell"))
        let run = MaintenanceRun(jobID: "hermetic-\(UUID().uuidString.prefix(6))")
        defer { run.close(); try? FileManager.default.removeItem(at: run.logURL) }
        XCTAssertTrue(run.logURL.path.hasPrefix(SettingsStore.supportDirectory.path), run.logURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.logURL.path))
        XCTAssertFalse(MaintenanceRun.dryRun)
    }

    func testStepRunsTheCommandAndCapturesItsOutput() async throws {
        let exe = try script(dir, "hello", #"echo "hello $1 FOO=$FOO CI=$CI NONINTERACTIVE=$NONINTERACTIVE""#)
        let run = MaintenanceRun(jobID: "step-\(UUID().uuidString.prefix(6))")
        var steps: [String] = []
        run.onStep = { steps.append($0) }
        run.note("starting")
        let r = await run.step("say hello", exe, ["world"], env: ["FOO": "bar"])
        run.close()
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("hello world FOO=bar CI=1 NONINTERACTIVE=1"), r.output)
        XCTAssertEqual(steps, ["say hello"])
        let log = try String(contentsOf: run.logURL, encoding: .utf8)
        XCTAssertTrue(log.hasPrefix("starting\n\n$ say hello\nhello world"), log)
    }

    func testFailingStepReportsItsExitStatus() async throws {
        let exe = try script(dir, "fail", "echo broken >&2; exit 3")
        let run = MaintenanceRun(jobID: "fail-\(UUID().uuidString.prefix(6))")
        let r = await run.step("fail", exe, [])
        run.close()
        XCTAssertEqual(r.status, 3)
        XCTAssertTrue(r.output.contains("broken"))
        let log = try String(contentsOf: run.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("(exit 3)"), log)
    }

    func testMissingExecutableFailsWithoutCrashing() async throws {
        let run = MaintenanceRun(jobID: "missing-\(UUID().uuidString.prefix(6))")
        let r = await run.step("ghost", dir.appendingPathComponent("nope").path, [])
        run.close()
        XCTAssertEqual(r.status, -1)
        let log = try String(contentsOf: run.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("failed to launch"), log)
    }

    func testCancelStopsTheRunningStepAndSkipsLaterOnes() async throws {
        let exe = try script(dir, "slow", "echo started; sleep 10")
        let marker = try script(dir, "marker", "touch \"\(dir.appendingPathComponent("ran").path)\"")
        let run = MaintenanceRun(jobID: "cancel-\(UUID().uuidString.prefix(6))")
        let task = Task { await run.step("slow", exe, []) }
        try await Task.sleep(for: .milliseconds(300))
        run.cancel()
        let r = await task.value
        XCTAssertTrue(run.cancelled)
        XCTAssertNotEqual(r.status, 0)
        let skipped = await run.step("marker", marker, [])
        run.close()
        XCTAssertEqual(skipped.status, -1)
        XCTAssertEqual(skipped.output, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ran").path))
    }

    func testScheduleIntervalsAndTitles() {
        XCTAssertNil(AutoUpdateSchedule.off.interval)
        XCTAssertEqual(AutoUpdateSchedule.daily.interval, 86400)
        XCTAssertEqual(AutoUpdateSchedule.weekly.interval, 7 * 86400)
        XCTAssertEqual(AutoUpdateSchedule.monthly.interval, 30 * 86400)
        XCTAssertEqual(AutoUpdateSchedule.weekly.title, "Weekly")
        XCTAssertEqual(AutoUpdateSchedule.monthly.id, "monthly")
    }
}

// MARK: - ScheduledMaintenance

@MainActor
final class ScheduledMaintenanceTests: XCTestCase {
    private var dir: URL!
    private var notifications: [(String, String, SettingsPane)] = []

    override func setUp() async throws {
        dir = try makeTemporaryDirectory()
        notifications = []
    }

    private func make(_ job: FakeJob) -> ScheduledMaintenance {
        let m = ScheduledMaintenance(job: job)
        m.notify = { [weak self] in self?.notifications.append(($0, $1, $2)) }
        let state = SettingsStore.supportDirectory.appendingPathComponent("maintenance-\(job.id).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        return m
    }

    func testNextRunFollowsScheduleSuccessAndRetry() async {
        let job = FakeJob()
        job.schedule = .off
        let m = make(job)
        XCTAssertNil(m.nextRun, "off never runs")
        job.schedule = .weekly
        XCTAssertEqual(m.schedule, .weekly)
        let now = try? XCTUnwrap(m.nextRun)
        XCTAssertLessThanOrEqual(now?.timeIntervalSinceNow ?? 99, 1, "never run: due now")

        await m.run()
        let success = try? XCTUnwrap(m.lastSuccess)
        XCTAssertEqual(m.nextRun, success?.addingTimeInterval(7 * 86400))

        // A failure after the success pushes the next try out by the retry delay at least.
        job.schedule = .daily
        job.outcome = MaintenanceOutcome(failedStep: "boom")
        await m.run()
        XCTAssertEqual(m.lastSuccess, success, "failures don't move lastSuccess")
        let next = try? XCTUnwrap(m.nextRun)
        let retry = (m.lastRun?.startedAt ?? Date()).addingTimeInterval(ScheduledMaintenance.retryAfterFailure)
        XCTAssertEqual(next, max(success!.addingTimeInterval(86400), retry))
    }

    func testSuccessfulRunRecordsPersistsAndNotifies() async throws {
        let job = FakeJob()
        job.outcome = MaintenanceOutcome(changes: ["jq", "wget"], warnings: ["w1"], summary: "two updates")
        var stepsSeen: [String?] = []
        let m = make(job)
        job.action = { run in
            run.onStep?("step one")
            stepsSeen.append(m.currentStep)
            XCTAssertTrue(m.isRunning)
        }
        await m.run()
        XCTAssertEqual(stepsSeen, ["step one"])
        XCTAssertFalse(m.isRunning)
        XCTAssertNil(m.currentStep)
        let record = try XCTUnwrap(m.lastRun)
        XCTAssertEqual(record.outcome, .success)
        XCTAssertEqual(record.changes, ["jq", "wget"])
        XCTAssertEqual(record.warnings, ["w1"])
        XCTAssertEqual(record.summary, "two updates")
        XCTAssertNil(record.failedStep)
        XCTAssertTrue(record.logPath.hasPrefix(SettingsStore.supportDirectory.path))
        XCTAssertEqual(m.lastSuccess, record.startedAt)
        XCTAssertEqual(job.finished, 1)
        XCTAssertEqual(job.records, [record])
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.0, "Fake finished")
        XCTAssertEqual(notifications.first?.2, .homebrew, "unknown job ids fall back to the Homebrew pane")

        // A new scheduler for the same job reads the saved state back.
        let reloaded = ScheduledMaintenance(job: job)
        XCTAssertEqual(reloaded.lastRun, record)
        XCTAssertEqual(reloaded.lastSuccess, record.startedAt)
    }

    func testFailedRunDropsChangesAndSkipsTheNotificationWhenNone() async throws {
        let job = FakeJob()
        job.outcome = MaintenanceOutcome(failedStep: "brew upgrade", changes: ["jq"], warnings: ["oops"])
        job.notificationResult = nil
        let m = make(job)
        await m.run()
        let record = try XCTUnwrap(m.lastRun)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStep, "brew upgrade")
        XCTAssertEqual(record.changes, [], "changes only count on success")
        XCTAssertEqual(record.warnings, ["oops"])
        XCTAssertNil(m.lastSuccess)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testCancelMarksTheRunCancelled() async throws {
        let slow = try script(dir, "slow", "sleep 10")
        let job = FakeJob()
        job.action = { run in _ = await run.step("waiting", slow, []) }
        let m = make(job)
        let task = Task { await m.run() }
        await assertEventually { m.currentStep == "waiting" }
        try await Task.sleep(for: .milliseconds(100))
        m.cancel()
        await task.value
        XCTAssertEqual(m.lastRun?.outcome, .cancelled)
        XCTAssertNil(m.lastSuccess)
    }

    func testUnavailableOrBusyJobsDontRun() async {
        let job = FakeJob()
        job.isAvailable = false
        let m = make(job)
        await m.run()
        m.runIfDue()
        XCTAssertEqual(job.performed, 0)
        XCTAssertNil(m.lastRun)
    }

    func testRunIfDueStartsADueJobAndIgnoresOffSchedules() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.isLowPowerModeEnabled, "Low Power Mode skips scheduled runs")
        let job = FakeJob()
        job.schedule = .off
        let m = make(job)
        m.runIfDue()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(job.performed, 0, "off")

        job.schedule = .daily
        m.runIfDue()
        await assertEventually { m.lastRun != nil }
        XCTAssertEqual(job.performed, 1)

        m.runIfDue() // just succeeded: not due again for a day
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(job.performed, 1)
    }

    func testConfigureSchedulesOnlyWhenOn() {
        let job = FakeJob()
        job.schedule = .daily
        let m = make(job)
        m.configure()
        m.configure() // reconfiguring replaces the timer and keeps one wake observer
        job.schedule = .off
        m.configure()
        XCTAssertEqual(job.performed, 0, "configuring never runs a job right away")
    }

    func testOldLogsArePrunedToTheNewestTwenty() async throws {
        let job = FakeJob()
        let logs = ScheduledMaintenance.logDirectory
        for i in 0..<25 {
            let url = logs.appendingPathComponent("\(job.id)-2020-01-01T0000\(String(format: "%02d", i)).log")
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let other = logs.appendingPathComponent("unrelated-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: other.path, contents: Data())
        addTeardownBlock {
            let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.lastPathComponent.hasPrefix(job.id) || f == other { try? FileManager.default.removeItem(at: f) }
        }
        let m = make(job)
        await m.run()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: logs.path).filter { $0.hasPrefix("\(job.id)-") }
        XCTAssertEqual(remaining.count, 20)
        XCTAssertFalse(remaining.contains("\(job.id)-2020-01-01T000000.log"), "the oldest go first")
        XCTAssertTrue(remaining.contains { !$0.hasPrefix("\(job.id)-2020") }, "the new run's log is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "other jobs' logs are untouched")
    }

    func testSharedSchedulersCoverEveryJob() {
        XCTAssertEqual(ScheduledMaintenance.all.map(\.job.id), ["homebrew", "node", "worktrees", "agentStorage"])
    }
}

// MARK: - Homebrew job

@MainActor
final class HomebrewMaintenanceJobTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = try makeTemporaryDirectory()
    }

    /// A stand-in brew: `update`/`upgrade` exit with `<cmd>.status` (default 0)
    /// and log their arguments; `outdated` and `doctor` print fixtures.
    private func fakeBrew(updateStatus: Int = 0, upgradeStatus: Int = 0) throws -> String {
        let log = dir.appendingPathComponent("calls.log").path
        return try script(dir, "brew", #"""
        echo "$* HOMEBREW_NO_AUTO_UPDATE=$HOMEBREW_NO_AUTO_UPDATE" >> "\#(log)"
        case "$1" in
          update) echo "Already up-to-date."; exit \#(updateStatus) ;;
          upgrade) echo "Upgrading jq"; exit \#(upgradeStatus) ;;
          outdated) echo '{"formulae":[{"name":"jq"},{"name":"wget"}],"casks":[{"name":"firefox"}]}' ;;
          doctor) echo "Please note"; echo "Warning: Some installed formulae are deprecated."; echo "Warning:   Unbrewed dylibs"; exit 1 ;;
          --version) echo "Homebrew 4.5.0" ;;
          info) echo '{"formulae":[],"casks":[]}' ;;
        esac
        """#)
    }

    func testUpdatesUpgradesAndCollectsDoctorWarnings() async throws {
        let brew = BrewService(candidates: [try fakeBrew()], terminal: { _, _ in XCTFail("no terminal") })
        let job = HomebrewMaintenanceJob(brew: brew)
        XCTAssertTrue(job.isAvailable)
        XCTAssertEqual(job.id, "homebrew")
        XCTAssertFalse(job.summary.isEmpty)
        let run = MaintenanceRun(jobID: "homebrew-test")
        let out = await job.perform(run)
        run.close()
        XCTAssertNil(out.failedStep)
        XCTAssertEqual(out.changes, ["jq", "wget", "firefox"])
        XCTAssertEqual(out.warnings, ["Some installed formulae are deprecated.", "Unbrewed dylibs"])
        let calls = try String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)
        XCTAssertEqual(calls.split(separator: "\n").map { $0.split(separator: " ").first.map(String.init) ?? "" },
                       ["update", "outdated", "upgrade", "doctor"])
        XCTAssertTrue(calls.contains("HOMEBREW_NO_AUTO_UPDATE=1"))

        await job.didFinish()
        XCTAssertEqual(brew.version, "Homebrew 4.5.0")
    }

    func testFailedUpdateOrUpgradeStopsTheJob() async throws {
        let failingUpdate = HomebrewMaintenanceJob(brew: BrewService(candidates: [try fakeBrew(updateStatus: 1)], terminal: { _, _ in }))
        var run = MaintenanceRun(jobID: "homebrew-test")
        var out = await failingUpdate.perform(run)
        run.close()
        XCTAssertEqual(out.failedStep, "brew update")

        let failingUpgrade = HomebrewMaintenanceJob(brew: BrewService(candidates: [try fakeBrew(upgradeStatus: 2)], terminal: { _, _ in }))
        run = MaintenanceRun(jobID: "homebrew-test")
        out = await failingUpgrade.perform(run)
        run.close()
        XCTAssertEqual(out.failedStep, "brew upgrade")
        XCTAssertTrue(out.changes.isEmpty)
    }

    func testMissingBrewFailsFast() async {
        let job = HomebrewMaintenanceJob(brew: BrewService(candidates: [dir.appendingPathComponent("brew").path], terminal: { _, _ in }))
        XCTAssertFalse(job.isAvailable)
        let run = MaintenanceRun(jobID: "homebrew-test")
        let out = await job.perform(run)
        run.close()
        XCTAssertEqual(out.failedStep, "find brew")
    }

    func testNotifications() {
        let job = HomebrewMaintenanceJob(brew: BrewService(candidates: [], terminal: { _, _ in }))
        func record(_ outcome: MaintenanceRecord.Outcome, changes: [String] = [], warnings: [String] = [], failedStep: String? = nil) -> MaintenanceRecord {
            MaintenanceRecord(startedAt: Date(), finishedAt: Date(), outcome: outcome, failedStep: failedStep,
                              changes: changes, warnings: warnings, logPath: "/tmp/x.log")
        }
        let one = job.notification(for: record(.success, changes: ["jq"]))
        XCTAssertEqual(one?.title, "Homebrew upgraded 1 package")
        XCTAssertEqual(one?.body, "jq")

        let many = job.notification(for: record(.success, changes: (1...8).map { "p\($0)" }, warnings: ["a"]))
        XCTAssertEqual(many?.title, "Homebrew upgraded 8 packages")
        XCTAssertEqual(many?.body, "p1, p2, p3, p4, p5, p6 +2 more · brew doctor: 1 warning")
        let twoWarnings = job.notification(for: record(.success, changes: ["a"], warnings: ["x", "y"]))
        XCTAssertEqual(twoWarnings?.body, "a · brew doctor: 2 warnings")

        XCTAssertNil(job.notification(for: record(.success)), "nothing changed")
        XCTAssertNil(job.notification(for: record(.cancelled)))
        let failed = job.notification(for: record(.failed, failedStep: "brew update"))
        XCTAssertEqual(failed?.title, "Homebrew auto-update failed")
        XCTAssertTrue(failed?.body.hasPrefix("brew update didn't finish") ?? false)
        XCTAssertTrue(job.notification(for: record(.failed))?.body.hasPrefix("brew didn't finish") ?? false)
    }

    func testScheduleComesFromSettings() {
        let job = HomebrewMaintenanceJob(brew: BrewService(candidates: [], terminal: { _, _ in }))
        withSettings({ $0.brewAutoUpdate = .weekly }) {
            XCTAssertEqual(job.schedule, .weekly)
        }
    }
}

// MARK: - Agent storage job

@MainActor
final class AgentStorageCleanupJobTests: XCTestCase {
    private var root: URL!
    private var original: AppSettings!

    override func setUp() async throws {
        root = try makeTemporaryDirectory()
        original = SettingsStore.shared.settings
    }

    override func tearDown() async throws {
        SettingsStore.shared.settings = original
    }

    @discardableResult
    private func file(_ path: String, age: TimeInterval) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func category(_ id: String, _ kind: StorageCategory.Kind, folder: String, agent: StorageCategory.Agent = .claude,
                          requiresClosed: String? = nil) -> StorageCategory {
        let dir = root.appendingPathComponent(folder)
        return StorageCategory(id: id, agent: agent, kind: kind, title: "Things \(id)", detail: "", roots: [dir],
                               requiresClosed: requiresClosed, items: { AgentStorage.children(dir) })
    }

    func testRemovesOldCachesKeepsRecentOnesAndSkipsHistoryByDefault() async throws {
        let oldCache = try file("cache/old.log", age: 3 * 86400)
        let freshCache = try file("cache/fresh.log", age: 60)
        let oldHistory = try file("history/old.jsonl", age: 90 * 86400)
        let busy = try file("busy/old.db", age: 3 * 86400)
        let categories = [
            category("c", .cache, folder: "cache"),
            category("h", .history, folder: "history"),
            // The test host is Shell itself, so "shell" is always running.
            category("b", .cache, folder: "busy", agent: .codex, requiresClosed: "shell"),
        ]
        SettingsStore.shared.settings.agentPruneHistory = false
        let model = AgentStorageModel(categories: categories)
        let job = AgentStorageCleanupJob(categories: { categories }, model: { model })
        var steps: [String] = []
        let run = MaintenanceRun(jobID: "agentStorage-test")
        run.onStep = { steps.append($0) }
        let out = await job.perform(run)
        run.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldCache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshCache.path), "touched in the last day")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldHistory.path), "history pruning is off")
        XCTAssertTrue(FileManager.default.fileExists(atPath: busy.path), "its app is running")
        XCTAssertEqual(steps, ["Things c"])
        XCTAssertEqual(out.changes, ["Claude Code things c"])
        XCTAssertTrue(out.warnings.isEmpty)
        XCTAssertTrue(out.summary?.hasPrefix("freed ") ?? false, out.summary ?? "")
        let log = try String(contentsOf: run.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("skip b: shell is running"), log)
        XCTAssertTrue(log.contains("c: removed 1 items"), log)
        await assertEventually { !model.isMeasuring && model.measured["c"] != nil }
        XCTAssertEqual(model.measured["c"]?.items.map(\.url.lastPathComponent), ["fresh.log"])
    }

    func testPrunesHistoryOlderThanTheConfiguredDays() async throws {
        let old = try file("history/old.jsonl", age: 10 * 86400)
        let recent = try file("history/recent.jsonl", age: 2 * 86400)
        let categories = [category("h", .history, folder: "history", agent: .codex)]
        SettingsStore.shared.settings.agentPruneHistory = true
        SettingsStore.shared.settings.agentHistoryDays = 7
        let model = AgentStorageModel(categories: categories)
        let job = AgentStorageCleanupJob(categories: { categories }, model: { model })
        let run = MaintenanceRun(jobID: "agentStorage-test")
        let out = await job.perform(run)
        run.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(out.changes, ["Codex things h"])

        let record = MaintenanceRecord(startedAt: Date(), finishedAt: Date(), outcome: .success, failedStep: nil,
                                       changes: out.changes, warnings: [], logPath: run.logURL.path, summary: out.summary)
        let note = try XCTUnwrap(job.notification(for: record))
        XCTAssertEqual(note.title, "Cleaned up Claude & Codex storage")
        XCTAssertTrue(note.body.hasPrefix("Freed "), note.body)
        XCTAssertTrue(note.body.hasSuffix(" · Codex things h"), note.body)
    }

    func testNothingOldEnoughMeansNoChangesAndACancelledRunStopsEarly() async throws {
        try file("cache/fresh.log", age: 60)
        let categories = [category("c", .cache, folder: "cache"), category("d", .cache, folder: "cache")]
        let model = AgentStorageModel(categories: categories)
        let job = AgentStorageCleanupJob(categories: { categories }, model: { model })
        let run = MaintenanceRun(jobID: "agentStorage-test")
        let out = await job.perform(run)
        run.close()
        XCTAssertTrue(out.changes.isEmpty)
        XCTAssertNil(job.notification(for: MaintenanceRecord(startedAt: Date(), finishedAt: Date(), outcome: .success, failedStep: nil,
                                                             changes: [], warnings: [], logPath: "")))

        var steps: [String] = []
        let cancelled = MaintenanceRun(jobID: "agentStorage-test")
        cancelled.onStep = { steps.append($0) }
        cancelled.cancel()
        _ = await job.perform(cancelled)
        cancelled.close()
        XCTAssertTrue(steps.isEmpty, "a cancelled run doesn't start any category")
        await job.didFinish()
        XCTAssertTrue(job.isAvailable)
    }
}

// MARK: - Auto-update bar

@MainActor
final class AutoUpdateBarTests: XCTestCase {
    private var original: AppSettings!

    override func setUp() async throws {
        original = SettingsStore.shared.settings
    }

    override func tearDown() async throws {
        SettingsStore.shared.settings = original
    }

    private func bar(_ m: ScheduledMaintenance) -> AutoUpdateBar { AutoUpdateBar(maintenance: m, schedule: \.agentStorageSchedule) }

    private func make(_ job: FakeJob) -> ScheduledMaintenance {
        let m = ScheduledMaintenance(job: job)
        m.notify = { _, _, _ in }
        let state = SettingsStore.supportDirectory.appendingPathComponent("maintenance-\(job.id).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        return m
    }

    func testRendersEachState() async throws {
        let job = FakeJob()
        let m = make(job)
        job.schedule = .off
        render(bar(m)) // never run, off
        job.schedule = .daily
        render(bar(m)) // never run: first run soon

        job.outcome = MaintenanceOutcome(changes: ["jq"], warnings: ["w"])
        await m.run()
        render(bar(m)) // success with a change and an issue; next run in a day
        job.outcome = MaintenanceOutcome(changes: ["a", "b"], warnings: ["w1", "w2"])
        await m.run()
        render(bar(m))
        job.outcome = MaintenanceOutcome()
        await m.run()
        render(bar(m)) // everything up to date
        job.outcome = MaintenanceOutcome(failedStep: "brew upgrade")
        await m.run()
        render(bar(m)) // failed
        job.outcome = MaintenanceOutcome()
        job.action = { $0.cancel() }
        await m.run()
        XCTAssertEqual(m.lastRun?.outcome, .cancelled)
        render(bar(m))
        job.schedule = .off
        render(bar(m)) // a last run, but off: no next run
    }

    func testDueNowShowsSoon() async throws {
        let job = FakeJob()
        job.schedule = .daily
        job.outcome = MaintenanceOutcome(failedStep: "x")
        let m = make(job)
        await m.run() // failed and never succeeded: due immediately
        XCTAssertLessThanOrEqual(m.nextRun?.timeIntervalSinceNow ?? 1, 0)
        render(bar(m))
    }

    func testRendersWhileRunning() async throws {
        let job = FakeJob()
        let m = make(job)
        var release: CheckedContinuation<Void, Never>?
        job.action = { run in
            run.onStep?("brew update")
            await withCheckedContinuation { release = $0 }
        }
        let task = Task { await m.run() }
        await assertEventually { release != nil }
        XCTAssertTrue(m.isRunning)
        render(bar(m))
        release?.resume()
        await task.value
        XCTAssertFalse(m.isRunning)
    }
}
