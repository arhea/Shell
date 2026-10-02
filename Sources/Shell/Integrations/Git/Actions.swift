import AppKit
import Observation

/// A GitHub Actions workflow run (`gh run list`).
struct WorkflowRun: Identifiable, Equatable {
    enum State: Equatable { case queued, running, success, failure, cancelled, skipped, neutral }

    var id: Int
    var number: Int
    var title: String
    var workflow: String
    var status: String
    var conclusion: String
    var branch: String
    var event: String
    var attempt: Int
    var url: URL
    var createdAt: Date?
    var startedAt: Date?
    var updatedAt: Date?

    var state: State { Self.state(status: status, conclusion: conclusion) }
    var isActive: Bool { state == .queued || state == .running }

    static func state(status: String, conclusion: String) -> State {
        switch status.lowercased() {
        case "queued", "waiting", "pending", "requested": return .queued
        case "in_progress": return .running
        default: break
        }
        switch conclusion.lowercased() {
        case "success": return .success
        case "failure", "timed_out", "startup_failure", "action_required": return .failure
        case "cancelled": return .cancelled
        case "skipped": return .skipped
        default: return .neutral
        }
    }

    /// Elapsed time for running runs, duration for finished ones.
    var duration: TimeInterval? {
        guard let start = startedAt ?? createdAt else { return nil }
        return (isActive ? Date() : (updatedAt ?? Date())).timeIntervalSince(start)
    }

    static func parse(_ o: [String: Any]) -> WorkflowRun? {
        guard let id = o["databaseId"] as? Int, let url = (o["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let iso = ISO8601DateFormatter()
        func date(_ k: String) -> Date? { (o[k] as? String).flatMap { iso.date(from: $0) } }
        return WorkflowRun(
            id: id, number: o["number"] as? Int ?? 0, title: o["displayTitle"] as? String ?? "",
            workflow: o["workflowName"] as? String ?? "", status: o["status"] as? String ?? "",
            conclusion: o["conclusion"] as? String ?? "", branch: o["headBranch"] as? String ?? "",
            event: o["event"] as? String ?? "", attempt: o["attempt"] as? Int ?? 1, url: url,
            createdAt: date("createdAt"), startedAt: date("startedAt"), updatedAt: date("updatedAt"))
    }
}

struct WorkflowJob: Identifiable, Equatable {
    var name: String
    var status: String
    var conclusion: String
    var url: URL?
    var startedAt: Date?
    var completedAt: Date?
    var id: String { name + (url?.absoluteString ?? "") }
    var state: WorkflowRun.State { WorkflowRun.state(status: status, conclusion: conclusion) }
}

/// Recent workflow runs for the sidebar's repository. Polls every 10 seconds
/// while any run is queued or running (and the Actions view is on screen).
@MainActor
@Observable
final class ActionsModel {
    enum Scope: String { case all, branch }

    let repoRoot: String
    private(set) var runs: [WorkflowRun] = []
    private(set) var jobs: [Int: [WorkflowJob]] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var busy: Set<Int> = []
    var message: String?
    /// Runs whose jobs are shown (and polled while running).
    var expanded: Set<Int> = []

    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0
    /// Set while the window is minimized, covered or on another Space: no
    /// polling then, and one catch-up load when it's visible again.
    @ObservationIgnored var isPaused = false {
        didSet {
            guard isPaused != oldValue, viewers > 0 else { return }
            if isPaused {
                pollTask?.cancel()
                pollTask = nil
            } else {
                startPolling()
            }
        }
    }
    @ObservationIgnored var branch: String?

    init(repoRoot: String, environment: [String: String]) {
        self.repoRoot = repoRoot
        self.environment = environment
    }

    var scope: Scope {
        get { Scope(rawValue: SettingsStore.shared.settings.actionsScope) ?? .all }
        set {
            SettingsStore.shared.settings.actionsScope = newValue.rawValue
            refresh()
        }
    }

    var activeCount: Int { runs.filter(\.isActive).count }

    // MARK: Polling

    /// Called when an Actions view appears/disappears; polling runs only while visible.
    func attach() {
        viewers += 1
        if viewers == 1, !isPaused { startPolling() }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.load()
            while !Task.isCancelled {
                // Running work updates every 10s; otherwise check back each minute.
                // `self` is re-read after each sleep so the loop never keeps the model alive.
                guard let active = self?.runs.contains(where: \.isActive) else { return }
                try? await Task.sleep(for: .seconds(active ? 10 : 60))
                guard !Task.isCancelled, let model = self else { return }
                await model.load()
            }
        }
    }

    func refresh() { Task { await load() } }

    private func load() async {
        guard let gh = GitRepository.findExecutable("gh", environment: environment) else {
            error = "Install the GitHub CLI (`brew install gh`) and run `gh auth login` to see Actions."
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var args = ["run", "list", "--limit", "30", "--json",
                    "databaseId,number,displayTitle,workflowName,status,conclusion,headBranch,event,attempt,url,createdAt,startedAt,updatedAt"]
        if scope == .branch, let branch { args += ["--branch", branch] }
        guard let out = await GitRepository.run(gh, args, in: repoRoot, environment: environment),
              let data = out.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            error = "Couldn't load workflow runs (is `gh auth login` done, and are Actions enabled?)"
            return
        }
        error = nil
        let parsed = list.compactMap(WorkflowRun.parse)
        if parsed != runs { runs = parsed }
        lastUpdated = Date()
        // Jobs for expanded runs: always on first expand, then only while running.
        for id in expanded {
            guard let run = runs.first(where: { $0.id == id }) else { continue }
            if run.isActive || jobs[id] == nil || jobs[id]?.contains(where: { $0.state == .running || $0.state == .queued }) == true {
                await loadJobs(id, gh: gh)
            }
        }
    }

    func toggle(_ run: WorkflowRun) {
        if expanded.contains(run.id) {
            expanded.remove(run.id)
        } else {
            expanded.insert(run.id)
            if let gh = GitRepository.findExecutable("gh", environment: environment) {
                Task { await loadJobs(run.id, gh: gh) }
            }
        }
    }

    private func loadJobs(_ id: Int, gh: String) async {
        guard let out = await GitRepository.run(gh, ["run", "view", "\(id)", "--json", "jobs"], in: repoRoot, environment: environment),
              let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let iso = ISO8601DateFormatter()
        let list = (obj["jobs"] as? [[String: Any]] ?? []).map { j in
            WorkflowJob(name: j["name"] as? String ?? "", status: j["status"] as? String ?? "", conclusion: j["conclusion"] as? String ?? "",
                        url: (j["url"] as? String).flatMap(URL.init(string:)),
                        startedAt: (j["startedAt"] as? String).flatMap { iso.date(from: $0) },
                        completedAt: (j["completedAt"] as? String).flatMap { iso.date(from: $0) })
        }
        if jobs[id] != list { jobs[id] = list }
    }

    // MARK: Actions

    /// `gh run rerun --failed` or `gh run cancel`.
    func perform(_ run: WorkflowRun, _ action: String) {
        guard let gh = GitRepository.findExecutable("gh", environment: environment) else { return }
        busy.insert(run.id)
        let args: [String] = action == "cancel" ? ["run", "cancel", "\(run.id)"] : ["run", "rerun", "\(run.id)", "--failed"]
        Task {
            defer { busy.remove(run.id) }
            if let err = await WorktreeService.runReportingError(gh, args, in: repoRoot, environment: environment) {
                message = err
            }
            try? await Task.sleep(for: AppEnvironment.wait(.seconds(2)))
            await load()
        }
    }
}
