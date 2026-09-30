import AppKit

/// A keyboard shortcut: a key plus modifiers. `key` is a lowercase character
/// ("d", "[", "=") or a named key ("left", "return", "tab", "pageup", "f5").
struct KeyShortcut: Codable, Hashable {
    enum Modifier: String, Codable, CaseIterable {
        case control, option, shift, command
        var flag: NSEvent.ModifierFlags {
            switch self {
            case .control: .control
            case .option: .option
            case .shift: .shift
            case .command: .command
            }
        }
        var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    var key: String
    var modifiers: Set<Modifier>

    init(key: String, modifiers: Set<Modifier>) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    static func cmd(_ key: String) -> KeyShortcut { .init(key: key, modifiers: [.command]) }
    static func cmdShift(_ key: String) -> KeyShortcut { .init(key: key, modifiers: [.command, .shift]) }
    static func cmdOpt(_ key: String) -> KeyShortcut { .init(key: key, modifiers: [.command, .option]) }
    static func cmdCtrl(_ key: String) -> KeyShortcut { .init(key: key, modifiers: [.command, .control]) }

    var modifierFlags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.flag) }
    }

    private static let named: [String: (equivalent: Int, symbol: String, keyCode: UInt16)] = [
        "left": (NSLeftArrowFunctionKey, "←", 0x7B),
        "right": (NSRightArrowFunctionKey, "→", 0x7C),
        "down": (NSDownArrowFunctionKey, "↓", 0x7D),
        "up": (NSUpArrowFunctionKey, "↑", 0x7E),
        "return": (0x0D, "↩", 0x24),
        "enter": (0x03, "⌤", 0x4C),
        "tab": (0x09, "⇥", 0x30),
        "space": (0x20, "Space", 0x31),
        "delete": (0x08, "⌫", 0x33),
        "forwarddelete": (NSDeleteFunctionKey, "⌦", 0x75),
        "escape": (0x1B, "⎋", 0x35),
        "home": (NSHomeFunctionKey, "↖", 0x73),
        "end": (NSEndFunctionKey, "↘", 0x77),
        "pageup": (NSPageUpFunctionKey, "⇞", 0x74),
        "pagedown": (NSPageDownFunctionKey, "⇟", 0x79),
        "f1": (NSF1FunctionKey, "F1", 0x7A), "f2": (NSF2FunctionKey, "F2", 0x78),
        "f3": (NSF3FunctionKey, "F3", 0x63), "f4": (NSF4FunctionKey, "F4", 0x76),
        "f5": (NSF5FunctionKey, "F5", 0x60), "f6": (NSF6FunctionKey, "F6", 0x61),
        "f7": (NSF7FunctionKey, "F7", 0x62), "f8": (NSF8FunctionKey, "F8", 0x64),
        "f9": (NSF9FunctionKey, "F9", 0x65), "f10": (NSF10FunctionKey, "F10", 0x6D),
        "f11": (NSF11FunctionKey, "F11", 0x67), "f12": (NSF12FunctionKey, "F12", 0x6F),
    ]

    /// The string used for `NSMenuItem.keyEquivalent`.
    var keyEquivalent: String {
        if let n = Self.named[key], let scalar = UnicodeScalar(n.equivalent) {
            return String(Character(scalar))
        }
        return key
    }

    var displayString: String {
        let order: [Modifier] = [.control, .option, .shift, .command]
        let mods = order.filter { modifiers.contains($0) }.map(\.symbol).joined()
        let keyLabel = Self.named[key]?.symbol ?? key.uppercased()
        return mods + keyLabel
    }

    /// Builds a shortcut from a key event (used by the shortcut recorder).
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var mods = Set<Modifier>()
        let f = event.modifierFlags
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.shift) { mods.insert(.shift) }

        if let match = Self.named.first(where: { $0.value.keyCode == event.keyCode }) {
            self.init(key: match.key, modifiers: mods)
            return
        }
        // Use the unshifted character so ⇧⌘] records as "]" + shift.
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), let first = chars.first else { return nil }
        var key = String(first)
        if mods.contains(.shift), let base = event.characters(byApplyingModifiers: [])?.lowercased(), let b = base.first {
            key = String(b)
        }
        self.init(key: key, modifiers: mods)
    }

    /// True when this shortcut matches the given key-down event.
    func matches(_ event: NSEvent) -> Bool {
        guard let other = KeyShortcut(event: event) else { return false }
        return other == self
    }

    /// Ghostty keybind trigger syntax, e.g. `super+shift+d`.
    var ghosttyTrigger: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("super") }
        let map = ["left": "arrow_left", "right": "arrow_right", "up": "arrow_up", "down": "arrow_down",
                   "return": "enter", "delete": "backspace", "forwarddelete": "delete", "pageup": "page_up", "pagedown": "page_down"]
        parts.append(map[key] ?? key)
        return parts.joined(separator: "+")
    }
}
