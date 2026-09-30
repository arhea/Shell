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
