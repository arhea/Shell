import AppKit
import SwiftUI
import XCTest
@testable import Shell

@MainActor
final class CommandPaletteTests: XCTestCase {
    private func uniqueCommand() -> String {
        "palette" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
    }

    // MARK: Model

    func testEmptyQueryListsTabsThenActions() throws {
        let fx = try tabsFixture()
        fx.tab("Server")
        fx.tab("Logs")
        let model = PaletteModel(controller: fx.controller)
        XCTAssertLessThanOrEqual(model.items.count, 60)
        XCTAssertEqual(model.items.prefix(2).map(\.id), ["tab:0", "tab:1"])
        XCTAssertEqual(model.items[0].title, "Server")
        XCTAssertTrue(model.items[1].subtitle.hasPrefix("Tab 2 · "))
        XCTAssertEqual(model.items[1].shortcut, "⌘2")
        let ids = Set(model.items.map(\.id))
        XCTAssertTrue(ids.contains("action:newTab"))
        XCTAssertFalse(ids.contains("action:commandPalette"), "the palette doesn't list itself")
        XCTAssertFalse(ids.contains("action:copy"))
        XCTAssertFalse(model.items.contains { $0.id.hasPrefix("theme:") || $0.id.hasPrefix("history:") })
    }

    func testTabsPastNineHaveNoShortcut() throws {
        let fx = try tabsFixture()
        for i in 0..<10 { fx.tab("Tab \(i)", select: false) }
        let model = PaletteModel(controller: fx.controller)
        XCTAssertEqual(model.items[8].shortcut, "⌘9")
        XCTAssertNil(model.items[9].shortcut)
    }

    func testQueryFuzzyFiltersAndRanksExactMatchesFirst() throws {
        let fx = try tabsFixture()
        fx.tab("Shell")
        let model = PaletteModel(controller: fx.controller)
        model.selected = 3
        model.query = "Split Right"
        XCTAssertEqual(model.selected, 0, "a new query resets the selection")
        XCTAssertEqual(model.items.first?.id, "action:splitRight")
        XCTAssertTrue(model.items.allSatisfy { FuzzyMatch.score("split right", in: $0.title.lowercased()) != nil })
        model.query = "zzqxv no such command"
        XCTAssertTrue(model.items.isEmpty)
    }

    func testRunningAnActionPerformsIt() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Shell")
        let model = PaletteModel(controller: fx.controller)
        model.query = "Split Right"
        model.items.first?.run()
        XCTAssertEqual(tab.sessions.count, 2)
    }

    func testRunningATabItemSelectsIt() throws {
        let fx = try tabsFixture()
        let first = fx.tab("First")
        fx.tab("Second")
        let model = PaletteModel(controller: fx.controller)
        try XCTUnwrap(model.items.first { $0.id == "tab:0" }).run()
        XCTAssertEqual(fx.workspace.selectedTabID, first.id)
    }

    func testThemesMatchTheCurrentAppearance() throws {
        let fx = try tabsFixture()
        fx.tab()
        let dark = ConfigController.shared.isDark
        let theme = try XCTUnwrap(ThemeLibrary.shared.themes.first { $0.isDark == dark })
        let model = PaletteModel(controller: fx.controller)
        model.query = "Theme: \(theme.name)"
        let item = try XCTUnwrap(model.items.first { $0.id == "theme:\(theme.name)" })
        XCTAssertEqual(item.subtitle, dark ? "Dark theme" : "Light theme")
        XCTAssertFalse(model.items.contains { item in
            ThemeLibrary.shared.themes.contains { $0.isDark != dark && item.id == "theme:\($0.name)" }
        })
        item.run()
        XCTAssertEqual(dark ? SettingsStore.shared.settings.darkTheme : SettingsStore.shared.settings.lightTheme, theme.name)
    }

    func testHistoryItemsRerunInTheFocusedPane() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Shell")
        let cmd = uniqueCommand()
        HistoryStore.shared.add(cmd)
        let model = PaletteModel(controller: fx.controller)
        model.query = cmd
        let item = try XCTUnwrap(model.items.first { $0.id == "history:\(cmd)" })
        XCTAssertEqual(item.subtitle, "Run from history")
        item.run()
        XCTAssertEqual(tab.focusedSession?.state, .running)
        XCTAssertEqual(tab.focusedSession?.runningCommand, cmd)
        // Busy: running it again does nothing.
        item.run()
        XCTAssertEqual(tab.focusedSession?.runningCommand, cmd)
    }

    func testInstallHooksItemIsListed() throws {
        let fx = try tabsFixture()
        fx.tab()
        let model = PaletteModel(controller: fx.controller)
        model.query = "Install Claude Code"
        XCTAssertEqual(model.items.first?.id, "install-hooks")
    }

    // MARK: View

    func testRendersTheListAndHighlightsTheSelection() throws {
        let fx = try tabsFixture()
        fx.tab("Shell")
        let model = PaletteModel(controller: fx.controller)
        render(PaletteView(model: model), size: CGSize(width: 600, height: 420))
        model.selected = 5
        render(PaletteView(model: model), size: CGSize(width: 600, height: 420))
        model.query = "tab"
        render(PaletteView(model: model), size: CGSize(width: 600, height: 420))
    }

    func testTypingArrowsAndEnterRunTheSelectedCommand() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Shell")
        let model = PaletteModel(controller: fx.controller)
        let w = claudeWindow(PaletteView(model: model), width: 600, height: 420)
        let field = try XCTUnwrap(w.subview(NSTextField.self))
        w.type("Split Right", into: field)
        XCTAssertTrue(waitUntil(timeout: 2) { model.query == "Split Right" })
        func key(_ code: UInt16, _ chars: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
                w.window.sendEvent(e)
            }
            w.layout(settle: 0.02)
        }
        key(125, "\u{F701}") // ↓
        key(126, "\u{F700}") // ↑
        key(126, "\u{F700}") // ↑ at the top stays
        XCTAssertEqual(model.selected, 0)
        key(36, "\r")
        XCTAssertTrue(waitUntil(timeout: 2) { tab.sessions.count == 2 })
        key(53, "\u{1B}") // Esc closes the (not shown) palette
    }

    func testShowsAsAChildPanelAndClosesWhenItLosesFocus() throws {
        let fx = try tabsFixture()
        fx.tab()
        let window = try XCTUnwrap(fx.controller.window)
        CommandPalette.show(for: fx.controller)
        let panel = try XCTUnwrap(window.childWindows?.first { $0 is PalettePanel })
        XCTAssertTrue(panel.canBecomeKey)
        // Showing again replaces it.
        CommandPalette.show(for: fx.controller)
        XCTAssertEqual(window.childWindows?.filter { $0 is PalettePanel }.count, 1)
        let current = try XCTUnwrap(window.childWindows?.first { $0 is PalettePanel })
        current.resignKey()
        XCTAssertTrue(waitUntil(timeout: 2) { window.childWindows?.contains { $0 is PalettePanel } != true })
        CommandPalette.close() // already closed
    }
}
