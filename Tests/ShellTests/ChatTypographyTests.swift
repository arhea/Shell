import XCTest
@testable import Shell

final class ChatTypographyTests: XCTestCase {
    func testDefaultsFollowTheTerminalFont() {
        var s = AppSettings()
        s.fontSize = 13
        s.editorFontSize = 0
        let t = ChatTypography.from(s)
        XCTAssertEqual(t.size, 14)
        XCTAssertEqual(t.codeSize, 12.5)
        XCTAssertEqual(t.lineSpacing, 6)      // (1.6 − 1.2) × 14 ≈ 5.6
        XCTAssertEqual(t.blockSpacing, 14)
        XCTAssertEqual(t.maxWidth, 700)
        XCTAssertEqual(t.codeFamily, s.fontFamily)
    }

    func testExplicitValuesAndClamping() {
        var s = AppSettings()
        s.chatFontSize = 16
        s.chatCodeFontSize = 13
        s.chatLineHeight = 0.5            // below 1 is clamped
        s.chatMaxWidth = 0
        s.chatCodeFontFamily = "Menlo"
        let t = ChatTypography.from(s)
        XCTAssertEqual(t.size, 16)
        XCTAssertEqual(t.codeSize, 13)
        XCTAssertEqual(t.lineSpacing, 0)
        XCTAssertNil(t.maxWidth)
        XCTAssertEqual(t.codeFamily, "Menlo")
        XCTAssertEqual(t.scaled(to: 12).codeSize, 9)
    }
}

@MainActor
final class ChatComposerWidthTests: XCTestCase {
    func testColumnWidthFollowsTheSetting() {
        var s = AppSettings()
        XCTAssertEqual(s.chatComposerWidth, .centered)
        XCTAssertEqual(ChatTypography.from(s).columnWidth, 1200)
        s.chatComposerWidth = .full
        XCTAssertNil(ChatTypography.from(s).columnWidth)
    }

    func testTurnedOffReadingWidthMigratesToFullWidth() {
        var merged: [String: Any] = ["chatComposerWidth": "centered"]
        SettingsStore.migrate(stored: ["chatMaxWidth": 0.0], into: &merged)
        XCTAssertEqual(merged["chatComposerWidth"] as? String, "full")
    }

    func testExistingReadingWidthStaysCentered() {
        var merged: [String: Any] = ["chatComposerWidth": "centered"]
        SettingsStore.migrate(stored: ["chatMaxWidth": 900.0], into: &merged)
        XCTAssertEqual(merged["chatComposerWidth"] as? String, "centered")
    }

    func testAnExplicitChoiceIsKept() {
        var merged: [String: Any] = ["chatComposerWidth": "centered"]
        SettingsStore.migrate(stored: ["chatMaxWidth": 0.0, "chatComposerWidth": "centered"], into: &merged)
        XCTAssertEqual(merged["chatComposerWidth"] as? String, "centered")
    }

    func testUnknownValueDecodesAsCentered() throws {
        let value = try JSONDecoder().decode([ChatComposerWidth].self, from: Data(#"["wide"]"#.utf8))
        XCTAssertEqual(value, [.centered])
    }

    func testSyncs() {
        XCTAssertTrue(SettingsSync.portableKeys.contains("chatComposerWidth"))
    }
}
