import AppKit
import SwiftUI
import XCTest
@testable import Shell

private typealias Block = TerminalSession.CommandBlock

@MainActor
private func block(_ command: String, dir: String = "~/code", branch: String? = "main", exit: Int? = 0,
                   finished: Bool = true) -> Block {
    Block(command: command, directory: dir, branch: branch, exitCode: exit, isFinished: finished)
}

// MARK: - Block history bookkeeping

@MainActor
final class CommandBlockHistoryTests: XCTestCase {
    func testRecordAppendsReplacesByIDAndStaysBounded() {
        var blocks: [Block] = []
        var a = block("make", finished: false)
        TerminalSession.record(a, in: &blocks, limit: 3)
        a.isFinished = true
        a.exitCode = 2
        TerminalSession.record(a, in: &blocks, limit: 3)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].exitCode, 2)
        XCTAssertTrue(blocks[0].failed)
        for cmd in ["b", "c", "d"] { TerminalSession.record(block(cmd), in: &blocks, limit: 3) }
        XCTAssertEqual(blocks.map(\.command), ["b", "c", "d"], "oldest dropped")
    }

    func testAnUnfinishedBlockIsReplacedByTheNextOne() {
        var blocks = [block("a")]
        TerminalSession.record(block("stuck", finished: false), in: &blocks)
        TerminalSession.record(block("next", finished: false), in: &blocks)
        XCTAssertEqual(blocks.map(\.command), ["a", "next"])
    }

    func testSessionRecordsBlocksFromThePromptCycle() throws {
        let original = SettingsStore.shared.settings
        addTeardownBlock { @MainActor in SettingsStore.shared.settings = original }
        let dir = try makeTemporaryDirectory().path
        let session = TerminalSession(workingDirectory: dir)
        addTeardownBlock { @MainActor in session.close() }
        session.promptReady(exitCode: nil, directory: dir, branch: "main", duration: nil)
        XCTAssertTrue(session.blocks.isEmpty)

        session.commandStarted("make test", directory: dir)
        XCTAssertEqual(session.blocks.count, 1)
        XCTAssertFalse(session.blocks[0].isFinished)
        XCTAssertEqual(session.blocks[0].cwd, dir)
        XCTAssertEqual(session.blocks[0].branch, "main")

        session.promptReady(exitCode: 65, directory: dir, branch: "main", duration: 18.4)
        let finished = try XCTUnwrap(session.blocks.last)
        XCTAssertEqual(session.blocks.count, 1, "the same block, finished")
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.exitCode, 65)
        XCTAssertEqual(finished.duration, 18.4)
        XCTAssertEqual(session.lastBlock?.id, finished.id)
        XCTAssertEqual(session.block(id: finished.id)?.command, "make test")

        session.submit(command: "ls")
        session.commandStarted("ls", directory: dir)
        session.promptReady(exitCode: 0, directory: dir, branch: "main", duration: nil)
        XCTAssertEqual(session.blocks.map(\.command), ["make test", "ls"])
        XCTAssertNotNil(session.blocks[1].duration, "measured when the shell doesn't report one")
        XCTAssertFalse(session.blocks[1].failed)
    }
}

// MARK: - Row mapping

@MainActor
final class CommandBlockLayoutTests: XCTestCase {
    func testRowCountWrapsByCellWidth() {
        XCTAssertEqual(CommandBlockLayout.rowCount("", columns: 10), 1)
        XCTAssertEqual(CommandBlockLayout.rowCount("0123456789", columns: 10), 1)
        XCTAssertEqual(CommandBlockLayout.rowCount("0123456789a", columns: 10), 2)
        XCTAssertEqual(CommandBlockLayout.rowCount(Substring(String(repeating: "x", count: 25)), columns: 10), 3)
        XCTAssertEqual(CommandBlockLayout.rowCount("日本語日本", columns: 10), 1, "five wide characters fill ten cells")
        XCTAssertEqual(CommandBlockLayout.rowCount("日本語日本語", columns: 10), 2)
    }

    func testLinesTrackRowsAndTrimTrailingSpace() {
        let lines = CommandBlockLayout.lines("ab  \n" + String(repeating: "x", count: 15) + "\nc", columns: 10, startRow: 100)
        XCTAssertEqual(lines.map(\.text), ["ab", String(repeating: "x", count: 15), "c"])
        XCTAssertEqual(lines.map(\.row), [100, 101, 103])
        XCTAssertEqual(lines.map(\.rows), [1, 2, 1])
    }

    func testHeaderMatchingFollowsHeaderIndexRules() {
        let b = block("make test")
        XCTAssertTrue(CommandBlockLayout.isHeader("~/code main ❯ make test", of: b))
        XCTAssertTrue(CommandBlockLayout.isHeader("~/elsewhere ❯ make test", of: b))
        XCTAssertTrue(CommandBlockLayout.isHeader("➜  code git:(main) make test", of: b), "custom theme prompt")
        XCTAssertFalse(CommandBlockLayout.isHeader("make test", of: b), "the output echoing the command alone")
        XCTAssertFalse(CommandBlockLayout.isHeader("~/code main ❯ make", of: b))
    }

    func testAnchorsWholeScreenNewestFirstIncludingWrappedLines() {
        let a = block("ls"), b = block("make", exit: 2), c = block("ls")
        let screen = [
            "~/code main ❯ ls", "file", "",
            "~/code main ❯ make", String(repeating: "e", count: 25), "",
            "~/code main ❯ ls", "file",
        ].joined(separator: "\n")
        let lines = CommandBlockLayout.lines(screen, columns: 20)
        let anchors = CommandBlockLayout.anchors(blocks: [a, b, c], lines: lines)
        XCTAssertEqual(anchors[a.id], 0)
        XCTAssertEqual(anchors[b.id], 3)
        XCTAssertEqual(anchors[c.id], 7, "the 25-cell line takes two rows at 20 columns")
    }

