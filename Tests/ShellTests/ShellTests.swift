import XCTest
@testable import Shell

final class PaneTreeTests: XCTestCase {
    func testSplitRemoveAndNeighbors() {
        let a = UUID(), b = UUID(), c = UUID()
        var tree = PaneTree.leaf(a)
        tree = tree.inserting(b, nextTo: a, direction: .horizontal)   // a | b
        tree = tree.inserting(c, nextTo: b, direction: .vertical)     // a | (b / c)
        XCTAssertEqual(tree.leaves, [a, b, c])
        XCTAssertEqual(tree.neighbor(of: a, .right), b)
        XCTAssertEqual(tree.neighbor(of: b, .down), c)
        XCTAssertEqual(tree.neighbor(of: c, .up), b)
        XCTAssertEqual(tree.neighbor(of: c, .left), a)
        XCTAssertNil(tree.neighbor(of: a, .left))

        let frames = tree.layout()
        XCTAssertEqual(frames[a]!.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(frames[c]!.minY, 0.5, accuracy: 0.0001)

        let removed = tree.removing(b)!
        XCTAssertEqual(removed.leaves, [a, c])
        XCTAssertNil(PaneTree.leaf(a).removing(a))
    }

    func testEqualizeWeightsByPaneCount() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = PaneTree.leaf(a)
            .inserting(b, nextTo: a, direction: .horizontal)
            .inserting(c, nextTo: b, direction: .horizontal)
            .equalized()
        let frames = tree.layout()
        for id in [a, b, c] { XCTAssertEqual(frames[id]!.width, 1.0 / 3.0, accuracy: 0.001) }
    }
}

final class HistoryParsingTests: XCTestCase {
    func testExtendedAndMultiline() {
        let text = ": 1700000000:0;git status\n: 1700000001:2;echo one \\\ntwo\nls -la\n"
        XCTAssertEqual(HistoryStore.parse(data: Data(text.utf8)), ["git status", "echo one \ntwo", "ls -la"])
    }

    func testUnmetafy() {
        // "é" is 0xC3 0xA9; zsh metafies 0xA9 as 0x83 0x89.
        let bytes: [UInt8] = Array("echo ".utf8) + [0xC3, 0x83, 0xA9 ^ 0x20] + [0x0A]
        XCTAssertEqual(HistoryStore.parse(data: Data(bytes)), ["echo é"])
    }

    func testFuzzy() {
        XCTAssertNotNil(FuzzyMatch.score("gst", in: "git status"))
        XCTAssertNil(FuzzyMatch.score("xyz", in: "git status"))
        XCTAssertLessThan(FuzzyMatch.score("stat", in: "git status")!, FuzzyMatch.score("gts", in: "git status")!)
    }
}

