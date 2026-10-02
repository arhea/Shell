import AppKit
import Observation
import os

/// State behind Review Changes: the working tree's diff, selection, view
/// options, staging, commenting and committing. Git runs off the main actor
/// through `WorkingTreeDiff` and `GitStaging`.
@MainActor
@Observable
final class ReviewChangesModel {
    let repository: GitRepository
    @ObservationIgnored let staging: GitStaging
    @ObservationIgnored private let git: String

    private(set) var files: [ReviewFile] = []
    private(set) var rows: [ReviewRow] = []
    private(set) var marks: [ReviewRows.Mark] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// The last load, stage, revert, commit or push error, shown inline.
    var error: String?

    var selectedPath: String?
    var split = true { didSet { rebuild() } }
    var hideWhitespace = false { didSet { if hideWhitespace != oldValue { refresh() } } }
    private(set) var collapsed: Set<String> = []
    private(set) var fullDiff: Set<String> = []
    private var expandedGaps: [String: [String]] = [:]

    // Commenting
    var comment: ReviewCommentTarget?
    var commentText = ""

    // Committing
    var commitMessage = ""
    var isCommitting = false
    var isDrafting = false
    var busyHunks: Set<ReviewHunkRef> = []

    /// Bumped to ask the view to scroll to `scrollTarget`.
    private(set) var scrollTarget: String?
    private(set) var scrollToken = 0
    /// The hunk ⌥↓ moves from.
    @ObservationIgnored private var cursor = -1

    /// Viewed files for this app session: repo root + path → content hash.
    private static var viewed: [String: Int] = [:]

    @ObservationIgnored private var loadAgain = false
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init(repository: GitRepository) {
        self.repository = repository
        git = GitRepository.findGit(environment: repository.environment)
        staging = GitStaging(git: git, root: repository.root.path, environment: repository.environment)
    }

    // MARK: Derived

    var stagedCount: Int { files.filter { $0.staged != nil }.count }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
    var viewedCount: Int { files.filter(isViewed).count }
    var branch: String { repository.branchLabel }
    var baseBranch: String { repository.defaultBranch ?? "main" }
    var selectedIndex: Int? { files.firstIndex { $0.path == selectedPath } }
    var canDraft: Bool { CommitMessageDraft.isAvailable }

    func isViewed(_ file: ReviewFile) -> Bool {
        Self.viewed[viewedKey(file)] == file.contentHash
    }

    private func viewedKey(_ file: ReviewFile) -> String { repository.root.path + "\u{0}" + file.path }

    // MARK: Loading

    /// Loads now and again whenever `git status` changes (debounced).
    func start() {
        refresh()
        guard watchTask == nil else { return }
        let repo = repository
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                // Resumed by the next status change or by stop()'s cancel,
                // whichever comes first; otherwise a stopped repository that
                // never changes again would park this task (and itself) forever.
                let slot = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        slot.withLock { $0 = cont }
                        withObservationTracking { _ = repo.status } onChange: { slot.withLock { $0.take() }?.resume() }
                        if Task.isCancelled { slot.withLock { $0.take() }?.resume() }
                    }
                } onCancel: {
                    slot.withLock { $0.take() }?.resume()
                }
                guard !Task.isCancelled, let self else { return }
                scheduleRefresh()
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        debounce?.cancel()
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: AppEnvironment.wait(.milliseconds(300)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Re-reads the diff. Coalesced: one load at a time.
    func refresh() {
        guard !isLoading else {
            loadAgain = true
            return
        }
        isLoading = true
        Task {
            repeat {
                loadAgain = false
                let result = await WorkingTreeDiff.load(git: git, root: repository.root.path, environment: repository.environment,
                                                        ignoreWhitespace: hideWhitespace)
                apply(result)
            } while loadAgain
            isLoading = false
        }
    }

    private func apply(_ result: WorkingTreeDiff.Result) {
        if let err = result.error { error = err }
        let firstLoad = !hasLoaded
        hasLoaded = true
        files = result.files
        let paths = Set(files.map(\.path))
        collapsed = collapsed.filter(paths.contains)
        if firstLoad { collapsed.formUnion(files.filter(isViewed).map(\.path)) }
        // Expanded gaps refer to old line numbers; drop them when the diff moves.
        expandedGaps = [:]
        // Opened on a file (from a link in the chat): start scrolled to it.
        let opened = firstLoad && selectedPath.map(paths.contains) == true
        if selectedPath == nil || !paths.contains(selectedPath ?? "") { selectedPath = files.first?.path }
        rebuild()
        if opened, let path = selectedPath { scroll(to: "file|\(path)") }
    }

    func rebuild() {
        rows = ReviewRows.build(.init(files: files, split: split, collapsed: collapsed, fullDiff: fullDiff,
                                      expandedGaps: expandedGaps, comment: comment))
        marks = ReviewRows.rulerMarks(rows)
    }

    // MARK: Files and navigation

    func select(_ file: ReviewFile) {
        selectedPath = file.path
        scroll(to: "file|\(file.path)")
    }

    func toggleCollapsed(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
        rebuild()
    }

    func setViewed(_ file: ReviewFile, _ on: Bool) {
        if on {
            Self.viewed[viewedKey(file)] = file.contentHash
            collapsed.insert(file.path)
        } else {
            Self.viewed[viewedKey(file)] = nil
            collapsed.remove(file.path)
        }
        rebuild()
    }

    func showFullDiff(_ path: String) {
        fullDiff.insert(path)
        rebuild()
    }

    func nextFile(_ delta: Int = 1) {
        guard !files.isEmpty else { return }
        let i = selectedIndex ?? -1
        let next = min(max(i + delta, 0), files.count - 1)
        select(files[next])
    }

    /// Moves to the next (or previous) hunk header.
    func nextChange(_ delta: Int = 1) {
        let hunks = rows.indices.filter { if case .hunkHeader = rows[$0].kind { true } else { false } }
        guard !hunks.isEmpty else { return }
        cursor = min(max(cursor + delta, 0), hunks.count - 1)
        let row = rows[hunks[cursor]]
        if case .hunkHeader(let ref, _) = row.kind { selectedPath = ref.path }
        scroll(to: row.id)
    }

    func scroll(to id: String) {
        scrollTarget = id
        scrollToken += 1
    }

    /// The row at a fraction of the list, for clicks on the overview ruler.
    func scroll(toFraction f: Double) {
        guard let i = ReviewRows.row(atFraction: f, in: rows) else { return }
        scroll(to: rows[i].id)
    }

    // MARK: Gaps

    func expandGap(_ id: String, _ ref: ReviewHunkRef) {
        Task {
            let lines = await newSideLines(ref)
            expandedGaps[id] = lines
            rebuild()
        }
    }

    /// The lines of the diff's new side: the working tree file, or the index for staged changes.
    private func newSideLines(_ ref: ReviewHunkRef) async -> [String] {
        let text: String?
        if ref.staged {
            text = await GitRepository.run(git, ["show", ":\(ref.path)"], in: repository.root.path, environment: repository.environment)
        } else {
            let url = repository.root.appendingPathComponent(ref.path)
            text = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
        }
        return (text ?? "").utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Hunk lookup

    func file(_ path: String) -> ReviewFile? { files.first { $0.path == path } }

    func diff(_ ref: ReviewHunkRef) -> UnifiedDiffFile? {
        file(ref.path).flatMap { ref.staged ? $0.staged : $0.unstaged }
    }

    func hunk(_ ref: ReviewHunkRef) -> UnifiedDiffHunk? {
        diff(ref).flatMap { ref.index < $0.hunks.count ? $0.hunks[ref.index] : nil }
    }
}
