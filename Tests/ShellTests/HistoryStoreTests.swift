import XCTest
@testable import Shell

/// `HistoryStore` is a process-wide singleton, so every test works with its
/// own unique command prefix and temp history files, and never assumes the
/// store is otherwise empty. Under tests it never reads ~/.zsh_history.
@MainActor
final class HistoryStoreTests: XCTestCase {
    private var store: HistoryStore { HistoryStore.shared }

    /// A unique, lowercase token so entries from other tests never match.
    private func uniquePrefix() -> String {
        "hst" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    private func historyFile(_ lines: [String]) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("zsh_history")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ lines: [String], to url: URL, mtimeOffset: TimeInterval = 10) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(mtimeOffset)], ofItemAtPath: url.path)
    }

    private func entries(_ prefix: String) -> [String] { store.entries.filter { $0.hasPrefix(prefix) } }

    // MARK: Loading

    func testLoadsAPlainAndExtendedHistoryFile() throws {
        let p = uniquePrefix()
        let url = try historyFile(["\(p) one", ": 1700000000:0;\(p) two", "\(p) multi \\", "line", "  ", "\(p) one"])
        store.load(path: url.path)
        XCTAssertTrue(waitUntil { self.entries(p).count == 3 })
        // Later occurrences win: "one" moved after "two".
        XCTAssertEqual(entries(p), ["\(p) two", "\(p) multi \nline", "\(p) one"])
    }

    func testReloadReadsOnlyTheAppendedTail() throws {
        let p = uniquePrefix()
        let url = try historyFile(["\(p) a", "\(p) b"])
        store.load(path: url.path)
        XCTAssertTrue(waitUntil { self.entries(p).count == 2 })

        // Unchanged file: nothing to do.
        store.reloadIfChanged(path: url.path)
        try append(["\(p) c", "\(p) a"], to: url)
        store.reloadIfChanged(path: url.path)
        XCTAssertTrue(waitUntil { self.entries(p) == ["\(p) b", "\(p) c", "\(p) a"] }, "\(entries(p))")

        // Loading the same path again behaves like a reload.
        try append(["\(p) d"], to: url, mtimeOffset: 20)
        store.load(path: url.path)
        XCTAssertTrue(waitUntil { self.entries(p).last == "\(p) d" })
    }

    func testABigAppendRebuildsTheIndex() throws {
        let p = uniquePrefix()
        let url = try historyFile(["\(p) first"])
        store.load(path: url.path)
        XCTAssertTrue(waitUntil { self.entries(p).count == 1 })
        try append((0..<70).map { "\(p) bulk \($0)" } + ["\(p) first"], to: url)
        store.reloadIfChanged(path: url.path)
        XCTAssertTrue(waitUntil { self.entries(p).count == 71 })
        XCTAssertEqual(entries(p).last, "\(p) first")
        XCTAssertEqual(entries(p).first, "\(p) bulk 0")
        // The rebuilt index still moves repeats to the end.
        store.add("\(p) bulk 0")
        XCTAssertEqual(entries(p).last, "\(p) bulk 0")
        XCTAssertEqual(entries(p).count, 71)
    }

    func testAShrunkFileIsReadAgainFromTheStart() throws {
        let p = uniquePrefix()
        let url = try historyFile(["\(p) long command one", "\(p) long command two", "\(p) long command three"])
        store.load(path: url.path)
        XCTAssertTrue(waitUntil { self.entries(p).count == 3 })
        try "\(p) new\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: url.path)
        store.reloadIfChanged(path: url.path)
        XCTAssertTrue(waitUntil { self.entries(p).last == "\(p) new" })
    }

    func testMissingAndEmptyFilesAreIgnored() throws {
        let before = store.entries
        store.reloadIfChanged(path: "/nonexistent/\(UUID().uuidString)")
        store.load(path: "/nonexistent/\(UUID().uuidString)")
        let empty = try makeTemporaryDirectory().appendingPathComponent("empty")
        try Data().write(to: empty)
        store.load(path: empty.path)
        // A reload of a different, existing path switches to it.
        let other = try historyFile(["   "])
        store.reloadIfChanged(path: other.path)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(store.entries, before)
    }

    // MARK: Adding

    func testAddAppendsAndPersistsEscapedCommands() throws {
        let p = uniquePrefix()
        store.add("\(p) echo \\ back")
        store.add("\(p) multi\nline")
        store.add("   ")
        XCTAssertEqual(Array(store.entries.suffix(2)), ["\(p) echo \\ back", "\(p) multi\nline"])
        let file = SettingsStore.supportDirectory.appendingPathComponent("history")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\(p) echo \\\\ back\n"))
        XCTAssertTrue(text.contains("\(p) multi\\nline\n"))
        // Round-trips through the parser.
        let parsed = HistoryStore.parse(data: Data(text.utf8))
        XCTAssertTrue(parsed.contains("\(p) multi\nline"))
    }

    func testAddMovesARepeatToTheEnd() {
        let p = uniquePrefix()
        store.add("\(p) 1")
        store.add("\(p) 2")
        store.add("\(p) 3")
        store.add("\(p) 1")
        XCTAssertEqual(entries(p), ["\(p) 2", "\(p) 3", "\(p) 1"])
        XCTAssertEqual(store.step(from: nil, prefix: "\(p) 1", backwards: true)?.1, "\(p) 1")
    }

    // MARK: Suggestions

    func testSuggestionIsTheNewestMatchAndIsMemoized() {
        let p = uniquePrefix()
        store.add("\(p) git status")
        store.add("\(p) git stash")
        XCTAssertNil(store.suggestion(for: ""))
        XCTAssertNil(store.suggestion(for: "\(p) git\n"))
        XCTAssertEqual(store.suggestion(for: "\(p) g"), "\(p) git stash")
        XCTAssertEqual(store.suggestion(for: "\(p) g"), "\(p) git stash") // same prefix: memo
        XCTAssertEqual(store.suggestion(for: "\(p) gi"), "\(p) git stash") // extends the previous answer
        XCTAssertEqual(store.suggestion(for: "\(p) git statu"), "\(p) git status") // previous answer stops matching
        XCTAssertNil(store.suggestion(for: "\(p) git status")) // an exact entry isn't a suggestion
        XCTAssertNil(store.suggestion(for: "\(p) git status!")) // extends a prefix with no match
        XCTAssertNil(store.suggestion(for: "\(p) zz"))
        XCTAssertNil(store.suggestion(for: "\(p) zzz")) // no match stays no match
        store.add("\(p) zzz top")
        XCTAssertEqual(store.suggestion(for: "\(p) zzz"), "\(p) zzz top") // adding clears the memo
    }

    // MARK: Stepping

    func testStepsBackwardsAndForwardsThroughMatches() throws {
        let p = uniquePrefix()
        for c in ["ls", "git a", "pwd", "git b"] { store.add("\(p) \(c)") }
        let prefix = "\(p) git"
        let newest = try XCTUnwrap(store.step(from: nil, prefix: prefix, backwards: true))
        XCTAssertEqual(newest.1, "\(p) git b")
        let older = try XCTUnwrap(store.step(from: newest.0, prefix: prefix, backwards: true))
        XCTAssertEqual(older.1, "\(p) git a")
        XCTAssertNil(store.step(from: older.0, prefix: prefix, backwards: true))
        XCTAssertEqual(store.step(from: older.0, prefix: prefix, backwards: false)?.1, "\(p) git b")
        XCTAssertNil(store.step(from: newest.0, prefix: prefix, backwards: false))
        XCTAssertNil(store.step(from: nil, prefix: prefix, backwards: false))
        // An empty prefix walks every entry.
        let last = try XCTUnwrap(store.step(from: nil, prefix: "", backwards: true))
        XCTAssertEqual(last.1, store.entries.last)
        if last.0 > 0 {
            XCTAssertEqual(store.step(from: last.0 - 1, prefix: "", backwards: false)?.1, store.entries.last)
        }
    }

    // MARK: Search

    func testSearchRanksExactSubstringsAboveScatteredMatches() {
        let p = uniquePrefix()
        store.add("\(p) docker compose up")
        store.add("\(p) dcu")
        store.add("\(p) Docker Compose Logs")
        let results = store.search("\(p) docker compose", limit: 10)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results), ["\(p) docker compose up", "\(p) Docker Compose Logs"])
        XCTAssertEqual(store.search("\(p) dcu", limit: 10).first, "\(p) dcu")
        XCTAssertTrue(store.search("\(p) qqqq").isEmpty)
        // Cached lowercase copy is reused, then rebuilt after a change.
        XCTAssertEqual(store.search("\(p) dcu").first, "\(p) dcu")
    }

    func testEmptySearchListsNewestFirstUpToTheLimit() {
        let p = uniquePrefix()
        store.add("\(p) older")
        store.add("\(p) newer")
        XCTAssertEqual(store.search("", limit: 2), ["\(p) newer", "\(p) older"])
        XCTAssertEqual(store.search("", limit: 1), ["\(p) newer"])
    }

    // MARK: Parsing

    func testParseHandlesContinuationsAndEscapedBackslashes() {
        let text = "one \\\ntwo\nkeep \\\\\n: 1:0;three\n\n"
        XCTAssertEqual(HistoryStore.parse(data: Data(text.utf8)), ["one \ntwo", "keep \\\\", "three"])
        XCTAssertEqual(HistoryStore.parse(data: Data()), [])
        XCTAssertEqual(HistoryStore.parse(data: Data("a\\nb\n".utf8)), ["a\nb"])
    }

    func testFuzzyScores() {
        XCTAssertEqual(FuzzyMatch.score("", in: "anything"), 0)
        XCTAssertEqual(FuzzyMatch.score("git", in: "git status"), 0)
        XCTAssertEqual(FuzzyMatch.score("status", in: "git status"), 1)
        XCTAssertEqual(FuzzyMatch.score("gs", in: "git status"), 24)
        XCTAssertNil(FuzzyMatch.score("xyz", in: "git status"))
    }
}
