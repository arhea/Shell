import Foundation

// The Review Changes diff flattened into one list of rows (file headers, hunk
// headers, line pairs, collapsed gaps, comment cards), so a single LazyVStack
// renders only what's on screen and the overview ruler and keyboard navigation
// work on row indices. Built off the view body, and pure, so it's unit-tested.

/// Identifies one hunk: the file, which diff it came from and its position.
struct ReviewHunkRef: Hashable, Sendable {
    var path: String
    var staged: Bool
    var index: Int
}

/// One side of a diff line, with its word-level change.
struct ReviewCell: Hashable, Sendable {
    var kind: UnifiedDiffLine.Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
    var change: Range<Int>?

    /// The number shown in a split gutter: old on the left, new on the right.
    func number(left: Bool) -> Int? { left ? oldNumber : newNumber }
}

/// Where a comment is attached.
struct ReviewCommentTarget: Hashable, Sendable {
    var rowID: String
    var hunk: ReviewHunkRef
    var line: Int
    /// True when `line` is a line of the new file.
    var isNew: Bool
}

struct ReviewRow: Identifiable, Sendable {
    enum Kind: Sendable {
        case fileHeader(ReviewFile, collapsed: Bool)
        case sectionLabel(path: String, staged: Bool)
        case hunkHeader(ReviewHunkRef, header: String)
        /// Split: both sides. Unified: `left` only, holding both numbers.
        case line(ReviewHunkRef, left: ReviewCell?, right: ReviewCell?)
        case gap(id: String, ReviewHunkRef, count: Int)
        case truncated(path: String, hidden: Int)
        case note(path: String, text: String)
        case comment(ReviewCommentTarget)
        case fileEnd(path: String)
    }

    let id: String
    let kind: Kind

    var hasChange: (added: Bool, removed: Bool) {
        guard case .line(_, let l, let r) = kind else { return (false, false) }
        return (l?.kind == .added || r?.kind == .added, l?.kind == .removed || r?.kind == .removed)
    }
}

enum ReviewRows {
    /// Line rows rendered per file before "Show full diff".
    static let lineCap = 3000

    struct Input {
        var files: [ReviewFile]
        var split = true
        var collapsed: Set<String> = []
        var fullDiff: Set<String> = []
        /// Expanded gap id → the new side's lines (1-based array index + 1 = line number).
        var expandedGaps: [String: [String]] = [:]
        var comment: ReviewCommentTarget?
    }

    static func build(_ input: Input) -> [ReviewRow] {
        var rows: [ReviewRow] = []
        for file in input.files {
            let collapsed = input.collapsed.contains(file.path)
            rows.append(ReviewRow(id: "file|\(file.path)", kind: .fileHeader(file, collapsed: collapsed)))
            if collapsed { continue }
            var budget = input.fullDiff.contains(file.path) ? Int.max : lineCap
            var hidden = 0
            let parts = [(true, file.staged), (false, file.unstaged)].compactMap { s, d in d.map { (s, $0) } }
            for (staged, diff) in parts {
                if parts.count > 1 {
                    rows.append(ReviewRow(id: "label|\(file.path)|\(staged)", kind: .sectionLabel(path: file.path, staged: staged)))
                }
                if let note = note(for: diff) {
                    rows.append(ReviewRow(id: "note|\(file.path)|\(staged)", kind: .note(path: file.path, text: note)))
                    continue
                }
                for (i, hunk) in diff.hunks.enumerated() {
                    let ref = ReviewHunkRef(path: file.path, staged: staged, index: i)
                    if budget <= 0 {
                        hidden += hunk.lines.count
                        continue
                    }
                    let prev = i > 0 ? diff.hunks[i - 1] : nil
                    if let g = gap(before: hunk, after: prev, ref: ref), g.count > 0 {
                        if let lines = input.expandedGaps[g.id] {
                            rows += expandedRows(g, lines: lines, ref: ref, split: input.split)
                        } else {
                            rows.append(ReviewRow(id: g.id, kind: .gap(id: g.id, ref, count: g.count)))
                        }
                    }
                    rows.append(ReviewRow(id: hunkID(ref), kind: .hunkHeader(ref, header: hunk.header)))
                    let lineRows = self.lineRows(hunk, ref: ref, split: input.split)
                    let shown = lineRows.prefix(budget)
                    hidden += lineRows.count - shown.count
                    budget -= shown.count
                    for row in shown {
                        rows.append(row)
                        if let c = input.comment, c.rowID == row.id {
                            rows.append(ReviewRow(id: "comment|\(row.id)", kind: .comment(c)))
                        }
                    }
                }
            }
            if hidden > 0 { rows.append(ReviewRow(id: "more|\(file.path)", kind: .truncated(path: file.path, hidden: hidden))) }
            rows.append(ReviewRow(id: "end|\(file.path)", kind: .fileEnd(path: file.path)))
        }
        return rows
    }

