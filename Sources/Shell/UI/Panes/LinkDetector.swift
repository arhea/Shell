import AppKit
import GhosttyKit

/// A link visible in the terminal: an http(s) URL or an existing local file
/// or folder. `rects` are in the surface view's flipped coordinates, one per
/// row the link spans.
struct DetectedLink: Equatable {
    enum Kind: Equatable {
        case url
        case file(isDirectory: Bool)
    }

    /// The URL, or the absolute file path.
    var target: String
    /// The text as it appears in the terminal.
    var text: String
    var kind: Kind
    var rects: [CGRect]

    var url: String { target }
    var isFile: Bool { if case .file = kind { true } else { false } }

    func contains(_ p: CGPoint) -> Bool { rects.contains { $0.contains(p) } }

    /// ⌘-click behavior: URLs open in their app; files and folders are
    /// revealed (selected) in a Finder window at their location.
    @MainActor
    func activate() {
        switch kind {
        case .url:
            _ = GhosttyRuntime.open(urlString: target)
        case .file:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
        }
    }
}

/// Finds http(s) URLs and existing local paths in the visible viewport.
///
/// libghostty's own matcher only highlights while ⌘ is held, and its hover
/// and click checks share the same modifier rule, so it can't underline a link
/// without also opening it on a plain click. Shell detects links itself,
/// draws the underlines, and handles ⌘-click for what it underlined.
enum LinkDetector {
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`{}|\\^\[\]]+"#, options: [.caseInsensitive])

    struct Geometry {
        var originX: CGFloat     // x of column 0, points
        var baseline0: CGFloat   // baseline of row 0, points from top
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var columns: Int
        var rows: Int
    }

    /// Resolves a candidate path to an existing absolute path. Injected so
    /// tests don't depend on the file system.
    typealias PathResolver = (_ candidate: String) -> (path: String, isDirectory: Bool)?

    @MainActor
    static func geometry(for surface: TerminalSurfaceView) -> Geometry? {
        guard let s = surface.surface, let size = surface.terminalSize, size.columns > 0, size.rows > 0 else { return nil }
        let scale = surface.window?.backingScaleFactor ?? 2
        // Read one cell to learn where the grid starts (padding is balanced by libghostty).
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(s, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        guard text.tl_px_x >= 0, text.tl_px_y >= 0 else { return nil }
        return Geometry(originX: text.tl_px_x, baseline0: text.tl_px_y,
                        cellWidth: CGFloat(size.cell_width_px) / scale, cellHeight: CGFloat(size.cell_height_px) / scale,
                        columns: Int(size.columns), rows: Int(size.rows))
    }

    /// A resolver that checks the file system relative to `cwd`, caching results.
    static func fileSystemResolver(cwd: String?, cache: FileCheckCache) -> PathResolver {
        let base = cwd ?? NSHomeDirectory()
        return { candidate in
            var path = (candidate as NSString).expandingTildeInPath
            if !path.hasPrefix("/") { path = (base as NSString).appendingPathComponent(path) }
            path = (path as NSString).standardizingPath
            guard let isDir = cache.check(path) else { return nil }
            return (path, isDir)
        }
    }

    /// Terminal cell width of a character (wide CJK and emoji take two cells).
    static func cellWidth(_ ch: Character) -> Int {
        guard let s = ch.unicodeScalars.first else { return 1 }
        if s.properties.isEmojiPresentation { return 2 }
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// Strips punctuation that usually ends a sentence rather than a URL,
    /// keeping balanced parentheses (e.g. Wikipedia links).
    static func trimmed(_ url: Substring) -> Substring {
        var u = url
        while let last = u.last, ".,;:!?'\"".contains(last) || (last == ")" && u.filter({ $0 == "(" }).count < u.filter({ $0 == ")" }).count) {
            u = u.dropLast()
        }
        return u
    }

    private static let pathTokenBoundaries: Set<Character> = [" ", "\t", "\"", "'", "`", "(", ")", "[", "]", "{", "}", "<", ">", ",", ";", "|", "=", "\u{00A0}"]
    private static let lineSuffix = try! NSRegularExpression(pattern: #"(:\d+){1,2}:?$"#)

    /// Whether a token looks enough like a path to be worth a stat() call.
    static func isPathCandidate(_ token: String) -> Bool {
        guard token.count >= 2, token.count < 1024, !token.contains("://") else { return false }
        if token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./") || token.hasPrefix("../") { return token.count > 2 }
        if token.contains("/") { return token.first != "-" && token.contains(where: \.isLetter) }
        // A bare name only counts when it has an extension, e.g. README.md.
        guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { return false }
        let ext = token[token.index(after: dot)...]
        return (1...8).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber } && ext.contains(where: \.isLetter)
            && token.first != "-"
    }

