import Foundation

// GitHub Flavored Markdown → blocks, plus the cache the transcript parses through.

// MARK: - Block parsing

/// GitHub Flavored Markdown split into the blocks the transcript renders
/// natively: fenced and indented code, ATX and setext headings, nested
/// quotes, GitHub alerts, task lists, tables with alignment, footnotes,
/// `<details>` and standalone images.
enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(Int, String)
    case code(language: String, code: String, closed: Bool)
    case list(items: [ListItem])
    indirect case quote([MarkdownBlock])
    /// `> [!NOTE]`, `> [!WARNING]`…
    indirect case alert(AlertKind, [MarkdownBlock])
    /// `<details><summary>…</summary>…</details>`
    indirect case details(summary: String, blocks: [MarkdownBlock])
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case image(alt: String, source: String)
    case footnotes([Footnote])
    case rule

    struct ListItem: Hashable {
        var marker: String // "•", "1.", "☐", "☑"
        /// The item's content; may hold several blocks (paragraphs, code).
        var text: String
        var indent: Int
    }

    enum AlertKind: String, Hashable, CaseIterable {
        case note, tip, important, warning, caution
    }

    enum TableAlignment: Hashable { case leading, center, trailing }

    struct Footnote: Hashable {
        var label: String
        var text: String
    }

    var isList: Bool {
        if case .list = self { return true }
        return false
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map(expandTabs)
        var footnotes: [Footnote] = []
        var blocks = parseBlocks(extractFootnotes(lines, into: &footnotes))
        if !footnotes.isEmpty { blocks.append(.footnotes(footnotes)) }
        return blocks
    }

    // MARK: Blocks

    private static func parseBlocks(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0
        func flush() {
            let p = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { blocks.append(.paragraph(p)) }
            paragraph = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingSpaces(line)
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            // Indented code, unless it continues a paragraph or follows a list.
            if indent >= 4, paragraph.isEmpty, !(blocks.last?.isList ?? false) {
                var code: [String] = []
                while i < lines.count, isBlank(lines[i]) || leadingSpaces(lines[i]) >= 4 {
                    code.append(String(lines[i].dropFirst(min(4, leadingSpaces(lines[i])))))
                    i += 1
                }
                while code.last.map(isBlank) == true { code.removeLast() }
                blocks.append(.code(language: "", code: code.joined(separator: "\n"), closed: true))
                continue
            }
            if let fence = Fence(line) {
                flush()
                i += 1
                var code: [String] = []
                var closed = false
                while i < lines.count {
                    if fence.isClosed(by: lines[i]) {
                        closed = true
                        i += 1
                        break
                    }
                    code.append(fence.strip(lines[i]))
                    i += 1
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n"), closed: closed))
                continue
            }
            if indent < 4, let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level, headingText(trimmed, level: level)))
                i += 1
                continue
            }
            // Setext: a paragraph underlined with === or ---.
            if indent < 4, !paragraph.isEmpty, let level = setextLevel(trimmed) {
                let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                paragraph = []
                blocks.append(.heading(level, text))
                i += 1
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !t.isEmpty, let last = inner.last, !isBlank(last), !startsBlock(lines[i]) {
                        inner.append(lines[i]) // lazy continuation
                    } else {
                        break
                    }
                    i += 1
                }
                if let first = inner.first, let kind = alertKind(first) {
                    blocks.append(.alert(kind, parseBlocks(Array(inner.dropFirst()))))
                } else {
                    blocks.append(.quote(parseBlocks(inner)))
                }
                continue
            }
            if trimmed.lowercased().hasPrefix("<details") {
                flush()
                var body: [String] = []
                var depth = 0
                while i < lines.count {
                    let lower = lines[i].lowercased()
                    depth += lower.components(separatedBy: "<details").count - 1
                    depth -= lower.components(separatedBy: "</details>").count - 1
                    body.append(lines[i])
                    i += 1
                    if depth <= 0 { break }
                }
                blocks.append(details(body.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("<!--") {
                flush()
                while i < lines.count, !lines[i].contains("-->") { i += 1 }
                i += 1
                continue
            }
            if let alignments = tableStart(lines, at: i) {
                flush()
                let header = tableCells(lines[i])
                i += 2
                var rows: [[String]] = []
                while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"), !startsBlock(lines[i]) {
                    var row = tableCells(lines[i])
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, alignments: alignments, rows: rows))
                continue
            }
            if listItem(line) != nil {
                flush()
                let (items, next) = parseList(lines, from: i)
                blocks.append(.list(items: items))
                i = next
                continue
            }
            if paragraph.isEmpty, let image = standaloneImage(trimmed) {
                blocks.append(image)
                i += 1
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    // MARK: Lists

    /// Flattens nested lists into items with an indent level; continuation
    /// lines, loose paragraphs and fenced code stay inside their item.
    private static func parseList(_ lines: [String], from start: Int) -> ([ListItem], Int) {
        var items: [ListItem] = []
        var contentColumns: [Int] = []
        var levels: [Int] = [] // indentation columns of the open nesting levels
        var i = start
        func appendToLast(_ s: String, separator: String = "\n") {
            items[items.count - 1].text += items[items.count - 1].text.isEmpty ? s : separator + s
        }
        /// Appends a continuation line, keeping a fenced block inside the item.
        func continuation(_ line: String, column: Int) {
            let content = String(line.dropFirst(min(leadingSpaces(line), column)))
            appendToLast(content)
            i += 1
            guard let fence = Fence(content) else { return }
            while i < lines.count {
                let inner = String(lines[i].dropFirst(min(leadingSpaces(lines[i]), column)))
                appendToLast(inner)
                i += 1
                if fence.isClosed(by: inner) { break }
            }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !isRule(trimmed), let item = listItem(line) {
                while let last = levels.last, last > item.column { levels.removeLast() }
                if levels.last != item.column { levels.append(item.column) }
                items.append(ListItem(marker: item.marker, text: item.text, indent: levels.count - 1))
                contentColumns.append(item.contentColumn)
                i += 1
                if let fence = Fence(item.text) {
                    while i < lines.count {
                        let inner = String(lines[i].dropFirst(min(leadingSpaces(lines[i]), item.contentColumn)))
                        appendToLast(inner)
                        i += 1
                        if fence.isClosed(by: inner) { break }
                    }
                }
                continue
            }
            guard let column = contentColumns.last else { break }
            if trimmed.isEmpty {
                var j = i + 1
                while j < lines.count, isBlank(lines[j]) { j += 1 }
                guard j < lines.count else { break }
                if listItem(lines[j]) != nil, !isRule(lines[j].trimmingCharacters(in: .whitespaces)) {
                    i = j
                } else if leadingSpaces(lines[j]) >= max(2, column) {
                    appendToLast("")
                    i = j
                    continuation(lines[j], column: column)
                } else {
                    break
                }
                continue
            }
            if leadingSpaces(line) >= 2 || !startsBlock(line) {
                continuation(line, column: column)
                continue
            }
            break
        }
        return (items, i)
    }

    private struct ListStart {
        var column: Int
        var contentColumn: Int
        var marker: String
        var text: String
    }

    private static func listItem(_ line: String) -> ListStart? {
        let column = leadingSpaces(line)
        let s = line.dropFirst(column)
        var marker: String
        var width: Int
        if let c = s.first, "-*+".contains(c), s.dropFirst().first.map({ $0 == " " }) ?? true {
            marker = "•"
            width = 1
        } else {
            let digits = s.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let delimiter = s.dropFirst(digits.count).first, delimiter == "." || delimiter == ")",
                  s.dropFirst(digits.count + 1).first.map({ $0 == " " }) ?? true else { return nil }
            marker = "\(digits)."
            width = digits.count + 1
        }
        var rest = s.dropFirst(width)
        let gap = rest.prefix { $0 == " " }.count
        rest = rest.dropFirst(gap)
        // An empty bullet line ("-") only counts when it can't be a setext underline.
        if rest.isEmpty && marker == "•" && s.count == 1 { return nil }
        for (box, checked) in [("[ ]", "☐"), ("[x]", "☑"), ("[X]", "☑")] where rest.hasPrefix(box) {
            let after = rest.dropFirst(3)
            if after.isEmpty || after.hasPrefix(" ") {
                marker = checked
                rest = after.drop { $0 == " " }
            }
            break
        }
        return ListStart(column: column, contentColumn: column + width + max(1, min(gap, 4)), marker: marker, text: String(rest))
    }

    // MARK: Line helpers

    private static func expandTabs(_ line: String) -> String {
        guard line.hasPrefix("\t") || line.hasPrefix(" ") else { return line }
        let lead = line.prefix { $0 == "\t" || $0 == " " }
        guard lead.contains("\t") else { return line }
        var col = 0
        for c in lead { col = c == "\t" ? (col / 4 + 1) * 4 : col + 1 }
        return String(repeating: " ", count: col) + line.dropFirst(lead.count)
    }

    private static func leadingSpaces(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    /// Whether a line would start a new block rather than continue a paragraph.
    private static func startsBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if leadingSpaces(line) >= 4 { return false }
        return Fence(line) != nil || headingLevel(t) != nil || isRule(t) || t.hasPrefix(">")
            || listItem(line) != nil || t.lowercased().hasPrefix("<details")
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.count > hashes, s[s.index(s.startIndex, offsetBy: hashes)] == " " else { return nil }
        return hashes
    }

    /// Heading text without the opening hashes or an optional closing run.
    private static func headingText(_ s: String, level: Int) -> String {
        var text = s.dropFirst(level).trimmingCharacters(in: .whitespaces)
        if let r = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func setextLevel(_ s: String) -> Int? {
        guard let c = s.first, c == "=" || c == "-", s.allSatisfy({ $0 == c }) else { return nil }
        return c == "=" ? 1 : 2
    }

    private static func isRule(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
        return compact.allSatisfy { $0 == c }
    }

    private static func alertKind(_ line: String) -> AlertKind? {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("[!"), t.hasSuffix("]") else { return nil }
        return AlertKind(rawValue: String(t.dropFirst(2).dropLast()))
    }

    // Regex is immutable once built; it just isn't marked Sendable.

    private nonisolated(unsafe) static let imagePattern = /^!\[([^\]]*)\]\(\s*<?([^\s>)]+)>?(?:\s+"[^"]*")?\s*\)$/

    private static func standaloneImage(_ s: String) -> MarkdownBlock? {
        guard let m = s.wholeMatch(of: imagePattern) else { return nil }
        return .image(alt: String(m.output.1), source: String(m.output.2))
    }

    private static func details(_ html: String) -> MarkdownBlock {
        var body = html
        if let open = body.range(of: #"<details[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            body.removeSubrange(body.startIndex..<open.upperBound)
        }
        if let close = body.range(of: "</details>", options: [.caseInsensitive, .backwards]) {
            body.removeSubrange(close.lowerBound..<body.endIndex)
        }
        var summary = "Details"
        if let r = body.range(of: #"<summary[^>]*>[\s\S]*?</summary>"#, options: [.regularExpression, .caseInsensitive]) {
            summary = body[r].replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeSubrange(r)
        }
        return .details(summary: summary, blocks: parseBlocks(body.components(separatedBy: "\n")))
    }

    // MARK: Footnotes

    // Regex is immutable once built; it just isn't marked Sendable.

    private nonisolated(unsafe) static let footnoteDefinition = /^ {0,3}\[\^([^\]\s]+)\]:\s?(.*)$/

    /// Pulls `[^label]: text` definitions (and their indented continuation
    /// lines) out of the flow, skipping fenced code.
    private static func extractFootnotes(_ lines: [String], into notes: inout [Footnote]) -> [String] {
        guard lines.contains(where: { $0.contains("[^") }) else { return lines }
        var out: [String] = []
        var fence: Fence?
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let open = fence {
                if open.isClosed(by: line) { fence = nil }
                out.append(line)
                i += 1
                continue
            }
            if let f = Fence(line) {
                fence = f
                out.append(line)
                i += 1
                continue
            }
            if let m = line.wholeMatch(of: footnoteDefinition) {
                var text = String(m.output.2)
                i += 1
                while i < lines.count, !isBlank(lines[i]), leadingSpaces(lines[i]) >= 2 {
                    text += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                notes.append(Footnote(label: String(m.output.1), text: text))
                continue
            }
            out.append(line)
            i += 1
        }
        return out
    }

    // MARK: Tables

    /// The column alignments when `lines[i]` starts a GFM table.
    private static func tableStart(_ lines: [String], at i: Int) -> [TableAlignment]? {
        guard i + 1 < lines.count, lines[i].contains("|"), leadingSpaces(lines[i]) < 4 else { return nil }
        let delimiter = lines[i + 1].trimmingCharacters(in: .whitespaces)
        guard delimiter.contains("-"), delimiter.allSatisfy({ "|-: ".contains($0) }) else { return nil }
        let cells = tableCells(delimiter)
        guard cells.count == tableCells(lines[i]).count,
              cells.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) else { return nil }
        // A single column needs a pipe in the delimiter row; otherwise it's a setext heading.
        guard cells.count > 1 || delimiter.contains("|") else { return nil }
        return cells.map { c in
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    /// Splits a row on unescaped pipes outside code spans; `\|` becomes `|`.
    static func tableCells(_ line: String) -> [String] {
        func split(protectCode: Bool) -> ([String], Bool) {
            var s = Substring(line.trimmingCharacters(in: .whitespaces))
            if s.hasPrefix("|") { s = s.dropFirst() }
            if s.hasSuffix("|"), !s.hasSuffix("\\|") { s = s.dropLast() }
            var cells: [String] = []
            var cell = ""
            var inCode = false
            var escaped = false
            for c in s {
                if escaped {
                    if c != "|" { cell.append("\\") }
                    cell.append(c)
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "|", !inCode {
                    cells.append(cell.trimmingCharacters(in: .whitespaces))
                    cell = ""
                } else {
                    if c == "`", protectCode { inCode.toggle() }
                    cell.append(c)
                }
            }
            if escaped { cell.append("\\") }
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            return (cells, !inCode)
        }
        let (cells, balanced) = split(protectCode: true)
        return balanced ? cells : split(protectCode: false).0
    }
}

/// A ``` or ~~~ code fence opener.
private struct Fence {
    let char: Character
    let length: Int
    let indent: Int
    let language: String

    init?(_ line: String) {
        let indent = line.prefix { $0 == " " }.count
        guard indent < 4 else { return nil }
        let s = line.dropFirst(indent)
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        let run = s.prefix { $0 == c }.count
        guard run >= 3 else { return nil }
        let info = s.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        char = c
        length = run
        self.indent = indent
        // "ts title=x" or "{.python}" → the first word. A file name ("bash
        // repro.sh", `title="a.ts"`, "bash:repro.sh") rides along as "lang:name".
        let words = info.split(separator: " ")
        let first = String(words.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
        var title: String?
        for word in words.dropFirst() {
            if let m = word.wholeMatch(of: /(?:title|filename|file)="?([^"]+)"?/) {
                title = String(m.output.1)
                break
            }
            if title == nil, word.contains("."), !word.contains("="), !word.hasPrefix("{") { title = String(word) }
        }
        language = first.contains(":") ? first : title.map { first + ":" + $0 } ?? first
    }

    func isClosed(by line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return line.prefix { $0 == " " }.count < 4 && t.count >= length && t.allSatisfy { $0 == char }
    }

    /// Removes the opener's indentation from a content line.
    func strip(_ line: String) -> String {
        String(line.dropFirst(min(indent, line.prefix { $0 == " " }.count)))
    }
}

/// Parsed markdown, cached. A reply that's still streaming grows on every
/// token; re-parsing all of it each time is quadratic over the reply. The
/// text is split at the last paragraph break that can't change what came
/// before it (outside code fences, not inside a list, quote or table), the
/// stable head is parsed once, and only the tail is re-parsed.
@MainActor
final class MarkdownParseCache {
    static let shared = MarkdownParseCache()
    private var complete = LRUCache<String, [MarkdownBlock]>(capacity: 400)
    private var heads = LRUCache<String, [MarkdownBlock]>(capacity: 64)

    func blocks(for text: String) -> [MarkdownBlock] {
        if let hit = complete[text] { return hit }
        let result: [MarkdownBlock]
        if let split = Self.stableSplit(text) {
            let head = String(text[..<split])
            let headBlocks = heads[head] ?? {
                let b = MarkdownBlock.parse(head)
                heads[head] = b
                return b
            }()
            result = headBlocks + MarkdownBlock.parse(String(text[split...]))
        } else {
            result = MarkdownBlock.parse(text)
        }
        complete[text] = result
        return result
    }

    /// Where a blank line ends everything before it: fences are balanced and
    /// the next line starts a new top-level paragraph (not a list item,
    /// indented continuation, quote, table row or footnote). Only worth it
    /// for longer texts.
    static func stableSplit(_ text: String) -> String.Index? {
        guard text.utf8.count > 2_000 else { return nil }
        var fenceOpen = false
        var candidate: String.Index?
        var lineStart = text.startIndex
        var previousBlank = false
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenceOpen.toggle() }
            let blank = trimmed.isEmpty
            if previousBlank, !blank, !fenceOpen, Self.startsTopLevelParagraph(line) {
                candidate = lineStart
            }
            previousBlank = blank && !fenceOpen
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        // Keep the last paragraph in the tail: it may still be growing.
        return candidate.flatMap { $0 > text.startIndex ? $0 : nil }
    }

    private static func startsTopLevelParagraph(_ line: Substring) -> Bool {
        guard let first = line.first, first != " ", first != "\t" else { return false }
        if "-*+>|[<".contains(first) { return false }
        if first.isNumber, line.prefix(6).contains(where: { $0 == "." || $0 == ")" }) { return false }
        return true
    }
}

/// A small least-recently-used cache. A streaming reply adds a new entry per
/// token batch; clearing everything when full would also throw away every
/// finished message on screen, which then re-parse and re-highlight at once.
struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var entries: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) { self.capacity = capacity }

    subscript(key: Key) -> Value? {
        mutating get {
            guard let entry = entries[key] else { return nil }
            clock &+= 1
            entries[key] = (entry.value, clock)
            return entry.value
        }
        set {
            guard let newValue else { entries[key] = nil; return }
            clock &+= 1
            if entries[key] == nil, entries.count >= capacity {
                // Drop the least recently used quarter in one pass (O(n) per eviction).
                let stale = entries.sorted { $0.value.used < $1.value.used }.prefix(max(1, capacity / 4))
                for (k, _) in stale { entries[k] = nil }
            }
            entries[key] = (newValue, clock)
        }
    }
}
