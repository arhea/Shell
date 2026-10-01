import AppKit
import XCTest
@testable import Shell

/// RGB parsing, Ghostty theme files, overrides and the theme library.
@MainActor
final class ThemeTests: XCTestCase {
    // MARK: RGB

    func testParsesHexForms() {
        XCTAssertEqual(RGB(hex: "#ff8000"), RGB(r: 255, g: 128, b: 0))
        XCTAssertEqual(RGB(hex: "FF8000"), RGB(r: 255, g: 128, b: 0))
        XCTAssertEqual(RGB(hex: "  #0a0b0c "), RGB(r: 10, g: 11, b: 12))
        XCTAssertEqual(RGB(hex: "#fa0"), RGB(r: 255, g: 170, b: 0), "three-digit shorthand doubles each digit")
    }

    func testRejectsInvalidHex() {
        XCTAssertNil(RGB(hex: ""))
        XCTAssertNil(RGB(hex: "#12345"))
        XCTAssertNil(RGB(hex: "#1234567"))
        XCTAssertNil(RGB(hex: "#gggggg"))
    }

    func testHexRoundTrip() {
        XCTAssertEqual(RGB(r: 1, g: 171, b: 255).hex, "#01abff")
        XCTAssertEqual(RGB(hex: RGB(r: 18, g: 52, b: 86).hex), RGB(r: 18, g: 52, b: 86))
    }

