import Foundation

/// Single-hunk patches for `git apply`: stage a hunk (`--cached`), unstage
/// one (`--cached -R`, from the staged diff) or revert one in the working
/// tree (`-R`, from the unstaged diff). Pure, so it's unit-tested.
enum GitPatch {
    /// A patch holding only `hunk` of `file`. The other side's start line is
    /// recomputed as if no other hunk of the file were applied, since git
    /// locates a forward hunk by its old side and a reverse one by its new side.
    static func patch(file: UnifiedDiffFile, hunk: UnifiedDiffHunk, reverse: Bool = false) -> String {
        let oldPath = file.oldPath ?? file.path
        let newPath = file.newPath ?? file.path
        var h = hunk
        if reverse {
            h.oldStart = hunk.newStart + (hunk.newCount == 0 ? 1 : 0) - (hunk.oldCount == 0 ? 1 : 0)
        } else {
            h.newStart = hunk.oldStart + (hunk.oldCount == 0 ? 1 : 0) - (hunk.newCount == 0 ? 1 : 0)
        }
        var out = "diff --git \(quote("a/" + oldPath)) \(quote("b/" + newPath))\n"
        out += "--- " + (file.isNew ? "/dev/null" : quote("a/" + oldPath)) + "\n"
        out += "+++ " + (file.isDeleted ? "/dev/null" : quote("b/" + newPath)) + "\n"
        out += h.text + "\n"
        return out
    }

    /// Quotes a path the way git does when it holds special characters.
    static func quote(_ path: String) -> String {
        guard path.contains(where: { $0 == "\"" || $0 == "\\" || $0 == "\n" || $0 == "\t" }) else { return path }
        var s = "\""
        for c in path {
            switch c {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\t": s += "\\t"
            default: s.append(c)
            }
        }
        return s + "\""
    }
}

/// Staging, reverting, committing and pushing in one repository. Every
/// method runs git off the main actor and returns git's error text, or nil.
struct GitStaging: Sendable {
    let git: String
    let root: String
    let environment: [String: String]

    init(git: String, root: String, environment: [String: String]) {
        self.git = git
        self.root = root
        self.environment = environment
    }

    // MARK: Hunks

    /// Stages a hunk from the unstaged diff. New and deleted files are staged whole.
    func stageHunk(_ hunk: UnifiedDiffHunk, of file: UnifiedDiffFile, ignoringWhitespace: Bool = false) async -> String? {
        if file.isNew || file.isDeleted || file.isBinary { return await stageFile(file.path) }
        return await apply(GitPatch.patch(file: file, hunk: hunk), ["--cached"] + (ignoringWhitespace ? ["--ignore-whitespace"] : []))
    }

    /// Unstages a hunk from the staged diff. New and deleted files are unstaged whole.
    func unstageHunk(_ hunk: UnifiedDiffHunk, of file: UnifiedDiffFile, ignoringWhitespace: Bool = false) async -> String? {
        if file.isNew || file.isDeleted || file.isBinary { return await unstageFile(file.path) }
        return await apply(GitPatch.patch(file: file, hunk: hunk, reverse: true),
                           ["--cached", "-R"] + (ignoringWhitespace ? ["--ignore-whitespace"] : []))
    }

    /// Discards a hunk of the unstaged diff from the working tree.
    func revertHunk(_ hunk: UnifiedDiffHunk, of file: UnifiedDiffFile, untracked: Bool, ignoringWhitespace: Bool = false) async -> String? {
        if untracked { return trash(file.path) }
        if file.isNew || file.isDeleted || file.isBinary { return await git(["checkout", "--", file.path]) }
        return await apply(GitPatch.patch(file: file, hunk: hunk, reverse: true), ["-R"] + (ignoringWhitespace ? ["--ignore-whitespace"] : []))
    }

    // MARK: Files

    func stageFile(_ path: String) async -> String? { await git(["add", "-A", "--", path]) }

    func unstageFile(_ path: String) async -> String? { await git(["reset", "-q", "--", path]) }

    func stageAll() async -> String? { await git(["add", "-A"]) }

    /// Throws away every change to a file: back to HEAD, or to the Trash when
    /// it's new.
    func revertFile(_ file: ReviewFile) async -> String? {
        if file.isUntracked { return trash(file.path) }
        if file.staged?.isNew == true {
            if let err = await git(["rm", "-q", "--cached", "-f", "--", file.path]) { return err }
            return trash(file.path)
        }
        return await git(["checkout", "HEAD", "--", file.path])
    }

    // MARK: Commit and push

    /// `git commit -F <message file>`. Hook output comes back as the error.
    func commit(message: String) async -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shell-commit-\(UUID().uuidString).txt")
        do {
            try message.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Couldn't write the commit message: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return await git(["commit", "-F", url.path])
    }

    /// `git push`, setting the upstream to origin when the branch has none.
    func push() async -> String? {
        let upstream = await GitRepository.run(git, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root,
                                                environment: environment)
        if upstream?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return await git(["push"])
        }
        return await git(["push", "-u", "origin", "HEAD"])
    }

    // MARK: Plumbing

    private func apply(_ patch: String, _ flags: [String]) async -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shell-hunk-\(UUID().uuidString).patch")
        do {
            try patch.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Couldn't write the patch: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return await git(["apply", "--whitespace=nowarn"] + flags + [url.path])
    }

    private func git(_ args: [String]) async -> String? {
        var env = environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return await WorktreeService.runReportingError(git, args, in: root, environment: env)
    }

    private func trash(_ path: String) -> String? {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: root).appendingPathComponent(path), resultingItemURL: nil)
            return nil
        } catch {
            return "Couldn't move \(path) to the Trash: \(error.localizedDescription)"
        }
    }
}
