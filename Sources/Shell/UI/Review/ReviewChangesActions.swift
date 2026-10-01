import AppKit

/// Staging, reverting, committing, pushing and the Claude hand-offs.
extension ReviewChangesModel {
    // MARK: Staging

    func stageAll() { run { await $0.stageAll() } }

    /// The checkbox: a fully staged file unstages, anything else stages whole.
    func toggleStaged(_ file: ReviewFile) {
        let path = file.path
        if file.stageState == .full {
            run { await $0.unstageFile(path) }
        } else {
            run { await $0.stageFile(path) }
        }
    }

    func stageHunk(_ ref: ReviewHunkRef) {
        guard let file = diff(ref), let hunk = hunk(ref) else { return }
        let ws = hideWhitespace
        run(ref) { await $0.stageHunk(hunk, of: file, ignoringWhitespace: ws) }
    }

    func unstageHunk(_ ref: ReviewHunkRef) {
        guard let file = diff(ref), let hunk = hunk(ref) else { return }
        let ws = hideWhitespace
        run(ref) { await $0.unstageHunk(hunk, of: file, ignoringWhitespace: ws) }
    }

    func revertHunk(_ ref: ReviewHunkRef) {
        guard let file = diff(ref), let hunk = hunk(ref) else { return }
        let untracked = self.file(ref.path)?.isUntracked ?? false
        let ws = hideWhitespace
        run(ref) { await $0.revertHunk(hunk, of: file, untracked: untracked, ignoringWhitespace: ws) }
    }

    func revertFile(_ file: ReviewFile) { run { await $0.revertFile(file) } }

    /// Runs a staging operation, shows its error, then reloads.
    private func run(_ ref: ReviewHunkRef? = nil, _ op: @escaping @Sendable (GitStaging) async -> String?) {
        let staging = self.staging
        if let ref { markBusy(ref, true) }
        Task {
            let err = await op(staging)
            if let ref { markBusy(ref, false) }
            error = err
            repository.refresh()
            refresh()
        }
    }

    // MARK: Committing

    /// "Commit N files" and ⌘⏎; with `push`, "Commit & Push" and ⇧⌘⏎.
    func commit(push: Bool = false) {
        guard !isCommitting else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stagedCount > 0 else {
            error = files.isEmpty ? "There's nothing to commit." : "Nothing is staged. Check the files or stage hunks to commit."
            return
        }
        guard !message.isEmpty else {
            error = "Write a commit message first."
            return
        }
        isCommitting = true
        let staging = self.staging
        Task {
            var err = await staging.commit(message: message)
            if err == nil {
                commitMessage = ""
                if push { err = await staging.push().map { "Committed, but the push failed:\n" + $0 } }
            }
            error = err
            isCommitting = false
            repository.refresh()
            refresh()
        }
    }

    /// "Write for me": an on-device draft from the staged diff.
    func draftMessage() {
        guard !isDrafting else { return }
        let staged = files.compactMap(\.staged)
        guard !staged.isEmpty else {
            error = "Stage some changes first, then Write for me drafts a message from them."
            return
        }
        let diff = staged.map { f in "--- \(f.path)\n" + f.hunks.map(\.text).joined(separator: "\n") }.joined(separator: "\n")
        isDrafting = true
        let git = GitRepository.findGit(environment: repository.environment)
        let root = repository.root.path, env = repository.environment
        Task {
            let log = await GitRepository.run(git, ["log", "-8", "--format=%s"], in: root, environment: env) ?? ""
            let subjects = log.split(separator: "\n").map(String.init)
            if let draft = await CommitMessageDraft.draft(diff: diff, recentSubjects: subjects) {
                commitMessage = draft
                error = nil
            } else {
                error = "Apple Intelligence couldn't draft a message. Try again or write one."
            }
            isDrafting = false
        }
    }

    // MARK: Claude

    /// The prompt "Ask Claude to review" sends.
    var reviewPrompt: String {
        let list = files.prefix(40).map { "- \($0.path) (\($0.letter), +\($0.additions) −\($0.deletions))" }.joined(separator: "\n")
        return """
        Review my uncommitted changes on \(branch) before I commit. Run `git diff` and `git diff --cached` to read them. \
        Point out bugs, risky or unintended changes, and missing tests, citing file:line. Don't edit anything yet.

        Changed files:
        \(list)
        """
    }

    func beginComment(rowID: String, ref: ReviewHunkRef, line: Int, isNew: Bool) {
        comment = ReviewCommentTarget(rowID: rowID, hunk: ref, line: line, isNew: isNew)
        commentText = ""
        rebuild()
    }

    func cancelComment() {
        comment = nil
        commentText = ""
        rebuild()
    }

    /// The comment as a message for Claude, or nil when it's empty.
    func commentMessage() -> String? {
        guard let c = comment, let hunk = hunk(c.hunk) else { return nil }
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Self.commentMessage(path: c.hunk.path, line: c.line, isNew: c.isNew, staged: c.hunk.staged, hunk: hunk, comment: text)
    }

    static func commentMessage(path: String, line: Int, isNew: Bool, staged: Bool, hunk: UnifiedDiffHunk, comment: String) -> String {
        var lines = hunk.text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 201 { lines = Array(lines.prefix(201)) + ["… (hunk truncated)"] }
        let side = isNew ? "" : " (a removed line; the number is in the old file)"
        return """
        Comment on \(path):\(line)\(side), in this \(staged ? "staged" : "unstaged") change:

        ```diff
        \(lines.joined(separator: "\n"))
        ```

        \(comment)
        """
    }

    // MARK: Private setters

    func markBusy(_ ref: ReviewHunkRef, _ on: Bool) {
        if on { busyHunks.insert(ref) } else { busyHunks.remove(ref) }
    }
}
