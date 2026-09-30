import AppKit
import Carbon

/// iTerm2-style hotkey window: a system-wide shortcut slides a terminal down
/// from the top of the current screen, over any app and any Space.
@MainActor
final class HotkeyWindow {
    static let shared = HotkeyWindow()

    private(set) var controller: TerminalWindowController?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var previousApp: NSRunningApplication?

    func configure() {
        unregister()
        let s = SettingsStore.shared.settings
        guard s.hotkeyWindow, let shortcut = s.hotkey, let keyCode = Self.keyCode(for: shortcut.key) else { return }
        register(keyCode: keyCode, modifiers: Self.carbonModifiers(shortcut.modifiers))
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyWindow.shared.toggle() } }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x5348_4C4C), id: 1) // 'SHLL'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    func toggle() {
        if let window = controller?.window, window.isVisible, window.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    private func makeController() -> TerminalWindowController {
        let c = TerminalWindowController.make()
        c.window?.level = .floating
        c.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        c.window?.animationBehavior = .utilityWindow
        c.onClose = { [weak self] _ in self?.controller = nil }
        c.newTab()
        return c
    }

    private func show() {
        let c = controller ?? makeController()
        controller = c
        guard let window = c.window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let height = frame.height * 0.45
        let target = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        window.setFrame(target.offsetBy(dx: 0, dy: height), display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }
        c.focusSelected()
    }

    private func hide() {
        guard let window = controller?.window else { return }
        let frame = window.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().setFrame(frame.offsetBy(dx: 0, dy: frame.height), display: true)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.setFrame(frame, display: false)
                if let prev = self.previousApp, prev != NSRunningApplication.current {
                    prev.activate()
                }
                self.previousApp = nil
            }
        })
    }

    static func carbonModifiers(_ mods: Set<KeyShortcut.Modifier>) -> UInt32 {
        var m: UInt32 = 0
        if mods.contains(.command) { m |= UInt32(cmdKey) }
        if mods.contains(.option) { m |= UInt32(optionKey) }
        if mods.contains(.control) { m |= UInt32(controlKey) }
        if mods.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// ANSI (US) virtual key codes.
    static func keyCode(for key: String) -> UInt32? {
        let table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ]
        return table[key].map(UInt32.init)
    }
}