    /// Maps viewport text (logical lines; soft-wrapped rows joined) to link rects.
    static func detect(text: String, geometry g: Geometry, resolvePath: PathResolver? = nil) -> [DetectedLink] {
        var result: [DetectedLink] = []
        var row = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard row < g.rows else { break }
            // Cell position of every character in this logical line.
            var positions: [(row: Int, col: Int, width: Int)] = []
            positions.reserveCapacity(line.count)
            var col = 0, r = row
            for ch in line {
                let w = cellWidth(ch)
                if col + w > g.columns { r += 1; col = 0 }
                positions.append((r, col, w))
                col += w
            }
            let lineRows = max(1, (positions.last.map { $0.row - row + 1 }) ?? 1)

            func rects(from start: Int, count: Int) -> [CGRect] {
                let end = start + count - 1
                guard count > 0, end < positions.count else { return [] }
                var out: [CGRect] = []
                var segStart = positions[start], prev = segStart
                func close(_ a: (row: Int, col: Int, width: Int), _ b: (row: Int, col: Int, width: Int)) {
                    guard a.row < g.rows else { return }
                    let x = g.originX + CGFloat(a.col) * g.cellWidth
                    let w = CGFloat(b.col + b.width - a.col) * g.cellWidth
                    let baseline = g.baseline0 + CGFloat(a.row) * g.cellHeight
                    out.append(CGRect(x: x, y: baseline - g.cellHeight * 0.8, width: w, height: g.cellHeight))
                }
                if end > start {
                    for i in (start + 1)...end {
                        let p = positions[i]
                        if p.row != prev.row { close(segStart, prev); segStart = p }
                        prev = p
                    }
                }
                close(segStart, prev)
                return out
            }

            let s = String(line)
            var taken: [Range<Int>] = [] // character ranges already used by URLs

            // 1. URLs
            if s.contains("://") {
                let ns = s as NSString
                var charIndexAtUTF16: [Int] = []
                charIndexAtUTF16.reserveCapacity(ns.length)
                for (i, ch) in s.enumerated() {
                    for _ in 0..<ch.utf16.count { charIndexAtUTF16.append(i) }
                }
                for m in urlRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    guard let range = Range(m.range, in: s) else { continue }
                    let url = trimmed(s[range])
                    guard url.count > 8 else { continue }
                    let start = charIndexAtUTF16[m.range.location]
                    let rs = rects(from: start, count: url.count)
                    guard !rs.isEmpty else { continue }
                    taken.append(start..<(start + url.count))
                    result.append(DetectedLink(target: String(url), text: String(url), kind: .url, rects: rs))
                }
            }

            // 2. Local paths (only if they exist)
            if let resolvePath {
                let chars = Array(s)
                var i = 0
                while i < chars.count {
                    if pathTokenBoundaries.contains(chars[i]) { i += 1; continue }
                    var j = i
                    while j < chars.count, !pathTokenBoundaries.contains(chars[j]) { j += 1 }
                    defer { i = j }
                    guard !taken.contains(where: { $0.overlaps(i..<j) }) else { continue }
                    var token = String(chars[i..<j])
                    // Trailing sentence punctuation, then compiler-style ":12:5".
                    while let last = token.last, ".:!?".contains(last), token.count > 1 { token.removeLast() }
                    // The suffix needs a ":", so skip the regex for most tokens.
                    if token.contains(":") {
                        let ns = token as NSString
                        if let m = lineSuffix.firstMatch(in: token, range: NSRange(location: 0, length: ns.length)) {
                            token = ns.substring(to: m.range.location)
                        }
                    }
                    guard isPathCandidate(token), let hit = resolvePath(token) else { continue }
                    let rs = rects(from: i, count: token.count)
                    guard !rs.isEmpty else { continue }
                    result.append(DetectedLink(target: hit.path, text: token, kind: .file(isDirectory: hit.isDirectory), rects: rs))
                }
            }
            row += lineRows
        }
        return result
    }
}

/// Caches existence checks so re-scanning the viewport doesn't re-stat every
/// path each time. Entries expire so newly created files get picked up.
final class FileCheckCache {
    private var entries: [String: (isDir: Bool?, at: Date)] = [:]
    private let ttl: TimeInterval = 5

    /// nil when the path doesn't exist; otherwise whether it's a directory.
    func check(_ path: String) -> Bool? {
        let now = Date()
        if let e = entries[path], now.timeIntervalSince(e.at) < ttl { return e.isDir }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let value: Bool? = exists ? isDir.boolValue : nil
        if entries.count > 5000 { entries.removeAll() }
        entries[path] = (value, now)
        return value
    }
}
