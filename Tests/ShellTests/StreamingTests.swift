import XCTest
@testable import Shell

@MainActor
final class StreamingTests: XCTestCase {
    private var longReply: String {
        var parts: [String] = []
        for i in 1...12 {
            parts.append("## Step \(i)\n\nParagraph \(i) explains the change in some detail so the reply is long enough to split. " + String(repeating: "More words here. ", count: 6))
            parts.append("- item a\n- item b\n\n  continued item b\n- item c")
            parts.append("```swift\nlet x = \(i)\n\nprint(x)\n```")
            parts.append("| a | b |\n| - | - |\n| 1 | 2 |")
            parts.append("> quote \(i)\n>\n> more")
        }
        return parts.joined(separator: "\n\n")
    }

    func testIncrementalParseMatchesFullParse() {
        let text = longReply
        XCTAssertNotNil(MarkdownParseCache.stableSplit(text))
        XCTAssertEqual(MarkdownParseCache.shared.blocks(for: text), MarkdownBlock.parse(text))
        // Every prefix while "streaming" matches too.
        var i = text.startIndex
        var step = 0
        while i < text.endIndex {
            i = text.index(i, offsetBy: 97, limitedBy: text.endIndex) ?? text.endIndex
            step += 1
            let prefix = String(text[..<i])
            XCTAssertEqual(MarkdownParseCache.shared.blocks(for: prefix), MarkdownBlock.parse(prefix), "prefix \(step)")
        }
    }

    func testNeverSplitsInsideAFence() {
        let text = String(repeating: "Intro paragraph. ", count: 150) + "\n\n```\ncode\n\nAfter blank inside fence\n"
        let split = MarkdownParseCache.stableSplit(text)
        if let split { XCTAssertFalse(text[split...].contains("Intro paragraph.")) }
        XCTAssertFalse(split.map { text[$0...].hasPrefix("After") } ?? false)
    }

    func testDecoderHandlesSplitLinesAndBatches() {
        let delivered = expectation(description: "batch")
        var seen: [String] = []
        let decoder = StreamJSONDecoder(interval: 0.01) { batch in
            seen += batch.objects.compactMap { $0["n"] as? String }
            if seen.count == 3 { delivered.fulfill() }
        }
        let payload = Data(#"{"n":"a"}"#.utf8) + Data([0x0A]) + Data(#"{"n":"b"}"#.utf8) + Data([0x0A]) + Data(#"{"n":"c"}"#.utf8) + Data([0x0A])
        // Feed in awkward chunks, including one that splits a line.
        DispatchQueue.global().async {
            decoder.feed(payload.prefix(5))
            decoder.feed(payload.dropFirst(5).prefix(14))
            decoder.feed(payload.dropFirst(19))
        }
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(seen, ["a", "b", "c"])
    }
}
