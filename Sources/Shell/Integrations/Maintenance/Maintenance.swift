import AppKit
import Observation

enum AutoUpdateSchedule: String, Codable, CaseIterable, Identifiable {
    case off, daily, weekly, monthly
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        case .monthly: 30 * 24 * 3600
        }
    }
}

struct MaintenanceRecord: Codable, Equatable {
    enum Outcome: String, Codable { case success, failed, cancelled }
    var startedAt: Date
    var finishedAt: Date
    var outcome: Outcome
    var failedStep: String?
    /// Human-readable changes, e.g. "jq" or "node v24.20.0 → v24.21.0".
    var changes: [String]
    /// Issues found (doctor output, health checks, non-fatal step failures).
    var warnings: [String]
    var logPath: String
    /// One-line result, e.g. "freed 3.2 GB".
    var summary: String? = nil
}

/// One execution of a maintenance job: runs commands, streams their output
/// to a log file, and tracks cancellation.
@MainActor
final class MaintenanceRun {
    let logURL: URL
    private let log: FileHandle?
    private(set) var cancelled = false
    private var process: Process?
    var onStep: ((String) -> Void)?

    init(jobID: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        logURL = ScheduledMaintenance.logDirectory.appendingPathComponent("\(jobID)-\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try? FileHandle(forWritingTo: logURL)
    }

    func note(_ line: String) {
        // The throwing API: the legacy write(_:) raises an uncatchable
        // Objective-C exception on a full disk or a vanished volume.
        try? log?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Runs a command, appending its output to the log. Returns the exit
    /// status and the output it produced.
    /// Test hook: SHELL_APP_DRY_RUN=1 logs commands instead of running them.
    static let dryRun = ProcessInfo.processInfo.environment["SHELL_APP_DRY_RUN"] != nil

    func step(_ title: String, _ executable: String, _ args: [String], env: [String: String] = [:]) async -> (status: Int32, output: String) {
        guard !cancelled else { return (-1, "") }
        if Self.dryRun {
            onStep?(title)
            note("\n$ \(title)\n[dry run] \(executable) \(args.joined(separator: " "))")
            return (0, "")
        }
        onStep?(title)
        note("\n$ \(title)")
        let start = (try? log?.offset()) ?? 0
        let status: Int32 = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            var e = ProcessInfo.processInfo.environment
            e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            e["NONINTERACTIVE"] = "1"
            e["CI"] = "1" // keeps npm/pnpm from prompting or drawing progress bars
            for (k, v) in env { e[k] = v }
            p.environment = e
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = log ?? FileHandle.nullDevice
            p.standardError = log ?? FileHandle.nullDevice
            p.qualityOfService = .utility
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do {
                try p.run()
                process = p
            } catch {
                note("failed to launch \(executable): \(error.localizedDescription)")
                cont.resume(returning: -1)
            }
        }
        process = nil
        var output = ""
        if let h = try? FileHandle(forReadingFrom: logURL) {
            try? h.seek(toOffset: start)
            output = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
            try? h.close()
        }
        if status != 0 { note("(exit \(status))") }
        return (status, output)
    }

    func cancel() {
        cancelled = true
        process?.interrupt()
    }

    func close() { try? log?.close() }
}

struct MaintenanceOutcome {
    var failedStep: String?
    var changes: [String] = []
    var warnings: [String] = []
    var summary: String?
}

@MainActor
protocol MaintenanceJob: AnyObject {
    var id: String { get }
    var title: String { get }
    var isAvailable: Bool { get }
    var schedule: AutoUpdateSchedule { get }
    /// A short description of what runs, for tooltips.
    var summary: String { get }
    func perform(_ run: MaintenanceRun) async -> MaintenanceOutcome
    func notification(for record: MaintenanceRecord) -> (title: String, body: String)?
    func didFinish() async
}

/// Schedules a maintenance job while Shell is open: checks every 30 minutes
/// and after wake, catches up after launch, retries failed runs hourly, and
/// skips runs in Low Power Mode.
@MainActor
@Observable
final class ScheduledMaintenance {
    static let homebrew = ScheduledMaintenance(job: HomebrewMaintenanceJob())
    static let node = ScheduledMaintenance(job: NodeMaintenanceJob())
    static let worktrees = ScheduledMaintenance(job: WorktreeCleanupJob())
    static let agentStorage = ScheduledMaintenance(job: AgentStorageCleanupJob())
    static var all: [ScheduledMaintenance] { [homebrew, node, worktrees, agentStorage] }

    private struct State: Codable {
        var lastSuccess: Date?
        var lastAttempt: Date?
        var lastRun: MaintenanceRecord?
    }

    let job: MaintenanceJob
    private(set) var isRunning = false
    private(set) var currentStep: String?
    private(set) var lastRun: MaintenanceRecord?
    private(set) var lastSuccess: Date?

    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activeRun: MaintenanceRun?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Posts the job's notification; replaceable in unit tests.
    @ObservationIgnored var notify: @MainActor (_ title: String, _ body: String, _ pane: SettingsPane) -> Void = { title, body, pane in
        NotificationManager.shared.postAppNotification(title: title, body: body, pane: pane)
    }

    static let retryAfterFailure: TimeInterval = 3600