final class LexerTests: XCTestCase {
    func testTokenKinds() {
        let tokens = ShellLexer.tokenize(#"FOO=1 sudo git commit -m "hi there" | grep $HOME > out.txt # note"#)
        let kinds = tokens.map(\.kind)
        XCTAssertEqual(kinds, [.assignment, .command, .command, .argument, .option, .string, .operatorToken, .command, .variable, .redirect, .argument, .comment])
    }

    func testCurrentWordRespectsQuotes() {
        let text = #"ls "My Fo"#
        let r = ShellLexer.currentWordRange(in: text, cursor: (text as NSString).length)
        XCTAssertEqual((text as NSString).substring(with: r), #""My Fo"#)
        let t2 = "git checkout ma"
        XCTAssertEqual((t2 as NSString).substring(with: ShellLexer.currentWordRange(in: t2, cursor: 15)), "ma")
    }

    @MainActor func testEditorHelpers() {
        XCTAssertTrue(InputEditorView.hasUnterminatedQuote(#"echo "abc"#))
        XCTAssertFalse(InputEditorView.hasUnterminatedQuote(#"echo "a\"b""#))
        XCTAssertEqual(InputEditorView.commonPrefix(["status", "stash", "stage"]), "sta")
    }
}

final class ShortcutTests: XCTestCase {
    func testDisplayAndGhosttyTrigger() {
        let s = KeyShortcut(key: "d", modifiers: [.command, .shift])
        XCTAssertEqual(s.displayString, "⇧⌘D")
        XCTAssertEqual(KeyShortcut(key: "left", modifiers: [.option]).ghosttyTrigger, "alt+arrow_left")
    }

    @MainActor func testNoDuplicateDefaults() {
        var seen: [KeyShortcut: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            guard let sc = action.defaultShortcut else { continue }
            XCTAssertNil(seen[sc], "\(action) and \(seen[sc]!) share \(sc.displayString)")
            seen[sc] = action
        }
    }

    @MainActor func testShiftedPunctuationForMenus() {
        let item = NSMenuItem()
        item.apply(KeyShortcut(key: "]", modifiers: [.command, .shift]))
        XCTAssertEqual(item.keyEquivalent, "}")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    }
}

final class ZshrcTests: XCTestCase {
    @MainActor func testParsePlugins() {
        let rc = """
        # plugins=(commented)
        ZSH_THEME="robbyrussell"
        plugins=(
          git   # version control
          docker
        )
        source $ZSH/oh-my-zsh.sh
        """
        XCTAssertEqual(ZshService.parsePlugins(rc), ["git", "docker"])
        XCTAssertEqual(ZshService.parseTheme(rc), "robbyrussell")
    }
}

final class ThemeAndProtocolTests: XCTestCase {
    func testThemeParse() {
        let t = TerminalTheme.parse(name: "X", contents: "background = #101010\nforeground = ffffff\npalette = 1=#ff0000\n")!
        XCTAssertEqual(t.background.hex, "#101010")
        XCTAssertEqual(t.palette[1].hex, "#ff0000")
        XCTAssertTrue(t.isDark)
    }

    func testUnescape() {
        XCTAssertEqual(ControlServer.unescape(#"a\tb\nc\\d"#), "a\tb\nc\\d")
    }

    @MainActor func testGeneratedConfigClearsKeybinds() {
        let text = ConfigController.generate(settings: AppSettings(), theme: .shellDark)
        XCTAssertTrue(text.contains("keybind = clear"))
        XCTAssertTrue(text.contains("shell-integration = none"))
        XCTAssertTrue(text.contains("palette = 15=#ffffff"))
    }
}

final class BrewTests: XCTestCase {
    func testParseOutdated() {
        let json = #"{"formulae":[{"name":"jq","current_version":"1.8"}],"casks":[{"name":"iterm2"}]}"#
        XCTAssertEqual(BrewService.parseOutdated(Data(json.utf8)), ["jq", "iterm2"])
        XCTAssertEqual(BrewService.parseOutdated(Data("not json".utf8)), [])
    }

    func testScheduleIntervals() {
        XCTAssertNil(AutoUpdateSchedule.off.interval)
        XCTAssertEqual(AutoUpdateSchedule.daily.interval, 86_400)
        XCTAssertEqual(AutoUpdateSchedule.weekly.interval, 604_800)
    }
}

final class NodeTests: XCTestCase {
    func testSemVer() {
        XCTAssertEqual(SemVer("v24.21.0"), SemVer(major: 24, minor: 21, patch: 0))
        XCTAssertEqual(SemVer("11.21.0\n"), SemVer(major: 11, minor: 21, patch: 0))
        XCTAssertEqual(SemVer("4.0.0-rc.1")?.description, "4.0.0")
        XCTAssertLessThan(SemVer("v22.9.0")!, SemVer("v22.10.0")!)
        XCTAssertNil(SemVer("latest"))
    }

    func testTrackRoundTrip() {
        for raw in ["lts", "current", "22", "pinned"] { XCTAssertEqual(NodeTrack(raw).raw, raw) }
        XCTAssertEqual(NodeTrack("garbage"), .lts)
    }

    func testLineStatus() {
        let day: TimeInterval = 86_400
        let now = Date()
        let line = NodeLine(major: 22, codename: "Jod", start: now - 400 * day, ltsStart: now - 200 * day,
                            maintenanceStart: now + 100 * day, end: now + 500 * day)
        XCTAssertEqual(line.status(on: now), "Active LTS")
        XCTAssertEqual(line.status(on: now + 600 * day), "End of life")
        XCTAssertFalse(line.isSupported(on: now + 600 * day))
    }
}

final class LinkDetectorTests: XCTestCase {
    let g = LinkDetector.Geometry(originX: 10, baseline0: 20, cellWidth: 8, cellHeight: 16, columns: 40, rows: 10)

    /// Fake file system rooted at /repo.
    let fs: LinkDetector.PathResolver = { candidate in
        let existing: [String: Bool] = ["/repo/README.md": false, "/repo/Sources/App.swift": false,
                                        "/repo/Sources": true, "/usr/bin/git": false]
        let path = candidate.hasPrefix("/") ? candidate : "/repo/" + (candidate.hasPrefix("./") ? String(candidate.dropFirst(2)) : candidate)
        return existing[path].map { (path, $0) }
    }

    func testFindsExistingPathsOnly() {
        let text = "error: Sources/App.swift:42:7: boom. See README.md, ./Sources and /usr/bin/git. Missing: Nope/Gone.swift -v"
        let links = LinkDetector.detect(text: String(text.prefix(1000)), geometry: LinkDetector.Geometry(originX: 0, baseline0: 0, cellWidth: 1, cellHeight: 1, columns: 200, rows: 5), resolvePath: fs)
        XCTAssertEqual(links.map(\.text), ["Sources/App.swift", "README.md", "./Sources", "/usr/bin/git"])
        XCTAssertEqual(links[2].kind, .file(isDirectory: true))
        XCTAssertEqual(links[0].target, "/repo/Sources/App.swift")
    }

    func testURLsAreNotAlsoPaths() {
        let links = LinkDetector.detect(text: "https://example.com/Sources/App.swift", geometry: g, resolvePath: fs)
        XCTAssertEqual(links.map(\.kind), [.url])
    }

    func testPathCandidates() {
        XCTAssertTrue(LinkDetector.isPathCandidate("README.md"))
        XCTAssertTrue(LinkDetector.isPathCandidate("~/code"))
        XCTAssertFalse(LinkDetector.isPathCandidate("go"))        // bare words are too noisy
        XCTAssertFalse(LinkDetector.isPathCandidate("--flag=a/b"))
        XCTAssertFalse(LinkDetector.isPathCandidate("v1.2"))      // extension must contain a letter
        XCTAssertFalse(LinkDetector.isPathCandidate("/"))
    }

    func testTrimsPunctuationAndKeepsBalancedParens() {
        let text = "see https://a.com/x. and (https://en.wikipedia.org/wiki/Shell_(computing)), ok"
        let urls = LinkDetector.detect(text: text, geometry: g).map(\.url)
        XCTAssertEqual(urls, ["https://a.com/x", "https://en.wikipedia.org/wiki/Shell_(computing)"])
    }

    func testOnlyHttpSchemes() {
        XCTAssertTrue(LinkDetector.detect(text: "ftp://x.com file:///tmp/a", geometry: g).isEmpty)
    }

    func testRectsAndWrapping() {
        // Second line: 30 chars of padding then a URL that wraps past column 40.
        let text = "first line\n" + String(repeating: "x", count: 30) + " https://example.com/abc"
        let links = LinkDetector.detect(text: text, geometry: g)
        XCTAssertEqual(links.count, 1)
        let rects = links[0].rects
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].minX, 10 + 31 * 8)           // starts at column 31, row 1
        XCTAssertEqual(rects[0].width, 9 * 8)                // columns 31...39
        XCTAssertEqual(rects[1].minX, 10)                    // continues at column 0, row 2
        XCTAssertEqual(rects[1].minY - rects[0].minY, 16, accuracy: 0.001) // one row down
    }

    func testWideCharactersShiftColumns() {
        let links = LinkDetector.detect(text: "日本 https://x.dev", geometry: g)
        XCTAssertEqual(links.first?.rects.first?.minX, 10 + 5 * 8) // two wide chars (4 cells) + space
    }
}

final class CommandBlockTests: XCTestCase {
    @MainActor func testFindsLatestHeaderNotOutputLines() {
        let block = TerminalSession.CommandBlock(command: "ls", directory: "~/code", branch: "main")
        let lines = [
            "~/code main ❯ ls", "a", "b", "",
            "~/code main ❯ echo ls", "ls", "",
            "~/code main ❯ ls", "c", "tools",
        ]
        XCTAssertEqual(TerminalSession.headerIndex(of: block, in: lines, before: lines.count), 7)
        XCTAssertEqual(TerminalSession.headerIndex(of: block, in: lines, before: 7), 0)
    }

    @MainActor func testThemePromptFallback() {
        let block = TerminalSession.CommandBlock(command: "make test", directory: "~/x", branch: nil)
        let lines = ["➜  x git:(main) make test", "ok"]
        XCTAssertEqual(TerminalSession.headerIndex(of: block, in: lines, before: 2), 0)
    }
}