    static func hunkID(_ ref: ReviewHunkRef) -> String { "hunk|\(ref.path)|\(ref.staged ? "s" : "u")|\(ref.index)" }

    static func note(for diff: UnifiedDiffFile) -> String? {
        if let note = diff.note { return note }
        if diff.isBinary { return "Binary file" }
        if diff.hunks.isEmpty { return diff.isNew ? "Empty file" : "Only whitespace or mode changes" }
        return nil
    }

    // MARK: Lines

    /// A hunk's lines as rows: paired side by side (with word-level changes
    /// from ClaudeDiff), or one per line.
    static func lineRows(_ hunk: UnifiedDiffHunk, ref: ReviewHunkRef, split: Bool) -> [ReviewRow] {
        let lines = hunk.lines.map { l in
            ClaudeDiff.Line(kind: l.kind == .added ? .added : l.kind == .removed ? .removed : .context,
                            text: l.text, oldNumber: l.oldNumber, newNumber: l.newNumber)
        }
        let pairs = ClaudeDiff.rows(lines)
        let base = "line|\(ref.path)|\(ref.staged ? "s" : "u")|\(ref.index)|"
        func cell(_ l: ClaudeDiff.Line?, _ change: Range<Int>?) -> ReviewCell? {
            guard let l else { return nil }
            let kind: UnifiedDiffLine.Kind = l.kind == .added ? .added : l.kind == .removed ? .removed : .context
            return ReviewCell(kind: kind, text: l.text, oldNumber: l.oldNumber, newNumber: l.newNumber, change: change)
        }
        if split {
            return pairs.enumerated().map { k, p in
                ReviewRow(id: base + "\(k)", kind: .line(ref, left: cell(p.left, p.leftChange), right: cell(p.right, p.rightChange)))
            }
        }
        var changes: [ClaudeDiff.Line: Range<Int>] = [:]
        for p in pairs {
            if let l = p.left, let c = p.leftChange { changes[l] = c }
            if let r = p.right, let c = p.rightChange { changes[r] = c }
        }
        return lines.enumerated().map { k, l in
            ReviewRow(id: base + "\(k)", kind: .line(ref, left: cell(l, changes[l]), right: nil))
        }
    }

    // MARK: Gaps

    struct Gap: Equatable {
        var id: String
        /// First hidden line on the new side, and how many.
        var newStart: Int
        var count: Int
        /// Old line number minus new line number across the gap.
        var oldOffset: Int
    }

    /// The unchanged lines between `previous` (or the top of the file) and `hunk`.
    static func gap(before hunk: UnifiedDiffHunk, after previous: UnifiedDiffHunk?, ref: ReviewHunkRef) -> Gap? {
        let newBegin = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
        let oldBegin = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
        let prevEnd: Int
        if let p = previous {
            prevEnd = p.newCount == 0 ? p.newStart : p.newStart + p.newCount - 1
        } else {
            prevEnd = 0
        }
        let count = newBegin - prevEnd - 1
        guard count > 0 else { return nil }
        return Gap(id: "gap|\(ref.path)|\(ref.staged ? "s" : "u")|\(ref.index)", newStart: prevEnd + 1, count: count,
                   oldOffset: oldBegin - newBegin)
    }

    static func expandedRows(_ g: Gap, lines: [String], ref: ReviewHunkRef, split: Bool) -> [ReviewRow] {
        (0..<g.count).compactMap { k in
            let n = g.newStart + k
            guard n - 1 < lines.count else { return nil }
            let c = ReviewCell(kind: .context, text: lines[n - 1], oldNumber: n + g.oldOffset, newNumber: n)
            return ReviewRow(id: "\(g.id)|\(k)", kind: .line(ref, left: c, right: split ? c : nil))
        }
    }

    // MARK: Ruler

    struct Mark: Equatable {
        enum Kind { case added, removed, modified }
        var position: Double
        var kind: Kind
    }

    /// Change positions as fractions of the row list, merged when adjacent.
    static func rulerMarks(_ rows: [ReviewRow]) -> [Mark] {
        guard !rows.isEmpty else { return [] }
        var marks: [Mark] = []
        let total = Double(rows.count)
        for (i, row) in rows.enumerated() {
            let c = row.hasChange
            guard c.added || c.removed else { continue }
            let kind: Mark.Kind = c.added && c.removed ? .modified : c.added ? .added : .removed
            let pos = Double(i) / total
            if let last = marks.last, last.kind == kind, pos - last.position < 0.004 { continue }
            marks.append(Mark(position: pos, kind: kind))
        }
        return marks
    }
}
