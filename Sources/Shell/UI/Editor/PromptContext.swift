import AppKit
import Observation

/// What the prompt's chips show beyond the session's own state: the git
/// repository (dirty count, pull request, checks) and the runtime version
/// for the current directory.
///
/// Updated only when the shell reaches a prompt in a new directory, never per
/// keystroke; discovery and `node --version` run in the background.
@MainActor
@Observable
final class PromptContextModel {
    private(set) var repository: GitRepository?
    private(set) var runtime: String?
    /// Checks for the branch's pull request, while the pane is in a window.
    private(set) var checks: BranchChecksModel?

    @ObservationIgnored private var directory: String?
    @ObservationIgnored private var discovering: String?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var checksStarted: BranchChecksModel?
    @ObservationIgnored private var generation = 0

    /// Call when the shell is at a prompt in `directory`.
    func update(directory: String?) {
        guard active, let directory else { return }
        let changed = directory != self.directory
        self.directory = directory
        updateRuntime(directory)
        if let repo = repository, directory == repo.root.path || directory.hasPrefix(repo.root.path + "/") {
            // Same repository (its own watcher keeps status current); the branch
            // may have changed or gained a PR.
            repo.refreshPullRequest()
            updateChecks()
            return
        }
        guard changed, discovering != directory else { return }
        discovering = directory
        generation += 1
        let gen = generation
        Task { [weak self] in
            let repo = await GitRepository.discover(from: directory, environment: MCPManager.defaultEnvironment())
            guard let self, active, gen == generation else { repo?.stop(); return }
            discovering = nil
            setRepository(repo)
        }
    }

    private func updateRuntime(_ directory: String) {
        if let cached = RuntimeDetector.shared.cachedLabel(for: directory) {
            if runtime != cached { runtime = cached }
            return
        }
        Task { [weak self] in
            let label = await RuntimeDetector.shared.label(for: directory, environment: MCPManager.defaultEnvironment())
            guard let self, self.directory == directory, runtime != label else { return }
            runtime = label
        }
    }

    private func setRepository(_ repo: GitRepository?) {
        repository?.stop()
        repository = repo
        updateChecks()
        observePullRequest()
    }

    /// The PR lookup finishes after discovery; start checks when it lands.
    private func observePullRequest() {
        guard let repo = repository else { return }
        withObservationTracking {
            _ = repo.pullRequest
            _ = repo.github
        } onChange: { [weak self, weak repo] in
            Task { @MainActor in
                guard let self, let repo, self.repository === repo else { return }
                self.updateChecks()
                self.observePullRequest()
            }
        }
    }

    /// Starts watching checks once the branch has a pull request.
    func updateChecks() {
        let wanted = repository.flatMap { $0.github != nil && $0.pullRequest != nil ? BranchChecksModel.shared(for: $0) : nil }
        guard wanted !== checksStarted else { return }
        checksStarted?.stop()
        checksStarted = wanted
        wanted?.start()
        checks = wanted
    }

    /// The pane joined a window: start following its directory.
    func activate(directory: String?) {
        guard !active else { return }
        active = true
        update(directory: directory)
    }

    /// The pane left its window: release the repository and stop polling.
    func deactivate() {
        guard active else { return }
        active = false
        generation += 1
        discovering = nil
        directory = nil
        checksStarted?.stop()
        checksStarted = nil
        checks = nil
        repository?.stop()
        repository = nil
    }
}
