import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// Markdown covering every block kind the native Claude view renders.
private let everyBlock = """
# Heading one

## Heading two

### Heading three

A paragraph with **bold**, *italic*, ~~struck~~, `code`, [a link](https://example.com) and a footnote[^1].
Visit https://example.org or www.example.net, or mail someone@example.com.

- first item
- second item with `code`
  - nested item
- [ ] open task
- [x] done task

1. one
2. two

- a lazy item
  that wraps onto a second line

- multi-line item
  continued here

  ```swift
  let inside = true
  ```

> A quote
> over two lines

> [!NOTE]
> A note.

> [!TIP]
> A tip.

> [!IMPORTANT]
> Important.

> [!WARNING]
> Careful.

> [!CAUTION]
> Danger.

<details>
<summary>More **detail**</summary>

Hidden text.

</details>

| Left | Center | Right |
| :--- | :----: | ----: |
| a | b | c |
| `x` | **y** | z |

![remote image](https://example.com/image.png)

![local image](missing/picture.png)

```swift
// A comment
let answer = 42
struct Thing { var name = "x" }
```

---

[^1]: The footnote text.

```
unclosed fence while streaming
"""

@MainActor
final class ClaudeMarkdownViewTests: XCTestCase {
    private var palette: ClaudePalette { ClaudePalette.current }

    // MARK: Palette

