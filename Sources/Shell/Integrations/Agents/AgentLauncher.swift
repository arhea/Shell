import AppKit

/// The coding agent the prompt's launch button starts.
enum CodingAgent: String, Codable, CaseIterable, Identifiable {
    case claude
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        }
    }

    /// The command line that starts the agent with a session name and,
    /// when set, a permission mode.
    func command(name: String, permissionMode: String? = nil) -> String {
        switch self {
        case .claude:
            "claude -n \(AgentLauncher.shellQuote(name))"
                + (permissionMode.map { $0.isEmpty ? "" : " --permission-mode \(AgentLauncher.shellQuote($0))" } ?? "")
        }
    }
}

/// Starts the default agent: in the current pane, or in a new tab in a
/// new git worktree (under the configured worktree folder) branched from the
/// repository's default branch.
@MainActor
enum AgentLauncher {
    enum Mode: Equatable {
        case here
        case worktree
        /// A new branch with this name off the default branch.
        case newBranch(String)
        /// An existing branch; `remote` is set when only `remote/name` exists.
        case existingBranch(name: String, remote: String?)
    }

    /// What a new tab should run, and where.
    struct Plan: Equatable {
        var directory: String
        var command: String
        var name: String
    }

    /// Facts about the repository gathered before building the command.
    struct RepoInfo: Equatable {
        /// Top level of the checkout the pane is in (a worktree or the main checkout).
        var toplevel: String
        /// The main checkout's folder name (the repo name, even from inside a worktree).
        var repoName: String
        /// e.g. ("origin", "main"); remote is nil when the base is a local branch.
        var baseRemote: String?
        var baseBranch: String
    }

    enum LaunchError: LocalizedError {
        case notARepository
        case invalidBranch(String)
        case git(String)

        var errorDescription: String? {
            switch self {
            case .notARepository: "Worktrees need a git repository"
            case .invalidBranch(let s): "\"\(s)\" isn't a valid branch name"
            case .git(let s): s
            }
        }
    }

    // MARK: Launch

    /// Starts the agent here, or in a new tab for a worktree. Calls `report` with progress
    /// or an error for the pane that asked. `open` replaces opening the new tab
    /// in the session's window (for unit tests).
    static func start(_ mode: Mode, from session: TerminalSession, report: @escaping (String, Bool) -> Void,
                      open opener: ((Plan) -> Void)? = nil) {
        let openPlan: (Plan) -> Void
        if let opener {
            openPlan = opener
        } else {
            guard let controller = controller(for: session) else { return }
            openPlan = { open($0, in: controller) }
        }
        let agent = SettingsStore.shared.settings.defaultAgent
        let directory = session.workingDirectory ?? NSHomeDirectory()
        if mode == .here {
            // Runs in this pane, like typing it at the prompt.
            let command = agent.command(name: randomName(), permissionMode: SettingsStore.shared.settings.claudePermissionMode)
            if session.state == .idle {
                session.submit(command: command)
            } else if session.state == .unmanaged {
                session.surfaceView.sendText(command)
                session.surfaceView.writeRaw("\r")
            } else {
                session.pendingCommand = command
            }
            return
        }
        var branch: String?
        var name: String?
        var remote: String?
        switch mode {
        case .newBranch(let input):
            guard let b = branchName(from: input) else { return report(LaunchError.invalidBranch(input).localizedDescription, false) }
            (branch, name) = (b, b)
        case .existingBranch(let b, let r):
            (branch, name, remote) = (b, b, r)
        case .here, .worktree:
            break
        }
        report("Preparing worktree…", true)
        let env = MCPManager.defaultEnvironment()
        let root = WorktreeService.worktreeRoot(environment: env)
        Task {
            do {
                let plan = try await worktreePlan(directory: directory, branch: branch, name: name, trackRemote: remote,
                                                  agent: agent, worktreeRoot: root, environment: env)
                openPlan(plan)
            } catch {
                report(error.localizedDescription, false)
            }
        }
    }

    private static func open(_ plan: Plan, in controller: TerminalWindowController) {
        let tab = controller.newTab(directory: plan.directory)
        tab.focusedSession?.pendingCommand = plan.command
    }

    static func controller(for session: TerminalSession) -> TerminalWindowController? {
        ClaudeDashboard.controllers.first { c in c.workspace.tabs.contains { $0.sessions[session.id] != nil } }
    }

    // MARK: Worktree plan

