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
    let repository: GitRepository
    private(set) var snapshot: BranchChecksSnapshot?
    private(set) var isLoading = false
    private(set) var error: String?
    /// When on, a newly failed job sends its log to the session's Claude.
    var sendFailuresToClaude = false
    /// Called with each job that newly fails (state changed to `.failed`).
    var onNewFailure: ((CheckJob) -> Void)?

    init(repository: GitRepository) {
        self.repository = repository
    }

    private static var models: [URL: BranchChecksModel] = [:]

    /// The shared model for a repository (one per worktree root).
    static func shared(for repository: GitRepository) -> BranchChecksModel {
        if let model = models[repository.root] { return model }
        let model = BranchChecksModel(repository: repository)
        models[repository.root] = model
        return model
    }

    func refresh() {}
    func stop() {}
    func rerunFailed() async {}
    func rerun(_ job: CheckJob) async {}
    /// The failing log lines for a job (`gh run view --log-failed`), trimmed
    /// to a size that's useful as Claude context.
    func failedLog(for job: CheckJob) async -> String { "" }
}
