import AppKit
import XCTest
@testable import Shell

/// AppSettings: defaults, enum titles, lenient decoding, migrations, loading
/// and the store's observers.
@MainActor
final class SettingsModelTests: XCTestCase {
    // MARK: Enums

    func testEveryEnumCaseHasATitleAndStableID() {
        func check<E: CaseIterable & Identifiable & RawRepresentable>(_ type: E.Type, _ title: (E) -> String) where E.RawValue == String, E.ID == String {
            let titles = E.allCases.map(title)
            XCTAssertFalse(titles.contains(""), "\(E.self) has an empty title")
            XCTAssertEqual(Set(titles).count, titles.count, "\(E.self) titles must be distinct")
            let stableIDs = E.allCases.allSatisfy { $0.id == $0.rawValue }
            XCTAssertTrue(stableIDs, "\(E.self) ids are its raw values")
        }
        check(AppearanceMode.self, \.title)
        check(CursorStyle.self, \.title)
        check(OptionKeyMode.self, \.title)
        check(InputPosition.self, \.title)
        check(PromptStyle.self, \.title)
        check(ChatComposerWidth.self, \.title)
        check(ClaudeSessionsButton.self, \.title)
        check(DiffStyle.self, \.title)
        check(ToolCallDisplay.self, \.title)
        check(ClaudeLaunchMode.self, \.title)
        check(TabBarStyle.self, \.title)
        check(NewTabDirectory.self, \.title)
        check(NewTabPlacement.self, \.title)
    }

