import AppKit
import GhosttyKit

// Key/mouse translation between AppKit and libghostty. The heuristics here
// follow Ghostty's own macOS app (MIT licensed), which has years of real-world
// hardening around dead keys, IMEs and modifier handling.

enum GhosttyInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        case 8: return GHOSTTY_MOUSE_NINE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Packs precision/momentum into Ghostty's scroll mods bitfield.
    static func scrollMods(precise: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = precise ? 1 : 0
        let m: ghostty_input_mouse_momentum_e
        switch momentum {
        case .began: m = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: m = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: m = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: m = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: m = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: m = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: m = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        value |= Int32(m.rawValue) << 1
        return ghostty_input_scroll_mods_t(value)
    }
}

extension NSEvent {
    /// A Ghostty key event without `text`/`composing` (callers own those lifetimes).
    func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = GhosttyInput.mods(modifierFlags)
        // Control and command never contribute to text translation on macOS.
        ev.consumed_mods = GhosttyInput.mods((translationMods ?? modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            ev.unshifted_codepoint = scalar.value
        }
        return ev
    }

    /// Text to hand to Ghostty for this event. Control characters are sent
    /// without control applied because Ghostty's encoder handles that itself,
    /// and function-key private-use codepoints are dropped.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}

extension String {
    /// Ghostty treats a single control character as "no text" and encodes the
    /// key itself; anything else is passed through.
    var keyEventText: String? {
        if count == 1, let scalar = unicodeScalars.first, scalar.value < 0x20 { return nil }
        return self
    }

    /// Runs `body` with a C string and its UTF-8 byte length.
    func withCStringLen<T>(_ body: (UnsafePointer<CChar>, UInt) -> T) -> T {
        let len = UInt(utf8.count)
        return withCString { body($0, len) }
    }
}

extension String? {
    func withCString<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        if let value = self {
            return try value.withCString(body)
        }
        return try body(nil)
    }
}

extension NSPasteboard {
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION, GHOSTTY_CLIPBOARD_PRIMARY:
            return NSPasteboard(name: .init("app.bethesdalabs.Shell.selection"))
        default: return nil
        }
    }

    /// Returns data for a MIME type, mapping text/plain to the string
    /// representation (including file URLs, which become shell-escaped paths).
    func ghosttyData(forMime mime: String) -> Data? {
        if mime == "text/plain" || mime.hasPrefix("text/plain;") {
            if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
                let joined = urls.map { $0.isFileURL ? ShellEscape.quote($0.path) : $0.absoluteString }
                    .joined(separator: " ")
                return joined.data(using: .utf8)
            }
            return string(forType: .string)?.data(using: .utf8)
        }
        if let type = NSPasteboard.PasteboardType(mimeType: mime) {
            return data(forType: type)
        }
        return nil
    }

    func ghosttyAvailableMimes() -> [String] {
        var mimes: [String] = []
        for type in types ?? [] {
            if type == .string { mimes.append("text/plain"); continue }
            if let utType = UTType(type.rawValue), let mime = utType.preferredMIMEType {
                mimes.append(mime)
            }
        }
        return Array(Set(mimes))
    }
}

extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        switch mimeType {
        case "text/plain", "text/plain;charset=utf-8": self = .string
        case "text/html": self = .html
        case "image/png": self = .png
        case "image/tiff": self = .tiff
        default:
            guard let ut = UTType(mimeType: mimeType) else { return nil }
            self.init(ut.identifier)
        }
    }
}

import UniformTypeIdentifiers

enum ShellEscape {
    /// Escapes a path for pasting into a POSIX shell.
    static func quote(_ s: String) -> String {
        let special = CharacterSet(charactersIn: " \\\"'`$&|;<>()[]{}*?!#~=%^\t\n")
        var out = ""
        for ch in s.unicodeScalars {
            if special.contains(ch) { out.append("\\") }
            out.unicodeScalars.append(ch)
        }
        return out
    }
}