    func testPaletteIsCachedPerTheme() {
        let a = ClaudePalette.current
        let b = ClaudePalette.current
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.isDark, ConfigController.shared.theme.isDark)
        XCTAssertNotNil(a.nsColor(a.red).usingColorSpace(.sRGB))
    }

    // MARK: Rendering

    func testRendersEveryBlockKind() {
        let blocks = MarkdownBlock.parse(everyBlock)
        // Every block kind is present, so each branch of the block view runs.
        XCTAssertTrue(blocks.contains { if case .heading(1, _) = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .table = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .details = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .footnotes = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .image = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .code(_, _, false) = $0 { true } else { false } })
        XCTAssertEqual(Set(blocks.compactMap { if case .alert(let k, _) = $0 { k } else { nil } }), Set(MarkdownBlock.AlertKind.allCases))

        let host = render(MarkdownView(text: everyBlock, palette: palette, fontSize: 13, directory: NSTemporaryDirectory()),
                          size: CGSize(width: 700, height: 3000))
        XCTAssertGreaterThan(host.fittingSize.height, 200)
    }

    func testRendersWithMentionsAndCustomFonts() throws {
        let dir = try makeTemporaryDirectory()
        try "x".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let style = InlineMarkdown.MentionStyle(skills: ["review"], commands: ["help"], mcpServers: ["github"], agents: ["planner"])
        withSettings({
            $0.chatFontFamily = "Helvetica"
            $0.chatCodeFontFamily = "Menlo"
            $0.chatLineHeight = 2
        }) {
            let text = "Run /review then /help with @github, @agent-planner and @main.swift. See `main.swift`.\n\n" + everyBlock
            let host = render(MarkdownView(text: text, palette: palette, mentions: style, fontSize: 15, directory: dir.path),
                              size: CGSize(width: 500, height: 3000))
            XCTAssertGreaterThan(host.fittingSize.height, 200)
        }
    }

    func testRendersLongStreamingReplyThroughTheParseCache() {
        let paragraphs = (1...60).map { "Paragraph \($0) of a long streaming reply that keeps growing." }.joined(separator: "\n\n")
        let text = paragraphs + "\n\n```python\n" + String(repeating: "x = 1  # comment\n", count: 400)
        XCTAssertNotNil(MarkdownParseCache.stableSplit(text))
        let first = MarkdownParseCache.shared.blocks(for: text)
        XCTAssertEqual(MarkdownParseCache.shared.blocks(for: text), first, "served from the cache")
        render(MarkdownView(text: text, palette: palette), size: CGSize(width: 600, height: 2000))
    }

    func testCodeBlockStates() {
        render(CodeBlockView(language: "", code: "plain", palette: palette))
        render(CodeBlockView(language: "go", code: "func main() {}", palette: palette, fontSize: 14, lineSpacing: 4, font: .system(size: 12), isComplete: true))
        // A large block still streaming isn't highlighted.
        let big = String(repeating: "let x = 1\n", count: 600)
        render(CodeBlockView(language: "swift", code: big, palette: palette, isComplete: false), size: CGSize(width: 600, height: 400))
    }

    func testAlertAndDetailsBlocks() {
        for kind in MarkdownBlock.AlertKind.allCases {
            render(AlertBlockView(kind: kind, palette: palette, fontSize: 13) { Text("Body") }, size: CGSize(width: 400, height: 100))
        }
        render(DetailsBlockView(summary: AttributedString("Summary"), palette: palette, fontSize: 13) { Text("Hidden") },
               size: CGSize(width: 400, height: 100))
        let open = render(DetailsBlockView(summary: AttributedString("Summary"), palette: palette, fontSize: 13, content: { Text("Shown") }, expanded: true),
                          size: CGSize(width: 400, height: 100))
        XCTAssertGreaterThan(open.fittingSize.height, 0)
    }

    func testTableBlockAlignments() {
        render(TableBlockView(header: ["A", "B", "C", "D"], alignments: [.leading, .center, .trailing], rows: [["1", "2", "3", "4"], ["`a`", "**b**", "c", "d"]],
                              palette: palette, fontSize: 13, directory: nil))
        render(TableBlockView(header: ["Only"], rows: [["x"]], palette: palette, fontSize: 12))
    }

    func testImageViewSources() throws {
        let dir = try makeTemporaryDirectory()
        let png = dir.appendingPathComponent("dot.png")
        try Self.pngData().write(to: png)
        for source in ["https://example.com/a.png", "dot.png", png.path, "file://" + png.path, "~/definitely-missing-\(UUID().uuidString).png", ""] {
            render(MarkdownImageView(alt: source.isEmpty ? "" : "alt", source: source, directory: dir.path, palette: palette, fontSize: 13),
                   size: CGSize(width: 400, height: 300))
        }
    }

    private static func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: Inline markdown

    func testInlineHTMLOutsideCodeSpans() {
        XCTAssertEqual(InlineMarkdown.inlineHTML("no tags"), "no tags")
        XCTAssertEqual(InlineMarkdown.inlineHTML("a<br>b"), "a\nb")
        XCTAssertEqual(InlineMarkdown.inlineHTML("<b>bold</b> <em>it</em> <del>gone</del> <kbd>K</kbd>"), "**bold** *it* ~~gone~~ `K`")
        XCTAssertEqual(InlineMarkdown.inlineHTML(#"<a href="https://x.dev">site</a>"#), "[site](https://x.dev)")
        XCTAssertEqual(InlineMarkdown.inlineHTML("x<!-- hidden -->y<sup>2</sup>"), "xy2")
        // Code spans keep their tags; an unclosed span keeps the rest verbatim.
        XCTAssertEqual(InlineMarkdown.inlineHTML("`<b>` and <b>x</b>"), "`<b>` and **x**")
        XCTAssertEqual(InlineMarkdown.inlineHTML("<i>a</i> ``<b>"), "*a* ``<b>")
    }

    func testInlineAttributesForCodeLinksAndStrikethrough() throws {
        let dir = try makeTemporaryDirectory()
        try "x".write(to: dir.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)
        let s = InlineMarkdown.attributed("`file.swift` ~~old~~ [docs](https://docs.dev) ![img](https://x.dev/i.png)", palette: palette, directory: dir.path,
                                          codeFont: .system(size: 11))
        let links = s.runs.compactMap(\.link)
        XCTAssertTrue(links.contains { $0.isFileURL && $0.lastPathComponent == "file.swift" })
        XCTAssertTrue(links.contains { $0.absoluteString == "https://docs.dev" })
        XCTAssertTrue(links.contains { $0.absoluteString == "https://x.dev/i.png" })
        XCTAssertTrue(s.runs.contains { $0.strikethroughStyle == .single })
    }

    func testAutolinksAndFootnotes() {
        let s = InlineMarkdown.attributed("See https://a.dev, www.b.dev and me@c.dev, not plain.dev, and `https://code.dev` [^note]", palette: palette)
        let links = Set(s.runs.compactMap(\.link).map(\.absoluteString))
        XCTAssertTrue(links.contains("https://a.dev"))
        XCTAssertTrue(links.contains { $0.contains("www.b.dev") })
        XCTAssertTrue(links.contains("mailto:me@c.dev"))
        XCTAssertFalse(links.contains { $0.contains("plain.dev") })
        XCTAssertFalse(links.contains { $0.contains("code.dev") })
        XCTAssertTrue(String(s.characters).hasSuffix("note"), "footnote reference becomes its label")
        // Footnote syntax inside code is left alone.
        XCTAssertTrue(String(InlineMarkdown.attributed("`[^x]`", palette: palette).characters).contains("[^x]"))
    }

    func testMentionTokensAreHighlighted() throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        let style = InlineMarkdown.MentionStyle(skills: ["s"], commands: ["c"], mcpServers: ["m"], agents: ["g"])
        let s = InlineMarkdown.attributed("/s /c @m @agent-g @src/a.swift @nope /unknown [x](https://a.dev/s)", palette: palette, mentions: style, directory: dir.path)
        let colored = s.runs.filter { $0.backgroundColor != nil }.map { String(s[$0.range].characters) }
        XCTAssertEqual(colored, ["/s", "/c", "@m", "@agent-g", "@src/a.swift"])
        XCTAssertTrue(s.runs.contains { $0.link?.lastPathComponent == "a.swift" })
        for kind in [InlineMarkdown.TokenKind.skill, .command, .mcp, .agent, .file] {
            _ = InlineMarkdown.color(for: kind, palette: palette)
        }
    }

    func testClassifyTokens() {
        let style = InlineMarkdown.MentionStyle(skills: ["s"], commands: ["c"], mcpServers: ["m"], agents: ["g"])
        XCTAssertNil(InlineMarkdown.classify("/", style: style))
        XCTAssertEqual(InlineMarkdown.classify("/s", style: style), .skill)
        XCTAssertEqual(InlineMarkdown.classify("/c", style: style), .command)
        XCTAssertNil(InlineMarkdown.classify("/x", style: style))
        XCTAssertEqual(InlineMarkdown.classify("@m", style: style), .mcp)
        XCTAssertEqual(InlineMarkdown.classify("@agent-g", style: style), .agent)
        XCTAssertEqual(InlineMarkdown.classify("@a/b", style: style), .file)
        XCTAssertNil(InlineMarkdown.classify("@plain", style: style))
        XCTAssertNil(InlineMarkdown.classify("#x", style: style))
    }

    // MARK: Links

    func testSplitLine() {
        XCTAssertEqual(ClaudeLinks.splitLine("a.swift#L12-L14").path, "a.swift")
        XCTAssertEqual(ClaudeLinks.splitLine("a.swift#L12").line, 12)
        XCTAssertEqual(ClaudeLinks.splitLine("a.swift:7:3").line, 7)
        XCTAssertEqual(ClaudeLinks.splitLine("a.swift:7-9").path, "a.swift")
        XCTAssertNil(ClaudeLinks.splitLine("a.swift").line)
    }

    func testFileURLResolvesExistingFiles() throws {
        let dir = try makeTemporaryDirectory()
        try "x".write(to: dir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeLinks.fileURL("b.swift:4", directory: dir.path)?.fragment, "L4")
        XCTAssertNil(ClaudeLinks.fileURL("b.swift", directory: dir.path)?.fragment)
        XCTAssertNotNil(ClaudeLinks.fileURL(dir.appendingPathComponent("b.swift").path, directory: "/"))
        XCTAssertNil(ClaudeLinks.fileURL("", directory: dir.path))
        XCTAssertNil(ClaudeLinks.fileURL("has space.swift", directory: dir.path))
        XCTAssertNil(ClaudeLinks.fileURL("noextension", directory: dir.path))
        XCTAssertNil(ClaudeLinks.fileURL("missing.swift", directory: dir.path))
    }

    func testOpenLinksWithoutAFileGoToTheSystem() {
        func isSystem(_ r: OpenURLAction.Result) -> Bool { String(describing: r).contains("system") }
        func isDiscarded(_ r: OpenURLAction.Result) -> Bool { String(describing: r).contains("discard") }
        XCTAssertTrue(isSystem(ClaudeLinks.open(URL(string: "https://example.com")!, directory: nil)))
        XCTAssertTrue(isSystem(ClaudeLinks.open(URL(string: "mailto:a@b.dev")!, directory: nil)))
        // No such file: relative links are dropped, other schemes go to the system.
        XCTAssertTrue(isDiscarded(ClaudeLinks.open(URL(string: "src/missing-\(UUID().uuidString).swift")!, directory: NSTemporaryDirectory())))
        XCTAssertTrue(isSystem(ClaudeLinks.open(URL(string: "zed://missing-\(UUID().uuidString)")!, directory: nil)))
        XCTAssertTrue(isDiscarded(ClaudeLinks.open(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.swift"), directory: nil)) ||
                      isSystem(ClaudeLinks.open(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.swift"), directory: nil)))
    }

    // MARK: Highlighting

    func testHighlighterTokens() {
        let swift = CodeHighlighter.tokens(in: "// c\nlet x = \"s\" + 'c' + `t` /* b */ 0x1F Foo bar", language: "swift").map(\.1)
        XCTAssertEqual(swift.filter { $0 == .comment }.count, 2)
        XCTAssertEqual(swift.filter { $0 == .string }.count, 3)
        XCTAssertTrue(swift.contains(.number))
        XCTAssertTrue(swift.contains(.keyword))
        XCTAssertTrue(swift.contains(.type))
        // `#` starts a comment only in hash-comment languages.
        XCTAssertEqual(CodeHighlighter.tokens(in: "# note", language: "python").map(\.1), [.comment])
        XCTAssertTrue(CodeHighlighter.tokens(in: "# note", language: "swift").allSatisfy { $0.1 != .comment })
        for token in [CodeHighlighter.Token.comment, .string, .number, .keyword, .type] {
            _ = CodeHighlighter.color(token, palette)
        }
    }

    func testHighlightIsCached() {
        let code = "let cached = \(UUID().uuidString.count)"
        let a = CodeHighlighter.attributed(code, language: "swift", palette: palette)
        let b = CodeHighlighter.attributed(code, language: "swift", palette: palette)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.runs.contains { $0.foregroundColor != nil })
    }

    // MARK: Parser cache

    func testStableSplitSkipsShortAndStructuredText() {
        XCTAssertNil(MarkdownParseCache.stableSplit("short"))
        let list = (1...200).map { "- item \($0)" }.joined(separator: "\n\n")
        XCTAssertNil(MarkdownParseCache.stableSplit(list))
        let fenced = "```\n" + String(repeating: "code\n\nmore\n", count: 300) + "```"
        XCTAssertNil(MarkdownParseCache.stableSplit(fenced))
        let numbered = (1...200).map { "\($0). step" }.joined(separator: "\n\n")
        XCTAssertNil(MarkdownParseCache.stableSplit(numbered))
    }

    func testLRUCacheEvictsLeastRecentlyUsed() {
        var cache = LRUCache<Int, String>(capacity: 4)
        for i in 0..<4 { cache[i] = "\(i)" }
        _ = cache[0] // most recent now
        cache[4] = "4"
        XCTAssertNil(cache[1], "the least recently used entry went first")
        XCTAssertEqual(cache[0], "0")
        cache[0] = nil
        XCTAssertNil(cache[0])
    }
}

// MARK: - Typography

@MainActor
final class ChatTypographyFontTests: XCTestCase {
    func testFontsFallBackToSystem() {
        var s = AppSettings()
        s.chatFontFamily = ""
        let t = ChatTypography.from(s)
        XCTAssertEqual(t.nsFont().pointSize, t.size)
        XCTAssertEqual(t.nsFont(size: 20).pointSize, 20)
        _ = t.font()
        _ = t.font(size: 18, weight: .bold)
        _ = t.codeFont()
        _ = t.codeFont(size: 9)
    }

    func testNamedFamilies() {
        var s = AppSettings()
        s.chatFontFamily = "Helvetica"
        let t = ChatTypography.from(s)
        XCTAssertEqual(t.nsFont(size: 15).familyName, "Helvetica")
        _ = t.font(weight: .semibold)
        s.chatFontFamily = "No Such Font \(UUID().uuidString)"
        XCTAssertEqual(ChatTypography.from(s).nsFont(size: 15).pointSize, 15)
    }

    func testPreferencesFollowSettings() {
        withSettings({
            $0.claudeToolCalls = .showAll
            $0.claudeDiffStyle = .unified
            $0.chatFontSize = 21
        }) {
            XCTAssertEqual(ChatPreferences.shared.toolCalls, .showAll)
            XCTAssertEqual(ChatPreferences.shared.diffStyle, .unified)
            XCTAssertEqual(ChatTypography.current.size, 21)
        }
        XCTAssertEqual(ChatPreferences.shared.toolCalls, SettingsStore.shared.settings.claudeToolCalls)
    }
}

// MARK: - Diffs

@MainActor
final class ClaudeDiffViewTests: XCTestCase {
    private let palette = ClaudePalette.current

    private var edit: [ClaudeDiff.Line] {
        let old = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\n").replacingOccurrences(of: "line 20\n", with: "")
            + "\nappended"
        return ClaudeDiff.collapseContext(ClaudeDiff.diff(old: old, new: new))
    }

    func testRendersEachStyle() {
        XCTAssertTrue(edit.contains { $0.kind == .gap })
        for style in DiffStyle.allCases {
            withSettings({ $0.claudeDiffStyle = style }) {
                for width in [400.0, 900.0] {
                    let host = render(DiffView(lines: edit, palette: palette, fontSize: 12), size: CGSize(width: width, height: 800))
                    XCTAssertGreaterThan(host.fittingSize.height, 0)
                }
            }
        }
    }

    func testCollapsedDiffShowsHowManyMoreLines() {
        withSettings({ $0.claudeDiffStyle = .unified }) {
            render(DiffView(lines: edit, palette: palette, fontSize: 12, collapsedLimit: 3))
        }
        withSettings({ $0.claudeDiffStyle = .sideBySide }) {
            render(DiffView(lines: edit, palette: palette, fontSize: 12, collapsedLimit: 3))
        }
    }

    func testNewFileIsAlwaysUnified() {
        let lines = ["a", "", "b"].enumerated().map { ClaudeDiff.Line(kind: .added, text: $1, newNumber: $0 + 1) }
        withSettings({ $0.claudeDiffStyle = .sideBySide }) {
            render(DiffView(lines: lines, palette: palette, fontSize: 12))
        }
    }

    func testGapWithoutTextAndEmptyLines() {
        let gap = ClaudeDiff.Line(kind: .gap, text: "")
        let lines = [gap] + ClaudeDiff.diff(old: "x\n\ny", new: "x\n\nz")
        for style in [DiffStyle.unified, .sideBySide] {
            withSettings({ $0.claudeDiffStyle = style }) { render(DiffView(lines: lines, palette: palette, fontSize: 11)) }
        }
    }
}

// MARK: - Tool groups

@MainActor
final class ToolGroupViewTests: XCTestCase {
    private func tool(_ name: String, error: Bool = false, running: Bool = false) -> ClaudeItem {
        let item = ClaudeItem(kind: .tool)
        item.toolName = name
        item.isError = error
        item.isRunning = running
        return item
    }

    func testRendersSummaryStates() {
        let style = InlineMarkdown.MentionStyle(skills: [], commands: [], mcpServers: [], agents: [])
        let palette = ClaudePalette.current
        let one = [tool("Read")]
        let many = [tool("Read"), ClaudeItem(kind: .thinking, text: "hmm"), tool("Read"), tool("Edit", error: true), tool("Bash", running: true)]
        for items in [one, many] {
            for expanded in [false, true] {
                let host = render(ToolGroupView(items: items, palette: palette, mentions: style, fontSize: 13, directory: nil, expanded: expanded),
                                  size: CGSize(width: 600, height: 400))
                XCTAssertGreaterThan(host.fittingSize.height, 0)
            }
        }
        XCTAssertEqual(ToolGroupView.breakdown(many.filter { $0.kind == .tool }).components(separatedBy: " · ").first, "Read 2")
    }

    func testRowIDsComeFromTheFirstItem() {
        let a = tool("Read"), b = tool("Edit")
        let rows = ClaudeTranscript.rows([a, b, ClaudeItem(kind: .user, text: "next")], mode: .collapseAll)
        XCTAssertEqual(rows.first?.id, a.id)
        guard case .item(let last)? = rows.last else { return XCTFail("expected the user message last") }
        XCTAssertEqual(last.kind, .user)
    }
}
