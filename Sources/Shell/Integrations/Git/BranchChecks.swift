import Foundation
import Observation

/// One CI job (a GitHub Actions job or a status context) on a branch's PR.
struct CheckJob: Identifiable, Hashable, Sendable {
    enum State: String, Sendable {
        case queued, running, passed, failed, skipped, cancelled

        var isFinished: Bool { self != .queued && self != .running }
    }

    struct Step: Hashable, Sendable {
        var name: String
        var state: State
        var duration: TimeInterval?
    }

    /// Stable within a snapshot: the job's database id, or the context name.
    var id: String
    /// "Build and test", "Lint / swiftlint".
    var name: String
    /// Workflow name and file, e.g. "Test · test.yml", when known.
    var workflow: String?
    var state: State
    var duration: TimeInterval?
    /// One-line detail: the failing step, an error line, "Running · step 3 of 5".
    var detail: String?
    var url: URL?
    /// Actions run id, for re-runs and logs. Nil for external status contexts.
    var runID: Int?
    /// Actions job id, for `gh run view --job <id> --log-failed`.
    var jobID: Int?
    var steps: [Step] = []
}

/// The checks on the PR for a branch at one point in time.
struct BranchChecksSnapshot: Equatable, Sendable {
    var branch: String
    var prNumber: Int?
    var prURL: URL?
    var headSHA: String?
    var updatedAt: Date
    var jobs: [CheckJob]

    var failing: [CheckJob] { jobs.filter { $0.state == .failed } }
    var running: [CheckJob] { jobs.filter { $0.state == .running || $0.state == .queued } }
    var passed: [CheckJob] { jobs.filter { $0.state == .passed } }
    var skipped: [CheckJob] { jobs.filter { $0.state == .skipped || $0.state == .cancelled } }

    /// Worst state across jobs, for a single capsule.
    var overall: CheckJob.State? {
        if jobs.isEmpty { return nil }
        if !failing.isEmpty { return .failed }
        if !running.isEmpty { return .running }
        return .passed
    }

    /// "1 check failing", "2 running", "5 passed".
    var summary: String {
        if !failing.isEmpty { return failing.count == 1 ? "1 check failing" : "\(failing.count) checks failing" }
        if !running.isEmpty { return "\(running.count) running" }
        return jobs.isEmpty ? "No checks" : "\(passed.count) passed"
    }
}

/// Live checks for the branch a session is on. One model per repository root
/// and branch, shared by every view that shows it (toolbar capsule, Checks
/// inspector, transcript failure card, terminal prompt chip), so `gh` runs
/// once however many views are open.
///
/// Polls only while a run is active (every 10 s), plus on `refresh()`.
@MainActor
@Observable
final class BranchChecksModel {
    private(set) var repository: GitRepository
    private(set) var snapshot: BranchChecksSnapshot?
    private(set) var isLoading = false
    private(set) var error: String?
    /// Jobs with a re-run in flight.
    private(set) var rerunning: Set<String> = []
    /// When on, a newly failed job sends its log to the session's Claude.
    var sendFailuresToClaude: Bool {
        get { SettingsStore.shared.settings.sendCheckFailuresToClaude }
        set { SettingsStore.shared.settings.sendCheckFailuresToClaude = newValue }
    }
    /// Called with each job that newly fails while Shell is watching (not for
    /// failures that were already there on the first load). Keyed by the
    /// observer, so several sessions on one branch each hear about it.
    @ObservationIgnored private var failureObservers: [ObjectIdentifier: (CheckJob) -> Void] = [:]

    /// Starts watching (as `start()`) and calls `handler` for new failures
    /// until `removeFailureObserver(_:)`.
    func addFailureObserver(_ owner: AnyObject, _ handler: @escaping (CheckJob) -> Void) {
        failureObservers[ObjectIdentifier(owner)] = handler
        start()
    }

    func removeFailureObserver(_ owner: AnyObject) {
        guard failureObservers.removeValue(forKey: ObjectIdentifier(owner)) != nil else { return }
        stop()
    }

    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var users = 0

    /// Seconds between polls while a run is active.
    static let pollInterval: TimeInterval = 10

    init(repository: GitRepository) {
        self.repository = repository
    }

    private static var models: [URL: BranchChecksModel] = [:]

    /// The shared model for a repository (one per worktree root).
    static func shared(for repository: GitRepository) -> BranchChecksModel {
        if let model = models[repository.root] {
            // A new instance for the same root means the old one was stopped
            // (every holder left, then one came back). Rebind, keeping the
            // watchers and failure observers, so checks follow the live branch.
            if model.repository !== repository {
                model.repository = repository
                if model.users > 0 { model.refresh(force: true) }
            }
            return model
        }
        let model = BranchChecksModel(repository: repository)
        models[repository.root] = model
        return model
    }

    /// Views call `start()` on appear and `stop()` on disappear; polling runs
    /// while anyone is watching.
    func start() {
        users += 1
        refresh()
    }

