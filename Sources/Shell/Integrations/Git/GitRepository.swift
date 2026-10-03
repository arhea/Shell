import AppKit
import CoreServices
import Observation
import os

/// A file's state in `git status`.
struct GitFileStatus: Equatable {
    enum Kind: Int, Comparable {
        case ignored, untracked, modified, renamed, added, deleted, conflicted
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var index: Character
    var worktree: Character

    var kind: Kind {
        switch (index, worktree) {
        case ("!", _): .ignored
        case ("?", _): .untracked
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): .conflicted
        case ("D", _), (_, "D"): .deleted
        case ("A", _): .added
        case ("R", _), ("C", _): .renamed
        default: .modified
        }
    }

    /// True when some of the change is staged.
    var isStaged: Bool { ![" ", "?", "!"].contains(index) }

    var letter: String {
        switch kind {
        case .ignored: "!"
        case .untracked: "U"
        case .modified: "M"
        case .renamed: "R"
        case .added: "A"
        case .deleted: "D"
        case .conflicted: "C"
        }
    }
}

/// Parsed `git status --porcelain=v1 -z -b`.
struct GitStatusSnapshot: Equatable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var detached = false
    /// Repository-relative path → status. Ignored directories end in "/".
    var files: [String: GitFileStatus] = [:]

    /// Number of non-ignored entries, without sorting `changes`.
    var changeCount: Int { files.values.reduce(0) { $1.kind == .ignored ? $0 : $0 + 1 } }

    var changes: [(path: String, status: GitFileStatus)] {
        files.filter { $0.value.kind != .ignored }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
    }

    static func parse(_ output: String) -> GitStatusSnapshot {
        var snap = GitStatusSnapshot()
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            if entry.hasPrefix("## ") {
                snap.parseBranch(String(entry.dropFirst(3)))
                continue
            }
            guard entry.count > 3 else { continue }
            let chars = Array(entry)
            let status = GitFileStatus(index: chars[0], worktree: chars[1])
            let path = String(entry.dropFirst(3))
            snap.files[path] = status
            // Renames and copies are followed by the original path.
            if status.index == "R" || status.index == "C" { _ = entries.popFirst() }
        }
        return snap
    }

    private mutating func parseBranch(_ line: String) {
        // "main...origin/main [ahead 1, behind 2]", "HEAD (no branch)", "No commits yet on main"
        var head = line
        if let bracket = head.range(of: " [") {
            let info = head[bracket.upperBound...].dropLast()
            for part in info.components(separatedBy: ", ") {
                let bits = part.split(separator: " ")
                guard bits.count == 2, let n = Int(bits[1]) else { continue }
                if bits[0] == "ahead" { ahead = n } else if bits[0] == "behind" { behind = n }
            }
            head = String(head[..<bracket.lowerBound])
        }
        if head.hasPrefix("No commits yet on ") { head = String(head.dropFirst("No commits yet on ".count)) }
        if head.hasPrefix("HEAD (no branch)") {
            detached = true
            return
        }
        let parts = head.components(separatedBy: "...")
        branch = parts.first
        upstream = parts.count > 1 ? parts[1] : nil
    }
}

/// The GitHub repository a remote points at.
struct GitHubRemote: Equatable {
    var host: String
    var owner: String
    var name: String

    var slug: String { "\(owner)/\(name)" }
    /// `parse` only returns remotes whose URL builds.
    // swiftlint:disable:next force_unwrapping - validated in parse(_:)
    var url: URL { Self.url(host: host, owner: owner, name: name)! }

    private static func url(host: String, owner: String, name: String) -> URL? {
        URL(string: "https://\(host)/\(owner)/\(name)")
    }

    func branchURL(_ branch: String) -> URL {
        url.appendingPathComponent("tree").appendingPathComponent(branch)
    }

    func compareURL(_ branch: String) -> URL {
        let compare = url.appendingPathComponent("compare").appendingPathComponent(branch)
        guard var c = URLComponents(url: compare, resolvingAgainstBaseURL: false) else { return compare }
        c.queryItems = [URLQueryItem(name: "expand", value: "1")]
        return c.url ?? compare
    }