    /// The repository `directory` is in, its default branch and its worktrees.
    static func inspect(directory: String, environment env: [String: String]) async throws -> (RepoInfo, [WorktreeInfo]) {
        let git = GitRepository.findGit(environment: env)
        func run(_ args: [String]) async -> String? {
            await GitRepository.run(git, args, in: directory, environment: env)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let out = await run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"]) else {
            throw LaunchError.notARepository
        }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { throw LaunchError.notARepository }
        let common = URL(fileURLWithPath: lines[1])
        let mainCheckout = common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : lines[0]

        // Default branch: origin/HEAD, else a conventional name, else the current branch.
        var baseRemote: String?
        var baseBranch: String?
        if let head = await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]), let slash = head.firstIndex(of: "/") {
            baseRemote = String(head[..<slash])
            baseBranch = String(head[head.index(after: slash)...])
        } else {
            for candidate in ["main", "master", "develop"] {
                if await run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"]) != nil {
                    (baseRemote, baseBranch) = ("origin", candidate)
                    break
                }
                if await run(["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"]) != nil {
                    baseBranch = candidate
                    break
                }
            }
        }
        if baseBranch == nil { baseBranch = await run(["rev-parse", "--abbrev-ref", "HEAD"]) }
        guard let baseBranch, baseBranch != "HEAD" else { throw LaunchError.git("Couldn't find the default branch") }
        let info = RepoInfo(toplevel: lines[0], repoName: URL(fileURLWithPath: mainCheckout).lastPathComponent,
                            baseRemote: baseRemote, baseBranch: baseBranch)

        let worktrees = WorktreeInfo.parse(porcelain: await run(["worktree", "list", "--porcelain"]) ?? "")
        return (info, worktrees)
    }

    static func worktreePlan(directory: String, branch requested: String?, name: String?, trackRemote: String?,
                                     agent: CodingAgent, worktreeRoot: String, environment env: [String: String]) async throws -> Plan {
        let (info, worktrees) = try await inspect(directory: directory, environment: env)
        let git = GitRepository.findGit(environment: env)
        func run(_ args: [String]) async -> String? {
            await GitRepository.run(git, args, in: directory, environment: env)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func branchExists(_ b: String) async -> Bool { await run(["rev-parse", "--verify", "--quiet", "refs/heads/\(b)"]) != nil }

        var branch = requested ?? randomName()
        if requested == nil {
            // Random names should never collide with existing work.
            var tries = 0
            while await branchExists(branch), tries < 8 {
                branch = randomName()
                tries += 1
            }
        }
        let existingPath = worktrees.first(where: { $0.branch == branch })?.path
        var exists = existingPath != nil
        if !exists { exists = await branchExists(branch) }
        let taken = Set(worktrees.map(\.path))
        return plan(info: info, branch: branch, name: name ?? branch, agent: agent,
                    permissionMode: SettingsStore.shared.settings.claudePermissionMode,
                    worktreeRoot: worktreeRoot, branchExists: exists, existingWorktree: existingPath, trackRemote: trackRemote,
                    pathTaken: { taken.contains($0) || FileManager.default.fileExists(atPath: $0) })
    }

    /// Builds the command a new tab runs. Pure, so it can be tested.
    ///
    /// New branch: `git fetch origin main; git worktree add --no-track -b fix-login <path> origin/main && cd <path> && claude -n fix-login`.
    /// The fetch is best-effort (`;`) so it still works offline.
    static func plan(info: RepoInfo, branch: String, name: String, agent: CodingAgent, permissionMode: String? = nil, worktreeRoot: String,
                     branchExists: Bool, existingWorktree: String?, trackRemote: String? = nil,
                     pathTaken: (String) -> Bool) -> Plan {
        let start = agent.command(name: name, permissionMode: permissionMode)
        if let existingWorktree {
            return Plan(directory: existingWorktree, command: start, name: name)
        }
        let path = worktreePath(root: worktreeRoot, repoName: info.repoName, branch: branch, taken: pathTaken)
        let p = shellPath(path)
        var parts: [String] = []
        let add: String
        if branchExists {
            add = "git worktree add \(p) \(shellQuote(branch))"
        } else if let trackRemote {
            // A branch that only exists on the remote: check it out locally, tracking it.
            add = "git worktree add --track -b \(shellQuote(branch)) \(p) \(shellQuote(trackRemote + "/" + branch))"
        } else if let remote = info.baseRemote {
            parts.append("git fetch \(shellQuote(remote)) \(shellQuote(info.baseBranch));")
            add = "git worktree add --no-track -b \(shellQuote(branch)) \(p) \(shellQuote(remote + "/" + info.baseBranch))"
        } else {
            add = "git worktree add -b \(shellQuote(branch)) \(p) \(shellQuote(info.baseBranch))"
        }
        parts.append("\(add) && cd \(p) && \(start)")
        return Plan(directory: info.toplevel, command: parts.joined(separator: " "), name: name)
    }

    /// `<root>/<repo>/<branch with / as ->`, suffixed -2, -3… when taken.
    nonisolated static func worktreePath(root: String, repoName: String, branch: String, taken: (String) -> Bool) -> String {
        let base = "\(root)/\(repoName)/\(branch.replacingOccurrences(of: "/", with: "-"))"
        var path = base
        var n = 2
        while taken(path) {
            path = "\(base)-\(n)"
            n += 1
        }
        return path
    }

    // MARK: Helpers

    /// A usable branch name from what the user typed: spaces become dashes;
    /// nil when git would reject it (see `git check-ref-format`).
    nonisolated static func branchName(from input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.hasSuffix(".lock"), name != "@", !name.contains(".."), !name.contains("//"), !name.contains("@{"),
              !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "~^:?*[\\").union(.controlCharacters)) == nil else { return nil }
        return name
    }

    private static let adjectives = ["amber", "bold", "brisk", "calm", "clever", "cosmic", "crisp", "daring", "eager", "fleet",
                                     "gentle", "golden", "happy", "keen", "lucky", "mellow", "nimble", "quiet", "rapid", "royal",
                                     "shy", "silver", "steady", "sunny", "swift", "tidy", "vivid", "wise", "witty", "zesty"]
    private static let nouns = ["badger", "comet", "falcon", "fern", "finch", "fox", "glacier", "harbor", "heron", "lantern",
                                "maple", "meadow", "moose", "nebula", "otter", "panda", "pebble", "pine", "quartz", "raven",
                                "river", "robin", "sparrow", "summit", "thistle", "tiger", "walrus", "willow", "wren", "yak"]

    static func randomName() -> String {
        "\(adjectives.randomElement() ?? "brisk")-\(nouns.randomElement() ?? "otter")"
    }

    nonisolated static func shellQuote(_ s: String) -> String { ShellQuote.quote(s) }

    /// A path for the command line, with the home folder shown as `~`.
    nonisolated static func shellPath(_ path: String, home: String = NSHomeDirectory()) -> String { ShellQuote.path(path, home: home) }
}