    func stop() {
        users = max(0, users - 1)
        if users == 0 { pollTask?.cancel(); pollTask = nil }
    }

    /// Loads now, unless a load finished in the last few seconds.
    func refresh(force: Bool = false) {
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < 4 { return }
        Task { await load() }
    }

    private var gh: String? { GitRepository.findExecutable("gh", environment: repository.environment) }

    private func load() async {
        guard !isLoading else { return }
        guard repository.github != nil, let branch = repository.status.branch, !repository.status.detached else {
            if snapshot != nil { snapshot = nil }
            return
        }
        guard let gh else {
            error = "Install the GitHub CLI (`brew install gh`) and run `gh auth login` to see checks."
            return
        }
        isLoading = true
        defer { isLoading = false; refreshedAt = Date() }
        let dir = repository.root.path, env = repository.environment
        guard let out = await GitRepository.run(gh, ["pr", "view", branch, "--json", "number,url,headRefOid,statusCheckRollup"],
                                                in: dir, environment: env) else {
            // No PR for this branch (or gh isn't signed in): nothing to show.
            error = nil
            if snapshot != nil { snapshot = nil }
            return
        }
        guard var next = Self.parse(prView: out, branch: branch) else { return }
        // Steps for failing and running Actions jobs (one API call each).
        if let remote = repository.github {
            for i in next.jobs.indices where next.jobs[i].state == .failed || next.jobs[i].state == .running {
                guard let id = next.jobs[i].jobID else { continue }
                if let json = await GitRepository.run(gh, ["api", "repos/\(remote.owner)/\(remote.name)/actions/jobs/\(id)"], in: dir, environment: env) {
                    Self.applySteps(json, to: &next.jobs[i])
                }
            }
        }
        guard repository.status.branch == branch else { return }
        let previous = snapshot
        error = nil
        if next.jobs != previous?.jobs || next.headSHA != previous?.headSHA || next.prNumber != previous?.prNumber {
            snapshot = next
        }
        if let previous {
            let before = Dictionary(previous.jobs.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            for job in next.jobs where job.state == .failed && before[job.id] != .failed {
                for handler in failureObservers.values { handler(job) }
            }
        }
        schedulePoll(active: !next.running.isEmpty)
    }

    private func schedulePoll(active: Bool) {
        pollTask?.cancel()
        guard active, users > 0 else { pollTask = nil; return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pollInterval))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    // MARK: Actions

    /// `gh run rerun <run> --failed` for every run with a failing job.
    func rerunFailed() async {
        guard let gh, let snapshot else { return }
        let runs = Set(snapshot.failing.compactMap(\.runID))
        rerunning.formUnion(snapshot.failing.map(\.id))
        for run in runs {
            if let err = await WorktreeService.runReportingError(gh, ["run", "rerun", "\(run)", "--failed"], in: repository.root.path,
                                                                 environment: repository.environment) {
                error = err
            }
        }
        await afterRerun()
    }

    /// `gh run rerun --job <id>` for one job.
    func rerun(_ job: CheckJob) async {
        guard let gh, let jobID = job.jobID else { return }
        rerunning.insert(job.id)
        if let err = await WorktreeService.runReportingError(gh, ["run", "rerun", "--job", "\(jobID)"], in: repository.root.path,
                                                             environment: repository.environment) {
            error = err
        }
        await afterRerun()
    }

    private func afterRerun() async {
        try? await Task.sleep(for: AppEnvironment.wait(.seconds(2)))
        rerunning.removeAll()
        refreshedAt = nil
        await load()
    }

    /// The failing log lines for a job (`gh run view --log-failed`), trimmed
    /// to a size that's useful as Claude context.
    func failedLog(for job: CheckJob) async -> String {
        guard let gh, let runID = job.runID else { return "" }
        var args = ["run", "view", "\(runID)", "--log-failed"]
        if let jobID = job.jobID { args += ["--job", "\(jobID)"] }
        guard let out = await GitRepository.run(gh, args, in: repository.root.path, environment: repository.environment) else { return "" }
        return Self.trimLog(out)
    }

    // MARK: Parsing (static for tests)

    /// Parses `gh pr view --json number,url,headRefOid,statusCheckRollup`.
    nonisolated static func parse(prView json: String, branch: String, now: Date = Date()) -> BranchChecksSnapshot? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let items = obj["statusCheckRollup"] as? [[String: Any]] ?? []
        var jobs = items.compactMap(parseCheck)
        // Failing first, then running, then the rest; stable by name.
        func rank(_ s: CheckJob.State) -> Int {
            switch s {
            case .failed: 0
            case .running, .queued: 1
            case .passed: 2
            case .skipped, .cancelled: 3
            }
        }
        jobs.sort { (rank($0.state), $0.name) < (rank($1.state), $1.name) }
        return BranchChecksSnapshot(
            branch: branch, prNumber: obj["number"] as? Int,
            prURL: (obj["url"] as? String).flatMap(URL.init(string:)),
            headSHA: obj["headRefOid"] as? String, updatedAt: now, jobs: jobs)
    }