    /// ~/Library/Logs/Shell. Unit tests log into their throwaway support
    /// folder instead, so they never write to the real one.
    static var logDirectory: URL {
        let url = AppEnvironment.isRunningTests
            ? SettingsStore.supportDirectory.appendingPathComponent("Logs", isDirectory: true)
            : FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Shell", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var stateURL: URL { SettingsStore.supportDirectory.appendingPathComponent("maintenance-\(job.id).json") }

    init(job: MaintenanceJob) {
        self.job = job
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            lastSuccess = s.lastSuccess
            lastAttempt = s.lastAttempt
            lastRun = s.lastRun
        }
    }

    var schedule: AutoUpdateSchedule { job.schedule }

    var nextRun: Date? {
        guard let interval = schedule.interval else { return nil }
        guard let lastSuccess else { return Date() }
        var next = lastSuccess.addingTimeInterval(interval)
        if let lastAttempt, lastAttempt > lastSuccess {
            next = max(next, lastAttempt.addingTimeInterval(Self.retryAfterFailure))
        }
        return next
    }

    static func configureAll() { all.forEach { $0.configure() } }

    func configure() {
        timer?.invalidate()
        timer = nil
        guard schedule != .off else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runIfDue() }
        }
        timer?.tolerance = 5 * 60
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    MainActor.assumeIsolated { self?.runIfDue() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            MainActor.assumeIsolated { self?.runIfDue() }
        }
    }

    func runIfDue() {
        guard schedule != .off, !isRunning, job.isAvailable,
              let next = nextRun, next <= Date(),
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        // Don't run two jobs at once; they compete for network and CPU.
        guard !Self.all.contains(where: { $0 !== self && $0.isRunning }) else { return }
        Task { await run() }
    }

    func run() async {
        guard !isRunning, job.isAvailable else { return }
        isRunning = true
        let started = Date()
        lastAttempt = started
        persist()

        let run = MaintenanceRun(jobID: job.id)
        run.onStep = { [weak self] s in self?.currentStep = s }
        activeRun = run
        let result = await job.perform(run)
        run.close()

        let outcome: MaintenanceRecord.Outcome = run.cancelled ? .cancelled : result.failedStep == nil ? .success : .failed
        let record = MaintenanceRecord(startedAt: started, finishedAt: Date(), outcome: outcome, failedStep: result.failedStep,
                                       changes: outcome == .success ? result.changes : [], warnings: result.warnings,
                                       logPath: run.logURL.path, summary: result.summary)
        lastRun = record
        if outcome == .success { lastSuccess = started }
        isRunning = false
        currentStep = nil
        activeRun = nil
        persist()
        pruneLogs()
        if let n = job.notification(for: record) {
            notify(n.title, n.body, SettingsPane(rawValue: job.id) ?? .homebrew)
        }
        await job.didFinish()
    }

    func cancel() { activeRun?.cancel() }

    private func persist() {
        let s = State(lastSuccess: lastSuccess, lastAttempt: lastAttempt, lastRun: lastRun)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func pruneLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.logDirectory, includingPropertiesForKeys: nil) else { return }
        let logs = files.filter { $0.lastPathComponent.hasPrefix("\(job.id)-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in logs.dropFirst(20) { try? fm.removeItem(at: old) }
    }
}

// MARK: - Homebrew job

/// `brew update && brew upgrade && brew doctor`
@MainActor
final class HomebrewMaintenanceJob: MaintenanceJob {
    let id = "homebrew"
    let title = "Homebrew"
    let summary = "Runs brew update && brew upgrade && brew doctor in the background while Shell is open"
    /// Injectable for unit tests.
    let brew: BrewService

    init(brew: BrewService = .shared) { self.brew = brew }

    var isAvailable: Bool {
        brew.detect()
        return brew.isInstalled
    }
    var schedule: AutoUpdateSchedule { SettingsStore.shared.settings.brewAutoUpdate }

    func perform(_ run: MaintenanceRun) async -> MaintenanceOutcome {
        guard let brew = brew.brewPath else { return MaintenanceOutcome(failedStep: "find brew") }
        let env = ["PATH": "\((brew as NSString).deletingLastPathComponent):/usr/bin:/bin:/usr/sbin:/sbin",
                   "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_AUTO_UPDATE": "1"]
        var out = MaintenanceOutcome()
        if await run.step("brew update", brew, ["update"], env: env).status != 0 {
            out.failedStep = "brew update"
            return out
        }
        let outdated = await ProcessRunner.run(brew, ["outdated", "--json=v2"], environment: env)
        let names = BrewService.parseOutdated(outdated.stdout)
        if await run.step("brew upgrade", brew, ["upgrade"], env: env).status != 0 {
            out.failedStep = "brew upgrade"
            return out
        }
        out.changes = names
        // doctor exits non-zero when it has warnings; that's a report, not a failure.
        let doctor = await run.step("brew doctor", brew, ["doctor"], env: env)
        out.warnings = doctor.output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("Warning:") }
            .map { String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        return out
    }

    func notification(for r: MaintenanceRecord) -> (title: String, body: String)? {
        switch r.outcome {
        case .success where !r.changes.isEmpty:
            let list = r.changes.prefix(6).joined(separator: ", ") + (r.changes.count > 6 ? " +\(r.changes.count - 6) more" : "")
            let doctor = r.warnings.isEmpty ? "" : " · brew doctor: \(r.warnings.count) warning\(r.warnings.count == 1 ? "" : "s")"
            return ("Homebrew upgraded \(r.changes.count) package\(r.changes.count == 1 ? "" : "s")", list + doctor)
        case .failed:
            return ("Homebrew auto-update failed", "\(r.failedStep ?? "brew") didn't finish. Shell will retry in an hour — open the log for details.")
        default:
            return nil
        }
    }

    func didFinish() async { await brew.refresh() }
}
