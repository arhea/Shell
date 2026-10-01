import AppKit
import SwiftUI

// MARK: - Inline

enum InlineMarkdown {
    /// Inline GFM (bold, italics, strikethrough, code, links, autolinks,
    /// footnote references, a little inline HTML) plus highlighted `/skill`
    /// and `@mention` tokens. With a `directory`, `@file` mentions and
    /// code spans naming files that exist become links.
    @MainActor
    static func attributed(_ text: String, palette: ClaudePalette, mentions: MentionStyle? = nil, directory: String? = nil,
                           codeFont: Font? = nil) -> AttributedString {
        let source = inlineHTML(text)
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        for run in result.runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    // Neutral, not accent-colored: code reads as code without shouting.
                    result[run.range].font = codeFont ?? .system(.body, design: .monospaced)
                    result[run.range].foregroundColor = palette.foreground
                    result[run.range].backgroundColor = palette.foreground.opacity(0.08)
                    if let directory, let url = ClaudeLinks.fileURL(String(result[run.range].characters), directory: directory) {
                        result[run.range].link = url
                    }
                }
                if intent.contains(.strikethrough) {
                    result[run.range].strikethroughStyle = .single
                    result[run.range].foregroundColor = palette.dim
                }
            }
            if let image = run.imageURL, run.link == nil {
                result[run.range].link = image
            }
            if run.link != nil, run.inlinePresentationIntent?.contains(.code) != true {
                result[run.range].foregroundColor = palette.blue
                result[run.range].underlineStyle = .single
            }
        }
        autolink(&result, palette: palette)
        footnoteReferences(&result, palette: palette)
        if let mentions { highlightTokens(in: &result, style: mentions, palette: palette, directory: directory) }
        return result
    }

    // MARK: Inline HTML

    // Regex is immutable once built; it just isn't marked Sendable.

    nonisolated(unsafe) private static let htmlReplacements: [(Regex<AnyRegexOutput>, String)] = ([
        (#"<br\s*/?>"#, "\n"),
        (#"</?(?:b|strong)>"#, "**"),
        (#"</?(?:i|em)>"#, "*"),
        (#"</?(?:s|del|strike)>"#, "~~"),
        (#"</?(?:code|kbd|samp)>"#, "`"),
        (#"<a\s+[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>"#, "[$2]($1)"),
        (#"<!--[\s\S]*?-->"#, ""),
        (#"</?(?:sub|sup|u|ins|mark|span|p|div|small|big|abbr|cite|q|var|picture|source)(?:\s[^>]*)?>"#, ""),
    ] as [(String, String)]).compactMap { pattern, template in
        (try? Regex(pattern).ignoresCase()).map { ($0, template) }
    }

    /// Maps the inline HTML GitHub allows onto markdown, outside code spans.
    static func inlineHTML(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out = ""
        var rest = Substring(text)
        // Alternate between prose and code spans; only prose is rewritten.
        while !rest.isEmpty {
            guard let tick = rest.firstIndex(of: "`") else {
                out += rewriteHTML(String(rest))
                break
            }
            out += rewriteHTML(String(rest[..<tick]))
            let run = rest[tick...].prefix { $0 == "`" }
            let afterOpen = rest.index(tick, offsetBy: run.count)
            if let close = rest[afterOpen...].range(of: String(run)) {
                out += rest[tick..<close.upperBound]
                rest = rest[close.upperBound...]
            } else {
                out += rest[tick...]
                break
            }
        }
        return out
    }

    private static func rewriteHTML(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var s = s
        for (regex, template) in htmlReplacements {
            s = s.replacing(regex) { match in
                var out = template
                for i in stride(from: match.output.count - 1, through: 1, by: -1) {
                    let value = match.output[i].substring.map(String.init) ?? ""
                    out = out.replacingOccurrences(of: "$\(i)", with: value)
                }
                return out
            }
        }
        return s
    }

    // MARK: Autolinks and footnotes

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// GFM's extended autolinks: bare `https://…`, `www.…` and email addresses.
    @MainActor
    private static func autolink(_ text: inout AttributedString, palette: ClaudePalette) {
        let plain = String(text.characters)
        guard let detector = linkDetector, plain.contains(".") else { return }
        let ns = plain as NSString
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: plain) else { continue }
            let raw = plain[range].lowercased()
            let explicit = raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("www.")
            guard explicit || url.scheme == "mailto",
                  let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            let span = lower..<upper
            guard text[span].runs.allSatisfy({ $0.link == nil && $0.inlinePresentationIntent?.contains(.code) != true }) else { continue }
            text[span].link = url
            text[span].foregroundColor = palette.blue
            text[span].underlineStyle = .single
        }
    }

    // Regex is immutable once built; it just isn't marked Sendable.

    nonisolated(unsafe) static let footnotePattern = /\[\^([^\]\s]+)\]/

    /// `[^1]` → a small raised reference.
    @MainActor
    private static func footnoteReferences(_ text: inout AttributedString, palette: ClaudePalette) {
        let plain = String(text.characters)
        guard plain.contains("[^") else { return }
        for match in plain.matches(of: footnotePattern).reversed() {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: text),
                  let upper = AttributedString.Index(match.range.upperBound, within: text),
                  text[lower..<upper].runs.allSatisfy({ $0.inlinePresentationIntent?.contains(.code) != true }) else { continue }
            var ref = AttributedString(String(match.output.1))
            ref.foregroundColor = palette.blue
            ref.baselineOffset = 5
            ref.font = .system(size: 9, weight: .semibold)
            text.replaceSubrange(lower..<upper, with: ref)
        }
    }

    // MARK: Mentions

    struct MentionStyle: Equatable {
        var skills: Set<String>
        var commands: Set<String>
        var mcpServers: Set<String>
        var agents: Set<String>
    }

    enum TokenKind { case skill, command, mcp, agent, file }

    /// Classifies a `/name` or `@name` token.
    static func classify(_ token: String, style: MentionStyle) -> TokenKind? {
        guard token.count > 1 else { return nil }
        let name = String(token.dropFirst())
        if token.hasPrefix("/") {
            if style.skills.contains(name) { return .skill }
            if style.commands.contains(name) { return .command }
            return nil
        }
        if token.hasPrefix("@") {
            if style.mcpServers.contains(name) { return .mcp }
            if name.hasPrefix("agent-"), style.agents.contains(String(name.dropFirst(6))) { return .agent }
            if name.contains("/") || name.contains(".") { return .file }
        }
        return nil
    }

    // Regex is immutable once built; it just isn't marked Sendable.

    nonisolated(unsafe) static let tokenPattern = /(?:^|[\s(\[])([\/@][\w\-:.\/~]+)/.anchorsMatchLineEndings()

    @MainActor
    private static func highlightTokens(in text: inout AttributedString, style: MentionStyle, palette: ClaudePalette, directory: String?) {
        let plain = String(text.characters)
        for match in plain.matches(of: tokenPattern) {
            let token = String(match.output.1)
            guard let kind = classify(token, style: style),
                  let lower = AttributedString.Index(match.output.1.startIndex, within: text),
                  let upper = AttributedString.Index(match.output.1.endIndex, within: text) else { continue }
            // Leave links (e.g. /path inside a URL) alone.
            guard text[lower..<upper].runs.allSatisfy({ $0.link == nil }) else { continue }
            text[lower..<upper].foregroundColor = color(for: kind, palette: palette)
            text[lower..<upper].backgroundColor = color(for: kind, palette: palette).opacity(0.14)
            text[lower..<upper].font = .body.weight(.semibold)
            if kind == .file, let directory, let url = ClaudeLinks.fileURL(String(token.dropFirst()), directory: directory) {
                text[lower..<upper].link = url
            }
        }
    }

    @MainActor
    static func color(for kind: TokenKind, palette: ClaudePalette) -> Color {
        switch kind {
        case .skill: palette.magenta
        case .command: palette.claude
        case .mcp: palette.cyan
        case .agent: palette.yellow
        case .file: palette.blue
        }
    }
}

// MARK: - Links

/// Opens links from Claude's replies. Web links go to the browser; file
/// references — `[Bar.tsx:42](src/Bar.tsx:42)`, `path#L12`, or a code span
/// naming a file — open in the preferred editor, at the line when it can.
enum ClaudeLinks {
    static let webSchemes: Set<String> = ["http", "https", "mailto"]

    /// Splits `path:12:3` or `path#L12` into the path and line.
    static func splitLine(_ raw: String) -> (path: String, line: Int?) {
        if let m = raw.wholeMatch(of: /(.+?)#L(\d+)(?:-L?\d+)?/) { return (String(m.output.1), Int(m.output.2)) }
        if let m = raw.wholeMatch(of: /(.+?):(\d+)(?::\d+)?(?:-\d+)?/) { return (String(m.output.1), Int(m.output.2)) }
        return (raw, nil)
    }

    /// A file URL (with the line as a fragment) when `reference` names a
    /// file that exists, relative to `directory`.
    static func fileURL(_ reference: String, directory: String) -> URL? {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty, reference.count < 400, !reference.contains(" "), !reference.contains("\n"),
              reference.contains("/") || reference.contains(".") else { return nil }
        let (path, line) = splitLine(reference)
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
        guard FileManager.default.fileExists(atPath: full) else { return nil }
        var components = URLComponents(url: URL(fileURLWithPath: full), resolvingAgainstBaseURL: false)
        if let line { components?.fragment = "L\(line)" }
        return components?.url
    }

    @MainActor
    static func open(_ url: URL, directory: String?) -> OpenURLAction.Result {
        if let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme) { return .systemAction(url) }
        let reference: String
        if url.isFileURL {
            reference = url.path + (url.fragment.map { "#\($0)" } ?? "")
        } else {
            // Relative links ("src/a.swift:12") and ones that parse with a
            // bogus scheme ("Bar.tsx:42").
            reference = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        }
        guard let file = fileURL(reference, directory: directory ?? FileManager.default.currentDirectoryPath) else {
            return url.scheme == nil ? .discarded : .systemAction(url)
        }
        let line = file.fragment.flatMap { Int($0.dropFirst()) }
        openInEditor(URL(fileURLWithPath: file.path), line: line)
        return .handled
    }

    @MainActor
    static func openInEditor(_ file: URL, line: Int?) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: file.path)
            return
        }
        guard let editor = ExternalEditor.preferred else {
            NSWorkspace.shared.open(file)
            return
        }
        // VS Code and Cursor jump to a line through their URL handlers.
        let schemes = ["com.microsoft.VSCode": "vscode", "com.microsoft.VSCodeInsiders": "vscode-insiders", "com.todesktop.230313mzl4w4u92": "cursor"]
        if let line, let scheme = schemes[editor.bundleID],
           let url = URL(string: "\(scheme)://file\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path):\(line)") {
            SettingsStore.shared.settings.claudePreferredEditor = editor.bundleID
            NSWorkspace.shared.open(url)
        } else {
            editor.open([file])
        }
    }
}

// MARK: - Code highlighting

/// A small, language-agnostic highlighter: comments, strings, numbers and
/// common keywords. Good enough to make code blocks readable.
enum CodeHighlighter {
    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case", "switch",
        "default", "break", "continue", "guard", "in", "do", "try", "catch", "throw", "throws", "async", "await", "static",
        "private", "public", "internal", "fileprivate", "protocol", "extension", "self", "Self", "nil", "true", "false",
        "def", "elif", "from", "as", "with", "pass", "None", "True", "False", "lambda", "yield", "not", "and", "or", "is",
        "function", "const", "new", "this", "typeof", "instanceof", "export", "interface", "type", "null", "undefined",
        "package", "go", "chan", "select", "defer", "map", "range", "fn", "mut", "impl", "pub", "use", "mod", "match",
        "then", "fi", "done", "esac", "local", "echo", "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN",
        "val", "fun", "override", "object", "when", "void", "int", "string", "bool", "final", "abstract", "extends", "implements",
    ]

    // Regex is immutable once built; it just isn't marked Sendable.
    nonisolated(unsafe) static let pattern = /(\/\/[^\n]*|#[^\n{]*$|\/\*[\s\S]*?\*\/|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`]*`|\b\d[\d_.xXa-fA-F]*\b|\b[A-Za-z_][A-Za-z0-9_]*\b)/.anchorsMatchLineEndings()

    enum Token { case comment, string, number, keyword, type }

    static func tokens(in code: String, language: String) -> [(Range<String.Index>, Token)] {
        let hashComments = ["", "sh", "bash", "zsh", "shell", "python", "py", "ruby", "rb", "yaml", "yml", "toml", "make", "makefile", "dockerfile", "r"]
            .contains(language.lowercased())
        var out: [(Range<String.Index>, Token)] = []
        for m in code.matches(of: pattern) {
            let s = m.output.0
            let token: Token
            if s.hasPrefix("//") || s.hasPrefix("/*") {
                token = .comment
            } else if s.hasPrefix("#") {
                guard hashComments else { continue }
                token = .comment
            } else if s.hasPrefix("\"") || s.hasPrefix("'") || s.hasPrefix("`") {
                token = .string
            } else if s.first?.isNumber == true {
                token = .number
            } else if keywords.contains(String(s)) {
                token = .keyword
            } else if s.first?.isUppercase == true, s.count > 1 {
                token = .type
            } else {
                continue
            }
            out.append((m.range, token))
        }
        return out
    }

    @MainActor private static var highlightCache = LRUCache<String, AttributedString>(capacity: 300)

    /// Highlighted code, cached: finished code blocks re-render (theme, scroll,
    /// a new message below) without re-running the highlighter.
    @MainActor
    static func attributed(_ code: String, language: String, palette: ClaudePalette) -> AttributedString {
        let key = language + "\u{1}" + (palette.isDark ? "d" : "l") + "\u{1}" + code
        if let hit = highlightCache[key] { return hit }
        let result = highlight(code, language: language, palette: palette)
        highlightCache[key] = result
        return result
    }

    @MainActor
    private static func highlight(_ code: String, language: String, palette: ClaudePalette) -> AttributedString {
        var result = AttributedString(code)
        for (range, token) in tokens(in: code, language: language) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = color(token, palette)
        }
        return result
    }

    @MainActor
    static func color(_ token: Token, _ palette: ClaudePalette) -> Color {
        switch token {
        case .comment: palette.dim
        case .string: palette.green
        case .number: palette.yellow
        case .keyword: palette.magenta
        case .type: palette.cyan
        }
    }
}