    nonisolated static func parseCheck(_ c: [String: Any]) -> CheckJob? {
        let iso = ISO8601DateFormatter()
        func date(_ key: String) -> Date? { (c[key] as? String).flatMap { iso.date(from: $0) } }
        if let name = c["name"] as? String { // CheckRun
            let status = (c["status"] as? String ?? "").uppercased()
            let conclusion = (c["conclusion"] as? String ?? "").uppercased()
            let state: CheckJob.State
            switch (status, conclusion) {
            case (_, "FAILURE"), (_, "TIMED_OUT"), (_, "STARTUP_FAILURE"), (_, "ACTION_REQUIRED"): state = .failed
            case (_, "CANCELLED"): state = .cancelled
            case (_, "SKIPPED"), (_, "NEUTRAL"): state = .skipped
            case ("COMPLETED", _): state = .passed
            case ("QUEUED", _), ("PENDING", _), ("WAITING", _), ("REQUESTED", _): state = .queued
            default: state = .running
            }
            let url = (c["detailsUrl"] as? String).flatMap(URL.init(string:))
            let ids: (run: Int?, job: Int?) = url.map { actionsIDs(from: $0) } ?? (nil, nil)
            let started = date("startedAt"), completed = date("completedAt")
            let workflow = (c["workflowName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CheckJob(
                id: ids.job.map(String.init) ?? "\(workflow ?? "")/\(name)", name: name, workflow: workflow, state: state,
                duration: started.map { (completed ?? Date()).timeIntervalSince($0) }.flatMap { $0 >= 0 ? $0 : nil },
                detail: nil, url: url, runID: ids.run, jobID: ids.job)
        }
        if let context = c["context"] as? String { // StatusContext
            let raw = (c["state"] as? String ?? "").uppercased()
            let state: CheckJob.State = switch raw {
            case "SUCCESS": .passed
            case "FAILURE", "ERROR": .failed
            default: .running
            }
            return CheckJob(id: "status/\(context)", name: context, workflow: nil, state: state, duration: nil,
                            detail: (c["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            url: (c["targetUrl"] as? String).flatMap(URL.init(string:)), runID: nil, jobID: nil)
        }
        return nil
    }

    /// Run and job ids from an Actions URL: `…/actions/runs/123/job/456`.
    nonisolated static func actionsIDs(from url: URL) -> (run: Int?, job: Int?) {
        let parts = url.pathComponents
        func after(_ key: String) -> Int? {
            guard let i = parts.firstIndex(of: key), i + 1 < parts.count else { return nil }
            return Int(parts[i + 1])
        }
        return (after("runs"), after("job"))
    }

    /// Adds steps and a one-line detail from `gh api repos/…/actions/jobs/<id>`.
    nonisolated static func applySteps(_ json: String, to job: inout CheckJob) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = obj["steps"] as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        job.steps = steps.map { s in
            let status = (s["status"] as? String ?? "").lowercased()
            let conclusion = (s["conclusion"] as? String ?? "").lowercased()
            let state: CheckJob.State = switch (status, conclusion) {
            case (_, "failure"), (_, "timed_out"): .failed
            case (_, "skipped"): .skipped
            case (_, "cancelled"): .cancelled
            case ("completed", _): .passed
            case ("queued", _), ("pending", _), ("waiting", _): .queued
            default: .running
            }
            let start = (s["started_at"] as? String).flatMap { iso.date(from: $0) }
            let end = (s["completed_at"] as? String).flatMap { iso.date(from: $0) }
            return CheckJob.Step(name: s["name"] as? String ?? "", state: state,
                                 duration: start.flatMap { st in end.map { $0.timeIntervalSince(st) } })
        }
        if let failed = job.steps.first(where: { $0.state == .failed }) {
            job.detail = "Failed at step \(failed.name)"
        } else if job.state == .running, let index = job.steps.firstIndex(where: { $0.state == .running }) {
            job.detail = "Running · step \(index + 1) of \(job.steps.count)"
        }
        if let wf = obj["workflow_name"] as? String, !wf.isEmpty, job.workflow == nil { job.workflow = wf }
    }

    /// Strips the "job<TAB>step<TAB>timestamp " prefix `--log-failed` puts on
    /// every line, drops ANSI escapes and keeps the last `maxLines` lines.
    nonisolated static func trimLog(_ raw: String, maxLines: Int = 200, maxCharacters: Int = 20_000) -> String {
        var lines: [Substring] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = line
            let fields = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 3 { text = fields[2] }
            // ISO timestamp prefix: 2026-10-01T15:30:00.1234567Z
            if text.count > 29, text.dropFirst(4).first == "-", text.dropFirst(10).first == "T",
               let z = text.prefix(32).firstIndex(of: "Z") {
                text = text[text.index(after: z)...].drop(while: { $0 == " " })
            }
            lines.append(text)
        }
        var out = lines.suffix(maxLines).joined(separator: "\n")
        out = out.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        if out.count > maxCharacters { out = String(out.suffix(maxCharacters)) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
