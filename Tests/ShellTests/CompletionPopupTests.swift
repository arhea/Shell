import AppKit
import SwiftUI
import XCTest
@testable import Shell

@MainActor
private func popupItem(_ id: Int, _ insertion: String, display: String? = nil, description: String = "", tag: String = "files",
                       dir: Bool = false, file: Bool = false) -> CompletionItem {
    CompletionItem(id: id, insertion: insertion, display: display ?? insertion, description: description, tag: tag,
                   isDirectory: dir, isFile: file)
}

@MainActor
final class CompletionPopupTests: XCTestCase {
    // MARK: Model

    func testShowHideAndMoveTheSelection() {
        let model = CompletionModel()
        XCTAssertNil(model.selected)
        model.move(1) // nothing to move through
        XCTAssertFalse(model.userNavigated)
        model.show([popupItem(0, "a"), popupItem(1, "b"), popupItem(2, "c")], mode: .completions)
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.selected?.insertion, "a")
        model.move(-1)
        XCTAssertEqual(model.selected?.insertion, "c")
        XCTAssertTrue(model.userNavigated)
        model.move(2)
        XCTAssertEqual(model.selectedIndex, 1)
        model.hide()
        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(model.userNavigated)
        model.show([], mode: .history)
        XCTAssertFalse(model.isVisible, "an empty list never shows")
        XCTAssertEqual(model.mode, .history)
    }

    func testItemKindsAndSymbols() {
        let cases: [(CompletionItem, CompletionItem.Kind, String)] = [
            (popupItem(0, "ls", tag: "commands"), .command, "terminal"),
            (popupItem(0, "a.txt", file: true), .file, "doc"),
            (popupItem(0, "src/", dir: true), .directory, "folder"),
            (popupItem(0, "--all", tag: "options"), .option, "flag"),
            (popupItem(0, "-v", tag: "values"), .option, "flag"),
            (popupItem(0, "x", tag: "values"), .argument, "chevron.right"),
            (popupItem(0, "git log", tag: "history"), .history, "clock.arrow.circlepath"),
            (popupItem(0, "PATH", tag: "parameters"), .variable, "dollarsign"),
            (popupItem(0, "example.com", tag: "hosts"), .host, "network"),
            (popupItem(0, "main", tag: "git-branch-names"), .branch, "arrow.triangle.branch"),
        ]
        for (item, kind, symbol) in cases {
            XCTAssertEqual(item.kind, kind, item.insertion)
            XCTAssertEqual(item.symbol, symbol, item.insertion)
        }
    }

    // MARK: Rendering

    private var everyKind: [CompletionItem] {
        [popupItem(0, "ls", description: "list directory contents", tag: "commands"), popupItem(1, "src/", dir: true),
         popupItem(2, "a.txt", file: true), popupItem(3, "--all", description: "show hidden", tag: "options"),
         popupItem(4, "main", tag: "git-branch-names"), popupItem(5, "HOME", tag: "parameters"),
         popupItem(6, "old", tag: "history"), popupItem(7, "example.com", tag: "hosts")]
    }

    func testRendersCompletionsWithAndWithoutAPreview() throws {
        let dir = try makeTemporaryDirectory()
        let model = CompletionModel()
        model.workingDirectory = dir.path
        model.show(everyKind, mode: .completions)
        render(CompletionPopupView(model: model, onAccept: { _ in }, fontName: nil, fontSize: 12), size: CGSize(width: 700, height: 260))
        render(CompletionPopupView(model: model, onAccept: { _ in }, fontName: "Menlo", fontSize: 9), size: CGSize(width: 700, height: 260))
        model.showPreview = false
        render(CompletionPopupView(model: model, onAccept: { _ in }, fontName: nil, fontSize: 12), size: CGSize(width: 400, height: 260))
    }

    func testRendersTheHistorySearchHeader() {
        let model = CompletionModel()
        model.show([popupItem(0, "git status", tag: "history")], mode: .history)
        render(CompletionPopupView(model: model, onAccept: { _ in }, fontName: nil, fontSize: 12), size: CGSize(width: 400, height: 200))
        model.query = "git"
        render(CompletionPopupView(model: model, onAccept: { _ in }, fontName: nil, fontSize: 12), size: CGSize(width: 400, height: 200))
    }

    func testMovingTheSelectionScrollsToIt() {
        let model = CompletionModel()
        model.showPreview = false
        model.show((0..<30).map { popupItem($0, "item\($0)") }, mode: .completions)
        var accepted: [String] = []
        let w = claudeWindow(CompletionPopupView(model: model, onAccept: { accepted.append($0.insertion) }, fontName: nil, fontSize: 12),
                             width: 400, height: 120)
        model.move(25)
        w.layout(settle: 0.05)
        XCTAssertEqual(model.selected?.insertion, "item25")
        XCTAssertTrue(accepted.isEmpty)
    }

    func testPreviewRendersEachKindOfContent() async throws {
        let dir = try makeTemporaryDirectory()
        try "hello\nworld\n".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let palette = EditorPalette.current
        for item in [popupItem(0, "notes.txt", file: true), popupItem(0, ".", dir: true), popupItem(0, "ls", tag: "commands"),
                     popupItem(0, "-a", description: "all", tag: "options")] {
            let host = render(CompletionPreview(item: item, cwd: dir.path, palette: palette, font: .body), size: CGSize(width: 300, height: 260))
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
            host.display()
        }
    }

    // MARK: Preview content

    func testPreviewOfADirectoryListsItsVisibleEntries() async throws {
        let dir = try makeTemporaryDirectory()
        let sub = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: sub.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        for name in [".hidden", "b.txt", "a.txt"] { try "x".write(to: sub.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let c = await CompletionPreview.load(popupItem(0, "project/", display: "project", dir: true), cwd: dir.path)
        XCTAssertEqual(c.title, "project/")
        XCTAssertEqual(c.subtitle, "3 items")
        XCTAssertEqual(c.lines, ["Sources/", "a.txt", "b.txt"])

        let one = dir.appendingPathComponent("one")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try "x".write(to: one.appendingPathComponent("only"), atomically: true, encoding: .utf8)
        let single = await CompletionPreview.load(popupItem(0, one.path, dir: true), cwd: nil)
        XCTAssertEqual(single.subtitle, "1 item")
    }

    func testPreviewOfALongDirectorySaysHowManyMore() async throws {
        let dir = try makeTemporaryDirectory()
        for i in 0..<20 { try "x".write(to: dir.appendingPathComponent(String(format: "f%02d", i)), atomically: true, encoding: .utf8) }
        let c = await CompletionPreview.load(popupItem(0, dir.path, dir: true), cwd: nil)
        XCTAssertEqual(c.lines.count, 15)
        XCTAssertEqual(c.lines.last, "… 6 more")
    }

    func testPreviewOfATextFileShowsItsHead() async throws {
        let dir = try makeTemporaryDirectory()
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        try text.write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        let c = await CompletionPreview.load(popupItem(0, "log.txt", file: true), cwd: dir.path)
        XCTAssertEqual(c.title, "log.txt")
        XCTAssertEqual(c.lines.count, 14)
        XCTAssertEqual(c.lines.first, "line 1")
        XCTAssertNil(c.thumbnailPath)
        XCTAssertTrue(c.subtitle?.contains("modified") == true)
    }

    func testPreviewOfABinaryOrHugeFileIsAThumbnail() async throws {
        let dir = try makeTemporaryDirectory()
        let bin = dir.appendingPathComponent("image.png")
        try ClaudeViewFixtures.writePNG(to: bin)
        let c = await CompletionPreview.load(popupItem(0, "image.png", file: true), cwd: dir.path)
        XCTAssertEqual(c.thumbnailPath, bin.path)
        XCTAssertTrue(c.lines.isEmpty)

        let big = dir.appendingPathComponent("big.dat")
        try Data(count: 2_100_000).write(to: big)
        let b = await CompletionPreview.load(popupItem(0, "big.dat", file: true), cwd: dir.path)
        XCTAssertEqual(b.thumbnailPath, big.path)
    }

    func testPreviewFallsBackToTheEscapedInsertionAndThenToTheDescription() async throws {
        let dir = try makeTemporaryDirectory()
        try "hi".write(to: dir.appendingPathComponent("my file.txt"), atomically: true, encoding: .utf8)
        // zsh shows the plain name but inserts it escaped.
        let found = await CompletionPreview.load(popupItem(0, #"my\ file.txt"#, display: "my file (txt)", file: true), cwd: dir.path)
        XCTAssertEqual(found.title, "my file.txt")
        XCTAssertEqual(found.lines, ["hi"])

        let missing = await CompletionPreview.load(popupItem(0, "gone.txt", description: "was here", file: true), cwd: dir.path)
        XCTAssertEqual(missing.title, "gone.txt")
        XCTAssertEqual(missing.subtitle, "was here")
        XCTAssertTrue(missing.lines.isEmpty)
    }

    func testPreviewOfCommandsAndOtherItems() async throws {
        let withDesc = await CompletionPreview.load(popupItem(0, "ls", description: "list files", tag: "commands"), cwd: nil)
        XCTAssertEqual(withDesc.subtitle, "list files")
        let lsPath = try XCTUnwrap(CommandIndex.shared.path(for: "ls"))
        XCTAssertEqual(withDesc.lines, [lsPath])
        let plain = await CompletionPreview.load(popupItem(0, "ls", tag: "commands"), cwd: nil)
        XCTAssertEqual(plain.subtitle, lsPath)
        XCTAssertTrue(plain.lines.isEmpty)
        let unknown = await CompletionPreview.load(popupItem(0, "zzqnotacommand", tag: "external-commands"), cwd: nil)
        XCTAssertEqual(unknown.subtitle, "external commands")
        let other = await CompletionPreview.load(popupItem(0, "origin", tag: "git-remotes"), cwd: nil)
        XCTAssertEqual(other.title, "origin")
        XCTAssertEqual(other.subtitle, "git remotes")
        let described = await CompletionPreview.load(popupItem(0, "--all", description: "everything", tag: "options"), cwd: nil)
        XCTAssertEqual(described.subtitle, "everything")
    }

    // MARK: Quick Look

    func testQuickLookThumbnailRendersAnImage() async throws {
        let dir = try makeTemporaryDirectory()
        let png = dir.appendingPathComponent("pic.png")
        try ClaudeViewFixtures.writePNG(to: png, width: 80, height: 40)
        let image = await QuickLookThumbnail.thumbnail(for: png.path, size: CGSize(width: 120, height: 80))
        XCTAssertNotNil(image)
        let host = render(QuickLookThumbnail(path: png.path, maxSize: CGSize(width: 120, height: 80)), size: CGSize(width: 200, height: 120))
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
        host.display()
        let none = await QuickLookThumbnail.thumbnail(for: dir.appendingPathComponent("missing.png").path, size: CGSize(width: 50, height: 50))
        XCTAssertNil(none)
    }

    func testQuickLookControllerHasNothingToPreviewUntilShown() {
        XCTAssertEqual(QuickLookController.shared.numberOfPreviewItems(in: nil), 0)
    }
}

@MainActor
final class CommandIndexTests: XCTestCase {
    private static let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    func testKnowsBuiltinsPathCommandsAliasesAndFunctions() throws {
        let dir = try makeTemporaryDirectory()
        let tool = dir.appendingPathComponent("my-tool-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let index = CommandIndex.shared
        addTeardownBlock { @MainActor in CommandIndex.shared.update(path: Self.defaultPath, aliases: nil, functions: nil) }

        index.update(path: dir.path + ":/nonexistent-dir", aliases: "gst gco", functions: "mkcd")
        XCTAssertTrue(waitUntil { index.isKnown(tool.lastPathComponent, cwd: nil) })
        XCTAssertEqual(index.path(for: tool.lastPathComponent), tool.path)
        XCTAssertNil(index.path(for: "zzqnotacommand"))
        XCTAssertTrue(index.isKnown("gst", cwd: nil))
        XCTAssertTrue(index.isKnown("mkcd", cwd: nil))
        XCTAssertTrue(index.isKnown("cd", cwd: nil))
        XCTAssertTrue(index.isKnown("", cwd: nil))
        XCTAssertFalse(index.isKnown("zzqnotacommand", cwd: nil))
        // The same PATH again only refreshes the names.
        index.update(path: dir.path + ":/nonexistent-dir", aliases: nil, functions: "other")
        XCTAssertTrue(index.isKnown("other", cwd: nil))
        XCTAssertFalse(index.isKnown("gst", cwd: nil))
    }

    func testJudgesPathsAndLeavesQuotedOrVariableCommandsAlone() throws {
        let dir = try makeTemporaryDirectory()
        let script = dir.appendingPathComponent("run.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let index = CommandIndex.shared
        XCTAssertTrue(index.isKnown("./run.sh", cwd: dir.path))
        XCTAssertTrue(index.isKnown(script.path, cwd: nil))
        XCTAssertFalse(index.isKnown("./missing.sh", cwd: dir.path))
        XCTAssertFalse(index.isKnown("~/\(UUID().uuidString)/x", cwd: nil))
        XCTAssertTrue(index.isKnown("$EDITOR", cwd: nil))
        XCTAssertTrue(index.isKnown("\"quoted\"", cwd: nil))
        XCTAssertTrue(index.isKnown("'quoted'", cwd: nil))
        XCTAssertTrue(index.isKnown("FOO=bar", cwd: nil))
    }

    func testCommandPosition() {
        XCTAssertTrue(ShellLexer.isCommandPosition(in: "", cursor: 0))
        XCTAssertTrue(ShellLexer.isCommandPosition(in: "gi", cursor: 2))
        XCTAssertFalse(ShellLexer.isCommandPosition(in: "git ch", cursor: 6))
        XCTAssertTrue(ShellLexer.isCommandPosition(in: "ls | gr", cursor: 7))
        XCTAssertTrue(ShellLexer.isCommandPosition(in: "sudo ap", cursor: 7))
        XCTAssertFalse(ShellLexer.isCommandPosition(in: "ls > ou", cursor: 7))
        XCTAssertFalse(ShellLexer.isCommandPosition(in: "git -C dir st", cursor: 13))
    }

    func testLexerEdgeCases() {
        let tokens = ShellLexer.tokenize("echo \"a \\\" b\" 'c' `d` e\\ f #x\nnext a#b")
        XCTAssertEqual(tokens.map(\.text), ["echo", "\"a \\\" b\"", "'c'", "`d`", "e\\ f", "#x\nnext a#b"])
        XCTAssertEqual(tokens.last?.kind, .comment)
        let lines = ShellLexer.tokenize("ls\nwc a#b")
        XCTAssertEqual(lines.map(\.kind), [.command, .command, .argument])
        XCTAssertEqual(lines.last?.text, "a#b", "# inside a word isn't a comment")
        XCTAssertEqual(ShellLexer.tokenize("ls && pwd").map(\.kind), [.command, .operatorToken, .command])
        XCTAssertEqual(ShellLexer.tokenize("=x").first?.kind, .command)
        XCTAssertEqual(ShellLexer.tokenize("a-b=1").first?.kind, .command, "not a valid name")
        XCTAssertEqual(ShellLexer.tokenize("echo x$HOME").last?.kind, .argument)
        XCTAssertEqual(ShellLexer.tokenize("echo \"unterminated").last?.kind, .string)
        let r = ShellLexer.currentWordRange(in: "cat \"a \\\" b", cursor: 11)
        XCTAssertEqual(r.location, 4)
        XCTAssertEqual(ShellLexer.currentWordRange(in: "a\\ b", cursor: 4).location, 0)
        XCTAssertEqual(ShellLexer.currentWordRange(in: "ls|gr", cursor: 5).location, 3)
    }
}
