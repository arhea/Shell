import Foundation

/// Line diffs for Claude's file edits: real line-by-line changes (not "all
/// old lines, then all new lines"), with unchanged context, line numbers
/// from the file when it can be found, and side-by-side pairing.
enum ClaudeDiff {
    struct Line: Hashable {
        enum Kind { case context, removed, added, gap }
        var kind: Kind
        var text: String
        var oldNumber: Int?
        var newNumber: Int?

        init(kind: Kind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil) {
            self.kind = kind
            self.text = text
            self.oldNumber = oldNumber
            self.newNumber = newNumber
        }
    }

    /// One row of a side-by-side view.
    struct Row: Hashable {
        var left: Line?
        var right: Line?
        /// The changed part of each side when a removed line pairs with an added one.
        var leftChange: Range<Int>?
        var rightChange: Range<Int>?
    }

    // MARK: Building

    static func lines(tool: String, input: [String: Any]) -> [Line]? {
        let path = input["file_path"] as? String
        switch tool {
        case "Edit":
            return cached(tool, path, [(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")])
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
            return cached(tool, path, edits)
        case "Write":
            return (input["content"] as? String ?? "").components(separatedBy: "\n").prefix(400).enumerated()
                .map { Line(kind: .added, text: $1, newNumber: $0 + 1) }
        default:
            return nil
        }
    }

    private nonisolated(unsafe) static var cache: [String: [Line]] = [:]
    private static let cacheLock = NSLock()

    /// Diffs are rebuilt on every render of a tool call, so keep them.
    private static func cached(_ tool: String, _ path: String?, _ edits: [(String, String)]) -> [Line] {
        // Keyed by the edit's actual text (hash values can collide) and the file's
        // modification time (line numbers move when the file changes).
        let mtime = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }?.timeIntervalSince1970 ?? 0
        let key = "\(tool)|\(path ?? "")|\(mtime)|" + edits.map { $0.0 + "\u{0}" + $0.1 }.joined(separator: "\u{1}")
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let file = path.flatMap(readSmallFile)
        var result: [Line] = []
        for (i, edit) in edits.enumerated() {
            if i > 0 { result.append(Line(kind: .gap, text: "")) }
            let start = file.flatMap { startLine(of: edit.1, orOf: edit.0, in: $0) } ?? 1
            result += collapseContext(diff(old: edit.0, new: edit.1, startLine: start))
        }
        cacheLock.lock()
        if cache.count > 500 { cache.removeAll() }
        cache[key] = result
        cacheLock.unlock()
        return result
    }

    /// A line diff of two snippets (longest common subsequence), numbered from `startLine`.
    static func diff(old: String, new: String, startLine: Int = 1) -> [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let changes = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            // Removals first, then insertions, like git.
            if i < a.count, removed.contains(i) {
                out.append(Line(kind: .removed, text: a[i], oldNumber: startLine + i))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                out.append(Line(kind: .added, text: b[j], newNumber: startLine + j))
                j += 1
            } else if i < a.count, j < b.count {
                out.append(Line(kind: .context, text: a[i], oldNumber: startLine + i, newNumber: startLine + j))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return out
    }

    /// Long runs of unchanged lines shrink to `keep` lines around each change.
    static func collapseContext(_ lines: [Line], keep: Int = 3) -> [Line] {
        var out: [Line] = []
        var run: [Line] = []
        func flush(atEnd: Bool) {
            let leading = out.isEmpty
            if run.count <= keep * 2 + 1 || (leading && atEnd) {
                out += run
            } else {
                let head = leading ? [] : Array(run.prefix(keep))
                let tail = atEnd ? [] : Array(run.suffix(keep))
                let hidden = run.count - head.count - tail.count
                out += head
                out.append(Line(kind: .gap, text: "\(hidden) unchanged line\(hidden == 1 ? "" : "s")"))
                out += tail
            }
            run = []
        }
        for line in lines {
            if line.kind == .context { run.append(line) } else { flush(atEnd: false); out.append(line) }
        }
        flush(atEnd: true)
        return out
    }

    private nonisolated(unsafe) static var rowCache: [[Line]: [Row]] = [:]

    /// Pairs removed and added runs into rows (git's side-by-side view).
    /// Memoized: views call this on every render, including each frame of a
    /// window resize, and pairing a large edit isn't cheap.
    static func rows(_ lines: [Line]) -> [Row] {
        cacheLock.lock()
        if let hit = rowCache[lines] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let result = buildRows(lines)
        cacheLock.lock()
        if rowCache.count > 200 { rowCache.removeAll() }
        rowCache[lines] = result
        cacheLock.unlock()
        return result
    }

    private static func buildRows(_ lines: [Line]) -> [Row] {
        var rows: [Row] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            switch line.kind {
            case .context, .gap:
                rows.append(Row(left: line, right: line))
                i += 1
            case .removed, .added:
                var removed: [Line] = [], added: [Line] = []
                while i < lines.count, lines[i].kind == .removed { removed.append(lines[i]); i += 1 }
                while i < lines.count, lines[i].kind == .added { added.append(lines[i]); i += 1 }
                rows += pair(removed, added)
            }
        }
        return rows
    }

    /// Lines up a run of removals with the following additions. Each removed
    /// line pairs with the next similar added line (an edited line); lines in
    /// between pair up in order, like git, or stand alone.
    static func pair(_ removed: [Line], _ added: [Line]) -> [Row] {
        var rows: [Row] = []
        var pending: [Line] = []
        var next = 0
        func flush(upTo end: Int) {
            let adds = Array(added[next..<end])
            for k in 0..<max(pending.count, adds.count) {
                rows.append(Row(left: k < pending.count ? pending[k] : nil, right: k < adds.count ? adds[k] : nil))
            }
            pending = []
            next = end
        }
        for line in removed {
            // Look a bounded distance ahead so a large rewrite stays linear, not removed × added.
            let window = next..<min(added.count, next + pairLookahead)
            if let j = window.first(where: { similarity(line.text, added[$0].text) >= 0.4 }) {
                flush(upTo: j)
                var row = Row(left: line, right: added[j])
                (row.leftChange, row.rightChange) = changedRanges(line.text, added[j].text)
                rows.append(row)
                next = j + 1
            } else {
                pending.append(line)
            }
        }
        flush(upTo: added.count)
        return rows
    }

    /// How many added lines ahead a removed line looks for its edited version.
    static let pairLookahead = 64

    /// Shared prefix and suffix as a share of the longer line (0…1). Works on
    /// UTF-8 bytes without copying: this runs for many line pairs per diff.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = a.utf8, y = b.utf8
        let shorter = min(x.count, y.count)
        guard shorter > 0 else { return 0 }
        let prefix = zip(x, y).prefix { $0 == $1 }.count
        let suffix = min(zip(x.reversed(), y.reversed()).prefix { $0 == $1 }.count, shorter - prefix)
        return Double(prefix + suffix) / Double(max(x.count, y.count))
    }

    /// The differing middle of two similar lines (common prefix and suffix
    /// removed), as character offsets. Nil when the lines have little in common.
    static func changedRanges(_ a: String, _ b: String) -> (Range<Int>?, Range<Int>?) {
        let x = Array(a), y = Array(b)
        var prefix = 0
        while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < x.count - prefix, suffix < y.count - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix > 0, (prefix + suffix) * 3 >= min(x.count, y.count) else { return (nil, nil) }
        let l = prefix..<(x.count - suffix), r = prefix..<(y.count - suffix)
        return (l.isEmpty ? nil : l, r.isEmpty ? nil : r)
    }

    // MARK: Line numbers from the file

    private static func readSmallFile(_ path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size < 4_000_000 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// The line where the snippet starts: after the edit the file holds the
    /// new text; before it (a permission prompt) the old text.
    static func startLine(of new: String, orOf old: String, in file: String) -> Int? {
        for needle in [new, old] where !needle.isEmpty {
            if let range = file.range(of: needle) {
                return file[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            }
        }
        return nil
    }
}
