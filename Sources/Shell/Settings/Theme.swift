import AppKit
import Observation

/// An sRGB color parsed from/serialized to `#rrggbb`.
struct RGB: Hashable, Codable {
    var r: UInt8, g: UInt8, b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = UInt8((v >> 16) & 0xFF); g = UInt8((v >> 8) & 0xFF); b = UInt8(v & 0xFF)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = UInt8((c.redComponent * 255).rounded())
        g = UInt8((c.greenComponent * 255).rounded())
        b = UInt8((c.blueComponent * 255).rounded())
    }

    var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }

    /// Relative luminance (0...1).
    var luminance: Double {
        func lin(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - t) + Double(b) * t).rounded()) }
        return RGB(r: m(r, other.r), g: m(g, other.g), b: m(b, other.b))
    }
}

struct TerminalTheme: Identifiable, Hashable {
    var name: String
    var background: RGB
    var foreground: RGB
    var cursor: RGB?
    var cursorText: RGB?
    var selectionBackground: RGB?
    var selectionForeground: RGB?
    var palette: [RGB] // 16 entries

    var id: String { name }
    var isDark: Bool { background.luminance < 0.4 }

    /// Accent used for UI chrome (tab indicators, prompt glyph).
    var accent: RGB { palette.count > 4 ? palette[4] : foreground }

    func applying(_ o: ColorOverrides) -> TerminalTheme {
        var t = self
        if let v = o.background.flatMap(RGB.init(hex:)) { t.background = v }
        if let v = o.foreground.flatMap(RGB.init(hex:)) { t.foreground = v }
        if let v = o.cursor.flatMap(RGB.init(hex:)) { t.cursor = v }
        if let v = o.selectionBackground.flatMap(RGB.init(hex:)) { t.selectionBackground = v }
        if let v = o.selectionForeground.flatMap(RGB.init(hex:)) { t.selectionForeground = v }
        for (i, hex) in o.palette where i >= 0 && i < t.palette.count {
            if let v = RGB(hex: hex) { t.palette[i] = v }
        }
        return t
    }

    /// Parses Ghostty's theme file format (`key = value`, `palette = N=#hex`).
    static func parse(name: String, contents: String) -> TerminalTheme? {
        var bg: RGB?, fg: RGB?, cursor: RGB?, cursorText: RGB?, selBg: RGB?, selFg: RGB?
        var palette = [RGB?](repeating: nil, count: 16)
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": bg = RGB(hex: value)
            case "foreground": fg = RGB(hex: value)
            case "cursor-color": cursor = RGB(hex: value)
            case "cursor-text": cursorText = RGB(hex: value)
            case "selection-background": selBg = RGB(hex: value)
            case "selection-foreground": selFg = RGB(hex: value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)), idx >= 0, idx < 16 {
                    palette[idx] = RGB(hex: String(parts[1]))
                }
            default: break
            }
        }
        guard let bg, let fg else { return nil }
        let defaults = TerminalTheme.shellDark.palette
        return TerminalTheme(
            name: name, background: bg, foreground: fg, cursor: cursor, cursorText: cursorText,
            selectionBackground: selBg, selectionForeground: selFg,
            palette: palette.enumerated().map { $0.element ?? defaults[$0.offset] })
    }

    // MARK: Built-in themes

    // Constant hex literals; ThemeTests loads both themes.
    // swiftlint:disable force_unwrapping
    static let shellDark = TerminalTheme(
        name: "Shell Dark",
        background: RGB(hex: "#15171c")!, foreground: RGB(hex: "#e4e6eb")!,
        cursor: RGB(hex: "#7aa2f7")!, cursorText: RGB(hex: "#15171c")!,
        selectionBackground: RGB(hex: "#2f3549")!, selectionForeground: nil,
        palette: ["#1f2229", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
                  "#545c7e", "#ff7a93", "#b9f27c", "#ff9e64", "#7da6ff", "#c7a9ff", "#a4daff", "#ffffff"]
            .map { RGB(hex: $0)! })

    static let shellLight = TerminalTheme(
        name: "Shell Light",
        background: RGB(hex: "#fbfbfc")!, foreground: RGB(hex: "#24292f")!,
        cursor: RGB(hex: "#0969da")!, cursorText: RGB(hex: "#ffffff")!,
        selectionBackground: RGB(hex: "#cfe3fb")!, selectionForeground: nil,
        palette: ["#24292f", "#cf222e", "#116329", "#9a6700", "#0969da", "#8250df", "#1b7c83", "#6e7781",
                  "#57606a", "#a40e26", "#1a7f37", "#7d4e00", "#218bff", "#a475f9", "#3192aa", "#8c959f"]
            .map { RGB(hex: $0)! })
    // swiftlint:enable force_unwrapping

    static let builtIn: [TerminalTheme] = [shellDark, shellLight]
}

/// Discovers themes: Shell's built-ins plus Ghostty's bundled collection
/// (~600 iTerm2-Color-Schemes) and any in ~/.config/ghostty/themes.
@MainActor
@Observable
final class ThemeLibrary {
    static let shared = ThemeLibrary()

    private(set) var themes: [TerminalTheme] = TerminalTheme.builtIn
    @ObservationIgnored private var byName: [String: TerminalTheme] = [:]

    private init() {
        for t in themes { byName[t.name] = t }
        loadAsync()
    }

    static var themeDirectories: [URL] {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes") { dirs.append(res) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent(".config/ghostty/themes"))
        dirs.append(SettingsStore.supportDirectory.appendingPathComponent("themes"))
        return dirs
    }

    func theme(named name: String) -> TerminalTheme? {
        if let t = byName[name] { return t }
        // Loading may still be in flight; parse this one synchronously.
        for dir in Self.themeDirectories {
            let url = dir.appendingPathComponent(name)
            if let s = try? String(contentsOf: url, encoding: .utf8), let t = TerminalTheme.parse(name: name, contents: s) {
                byName[name] = t
                return t
            }
        }
        return nil
    }

    func loadAsync() {
        let dirs = Self.themeDirectories
        Task.detached(priority: .utility) {
            var loaded: [TerminalTheme] = []
            let fm = FileManager.default
            for dir in dirs {
                guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for f in files where !f.hasPrefix(".") {
                    let url = dir.appendingPathComponent(f)
                    guard let s = try? String(contentsOf: url, encoding: .utf8),
                          let t = TerminalTheme.parse(name: f, contents: s) else { continue }
                    loaded.append(t)
                }
            }
            loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let result = loaded
            await MainActor.run {
                var all = TerminalTheme.builtIn
                var seen = Set(all.map(\.name))
                for t in result where seen.insert(t.name).inserted { all.append(t) }
                self.themes = all
                for t in all { self.byName[t.name] = t }
                ConfigController.shared.themesLoaded()
            }
        }
    }

    /// The theme for the current effective appearance, with user overrides applied.
    func resolved(dark: Bool, settings: AppSettings) -> TerminalTheme {
        let name = dark ? settings.darkTheme : settings.lightTheme
        let base = theme(named: name) ?? (dark ? TerminalTheme.shellDark : TerminalTheme.shellLight)
        return base.applying(dark ? settings.darkOverrides : settings.lightOverrides)
    }
}
