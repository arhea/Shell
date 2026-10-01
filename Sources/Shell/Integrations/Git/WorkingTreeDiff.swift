import Foundation

// The working tree's changes as parsed unified diffs: `git diff` (worktree vs
// index), `git diff --cached` (index vs HEAD) and untracked files as new-file
// diffs. Feeds the Review Changes view and the hunk staging in GitStaging.

/// One line inside a hunk.
struct UnifiedDiffLine: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case context, added, removed }
    var kind: Kind
    /// The line's text without the leading ` `/`+`/`-` (a trailing `\r` is kept).
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
    /// Followed by `\ No newline at end of file`.
    var noNewline = false
}

/// One `@@ -a,b +c,d @@ section` hunk.
struct UnifiedDiffHunk: Hashable, Sendable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    /// The function context git prints after the second `@@`.
    var section: String
    var lines: [UnifiedDiffLine]

    var header: String { Self.header(oldStart, oldCount, newStart, newCount, section) }

    static func header(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int, _ section: String) -> String {
        func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        return "@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@" + (section.isEmpty ? "" : " " + section)
    }

    var additions: Int { lines.reduce(0) { $1.kind == .added ? $0 + 1 : $0 } }
    var deletions: Int { lines.reduce(0) { $1.kind == .removed ? $0 + 1 : $0 } }

    /// The hunk as diff text: header and prefixed lines.
    var text: String {
        var out = [header]
        for line in lines {
            out.append((line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text)
            if line.noNewline { out.append("\\ No newline at end of file") }
        }
        return out.joined(separator: "\n")
    }
}

/// One file of a unified diff.
struct UnifiedDiffFile: Hashable, Sendable {
    /// Nil when the old side is /dev/null (a new file).
    var oldPath: String?
    /// Nil when the new side is /dev/null (a deleted file).
    var newPath: String?
    var isNew = false
    var isDeleted = false
    var isBinary = false
    /// Set when the diff wasn't loaded (too large).
    var note: String?
    var hunks: [UnifiedDiffHunk] = []

    var path: String { newPath ?? oldPath ?? "" }
    var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }
}

