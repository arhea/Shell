import AppKit
import XCTest
@testable import Shell

/// KeyShortcut parsing and formatting, ShortcutAction defaults and overrides,
/// and how shortcuts land on menu items.
@MainActor
final class KeyShortcutTests: XCTestCase {
    private func keyEvent(_ chars: String, ignoring: String? = nil, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                          type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: keyCode)!
    }

    // MARK: KeyShortcut

    func testKeysAreLowercased() {
        XCTAssertEqual(KeyShortcut(key: "D", modifiers: [.command]).key, "d")
        XCTAssertEqual(KeyShortcut.cmd("T"), KeyShortcut(key: "t", modifiers: [.command]))
    }

    func testConvenienceConstructors() {
        XCTAssertEqual(KeyShortcut.cmd("a").modifiers, [.command])
        XCTAssertEqual(KeyShortcut.cmdShift("a").modifiers, [.command, .shift])
        XCTAssertEqual(KeyShortcut.cmdOpt("a").modifiers, [.command, .option])
        XCTAssertEqual(KeyShortcut.cmdCtrl("a").modifiers, [.command, .control])
    }

    func testModifierFlagsAndSymbols() {
        let all = KeyShortcut(key: "x", modifiers: Set(KeyShortcut.Modifier.allCases))
        XCTAssertEqual(all.modifierFlags, [.command, .option, .control, .shift])
        XCTAssertEqual(KeyShortcut.Modifier.allCases.map(\.symbol), ["⌃", "⌥", "⇧", "⌘"])
        XCTAssertEqual(KeyShortcut.Modifier.allCases.map(\.flag), [.control, .option, .shift, .command])
        XCTAssertEqual(KeyShortcut(key: "x", modifiers: []).modifierFlags, [])
    }

    func testDisplayStringOrdersModifiersLikeMacOS() {
        XCTAssertEqual(KeyShortcut(key: "d", modifiers: [.command, .shift]).displayString, "⇧⌘D")
        XCTAssertEqual(KeyShortcut(key: "c", modifiers: [.command, .shift, .option, .control]).displayString, "⌃⌥⇧⌘C")
        XCTAssertEqual(KeyShortcut.cmdOpt("left").displayString, "⌥⌘←")
        XCTAssertEqual(KeyShortcut.cmd("return").displayString, "⌘↩")
        XCTAssertEqual(KeyShortcut.cmd("space").displayString, "⌘Space")
        XCTAssertEqual(KeyShortcut(key: "f5", modifiers: []).displayString, "F5")
        XCTAssertEqual(KeyShortcut.cmd("[").displayString, "⌘[")
    }

    func testKeyEquivalentForNamedAndPlainKeys() {
        XCTAssertEqual(KeyShortcut.cmd("d").keyEquivalent, "d")
        XCTAssertEqual(KeyShortcut.cmd("return").keyEquivalent, "\r")
        XCTAssertEqual(KeyShortcut.cmd("tab").keyEquivalent, "\t")
        XCTAssertEqual(KeyShortcut.cmd("escape").keyEquivalent, "\u{1B}")
        XCTAssertEqual(KeyShortcut.cmd("left").keyEquivalent, String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        XCTAssertEqual(KeyShortcut.cmd("f12").keyEquivalent, String(Character(UnicodeScalar(NSF12FunctionKey)!)))
    }

    func testGhosttyTrigger() {
        XCTAssertEqual(KeyShortcut(key: "d", modifiers: [.command, .shift]).ghosttyTrigger, "shift+super+d")
        XCTAssertEqual(KeyShortcut(key: "x", modifiers: [.control, .option]).ghosttyTrigger, "ctrl+alt+x")
        XCTAssertEqual(KeyShortcut.cmdOpt("left").ghosttyTrigger, "alt+super+arrow_left")
        XCTAssertEqual(KeyShortcut.cmd("return").ghosttyTrigger, "super+enter")
        XCTAssertEqual(KeyShortcut.cmd("delete").ghosttyTrigger, "super+backspace")
        XCTAssertEqual(KeyShortcut.cmd("forwarddelete").ghosttyTrigger, "super+delete")
        XCTAssertEqual(KeyShortcut.cmd("pageup").ghosttyTrigger, "super+page_up")
        XCTAssertEqual(KeyShortcut(key: "f1", modifiers: []).ghosttyTrigger, "f1")
    }

    func testCodableRoundTrip() throws {
        let s = KeyShortcut(key: "]", modifiers: [.command, .shift])
        XCTAssertEqual(try JSONDecoder().decode(KeyShortcut.self, from: JSONEncoder().encode(s)), s)
    }

    func testRecordsPlainKeysWithModifiers() throws {
        let sc = try XCTUnwrap(KeyShortcut(event: keyEvent("d", keyCode: 0x02, modifiers: [.command, .option, .control])))
        XCTAssertEqual(sc, KeyShortcut(key: "d", modifiers: [.command, .option, .control]))
    }

    func testRecordsShiftedKeysAsTheUnshiftedCharacter() throws {
        // ⇧⌘D arrives as "D"; it's stored as "d" + shift.
        let sc = try XCTUnwrap(KeyShortcut(event: keyEvent("D", keyCode: 0x02, modifiers: [.command, .shift])))
        XCTAssertEqual(sc, KeyShortcut.cmdShift("d"))
    }

    func testRecordsNamedKeysByKeyCode() throws {
        XCTAssertEqual(KeyShortcut(event: keyEvent("\u{F702}", keyCode: 0x7B, modifiers: [.command, .option])), .cmdOpt("left"))
        XCTAssertEqual(KeyShortcut(event: keyEvent("\r", keyCode: 0x24, modifiers: [.command])), .cmd("return"))
        XCTAssertEqual(KeyShortcut(event: keyEvent("\u{F708}", keyCode: 0x60)), KeyShortcut(key: "f5", modifiers: []))
    }

    func testIgnoresKeyUpAndEmptyEvents() {
        XCTAssertNil(KeyShortcut(event: keyEvent("d", keyCode: 0x02, modifiers: [.command], type: .keyUp)))
        XCTAssertNil(KeyShortcut(event: keyEvent("", keyCode: 0x00, modifiers: [.command])))
    }

    func testMatches() {
        let event = keyEvent("t", keyCode: 0x11, modifiers: [.command])
        XCTAssertTrue(KeyShortcut.cmd("t").matches(event))
        XCTAssertFalse(KeyShortcut.cmdShift("t").matches(event))
        XCTAssertFalse(KeyShortcut.cmd("t").matches(keyEvent("t", keyCode: 0x11, modifiers: [.command], type: .keyUp)))
    }

    // MARK: ShortcutAction

    func testEveryActionHasATitleAndCategory() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.title.isEmpty, "\(action)")
            XCTAssertEqual(action.id, action.rawValue)
            XCTAssertTrue(ShortcutAction.Category.allCases.contains(action.category))
        }
        XCTAssertEqual(Set(ShortcutAction.allCases.map(\.title)).count, ShortcutAction.allCases.count, "titles are unique")
        // Every category has at least one action.
        for category in ShortcutAction.Category.allCases {
            XCTAssertTrue(ShortcutAction.allCases.contains { $0.category == category }, category.rawValue)
        }
    }

    func testSpotCheckCategoriesAndTitles() {
        XCTAssertEqual(ShortcutAction.settings.category, .app)
        XCTAssertEqual(ShortcutAction.newTab.category, .windows)
        XCTAssertEqual(ShortcutAction.splitRight.category, .panes)
        XCTAssertEqual(ShortcutAction.copy.category, .terminal)
        XCTAssertEqual(ShortcutAction.toggleSidebar.category, .view)
        XCTAssertEqual(ShortcutAction.settings.title, "Settings…")
        XCTAssertEqual(ShortcutAction.zoomPane.title, "Maximize Pane")
        XCTAssertEqual(ShortcutAction.Category.windows.rawValue, "Windows & Tabs")
    }

    func testDefaultShortcutsAreUnique() {
        let bound = ShortcutAction.allCases.compactMap { a in a.defaultShortcut.map { (a, $0) } }
        var seen: [KeyShortcut: ShortcutAction] = [:]
        for (action, sc) in bound {
            XCTAssertNil(seen[sc], "\(action) and \(seen[sc].map { "\($0)" } ?? "") share \(sc.displayString)")
            seen[sc] = action
        }
        XCTAssertGreaterThan(bound.count, 50)
    }

    func testITermStyleDefaults() {
        XCTAssertEqual(ShortcutAction.splitRight.defaultShortcut, .cmd("d"))
        XCTAssertEqual(ShortcutAction.splitDown.defaultShortcut, .cmdShift("d"))
        XCTAssertEqual(ShortcutAction.moveTabLeft.defaultShortcut, KeyShortcut(key: "left", modifiers: [.command, .shift, .control]))
        XCTAssertEqual(ShortcutAction.copyLastOutput.defaultShortcut, KeyShortcut(key: "c", modifiers: [.command, .shift, .option]))
        XCTAssertEqual(ShortcutAction.lastTab.defaultShortcut, .cmd("9"))
        XCTAssertNil(ShortcutAction.homebrew.defaultShortcut)
        XCTAssertNil(ShortcutAction.equalizePanes.defaultShortcut)
    }

    func testUserOverridesWinAndNilUnbinds() {
        let overrides: [String: KeyShortcut?] = ["newTab": .cmdShift("t"), "splitRight": nil]
        withSettings({ $0.shortcuts = overrides }) {
            XCTAssertEqual(ShortcutAction.newTab.shortcut, .cmdShift("t"))
            XCTAssertNil(ShortcutAction.splitRight.shortcut, "an explicit nil unbinds")
            XCTAssertEqual(ShortcutAction.splitDown.shortcut, .cmdShift("d"), "others keep their default")
        }
        XCTAssertEqual(ShortcutAction.newTab.shortcut, .cmd("t"))
    }

    func testSelectors() {
        XCTAssertEqual(ShortcutAction.copy.selector, #selector(NSText.copy(_:)))
        XCTAssertEqual(ShortcutAction.paste.selector, #selector(NSText.paste(_:)))
        XCTAssertEqual(ShortcutAction.selectAll.selector, #selector(NSText.selectAll(_:)))
        XCTAssertEqual(ShortcutAction.toggleFullScreen.selector, #selector(NSWindow.toggleFullScreen(_:)))
        XCTAssertEqual(ShortcutAction.newTab.selector, #selector(ShortcutActionHandling.performShortcutAction(_:)))
    }

    func testResolvesActionFromSender() {
        let item = NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "")
        item.representedObject = "newTab"
        XCTAssertEqual(ShortcutAction.from(sender: item), .newTab)
        item.representedObject = "notAnAction"
        XCTAssertNil(ShortcutAction.from(sender: item))
        XCTAssertNil(ShortcutAction.from(sender: NSMenuItem()))
        XCTAssertEqual(ShortcutAction.from(sender: ShortcutActionBox(.find)), .find)
        XCTAssertNil(ShortcutAction.from(sender: "newTab"))
        XCTAssertNil(ShortcutAction.from(sender: nil))
    }

    // MARK: Menu items

    func testMenuItemApplyPlainShortcut() {
        let item = NSMenuItem()
        item.apply(.cmdOpt("w"))
        XCTAssertEqual(item.keyEquivalent, "w")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
    }

    func testMenuItemApplyTranslatesShiftedPunctuation() {
        let item = NSMenuItem()
        item.apply(.cmdShift("]"))
        XCTAssertEqual(item.keyEquivalent, "}")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        item.apply(.cmdShift("="))
        XCTAssertEqual(item.keyEquivalent, "+")
    }

    func testMenuItemApplyKeepsShiftForLetters() {
        let item = NSMenuItem()
        item.apply(.cmdShift("d"))
        XCTAssertEqual(item.keyEquivalent, "d")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func testMenuItemApplyNilClears() {
        let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "x")
        item.keyEquivalentModifierMask = [.command]
        item.apply(nil)
        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertEqual(item.keyEquivalentModifierMask, [])
    }
}