    func testAnchorsSkipBlocksNoLongerOnScreen() {
        let gone = block("old"), kept = block("new")
        let lines = CommandBlockLayout.lines("~/code main ❯ new\nout", columns: 40)
        let anchors = CommandBlockLayout.anchors(blocks: [gone, kept], lines: lines)
        XCTAssertNil(anchors[gone.id])
        XCTAssertEqual(anchors[kept.id], 0)
    }

    func testViewportAnchoringKeepsBlockOrder() {
        let old = block("ls"), mid = block("ls"), new = block("pwd")
        // Viewport rows 50..<55; `old` is anchored above it.
        let lines = CommandBlockLayout.lines("~/code main ❯ ls\nx\n~/code main ❯ pwd\n/x\n", columns: 40, startRow: 50)
        var anchors: [UUID: Int] = [old.id: 10]
        CommandBlockLayout.anchorInViewport(blocks: [old, mid, new], anchors: &anchors, pending: [mid.id, new.id], lines: lines)
        XCTAssertEqual(anchors[new.id], 52)
        XCTAssertEqual(anchors[mid.id], 50)
        XCTAssertEqual(anchors[old.id], 10, "anchored blocks aren't moved")
    }

    func testViewportAnchoringWontPlaceANewerBlockAboveAnOlderOne() {
        let older = block("ls"), newer = block("ls")
        let lines = CommandBlockLayout.lines("~/code main ❯ ls\nx", columns: 40, startRow: 20)
        var anchors: [UUID: Int] = [older.id: 20]
        CommandBlockLayout.anchorInViewport(blocks: [older, newer], anchors: &anchors, pending: [newer.id], lines: lines)
        XCTAssertNil(anchors[newer.id], "the only matching header belongs to the older block")
    }

    func testSegmentsRunToTheNextHeaderAndTrimBlankTail() {
        let a = block("make", exit: 2), b = block("ls"), running = block("sleep 9", exit: nil, finished: false)
        let text = ["~/code main ❯ make", "error", "", "", "~/code main ❯ ls", "f", "", "~/code main ❯ sleep 9", ""].joined(separator: "\n")
        let lines = CommandBlockLayout.lines(text, columns: 40, startRow: 100)
        let anchors = [a.id: 100, b.id: 104, running.id: 107]
        let segs = CommandBlockLayout.segments(blocks: [a, b, running], anchors: anchors, verified: [a.id],
                                               viewportLines: lines, viewport: 100..<110, screenEnd: 110)
        XCTAssertEqual(segs, [
            .init(id: a.id, headerRow: 100, endRow: 101, headerVerified: true),
            .init(id: b.id, headerRow: 104, endRow: 105, headerVerified: false),
        ], "the running block isn't decorated")
    }

    func testSegmentsWithAHeaderAboveTheViewport() {
        let a = block("make", exit: 2)
        let lines = CommandBlockLayout.lines("line\nline\nline", columns: 40, startRow: 30)
        let segs = CommandBlockLayout.segments(blocks: [a], anchors: [a.id: 5], verified: [],
                                               viewportLines: lines, viewport: 30..<40, screenEnd: 40)
        XCTAssertEqual(segs.first?.headerRow, 5)
        XCTAssertEqual(segs.first?.endRow, 32, "trailing blank rows on screen are trimmed")
        XCTAssertTrue(CommandBlockLayout.segments(blocks: [a], anchors: [a.id: 5], verified: [], viewportLines: [],
                                                  viewport: 0..<0, screenEnd: 40).isEmpty)
    }

    func testSegmentsOutsideTheViewportAreSkipped() {
        let a = block("ls"), b = block("pwd")
        let segs = CommandBlockLayout.segments(blocks: [a, b], anchors: [a.id: 0, b.id: 60], verified: [],
                                               viewportLines: [], viewport: 20..<40, screenEnd: 80)
        XCTAssertEqual(segs.map(\.id), [a.id], "a runs to row 59, through the viewport; b starts below it")
    }

    func testStatusText() {
        let date = Date(timeIntervalSince1970: 0)
        let s = CommandBlockLayout.statusText(duration: 3.2, startedAt: date)
        XCTAssertTrue(s.hasPrefix("3.2s · "), s)
        XCTAssertFalse(CommandBlockLayout.statusText(duration: nil, startedAt: date).contains("·"))
    }
}

// MARK: - Overlay view

@MainActor
final class CommandBlockOverlayViewTests: XCTestCase {
    func testPassesClicksThroughAndDrawsNothingWithoutBlocks() throws {
        let original = SettingsStore.shared.settings
        addTeardownBlock { @MainActor in SettingsStore.shared.settings = original }
        let session = TerminalSession(workingDirectory: try makeTemporaryDirectory().path)
        addTeardownBlock { @MainActor in session.close() }
        let overlay = CommandBlockOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        overlay.session = session
        XCTAssertNil(overlay.hitTest(NSPoint(x: 100, y: 100)))
        overlay.scrollbarChanged(total: 100, offset: 70, length: 30)
        overlay.blocksChanged()
        overlay.refresh()
        XCTAssertTrue(overlay.debugSegments.isEmpty)
        XCTAssertTrue(overlay.debugButtonTitles.isEmpty)
        SettingsStore.shared.settings.showCommandBlocks = false
        XCTAssertFalse(overlay.isEnabled)
    }
}
