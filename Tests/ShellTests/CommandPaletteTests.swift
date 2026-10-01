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

    func testEmptyQueryListsTabsFirstThenActions() throws {
        let fx = try tabsFixture()
        let server = fx.tab("Server")
        let logs = fx.tab("Logs")
        let model = PaletteModel(controller: fx.controller)
        XCTAssertEqual(model.sections.first?.section, .tabs)
        XCTAssertEqual(model.rows.prefix(2).map(\.id), ["tab:\(server.id)", "tab:\(logs.id)"])
        XCTAssertEqual(model.rows[0].title, "Server")
        XCTAssertEqual(model.rows[1].trailing, "⌘2")
        XCTAssertEqual(model.sections.map(\.section), model.sections.map(\.section).sorted(), "sections keep their order")
        let ids = Set(model.rows.map(\.id))
        XCTAssertTrue(ids.contains("action:newTab"))
        XCTAssertFalse(ids.contains("action:commandPalette"), "the palette doesn't list itself")
        XCTAssertFalse(ids.contains("action:copy"))
        XCTAssertFalse(model.rows.contains { $0.section == .themes || $0.section == .history })
        XCTAssertLessThanOrEqual(model.sections.first { $0.section == .actions }?.items.count ?? 0, PaletteSection.actions.limit)
    }

    func testTabsPastNineHaveNoShortcut() throws {
        let fx = try tabsFixture()
        for i in 0..<10 { fx.tab("Tab \(i)", select: false) }
        let model = PaletteModel(controller: fx.controller)
        model.query = "Tab"
        let tabs = try XCTUnwrap(model.sections.first { $0.section == .tabs }).items
        XCTAssertEqual(tabs.count, PaletteSection.tabs.limit)
        XCTAssertEqual(tabs[8].trailing, "⌘9")
    }

    func testQueryFuzzyFiltersAndRanksExactMatchesFirst() throws {
        let fx = try tabsFixture()
        fx.tab("Shell")
        let model = PaletteModel(controller: fx.controller)
        model.selected = 3
        model.query = "Split Right"
        XCTAssertEqual(model.selected, 0, "a new query resets the selection")
        let actions = try XCTUnwrap(model.sections.first { $0.section == .actions })
        XCTAssertEqual(actions.items.first?.id, "action:splitRight")
        XCTAssertEqual(actions.items.first?.matches, Array(0..<11), "the matched characters are bold")
        XCTAssertTrue(model.rows.allSatisfy { FuzzyMatch.score("split right", in: $0.title.lowercased()) != nil })
        model.query = "zzqxv no such command"
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testPrefixesScopeTheSearch() throws {
        let fx = try tabsFixture()
        fx.tab("Split work")
        let model = PaletteModel(controller: fx.controller)
        model.query = "> split"
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertTrue(model.rows.allSatisfy { $0.section == .actions }, "> lists actions only")
        model.query = ">"
        XCTAssertGreaterThan(model.rows.count, PaletteSection.actions.limit, "> with no text lists every action")
        model.query = "@"
        XCTAssertTrue(model.rows.allSatisfy { $0.section == .folders || $0.section == .worktrees }, "@ lists places only")
        XCTAssertTrue(model.rows.allSatisfy(\.takesModifiers))
    }

    func testRunningAnActionPerformsIt() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Shell")
        let model = PaletteModel(controller: fx.controller)
        model.query = "> Split Right"
        model.run(.plain)
        XCTAssertEqual(tab.sessions.count, 2)
    }

    func testRunningATabItemSelectsIt() throws {
        let fx = try tabsFixture()
        let first = fx.tab("First")
        fx.tab("Second")
        let model = PaletteModel(controller: fx.controller)
        try XCTUnwrap(model.rows.first { $0.id == "tab:\(first.id)" }).run(.plain)
        XCTAssertEqual(fx.workspace.selectedTabID, first.id)
    }

    func testFolderModifiersOpenANewTab() throws {
        let fx = try tabsFixture()
        fx.tab("Here")
        RecentDirectories.note(fx.dir)
        let model = PaletteModel(controller: fx.controller)
        let name = (fx.dir as NSString).lastPathComponent
        let folder = try XCTUnwrap(model.rows.first { $0.section == .folders && $0.title == name })
        XCTAssertTrue(folder.takesModifiers)
        let before = fx.workspace.tabs.count
        folder.run(.newTab)
        XCTAssertEqual(fx.workspace.tabs.count, before + 1, "⌘⏎ opens a new tab")
        folder.run(.claude)
        XCTAssertEqual(fx.workspace.tabs.count, before + 2)
        XCTAssertNotNil(fx.workspace.tabs.last?.focusedSession?.pendingCommand, "⌥⏎ starts Claude in the new tab")
    }

    func testThemesMatchTheCurrentAppearance() throws {
        let fx = try tabsFixture()
        fx.tab()
        let dark = ConfigController.shared.isDark
        let theme = try XCTUnwrap(ThemeLibrary.shared.themes.first { $0.isDark == dark })
        let model = PaletteModel(controller: fx.controller)
        model.query = theme.name
        let item = try XCTUnwrap(model.rows.first { $0.id == "theme:\(theme.name)" })
        XCTAssertEqual(item.subtitle, dark ? "Dark theme" : "Light theme")
        XCTAssertFalse(model.rows.contains { item in
            ThemeLibrary.shared.themes.contains { $0.isDark != dark && item.id == "theme:\($0.name)" }
        })
        item.run(.plain)
        XCTAssertEqual(dark ? SettingsStore.shared.settings.darkTheme : SettingsStore.shared.settings.lightTheme, theme.name)
    }

    func testHistoryItemsRerunInTheFocusedPane() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Shell")
        let cmd = uniqueCommand()
        HistoryStore.shared.add(cmd)
        let model = PaletteModel(controller: fx.controller)
        model.query = cmd
        let item = try XCTUnwrap(model.rows.first { $0.id == "history:\(cmd)" })
        XCTAssertEqual(item.section, .history)
        item.run(.plain)
        XCTAssertEqual(tab.focusedSession?.state, .running)
        XCTAssertEqual(tab.focusedSession?.runningCommand, cmd)
        // Busy: running it again does nothing.
        item.run(.plain)
        XCTAssertEqual(tab.focusedSession?.runningCommand, cmd)
    }

    func testInstallHooksItemIsListed() throws {
        let fx = try tabsFixture()
        fx.tab()
        let model = PaletteModel(controller: fx.controller)
        model.query = "Install Claude Code"
        XCTAssertEqual(model.rows.first?.id, "install-hooks")
    }

    // MARK: View

    func testRendersTheListAndHighlightsTheSelection() throws {
        let fx = try tabsFixture()
        fx.tab("Shell")
        let model = PaletteModel(controller: fx.controller)
        render(PaletteView(model: model), size: CGSize(width: 680, height: 460))
        model.selected = 5
        render(PaletteView(model: model), size: CGSize(width: 680, height: 460))
        model.query = "tab"
        render(PaletteView(model: model), size: CGSize(width: 680, height: 460))
    }

    func testTypingArrowsAndEnterRunTheSelectedCommand() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Shell")
        let model = PaletteModel(controller: fx.controller)
        let w = claudeWindow(PaletteView(model: model), width: 680, height: 460)
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