    func testSpecificTitlesAndRawValues() {
        XCTAssertEqual(AppearanceMode.dark.title, "Dark")
        XCTAssertEqual(CursorStyle.hollow.rawValue, "block_hollow")
        XCTAssertEqual(CursorStyle.hollow.title, "Hollow Block")
        // Ghostty's macos-option-as-alt values.
        XCTAssertEqual(OptionKeyMode.normal.rawValue, "false")
        XCTAssertEqual(OptionKeyMode.meta.rawValue, "true")
        XCTAssertEqual(InputPosition.top.title, "Pin to top")
        XCTAssertEqual(PromptStyle.shell.title, "My zsh prompt (PS1 / theme)")
        XCTAssertEqual(ChatComposerWidth.full.title, "Full width")
        XCTAssertEqual(ChatComposerWidth.centeredMaxWidth, 1200)
        XCTAssertEqual(TabBarStyle.vertical.title, "Vertical (sidebar)")
        XCTAssertEqual(NewTabPlacement.end.title, "At the end")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data("\"\(raw)\"".utf8))
    }

    func testLenientEnumsFallBackOnUnknownValues() throws {
        XCTAssertEqual(try decode(SidebarTab.self, "files"), .files)
        XCTAssertEqual(try decode(SidebarTab.self, "worktrees"), .worktrees)
        XCTAssertEqual(try decode(SidebarTab.self, "prs"), .github, "the retired PRs tab became GitHub")
        XCTAssertEqual(try decode(SidebarTab.self, "nope"), .github)
        XCTAssertEqual(try decode(GitHubSection.self, "actions"), .actions)
        XCTAssertEqual(try decode(GitHubSection.self, "nope"), .prs)
        XCTAssertEqual(try decode(ChatComposerWidth.self, "full"), .full)
        XCTAssertEqual(try decode(ChatComposerWidth.self, "wide"), .centered)
        XCTAssertEqual(try decode(ClaudeSessionsButton.self, "whenActive"), .whenActive)
        XCTAssertEqual(try decode(ClaudeSessionsButton.self, "sometimes"), .always)
    }

    func testStrictEnumsRejectUnknownValues() {
        XCTAssertThrowsError(try decode(CursorStyle.self, "triangle"))
        XCTAssertNoThrow(try decode(CursorStyle.self, "block_hollow"))
    }

    // MARK: ColorOverrides

    func testColorOverridesIsEmpty() {
        var o = ColorOverrides()
        XCTAssertTrue(o.isEmpty)
        o.cursor = "#ffffff"
        XCTAssertFalse(o.isEmpty)
        o = ColorOverrides()
        o.palette[3] = "#123456"
        XCTAssertFalse(o.isEmpty)
        o = ColorOverrides(selectionForeground: "#000000")
        XCTAssertFalse(o.isEmpty)
    }

    // MARK: Codable

    func testRoundTripsThroughJSON() throws {
        var s = AppSettings()
        s.darkTheme = "Dracula"
        s.darkOverrides.palette[1] = "#ff0000"
        s.cursorStyle = .hollow
        s.optionKey = .meta
        s.environment = ["A": "1"]
        s.hotkey = nil
        s.shortcuts = ["newTab": nil, "splitRight": .cmdShift("e")]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
        XCTAssertNil(decoded.hotkey)
        XCTAssertTrue(decoded.shortcuts.keys.contains("newTab"), "an explicit unbind survives a round trip")
        XCTAssertNil(decoded.shortcuts["newTab"] ?? .cmd("x"))
    }

    func testDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.lightTheme, "Shell Light")
        XCTAssertEqual(s.darkTheme, "Shell Dark")
        XCTAssertEqual(s.fontSize, 13)
        XCTAssertEqual(s.cursorStyle, .bar)
        XCTAssertEqual(s.hotkey, KeyShortcut(key: "`", modifiers: [.option]))
        XCTAssertFalse(s.iCloudSync)
        XCTAssertEqual(s.claudePermissionMode, "auto")
        XCTAssertEqual(s.nodePackageManagers, ["npm", "pnpm", "yarn", "bun"])
        XCTAssertFalse(s.intelligenceBranchNames || s.intelligencePaletteIntents || s.intelligenceCommandFixes
            || s.intelligenceSessionSummaries || s.intelligenceTabNames, "Apple Intelligence features are off by default")
    }

    // MARK: Migration

    func testMigrateTurnsAZeroReadingWidthIntoFullWidth() {
        var merged: [String: Any] = [:]
        SettingsStore.migrate(stored: ["chatMaxWidth": 0.0], into: &merged)
        XCTAssertEqual(merged["chatComposerWidth"] as? String, "full")
    }

    func testMigrateKeepsAnExplicitComposerWidth() {
        var merged: [String: Any] = ["chatComposerWidth": "centered"]
        SettingsStore.migrate(stored: ["chatMaxWidth": 0.0, "chatComposerWidth": "centered"], into: &merged)
        XCTAssertEqual(merged["chatComposerWidth"] as? String, "centered")
        var other: [String: Any] = [:]
        SettingsStore.migrate(stored: ["chatMaxWidth": 700.0], into: &other)
        XCTAssertNil(other["chatComposerWidth"])
    }

    func testMigrateTurnsTheOldDashboardToggleIntoNever() {
        var merged: [String: Any] = ["claudeDashboard": false]
        SettingsStore.migrate(stored: ["claudeDashboard": false], into: &merged)
        XCTAssertEqual(merged["claudeSessionsButton"] as? String, "never")
        XCTAssertNil(merged["claudeDashboard"], "the retired key is dropped")

        var on: [String: Any] = ["claudeDashboard": true]
        SettingsStore.migrate(stored: ["claudeDashboard": true], into: &on)
        XCTAssertNil(on["claudeSessionsButton"])
        XCTAssertNil(on["claudeDashboard"])

        var explicit: [String: Any] = [:]
        SettingsStore.migrate(stored: ["claudeDashboard": false, "claudeSessionsButton": "always"], into: &explicit)
        XCTAssertNil(explicit["claudeSessionsButton"], "an explicit choice wins over the old toggle")
    }

    // MARK: Loading

    private func writeSettings(_ object: Any) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    func testLoadLayersAnOlderFileOverTheDefaults() throws {
        let url = try writeSettings(["fontSize": 17, "darkTheme": "Nord", "chatMaxWidth": 0, "claudeDashboard": false])
        let s = try XCTUnwrap(SettingsStore.load(from: url))
        XCTAssertEqual(s.fontSize, 17)
        XCTAssertEqual(s.darkTheme, "Nord")
        XCTAssertEqual(s.lightTheme, "Shell Light", "missing keys keep their defaults")
        XCTAssertEqual(s.chatComposerWidth, .full)
        XCTAssertEqual(s.claudeSessionsButton, .never)
    }

    func testLoadReturnsNilForMissingOrBrokenFiles() throws {
        let dir = try makeTemporaryDirectory()
        XCTAssertNil(SettingsStore.load(from: dir.appendingPathComponent("missing.json")))
        let garbage = dir.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        XCTAssertNil(SettingsStore.load(from: garbage))
        XCTAssertNil(SettingsStore.load(from: try writeSettings(["fontSize": "huge"])), "a wrongly typed value fails decoding")
    }

    func testSaveNowWritesTheCurrentSettings() throws {
        try withSettings({ $0.fontSize = 19.5; $0.darkTheme = "Saved Theme" }) {
            SettingsStore.shared.saveNow()
            let loaded = try XCTUnwrap(SettingsStore.load())
            XCTAssertEqual(loaded.fontSize, 19.5)
            XCTAssertEqual(loaded.darkTheme, "Saved Theme")
        }
        SettingsStore.shared.saveNow()
    }

    // MARK: Store

    func testObserversSeeChangesUntilRemoved() {
        withSettings({ _ in }) {
            var seen: [(Double, Double)] = []
            let token = SettingsStore.shared.observe { old, new in seen.append((old.fontSize, new.fontSize)) }
            SettingsStore.shared.settings.fontSize = 21
            SettingsStore.shared.settings.fontSize = 21 // no change, no callback
            SettingsStore.shared.removeObserver(token)
            SettingsStore.shared.settings.fontSize = 22
            XCTAssertEqual(seen.count, 1)
            XCTAssertEqual(seen.first?.1, 21)
        }
    }

    func testResetRestoresDefaults() {
        withSettings({ $0.fontSize = 30; $0.darkTheme = "X"; $0.shortcuts = ["newTab": nil] }) {
            SettingsStore.shared.reset()
            XCTAssertEqual(SettingsStore.shared.settings, AppSettings())
        }
    }

    // MARK: Visual diffing

    func testNonVisualChangesAreDetected() {
        let base = AppSettings()
        var s = base
        s.sidebarTab = .files
        s.worktreeStaleDays = 3
        s.notifyCommandFinished = false
        s.hotkey = nil
        s.claudeModel = "opus"
        s.nodePackageManagers = []
        XCTAssertTrue(s.differsOnlyInNonVisualState(from: base))
        XCTAssertTrue(base.differsOnlyInNonVisualState(from: base))
    }

    func testVisualChangesAreNotIgnored() {
        let base = AppSettings()
        for change: (inout AppSettings) -> Void in [{ $0.fontSize = 20 }, { $0.darkTheme = "Nord" }, { $0.paddingX = 0 },
                                                    { $0.inputEditor = false }, { $0.extraGhosttyConfig = "x = 1" }] {
            var s = base
            change(&s)
            XCTAssertFalse(s.differsOnlyInNonVisualState(from: base))
        }
    }

    func testTestsRunInTheTestEnvironment() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
        XCTAssertTrue(SettingsStore.fileURL.path.hasPrefix(SettingsStore.supportDirectory.path))
    }
}