    /// Parses https, ssh and scp-style remote URLs. Nil for non-GitHub hosts.
    static func parse(_ remote: String) -> GitHubRemote? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        if let url = URL(string: s), let h = url.host, url.scheme != nil {
            host = h
            path = url.path
        } else if let at = s.firstIndex(of: "@"), let colon = s[at...].firstIndex(of: ":") {
            // git@github.com:owner/repo.git
            host = String(s[s.index(after: at)..<colon])
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }
        host = host.lowercased()
        guard host == "github.com" || host.hasPrefix("github.") || host.hasSuffix(".github.com") || host.contains("github") else { return nil }
        if host == "ssh.github.com" { host = "github.com" }
        if path.hasSuffix(".git") { path.removeLast(4) }
        s = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              url(host: host, owner: parts[0], name: parts[1]) != nil else { return nil }
        return GitHubRemote(host: host, owner: parts[0], name: parts[1])
    }
}

/// The pull request for the current branch, from `gh`.
struct PullRequestInfo: Equatable {
    enum State: String { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }
    var number: Int
    var title: String
    var url: URL
    var state: State
    var isDraft: Bool
    /// APPROVED, CHANGES_REQUESTED or REVIEW_REQUIRED.
    var reviewDecision: String?
    /// The PR's head commit (full SHA), when known.
    var headOID: String?
}

/// A git repository (or linked worktree) that a native Claude view is working
/// in: branch, worktree info and live `git status`.
@MainActor
@Observable
final class GitRepository {
    let root: URL
    /// True for a linked worktree (`git worktree add`), not the main checkout.
    let isLinkedWorktree: Bool
    /// The main checkout of a linked worktree.
    let mainWorktree: URL?
    private(set) var status = GitStatusSnapshot() {
        didSet {
            directoryKinds = Self.rollUp(status)
            let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
            ignoredDirectories = status.files.compactMap { $0.value.kind == .ignored && $0.key.hasSuffix("/") ? base + $0.key : nil }
        }
    }
    /// Directory → most significant change inside it, rebuilt once per status
    /// change instead of scanning every entry for each folder row.
    @ObservationIgnored private var directoryKinds: [String: GitFileStatus.Kind] = [:]
    private(set) var headCommit: String?
    private(set) var lastRefresh: Date?
    /// The GitHub repository behind the upstream (or origin) remote.
    private(set) var github: GitHubRemote?
    private(set) var defaultBranch: String?
    /// The PR whose head is the current branch, if any.
    private(set) var pullRequest: PullRequestInfo?

    @ObservationIgnored private let git: String
    @ObservationIgnored private(set) var environment: [String: String] = [:]
    @ObservationIgnored private var remoteName: String?
    @ObservationIgnored private var prBranch: String?
    @ObservationIgnored private var prCheckedAt: Date?
    @ObservationIgnored private var prLookupRunning = false
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    var name: String { root.lastPathComponent }
    var branchLabel: String { status.detached ? (headCommit.map { "detached @ \($0)" } ?? "detached") : (status.branch ?? "—") }

    private init(root: URL, gitDir: URL, commonDir: URL, git: String) {
        self.root = root
        self.git = git
        isLinkedWorktree = gitDir.standardizedFileURL != commonDir.standardizedFileURL
        mainWorktree = isLinkedWorktree && commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent() : nil
    }