/// Parses `git diff` output (with the default `a/` and `b/` prefixes).
enum UnifiedDiffParser {
    static func parse(_ text: String) -> [UnifiedDiffFile] {
        var files: [UnifiedDiffFile] = []
        var file: UnifiedDiffFile?
        var hunk: UnifiedDiffHunk?
        var oldLeft = 0, newLeft = 0, oldLine = 0, newLine = 0

        func closeHunk() {
            if let h = hunk { file?.hunks.append(h) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let f = file { files.append(f) }
            file = nil
        }

        // Split on LF bytes only: Swift treats "\r\n" as one Character.
        for raw in text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = String(decoding: raw, as: UTF8.self)
            if hunk != nil, oldLeft > 0 || newLeft > 0 {
                let first = line.first
                let body = line.isEmpty ? "" : String(line.dropFirst())
                switch first {
                case "+":
                    hunk?.lines.append(UnifiedDiffLine(kind: .added, text: body, newNumber: newLine))
                    newLine += 1; newLeft -= 1
                    continue
                case "-":
                    hunk?.lines.append(UnifiedDiffLine(kind: .removed, text: body, oldNumber: oldLine))
                    oldLine += 1; oldLeft -= 1
                    continue
                case " ", nil:
                    hunk?.lines.append(UnifiedDiffLine(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                    continue
                case "\\":
                    markNoNewline(&hunk)
                    continue
                default:
                    break // malformed: fall through to header handling
                }
            }
            if line.hasPrefix("\\"), hunk != nil {
                markNoNewline(&hunk)
                continue
            }
            if line.hasPrefix("diff --git ") {
                closeFile()
                var f = UnifiedDiffFile()
                if let (a, b) = pathsFromDiffGit(String(line.dropFirst("diff --git ".count))) {
                    f.oldPath = a
                    f.newPath = b
                }
                file = f
            } else if line.hasPrefix("@@ "), file != nil, let parsed = parseHunkHeader(line) {
                closeHunk()
                hunk = parsed
                oldLeft = parsed.oldCount; newLeft = parsed.newCount
                oldLine = parsed.oldStart; newLine = parsed.newStart
                if parsed.oldCount == 0 { oldLine += 1 }
                if parsed.newCount == 0 { newLine += 1 }
            } else if file != nil, hunk == nil {
                if line.hasPrefix("new file mode") {
                    file?.isNew = true
                    file?.oldPath = nil
                } else if line.hasPrefix("deleted file mode") {
                    file?.isDeleted = true
                    file?.newPath = nil
                } else if line.hasPrefix("--- ") {
                    file?.oldPath = path(String(line.dropFirst(4)), prefix: "a/")
                    if file?.oldPath == nil { file?.isNew = true }
                } else if line.hasPrefix("+++ ") {
                    file?.newPath = path(String(line.dropFirst(4)), prefix: "b/")
                    if file?.newPath == nil { file?.isDeleted = true }
                } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    file?.isBinary = true
                }
            }
        }
        closeFile()
        return files
    }

    private static func markNoNewline(_ hunk: inout UnifiedDiffHunk?) {
        guard let last = hunk?.lines.indices.last else { return }
        hunk?.lines[last].noNewline = true
    }

    /// `@@ -40,7 +40,14 @@ func write()`.
    static func parseHunkHeader(_ line: String) -> UnifiedDiffHunk? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "@@",
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let nums = s.dropFirst().split(separator: ",")
            guard let start = nums.first.flatMap({ Int($0) }) else { return nil }
            return (start, nums.count > 1 ? (Int(nums[1]) ?? 1) : 1)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        let rest = parts[3]
        guard rest.hasPrefix("@@") else { return nil }
        let section = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return UnifiedDiffHunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section, lines: [])
    }

    /// `a/path` → path; `/dev/null` → nil. Handles git's C-style quoting.
    static func path(_ raw: String, prefix: String) -> String? {
        var s = raw
        // git appends a tab after paths containing spaces in ---/+++ lines.
        if s.hasSuffix("\t") { s.removeLast() }
        s = unquote(s)
        if s == "/dev/null" { return nil }
        return s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }

    /// `a/x b/x` → (x, x). Only when both halves match (no rename), else from a quoted pair.
    static func pathsFromDiffGit(_ s: String) -> (String, String)? {
        if s.hasPrefix("\"") {
            // "a/x y" "b/x y"
            let pieces = s.components(separatedBy: "\" \"")
            guard pieces.count == 2 else { return nil }
            let a = path(pieces[0] + "\"", prefix: "a/"), b = path("\"" + pieces[1], prefix: "b/")
            guard let a, let b else { return nil }
            return (a, b)
        }
        let n = s.count
        guard (n - 5) % 2 == 0, n > 5 else { return nil }
        let p = (n - 5) / 2
        let a = String(s.prefix(2 + p)), b = String(s.suffix(2 + p))
        guard a.hasPrefix("a/"), b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2) else { return nil }
        return (String(a.dropFirst(2)), String(b.dropFirst(2)))
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        var bytes: [UInt8] = []
        var it = Array(s.utf8.dropFirst().dropLast())[...]
        while let c = it.popFirst() {
            guard c == UInt8(ascii: "\\"), let e = it.popFirst() else { bytes.append(c); continue }
            switch e {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "\""): bytes.append(0x22)
            case UInt8(ascii: "\\"): bytes.append(0x5C)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Octal byte: \303\251
                var value = Int(e - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let d = it.first, d >= UInt8(ascii: "0"), d <= UInt8(ascii: "7") else { break }
                    value = value * 8 + Int(d - UInt8(ascii: "0"))
                    it = it.dropFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(e)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A changed file in the review: its staged part (index vs HEAD) and its
/// unstaged part (worktree vs index, or the whole file when untracked).
struct ReviewFile: Identifiable, Hashable, Sendable {
    enum Status: Sendable { case modified, added, deleted }
    enum StageState: Sendable { case none, partial, full }

    var path: String
    var staged: UnifiedDiffFile?
    var unstaged: UnifiedDiffFile?
    var isUntracked = false

    var id: String { path }

    var status: Status {
        if isUntracked || staged?.isNew == true { return .added }
        if staged?.isDeleted == true || unstaged?.isDeleted == true { return .deleted }
        return .modified
    }

    var letter: String {
        switch status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        }
    }

    var stageState: StageState {
        switch (staged != nil, unstaged != nil) {
        case (true, false): .full
        case (true, true): .partial
        default: .none
        }
    }

    var isNewFile: Bool { status == .added }
    var additions: Int { (staged?.additions ?? 0) + (unstaged?.additions ?? 0) }
    var deletions: Int { (staged?.deletions ?? 0) + (unstaged?.deletions ?? 0) }
    var fileName: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }

    /// Changes when any of the file's hunks change: "Viewed" resets then.
    var contentHash: Int {
        var h = Hasher()
        h.combine(staged)
        h.combine(unstaged)
        return h.finalize()
    }

    /// Merges the three diffs by path, sorted like Finder.
    static func merge(staged: [UnifiedDiffFile], unstaged: [UnifiedDiffFile], untracked: [UnifiedDiffFile]) -> [ReviewFile] {
        var byPath: [String: ReviewFile] = [:]
        for f in staged { byPath[f.path, default: ReviewFile(path: f.path)].staged = f }
        for f in unstaged { byPath[f.path, default: ReviewFile(path: f.path)].unstaged = f }
        for f in untracked where byPath[f.path] == nil {
            byPath[f.path] = ReviewFile(path: f.path, unstaged: f, isUntracked: true)
        }
        return byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Loads the working tree's diffs. Runs off the main actor.
enum WorkingTreeDiff {
    /// Untracked files shown at most; more is almost always a missing .gitignore.
    static let untrackedLimit = 200
    /// Untracked files bigger than this aren't diffed.
    static let untrackedByteLimit = 2_000_000

    static func diffArguments(cached: Bool, ignoreWhitespace: Bool) -> [String] {
        var args = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
                    "--no-relative", "--src-prefix=a/", "--dst-prefix=b/", "-U3"]
        if cached { args.append("--cached") }
        if ignoreWhitespace { args.append("-w") }
        args.append("--")
        return args
    }

    struct Result: Sendable {
        var files: [ReviewFile]
        var error: String?
    }

    static func load(git: String, root: String, environment: [String: String], ignoreWhitespace: Bool) async -> Result {
        async let unstagedOut = run(git, diffArguments(cached: false, ignoreWhitespace: ignoreWhitespace), root, environment)
        async let stagedOut = run(git, diffArguments(cached: true, ignoreWhitespace: ignoreWhitespace), root, environment)
        async let untrackedOut = run(git, ["-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard", "-z"], root, environment)
        let (u, s, t) = await (unstagedOut, stagedOut, untrackedOut)
        // `git diff --cached` fails before the first commit's index exists only on very old git; treat as empty.
        if !u.succeeded {
            return Result(files: [], error: u.stderr.isEmpty ? "git diff failed" : u.stderr)
        }
        let unstaged = UnifiedDiffParser.parse(u.text)
        let staged = s.succeeded ? UnifiedDiffParser.parse(s.text) : []
        let paths = t.text.split(separator: "\0").map(String.init).prefix(untrackedLimit)
        var untracked: [UnifiedDiffFile] = []
        for path in paths {
            untracked.append(await untrackedDiff(git: git, root: root, environment: environment, path: path))
        }
        return Result(files: ReviewFile.merge(staged: staged, unstaged: unstaged, untracked: untracked))
    }

    /// An untracked file as a new-file diff (`git diff --no-index /dev/null <file>`).
    static func untrackedDiff(git: String, root: String, environment: [String: String], path: String) async -> UnifiedDiffFile {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > untrackedByteLimit {
            return UnifiedDiffFile(oldPath: nil, newPath: path, isNew: true, note: "File too large to show")
        }
        let r = await run(git, ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
                                "--src-prefix=a/", "--dst-prefix=b/", "--no-index", "--", "/dev/null", path], root, environment)
        // --no-index exits 1 when the files differ.
        var file = UnifiedDiffParser.parse(r.text).first ?? UnifiedDiffFile(oldPath: nil, newPath: path, isNew: true)
        file.newPath = path
        file.oldPath = nil
        file.isNew = true
        return file
    }

    struct Output: Sendable {
        var text: String
        var stderr: String
        var succeeded: Bool
    }

    static func run(_ git: String, _ args: [String], _ root: String, _ environment: [String: String]) async -> Output {
        var env = environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["GH_PROMPT_DISABLED"] = "1"
        let r = await ProcessRunner.run(git, args, environment: env, directory: root, timeout: 60)
        let ok = !r.timedOut && (r.status == 0 || (args.contains("--no-index") && r.status == 1))
        return Output(text: String(decoding: r.stdout, as: UTF8.self),
                      stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines), succeeded: ok)
    }
}