    func testNSColorConversions() {
        let c = RGB(r: 255, g: 0, b: 128)
        XCTAssertEqual(RGB(c.nsColor), c)
        XCTAssertEqual(RGB(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)), RGB(r: 0, g: 255, b: 0))
        // Non-RGB colors convert through sRGB.
        XCTAssertEqual(RGB(NSColor(white: 1, alpha: 1)), RGB(r: 255, g: 255, b: 255))
    }

    func testLuminance() {
        XCTAssertEqual(RGB(r: 0, g: 0, b: 0).luminance, 0, accuracy: 1e-9)
        XCTAssertEqual(RGB(r: 255, g: 255, b: 255).luminance, 1, accuracy: 1e-9)
        XCTAssertEqual(RGB(r: 5, g: 5, b: 5).luminance, (5.0 / 255) / 12.92, accuracy: 1e-9, "the linear segment")
        XCTAssertGreaterThan(RGB(r: 0, g: 255, b: 0).luminance, RGB(r: 255, g: 0, b: 0).luminance)
    }

    func testMixing() {
        let black = RGB(r: 0, g: 0, b: 0), white = RGB(r: 255, g: 255, b: 255)
        XCTAssertEqual(black.mixed(with: white, 0), black)
        XCTAssertEqual(black.mixed(with: white, 1), white)
        XCTAssertEqual(black.mixed(with: white, 0.5), RGB(r: 128, g: 128, b: 128))
    }

    // MARK: TerminalTheme

    func testParsesAGhosttyThemeFile() throws {
        let contents = """
        # A comment = with an equals sign
        background = #101010
        foreground = #f0f0f0
        cursor-color = #ff0000
        cursor-text = #000000
        selection-background = #333333
        selection-foreground = #eeeeee
        palette = 0=#000000
        palette = 15 = #ffffff
        palette = 16=#123456
        palette = x=#123456
        palette = 3
        unknown-key = whatever
        """
        let t = try XCTUnwrap(TerminalTheme.parse(name: "Test", contents: contents))
        XCTAssertEqual(t.name, "Test")
        XCTAssertEqual(t.id, "Test")
        XCTAssertEqual(t.background, RGB(r: 16, g: 16, b: 16))
        XCTAssertEqual(t.foreground, RGB(r: 240, g: 240, b: 240))
        XCTAssertEqual(t.cursor, RGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(t.cursorText, RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(t.selectionBackground, RGB(hex: "#333333"))
        XCTAssertEqual(t.selectionForeground, RGB(hex: "#eeeeee"))
        XCTAssertEqual(t.palette.count, 16)
        XCTAssertEqual(t.palette[0], RGB(hex: "#000000"))
        XCTAssertEqual(t.palette[15], RGB(hex: "#ffffff"))
        XCTAssertEqual(t.palette[5], TerminalTheme.shellDark.palette[5], "missing entries come from Shell Dark")
        XCTAssertTrue(t.isDark)
    }

    func testThemeWithoutColorsIsRejected() {
        XCTAssertNil(TerminalTheme.parse(name: "x", contents: "background = #000000"))
        XCTAssertNil(TerminalTheme.parse(name: "x", contents: "foreground = #000000"))
        XCTAssertNil(TerminalTheme.parse(name: "x", contents: ""))
    }

    func testBuiltInThemes() {
        XCTAssertEqual(TerminalTheme.builtIn.map(\.name), ["Shell Dark", "Shell Light"])
        XCTAssertTrue(TerminalTheme.shellDark.isDark)
        XCTAssertFalse(TerminalTheme.shellLight.isDark)
        XCTAssertEqual(TerminalTheme.shellDark.accent, TerminalTheme.shellDark.palette[4])
        for t in TerminalTheme.builtIn { XCTAssertEqual(t.palette.count, 16) }
    }

    func testAccentFallsBackToForegroundWithAShortPalette() {
        var t = TerminalTheme.shellDark
        t.palette = Array(t.palette.prefix(3))
        XCTAssertEqual(t.accent, t.foreground)
    }

    func testApplyingOverrides() {
        var o = ColorOverrides()
        o.background = "#010203"
        o.foreground = "#040506"
        o.cursor = "#070809"
        o.selectionBackground = "#0a0b0c"
        o.selectionForeground = "#0d0e0f"
        o.palette = [2: "#ff0000", 99: "#00ff00", -1: "#0000ff", 3: "not a color"]
        let base = TerminalTheme.shellLight
        let t = base.applying(o)
        XCTAssertEqual(t.background, RGB(hex: "#010203"))
        XCTAssertEqual(t.foreground, RGB(hex: "#040506"))
        XCTAssertEqual(t.cursor, RGB(hex: "#070809"))
        XCTAssertEqual(t.selectionBackground, RGB(hex: "#0a0b0c"))
        XCTAssertEqual(t.selectionForeground, RGB(hex: "#0d0e0f"))
        XCTAssertEqual(t.palette[2], RGB(hex: "#ff0000"))
        XCTAssertEqual(t.palette[3], base.palette[3], "invalid colors are ignored")
        XCTAssertEqual(t.palette.count, 16, "out-of-range indexes are ignored")
    }

    func testEmptyOverridesChangeNothing() {
        XCTAssertEqual(TerminalTheme.shellDark.applying(ColorOverrides()), TerminalTheme.shellDark)
        var bad = ColorOverrides()
        bad.background = "nope"
        XCTAssertEqual(TerminalTheme.shellDark.applying(bad).background, TerminalTheme.shellDark.background)
    }

    // MARK: ThemeLibrary

    func testThemeDirectoriesIncludeTheSupportFolder() {
        let dirs = ThemeLibrary.themeDirectories
        XCTAssertTrue(dirs.contains(SettingsStore.supportDirectory.appendingPathComponent("themes")))
        XCTAssertTrue(dirs.contains { $0.path.hasSuffix(".config/ghostty/themes") })
    }

    func testFindsBuiltInsAndParsesUserThemesOnDemand() throws {
        let library = ThemeLibrary.shared
        XCTAssertEqual(library.theme(named: "Shell Dark"), TerminalTheme.shellDark)
        XCTAssertNil(library.theme(named: "No Such Theme \(UUID().uuidString)"))

        let dir = SettingsStore.supportDirectory.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "Settings Test Theme \(UUID().uuidString)"
        let file = dir.appendingPathComponent(name)
        try "background = #202020\nforeground = #dddddd\n".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }

        let t = try XCTUnwrap(library.theme(named: name))
        XCTAssertEqual(t.background, RGB(hex: "#202020"))
        // Cached after the first lookup, even once the file is gone.
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(library.theme(named: name), t)
    }

    func testResolvedPicksTheModeThemeAndAppliesOverrides() {
        var s = AppSettings()
        s.darkOverrides.background = "#000001"
        s.lightOverrides.foreground = "#000002"
        let library = ThemeLibrary.shared
        XCTAssertEqual(library.resolved(dark: true, settings: s).background, RGB(hex: "#000001"))
        XCTAssertEqual(library.resolved(dark: true, settings: s).name, "Shell Dark")
        XCTAssertEqual(library.resolved(dark: false, settings: s).foreground, RGB(hex: "#000002"))
        XCTAssertEqual(library.resolved(dark: false, settings: s).name, "Shell Light")
    }

    func testResolvedFallsBackToBuiltInsForUnknownThemes() {
        var s = AppSettings()
        s.darkTheme = "Missing \(UUID().uuidString)"
        s.lightTheme = "Missing \(UUID().uuidString)"
        XCTAssertEqual(ThemeLibrary.shared.resolved(dark: true, settings: s), TerminalTheme.shellDark)
        XCTAssertEqual(ThemeLibrary.shared.resolved(dark: false, settings: s), TerminalTheme.shellLight)
    }

    func testLoadsTheBundledCollection() {
        let library = ThemeLibrary.shared
        library.loadAsync()
        XCTAssertTrue(waitUntil(timeout: 10) { library.themes.count > TerminalTheme.builtIn.count })
        XCTAssertEqual(Array(library.themes.prefix(2)).map(\.name), ["Shell Dark", "Shell Light"], "built-ins stay first")
        XCTAssertEqual(Set(library.themes.map(\.name)).count, library.themes.count, "no duplicate names")
    }
}
