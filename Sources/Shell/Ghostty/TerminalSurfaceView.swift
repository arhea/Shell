import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Options used when creating a new terminal surface.
struct SurfaceOptions {
    var workingDirectory: String?
    var command: String?
    var environment: [String: String] = [:]
    var initialInput: String?
    var fontSize: Float?
    var waitAfterCommand = false
    var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW
}

/// An AppKit view hosting a single libghostty surface. libghostty renders into
/// this view's layer with Metal and owns the PTY; we translate input events.
///
/// Note: libghostty makes this a layer-hosting view, so it must not have
/// subviews. Overlays belong to the containing `PaneView`.
@MainActor
final class TerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    weak var session: TerminalSession?

    /// Called for every keyDown before it is sent to the terminal. Returning
    /// true consumes the event (used to redirect typing to the input editor).
    var keyInterceptor: ((NSEvent) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var onMouseDown: (() -> Void)?

    private(set) var focused = false
    private(set) var cellSize: CGSize = .zero
    var hoverURL: String? {
        didSet { if hoverURL != oldValue { onHoverURLChange?(hoverURL) } }
    }
    var onHoverURLChange: ((String?) -> Void)?
    var onScrollbarChange: ((UInt64, UInt64, UInt64) -> Void)?
    /// Pointer position in flipped (top-left) coordinates, or nil when it leaves.
    var onPointerMove: ((CGPoint?, NSEvent.ModifierFlags) -> Void)?
    var onScroll: (() -> Void)?
    /// Gets first look at left clicks (flipped point); return true to consume.
    var linkClickHandler: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
    /// Other surfaces that should receive this surface's key input (broadcast mode).
    var broadcastTargets: (() -> [TerminalSurfaceView])?
    private var isBroadcasting = false

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var contentSize: CGSize = .zero
    private var eventMonitor: Any?
    private var suppressNextLeftMouseUp = false
    private var prevPressureStage = 0

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init(options: SurfaceOptions) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            self?.localEvent(event) ?? event
        }

        guard let app = GhosttyRuntime.shared.app else { return }
        let created: ghostty_surface_t? = Self.withCConfig(options, view: self) { cfg in
            ghostty_surface_new(app, &cfg)
        }
        guard let created else {
            log.error("ghostty_surface_new failed")
            return
        }
        surface = created
        updateTrackingAreas()
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Frees the surface. Must be called when the pane closes; the PTY and
    /// child process are torn down by libghostty.
    func destroy() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let surface {
            ghostty_surface_free(surface)
        }
        surface = nil
    }

    private static func withCConfig<T>(_ o: SurfaceOptions, view: TerminalSurfaceView, _ body: (inout ghostty_surface_config_s) -> T) -> T {
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = o.fontSize ?? 0
        cfg.wait_after_command = o.waitAfterCommand
        cfg.context = o.context

        let keys = Array(o.environment.keys)
        let values = keys.map { o.environment[$0]! }
        let cKeys = keys.map { strdup($0) }
        let cValues = values.map { strdup($0) }
        defer {
            cKeys.forEach { free($0) }
            cValues.forEach { free($0) }
        }
        var env = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0.0, value: $0.1) }

        return o.workingDirectory.withCString { wd in
            cfg.working_directory = wd
            return o.command.withCString { cmd in
                cfg.command = cmd
                return o.initialInput.withCString { input in
                    cfg.initial_input = input
                    return env.withUnsafeMutableBufferPointer { buf in
                        cfg.env_vars = buf.baseAddress
                        cfg.env_var_count = buf.count
                        return body(&cfg)
                    }
                }
            }
        }
    }

    // MARK: - Public API

    /// Sends text as a paste (bracketed paste aware).
    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCStringLen { ghostty_surface_text(surface, $0, $1) }
    }

    /// Invokes a Ghostty binding action such as `copy_to_clipboard` or `text:\x1b[A`.
    @discardableResult
    func perform(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCStringLen { ghostty_surface_binding_action(surface, $0, $1) }
    }

    /// Writes raw bytes to the PTY (escaped for Ghostty's `text:` action).
    func writeRaw(_ text: String) {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case _ where scalar.value < 0x20 || scalar.value == 0x7f:
                escaped += String(format: "\\x%02x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        perform("text:\(escaped)")
    }

    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    var selectionText: String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Returns the visible viewport text, or the full scrollback when `screen` is true.
    func readText(screen: Bool = false) -> String {
        guard let surface else { return "" }
        let tag = screen ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    var foregroundPID: pid_t? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? pid_t(pid) : nil
    }

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    var terminalSize: ghostty_surface_size_s? {
        guard let surface else { return nil }
        return ghostty_surface_size(surface)
    }

    func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    func setColorScheme(dark: Bool) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    func setOcclusion(visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    // MARK: - Callbacks from runtime

    func cellSizeChanged(width: Double, height: Double) {
        // Ghostty reports backing pixels; convert to points.
        cellSize = convertFromBacking(NSSize(width: width, height: height))
    }

    func scrollbarChanged(total: UInt64, offset: UInt64, length: UInt64) {
        onScrollbarChange?(total, offset, length)
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: NSCursor.arrow.set()
        case GHOSTTY_MOUSE_SHAPE_TEXT: NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: NSCursor.crosshair.set()
        case GHOSTTY_MOUSE_SHAPE_GRAB: NSCursor.openHand.set()
        case GHOSTTY_MOUSE_SHAPE_GRABBING: NSCursor.closedHand.set()
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: NSCursor.operationNotAllowed.set()
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: NSCursor.resizeLeftRight.set()
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: NSCursor.resizeUpDown.set()
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: NSCursor.iBeamCursorForVerticalLayout.set()
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: NSCursor.contextualMenu.set()
        default: break
        }
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focusDidChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focusDidChange(false) }
        return ok
    }

    private func focusDidChange(_ focused: Bool) {
        guard self.focused != focused else { return }
        self.focused = focused
        if !focused { suppressNextLeftMouseUp = false }
        if let surface { ghostty_surface_set_focus(surface, focused) }
        onFocusChange?(focused)
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    private func sizeDidChange(_ size: CGSize) {
        contentSize = size
        guard let surface, size.width > 0, size.height > 0 else { return }
        let scaled = convertToBacking(size)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface else { return }
        let fb = convertToBacking(frame)
        let xScale = frame.width > 0 ? fb.width / frame.width : 2
        let yScale = frame.height > 0 ? fb.height / frame.height : 2
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        sizeDidChange(contentSize == .zero ? frame.size : contentSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if let surface, let screen = window.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
        viewDidChangeBackingProperties()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    // MARK: - Mouse

    private func localEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp:
            // Command-modified keys never deliver keyUp to the view.
            if focused, event.modifierFlags.contains(.command) { keyUp(with: event) }
            return event
        case .leftMouseDown:
            // Clicking into an unfocused pane should only focus it, not
            // send a click to the running program.
            guard event.window == window, let window,
                  window.isKeyWindow, !focused else { return event }
            let loc = convert(event.locationInWindow, from: nil)
            guard bounds.contains(loc), hitTest(convert(loc, to: superview)) === self else { return event }
            window.makeFirstResponder(self)
            onMouseDown?()
            suppressNextLeftMouseUp = true
            return nil
        default:
            return event
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        let p = convert(event.locationInWindow, from: nil)
        if let linkClickHandler, linkClickHandler(CGPoint(x: p.x, y: frame.height - p.y), event.modifierFlags) {
            suppressNextLeftMouseUp = true
            return
        }
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        prevPressureStage = 0
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GhosttyInput.mouseButton(event.buttonNumber), GhosttyInput.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GhosttyInput.mouseButton(event.buttonNumber), GhosttyInput.mods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags)) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags)) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerMove?(nil, event.modifierFlags)
        guard let surface else { return }
        if NSEvent.pressedMouseButtons != 0 { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    private func sendMousePos(_ event: NSEvent) {
        let pos = convert(event.locationInWindow, from: nil)
        onPointerMove?(CGPoint(x: pos.x, y: frame.height - pos.y), event.modifierFlags)
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?()
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyInput.scrollMods(precise: precise, momentum: event.momentumPhase))
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        guard prevPressureStage < 2 else { return }
        prevPressureStage = event.stage
        if event.stage == 2 { quickLook(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // If the program captured the mouse (e.g. vim with mouse=a) and control
        // isn't held, let the program handle right-click.
        if let surface, ghostty_surface_mouse_captured(surface), !event.modifierFlags.contains(.control) {
            return nil
        }
        let menu = NSMenu()
        if hasSelection {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Split Right", action: #selector(TerminalWindowController.splitRight(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Split Down", action: #selector(TerminalWindowController.splitDown(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Buffer", action: #selector(TerminalWindowController.clearBuffer(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        if let url = hoverURL {
            menu.insertItem(.separator(), at: 0)
            let item = NSMenuItem(title: "Open Link", action: #selector(openHoverLink(_:)), keyEquivalent: "")
            item.representedObject = url
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func openHoverLink(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String { _ = GhosttyRuntime.open(urlString: s) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if let keyInterceptor, keyInterceptor(event) { return }
        if !isBroadcasting, let targets = broadcastTargets?(), !targets.isEmpty {
            isBroadcasting = true
            for t in targets {
                t.isBroadcasting = true
                t.keyDown(with: event)
                t.isBroadcasting = false
            }
            isBroadcasting = false
        }
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        session?.userDidType()

        let translationModsGhostty = GhosttyInput.flags(
            ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let layoutBefore = markedTextBefore ? nil : KeyboardLayout.id
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && layoutBefore != KeyboardLayout.id { return }
        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                committedText(action, text: text)
            }
            if shouldReplayCommittedPreeditKey(translationEvent) {
                keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.suppressComposingControl(event.characters, composing: composing) { return }
            keyAction(action, event: event, translationEvent: translationEvent,
                      text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        if let window {
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(p) { onPointerMove?(CGPoint(x: p.x, y: frame.height - p.y), event.modifierFlags) }
        }
        let mods = GhosttyInput.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused else { return false }

        // Ghostty keybinds (terminal key mappings) take priority over menus.
        if let surface {
            var ev = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            var flags = ghostty_binding_flags_e(0)
            let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
                ev.text = ptr
                return ghostty_surface_key_is_binding(surface, ev, &flags)
            }
            if isBinding {
                keyDown(with: event)
                return true
            }
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: finalEvent)
        return true
    }

    @discardableResult
    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text = text?.keyEventText {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    private func committedText(_ action: ghostty_input_action_e, text: String) {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { ptr in
            ev.text = ptr
            _ = ghostty_surface_key(surface, ev)
        }
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: return true // down, right, up
        case 0x7B: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: return false
        }
    }

    private static func suppressComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let s = text.unicodeScalars.first else { return false }
        return s.value < 0x20
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            markedText.string.withCStringLen { ghostty_surface_preedit(surface, $0, $1) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    // MARK: - Edit actions

    @IBAction func copy(_ sender: Any?) {
        perform("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        // At an idle prompt the input editor owns the command line.
        if let session, session.acceptsEditorInput, let text = NSPasteboard.general.string(forType: .string) {
            session.insertIntoEditor(text)
            return
        }
        perform("paste_from_clipboard")
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    @IBAction override func selectAll(_ sender: Any?) {
        perform("select_all")
    }

    override func quickLook(with event: NSEvent) {
        guard let surface else { return super.quickLook(with: event) }
        var text = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &text) else { return super.quickLook(with: event) }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0 else { return super.quickLook(with: event) }
        var attrs: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attrs[.font] = font.takeUnretainedValue()
            font.release()
        }
        let pt = NSPoint(x: text.tl_px_x, y: frame.height - text.tl_px_y)
        showDefinition(for: NSAttributedString(string: String(cString: text.text), attributes: attrs), at: pt)
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let content: String?
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            content = urls.map { $0.isFileURL ? ShellEscape.quote($0.path) : $0.absoluteString }.joined(separator: " ")
        } else {
            content = pb.string(forType: .string)
        }
        guard let content else { return false }
        if let session, session.acceptsEditorInput {
            session.insertIntoEditor(content)
        } else {
            sendText(content)
        }
        return true
    }
}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0, y: Double = 0
        var w: Double = cellSize.width, h: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0, w > 0 {
            w = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.height - y, width: w, height: max(h, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if !chars.isEmpty { committedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }
}

/// Identifies the current keyboard input source so we can detect IME switches.
enum KeyboardLayout {
    static var id: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

import Carbon
