import Foundation
import Observation

/// One line of `git diff --numstat -z`: lines added and removed in a file.
struct DiffStat: Equatable, Sendable {
    var path: String
    /// Nil for binary files ("-").
    var additions: Int?
    var deletions: Int?
    /// The source path of a rename.
    var oldPath: String?

    /// Parses `git diff --numstat -z` output. Each entry is
    /// `added\tdeleted\tpath\0`, or for a rename `added\tdeleted\t\0old\0new\0`.
    static func parse(numstat: String) -> [DiffStat] {
        var out: [DiffStat] = []
        var tokens = numstat.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        while let token = tokens.popFirst() {
            let fields = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            var stat = DiffStat(path: fields[2], additions: Int(fields[0]), deletions: Int(fields[1]))
            if fields[2].isEmpty {
                // Rename: the old and new paths follow as their own tokens.
                guard let old = tokens.popFirst(), let new = tokens.popFirst(), !new.isEmpty else { break }
                stat.oldPath = old
                stat.path = new
            }
            out.append(stat)
        }
        return out
    }
}

extension InspectorChange {
    /// The working tree's changes from `git status`, with line counts from
    /// `git diff --numstat HEAD` and, for untracked files, their line counts.
    static func build(status: GitStatusSnapshot, stats: [DiffStat], untrackedLines: [String: Int]) -> [InspectorChange] {
        let byPath = Dictionary(stats.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return status.changes.map { path, file in
            let kind: Kind = switch file.kind {
            case .added, .untracked: .added
            case .deleted: .deleted
            case .renamed: .renamed
            case .conflicted: .conflicted
            case .modified, .ignored: .modified
            }
            var change = InspectorChange(path: path, kind: kind, isUntracked: file.kind == .untracked)
            if let stat = byPath[path] {
                change.additions = stat.additions
                change.deletions = stat.deletions
            } else if let lines = untrackedLines[path] {
                change.additions = lines
                change.deletions = 0
            }
            return change
        }
    }

    /// Lines in a text file, or nil for folders, binaries and files over `limit` bytes.
    static func lineCount(of url: URL, limit: Int = 2_000_000) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8000).contains(0) { return nil } // binary
        if data.isEmpty { return 0 }
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return data.last == 0x0A ? newlines : newlines + 1
    }
}

/// The working tree's changes with line counts, for the inspector's Session
/// tab. One per repository, refreshed when its `git status` changes.
@MainActor
@Observable
final class WorkingChangesModel {
    let repository: GitRepository
    private(set) var changes: [InspectorChange] = []
    private(set) var isLoading = false
    @ObservationIgnored private let git: String
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var again = false

    init(repository: GitRepository, environment: [String: String]) {
        self.repository = repository
        self.environment = environment
        git = GitRepository.findGit(environment: environment)
    }

    var totals: InspectorChangeTotals { InspectorChangeTotals(changes) }

    private static var models: [URL: WorkingChangesModel] = [:]

    /// The shared model for a repository root.
    static func shared(for repository: GitRepository, environment: [String: String] = MCPManager.defaultEnvironment()) -> WorkingChangesModel {
        if let model = models[repository.root], model.repository === repository { return model }
        let model = WorkingChangesModel(repository: repository, environment: environment)
        models[repository.root] = model
        return model
    }

    /// Re-reads line counts. Coalesced: at most one diff runs at a time.
    func refresh() {
        guard !isLoading else {
            again = true
            return
        }
        isLoading = true
        Task {
            repeat {
                again = false
                await load()
            } while again
            isLoading = false
        }
    }

    private func load() async {
        let status = repository.status
        let root = repository.root
        var stats: [DiffStat] = []
        if !status.files.isEmpty,
           let out = await GitRepository.run(git, ["diff", "--numstat", "-z", "HEAD", "--"], in: root.path, environment: environment) {
            stats = DiffStat.parse(numstat: out)
        }
        let untracked = status.files.filter { $0.value.kind == .untracked && !$0.key.hasSuffix("/") }.map(\.key)
        let lines: [String: Int] = await Task.detached(priority: .utility) {
            var result: [String: Int] = [:]
            for path in untracked.prefix(200) {
                if let n = InspectorChange.lineCount(of: root.appendingPathComponent(path)) { result[path] = n }
            }
            return result
        }.value
        changes = InspectorChange.build(status: status, stats: stats, untrackedLines: lines)
    }
}
