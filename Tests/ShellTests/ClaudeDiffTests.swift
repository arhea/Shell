import XCTest
@testable import Shell

final class ClaudeDiffTests: XCTestCase {
    static let before = """
        customerTermsGroup.Get("", customerTermsListHandler(hd))
        // Registered before the addressed routes below.
        customerTermsGroup.Get("/languages", customerTermLanguagesHandler(hd))
        customerTermsGroup.Get("/{entity_name}/{entity_key}/{field}/{locale}", customerTermsGetHandler(hd))
        """
    static let after = """
        customerTermsGroup.Get("", customerTermsListHandler(hd))
        customerTermsGroup.Get("/languages", customerTermLanguagesHandler(hd))
        // One translation is addressed by query parameters.
        customerTermsGroup.Get("/term", customerTermsGetHandler(hd))
        """

    func testLineDiffKeepsUnchangedLines() {
        let lines = ClaudeDiff.diff(old: Self.before, new: Self.after, startLine: 40)
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .context, .removed, .added, .added])
        XCTAssertEqual(lines[0].oldNumber, 40)
        XCTAssertEqual(lines[2].oldNumber, 42)
        XCTAssertEqual(lines[2].newNumber, 41)
        XCTAssertEqual(lines.last?.newNumber, 43)
    }

    func testSideBySidePairsRemovalsWithAdditions() {
        let rows = ClaudeDiff.rows(ClaudeDiff.diff(old: Self.before, new: Self.after))
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[1].left?.kind, .removed)     // the deleted comment
        XCTAssertNil(rows[1].right)
        XCTAssertNil(rows[3].left)                         // the new comment has nothing on the left
        XCTAssertEqual(rows[3].right?.kind, .added)
        let paired = rows[4]                               // the edited route lines up with its new version
        XCTAssertTrue(paired.left?.text.contains("{entity_name}") == true)
        XCTAssertTrue(paired.right?.text.contains("/term") == true)
        XCTAssertNotNil(paired.leftChange)
    }

    func testChangedRanges() {
        let (l, r) = ClaudeDiff.changedRanges("return a + b", "return a - b")
        XCTAssertEqual(l, 9..<10)
        XCTAssertEqual(r, 9..<10)
        XCTAssertEqual(ClaudeDiff.changedRanges("abc", "xyz").0, nil) // nothing in common
    }

    func testLongContextCollapses() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\n")
        let lines = ClaudeDiff.collapseContext(ClaudeDiff.diff(old: old, new: new))
        XCTAssertEqual(lines.first?.kind, .gap)
        XCTAssertEqual(lines.first?.text, "6 unchanged lines")
        XCTAssertEqual(lines.filter { $0.kind == .context }.count, 6)
        XCTAssertEqual(lines.last?.kind, .gap)
    }

    func testStartLineFromTheFile() {
        let file = "package api\n\nfunc routes() {\n\tb := 2\n}\n"
        XCTAssertEqual(ClaudeDiff.startLine(of: "\tb := 2", orOf: "\ta := 1", in: file), 4)
        XCTAssertNil(ClaudeDiff.startLine(of: "zzz", orOf: "yyy", in: file))
    }

    func testSimilarity() {
        XCTAssertEqual(ClaudeDiff.similarity("abc", "abc"), 1)
        XCTAssertEqual(ClaudeDiff.similarity("", "abc"), 0)
        XCTAssertEqual(ClaudeDiff.similarity("return a + b", "return a - b"), 11.0 / 12.0, accuracy: 0.0001)
        // Prefix and suffix don't double-count an overlapping middle.
        XCTAssertLessThanOrEqual(ClaudeDiff.similarity("aaaa", "aaaaaa"), 1)
    }

    /// A large rewrite pairs in bounded time rather than removed × added.
    func testLargeRewritePairsQuickly() {
        let old = (1...3000).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let new = (1...3000).map { "var item\($0) := other(\($0 * 7))" }.joined(separator: "\n")
        let lines = ClaudeDiff.diff(old: old, new: new)
        let start = Date()
        let rows = ClaudeDiff.rows(lines)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertGreaterThanOrEqual(rows.count, 3000)
    }
}

final class LRUCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsed() {
        var cache = LRUCache<Int, String>(capacity: 4)
        for i in 0..<4 { cache[i] = "\(i)" }
        _ = cache[0] // recently used: survives
        cache[4] = "4"
        XCTAssertEqual(cache[0], "0")
        XCTAssertNil(cache[1])
        XCTAssertEqual(cache[4], "4")
    }
}