    /// Finds the repository containing `directory`, or nil outside git.
    static func discover(from directory: String, environment: [String: String]) async -> GitRepository? {
        let git = findGit(environment: environment)
        guard let out = await run(git, ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: directory) else {
            return nil
        }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return nil }
        // One instance (one FSEvents stream, one `git status` loop) per checkout,
        // shared by the pane, the native Claude view, the dashboard and the MCP manager.
        if let existing = registry[lines[0]] {
            existing.leases += 1
            return existing
        }
        let repo = GitRepository(root: URL(fileURLWithPath: lines[0]), gitDir: URL(fileURLWithPath: lines[1]),
                                 commonDir: URL(fileURLWithPath: lines[2]), git: git)
        repo.environment = environment
        repo.leases = 1
        registry[lines[0]] = repo
        await repo.refreshNow()
        repo.startWatching()
        return repo
    }

    @MainActor private static var registry: [String: GitRepository] = [:]
    /// Holders of this shared instance; each `discover` must be balanced by one `stop`.
    @ObservationIgnored private var leases = 0

    /// Releases this holder's use; the watcher stops when the last one lets go.
    func stop() {
        leases -= 1
        guard leases <= 0 else { return }
        watcher?.stop()
        watcher = nil
        if Self.registry[root.path] === self { Self.registry[root.path] = nil }
    }

    /// Coalesces refresh requests; at most one `git status` runs at a time.
    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        Task { await refreshNow() }
    }

    private func refreshNow() async {
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            if let out = await Self.run(git, ["status", "--porcelain=v1", "-z", "-b", "--untracked-files=all", "--ignored=matching"], in: root.path) {
                let snap = GitStatusSnapshot.parse(out)
                if snap != status {
                    // Drop the PR as soon as HEAD leaves its branch, not after the
                    // rest of this refresh, so it never shows against the new HEAD.
                    if pullRequest != nil, snap.detached || snap.branch != prBranch { pullRequest = nil }
                    status = snap
                }
            }
            if status.detached || status.branch == nil {
                headCommit = await Self.run(git, ["rev-parse", "--short", "HEAD"], in: root.path)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            lastRefresh = Date()
        } while refreshAgain
        await refreshRemote()
        refreshPullRequest()
    }

    /// Finds the GitHub remote: the current branch's upstream remote, else origin.
    private func refreshRemote() async {
        let name = status.upstream.flatMap { $0.split(separator: "/").first.map(String.init) } ?? "origin"
        guard name != remoteName else { return }
        remoteName = name
        var url = await Self.run(git, ["remote", "get-url", name], in: root.path)
        if url == nil, name != "origin" { url = await Self.run(git, ["remote", "get-url", "origin"], in: root.path) }
        let remote = url.flatMap(GitHubRemote.parse)
        if remote != github { github = remote }
        if let head = await Self.run(git, ["symbolic-ref", "--short", "refs/remotes/\(name)/HEAD"], in: root.path) {
            let branch = head.trimmingCharacters(in: .whitespacesAndNewlines)
            defaultBranch = branch.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? branch
        }
    }

    /// Looks up the branch's PR with `gh` when the branch changes, or when
    /// `force`d (after a Claude turn, which may have opened one) at most every 15s.
    func refreshPullRequest(force: Bool = false) {
        guard github != nil, let branch = status.branch, !status.detached else {
            if pullRequest != nil { pullRequest = nil }
            return
        }
        let age = prCheckedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let due = branch != prBranch || age > 300 || (force && age > 15)
        guard due, !prLookupRunning else { return }
        if branch != prBranch { pullRequest = nil }
        prBranch = branch
        prCheckedAt = Date()
        prLookupRunning = true
        let env = environment, root = root.path
        Task {
            let pr = await Self.lookUpPullRequest(branch: branch, in: root, environment: env)
            self.prLookupRunning = false
            // Ignore answers for a branch we've since left.
            guard self.status.branch == branch else { return }
            if pr != self.pullRequest { self.pullRequest = pr }
        }
    }

    nonisolated static func lookUpPullRequest(branch: String, in directory: String, environment: [String: String]) async -> PullRequestInfo? {
        guard let gh = findExecutable("gh", environment: environment),
              let out = await run(gh, ["pr", "view", branch, "--json", "number,title,url,state,isDraft"], in: directory, environment: environment),
              let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = obj["number"] as? Int, let urlString = obj["url"] as? String, let url = URL(string: urlString) else { return nil }
        return PullRequestInfo(number: number, title: obj["title"] as? String ?? "", url: url,
                               state: PullRequestInfo.State(rawValue: obj["state"] as? String ?? "") ?? .open,
                               isDraft: obj["isDraft"] as? Bool ?? false)
    }

    /// True when the current branch exists on the remote.
    var isBranchPublished: Bool { status.upstream != nil }

    private func startWatching() {
        // A 1 s latency coalesces bursts (a build writes thousands of files).
        watcher = DirectoryWatcher(path: root.path, latency: AppEnvironment.wait(1.0)) { [weak self] paths in
            guard let self else { return }
            if paths.contains(where: { self.affectsStatus($0) }) { refresh() }
        }
    }

    /// Absolute paths of ignored directories (node_modules/, .build/…), from the last status.
    @ObservationIgnored private var ignoredDirectories: [String] = []

    /// Object writes, lock files and anything inside an ignored directory
    /// can't change `git status`.
    private func affectsStatus(_ path: String) -> Bool {
        if path.contains("/.git/objects/") || path.hasSuffix(".lock") { return false }
        return !ignoredDirectories.contains { path.hasPrefix($0) }
    }

    // MARK: Status lookups

    func status(for relativePath: String) -> GitFileStatus? { status.files[relativePath] }

    /// The most significant change inside a directory (for folder badges).
    func directoryStatus(for relativeDir: String) -> GitFileStatus.Kind? {
        let prefix = relativeDir.isEmpty ? "" : relativeDir + "/"
        if status.files[prefix]?.kind == .ignored { return .ignored }
        return directoryKinds[relativeDir]
    }

    /// For every ancestor directory of each changed path ("" is the root),
    /// the most significant change kind beneath it.
    private static func rollUp(_ status: GitStatusSnapshot) -> [String: GitFileStatus.Kind] {
        var result: [String: GitFileStatus.Kind] = [:]
        for (path, st) in status.files where st.kind != .ignored {
            func note(_ dir: String) {
                if let existing = result[dir], existing >= st.kind { return }
                result[dir] = st.kind
            }
            note("")
            // An untracked directory ("a/b/") also counts for the directory itself.
            var dir = path.hasSuffix("/") ? String(path.dropLast()) : (path as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                note(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return result
    }

    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        if status.files[relativePath]?.kind == .ignored || status.files[relativePath + "/"]?.kind == .ignored { return true }
        // Anything inside an ignored directory.
        var parts = relativePath.split(separator: "/").dropLast()
        while !parts.isEmpty {
            if status.files[parts.joined(separator: "/") + "/"]?.kind == .ignored { return true }
            parts = parts.dropLast()
        }
        return false
    }

    // MARK: Running git

    nonisolated static func findGit(environment: [String: String]) -> String {
        findExecutable("git", environment: environment) ?? "/usr/bin/git"
    }

    /// Searched after `PATH`. Tests narrow it so a real Homebrew `gh` is never found.
    nonisolated static var fallbackSearchDirectories: [String] {
        get { fallbackDirectories.withLock { $0 } }
        set { fallbackDirectories.withLock { $0 = newValue } }
    }
    private nonisolated static let fallbackDirectories = OSAllocatedUnfairLock(initialState: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])

    nonisolated static func findExecutable(_ name: String, environment: [String: String]) -> String? {
        let fm = FileManager.default
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallbackSearchDirectories
        return dirs.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs git (or gh); returns stdout on success. Killed after `timeout` so a
    /// stalled `gh` (network, keychain prompt) can't wedge a refresh forever.
    nonisolated static func run(_ git: String, _ args: [String], in directory: String,
                                environment: [String: String]? = nil, timeout: TimeInterval = 120) async -> String? {
        var env = environment ?? [:]
        env["GH_PROMPT_DISABLED"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0" // don't rewrite the index while Claude works
        env["LC_ALL"] = "C"
        let r = await ProcessRunner.run(git, args, environment: env, directory: directory, timeout: timeout)
        return r.succeeded ? String(data: r.stdout, encoding: .utf8) : nil
    }
}

/// FSEvents on a directory tree, delivered on the main queue with a short latency.
/// Unchecked Sendable: the stream is created, delivered and stopped on the main
/// queue only, and the callback is main-actor isolated.
final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let callback: @MainActor ([String]) -> Void

    init(path: String, latency: TimeInterval = 0.4, callback: @escaping @MainActor ([String]) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.callback(Array(list.prefix(count))) }
        }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// Code editors Shell can open a repository or file in.
struct ExternalEditor: Identifiable, Hashable {
    var bundleID: String
    var name: String
    var appURL: URL
    var id: String { bundleID }

    static let known: [(bundleID: String, name: String)] = [
        ("com.microsoft.VSCode", "VS Code"),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.sublimetext.3", "Sublime Text"),
    ]

    @MainActor static var installed: [ExternalEditor] = detect()

    @MainActor static func detect() -> [ExternalEditor] {
        var seen = Set<String>()
        return known.compactMap { entry in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID),
                  seen.insert(entry.name).inserted else { return nil }
            return ExternalEditor(bundleID: entry.bundleID, name: entry.name, appURL: url)
        }
    }

    /// The editor last used, else the first one installed.
    @MainActor static var preferred: ExternalEditor? {
        let id = SettingsStore.shared.settings.claudePreferredEditor
        return installed.first { $0.bundleID == id } ?? installed.first
    }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: appURL.path) }

    @MainActor func open(_ urls: [URL]) {
        SettingsStore.shared.settings.claudePreferredEditor = bundleID
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
    }
}
