import AppKit
import GhosttyKit
import OSLog

/// The general logger; see `Log` for per-area ones.
let log = Log.app

/// Receives app-level actions from libghostty that need window management.
@MainActor
protocol GhosttyRuntimeDelegate: AnyObject {
    func ghosttyNewWindow(from surface: TerminalSurfaceView?)
    func ghosttyNewTab(from surface: TerminalSurfaceView?)
    func ghosttyNewSplit(from surface: TerminalSurfaceView, direction: SplitDirection)
    func ghosttyCloseSurface(_ surface: TerminalSurfaceView, processAlive: Bool)
    func ghosttyGotoSplit(from surface: TerminalSurfaceView, direction: ghostty_action_goto_split_e)
    func ghosttyToggleSplitZoom(from surface: TerminalSurfaceView)
    func ghosttyCloseAllWindows()
}

/// Owns the single `ghostty_app_t` for the process and bridges its C
/// callbacks onto the main thread.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    weak var delegate: GhosttyRuntimeDelegate?

    /// Diagnostics from the most recent config load, surfaced in Settings.
    private(set) var configDiagnostics: [String] = []

    private init() {}

    var isReady: Bool { app != nil }

    func start(configPath: String) -> Bool {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            log.critical("ghostty_init failed")
            return false
        }

        guard let cfg = Self.loadConfig(path: configPath, diagnostics: &configDiagnostics) else { return false }

        var runtime = Self.runtimeConfig(userdata: Unmanaged.passUnretained(self).toOpaque())

        guard let app = ghostty_app_new(&runtime, cfg) else {
            log.critical("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return false
        }
        self.app = app
        self.config = cfg
        ghostty_app_set_focus(app, NSApp.isActive)
        applyColorScheme(NSApp.effectiveAppearance)

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) }
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) }
            }
        }
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) }
            }
        }
        return true
    }

    /// libghostty calls these from its own threads. Built outside the main
    /// actor so the closures aren't inferred as main-actor-isolated (Swift
    /// would then trap on its isolation check); each one hops to main itself.
    nonisolated private static func runtimeConfig(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: true,
            wakeup_cb: { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyRuntime.shared.tick() } }
            },
            action_cb: { app, target, action in
                GhosttyRuntime.handleAction(app: app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                guard let userdata else { return }
                let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        GhosttyRuntime.shared.delegate?.ghosttyCloseSurface(view, processAlive: processAlive)
                    }
                }
            }
        )
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Reloads the configuration file and pushes it to every surface.
    func reload(configPath: String) {
        guard let app else { return }
        var diags: [String] = []
        guard let cfg = Self.loadConfig(path: configPath, diagnostics: &diags) else { return }
        configDiagnostics = diags
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    func applyColorScheme(_ appearance: NSAppearance) {
        guard let app else { return }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    private static func loadConfig(path: String, diagnostics: inout [String]) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_file(cfg, path)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        let count = ghostty_config_diagnostics_count(cfg)
        diagnostics = (0..<count).compactMap { i in
            let d = ghostty_config_get_diagnostic(cfg, i)
            return d.message.map { String(cString: $0) }
        }
        for d in diagnostics { log.warning("config: \(d, privacy: .public)") }
        return cfg
    }

    // MARK: - Actions

    private static func surfaceView(_ target: ghostty_target_s) -> TerminalSurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    nonisolated private static func handleAction(app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // libghostty invokes actions from within ghostty_app_tick / surface
        // calls, which we only ever make on the main thread.
        mainSync { shared.perform(target: target, action: action) }
    }

    private func perform(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view = Self.surfaceView(target)
        let session = view?.session

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
        case GHOSTTY_ACTION_NEW_WINDOW:
            delegate?.ghosttyNewWindow(from: view)
        case GHOSTTY_ACTION_NEW_TAB:
            delegate?.ghosttyNewTab(from: view)
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let view else { return false }
            let dir: SplitDirection
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_SPLIT_DIRECTION_UP: dir = .vertical
            default: dir = .horizontal
            }
            delegate?.ghosttyNewSplit(from: view, direction: dir)
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let view else { return false }
            delegate?.ghosttyGotoSplit(from: view, direction: action.action.goto_split)
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let view else { return false }
            delegate?.ghosttyToggleSplitZoom(from: view)
        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            delegate?.ghosttyCloseAllWindows()
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            view?.window?.toggleFullScreen(nil)
        case GHOSTTY_ACTION_SET_TITLE:
            if let p = action.action.set_title.title {
                session?.terminalTitleChanged(String(cString: p))
            }
        case GHOSTTY_ACTION_PWD:
            if let p = action.action.pwd.pwd {
                session?.workingDirectoryChanged(String(cString: p))
            }
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            session?.desktopNotification(title: title, body: body)
        case GHOSTTY_ACTION_RING_BELL:
            session?.bellRang()
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let v = action.action.command_finished
            session?.commandFinished(exitCode: v.exit_code >= 0 ? Int(v.exit_code) : nil,
                                     duration: TimeInterval(v.duration) / 1_000_000_000)
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let v = action.action.progress_report
            session?.progressChanged(state: v.state, percent: v.progress >= 0 ? Int(v.progress) : nil)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursorShape(action.action.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let v = action.action.mouse_over_link
            if v.len > 0, let url = v.url {
                view?.hoverURL = String(data: Data(bytes: url, count: v.len), encoding: .utf8)
            } else {
                view?.hoverURL = nil
            }
        case GHOSTTY_ACTION_OPEN_URL:
            let v = action.action.open_url
            guard let p = v.url else { return false }
            let str = String(data: Data(bytes: p, count: Int(v.len)), encoding: .utf8) ?? ""
            return Self.open(urlString: str)
        case GHOSTTY_ACTION_CELL_SIZE:
            let v = action.action.cell_size
            view?.cellSizeChanged(width: Double(v.width), height: Double(v.height))
        case GHOSTTY_ACTION_SCROLLBAR:
            let v = action.action.scrollbar
            view?.scrollbarChanged(total: v.total, offset: v.offset, length: v.len)
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            session?.searchStarted(needle: needle)
        case GHOSTTY_ACTION_END_SEARCH:
            session?.searchEnded()
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            session?.searchTotalChanged(Int(action.action.search_total.total))
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            session?.searchSelectedChanged(Int(action.action.search_selected.selected))
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let c = action.action.color_change
            if c.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                session?.backgroundColorChanged(NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
            }
        case GHOSTTY_ACTION_SECURE_INPUT:
            SecureInput.shared.apply(action.action.secure_input)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let v = action.action.child_exited
            session?.childExited(code: Int(v.exit_code), runtimeMs: v.timetime_ms)
            return session != nil
        case GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_RELOAD_CONFIG,
             GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_QUIT_TIMER,
             GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_SELECTION_CHANGED,
             GHOSTTY_ACTION_READONLY:
            return true
        default:
            return false
        }
        return true
    }

    static func open(urlString: String) -> Bool {
        let url: URL
        if let u = URL(string: urlString), u.scheme != nil {
            url = u
        } else {
            let expanded = (urlString as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
        }
        // Local files and folders are revealed in Finder rather than opened.
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }
        // Only allow schemes that make sense to open from terminal output.
        let allowed: Set<String> = ["http", "https", "file", "mailto", "ftp", "ssh", "vscode", "cursor", "zed", "x-man-page"]
        guard let scheme = url.scheme?.lowercased(), allowed.contains(scheme) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - Clipboard

    nonisolated private static func view(from userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    nonisolated private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        // C pointers from libghostty, only used during this synchronous call.
        let args = UncheckedSendable((userdata, state, mimes))
        return mainSync {
            let (userdata, state, mimes) = args.value
            guard let view = view(from: userdata), let surface = view.surface,
                  let pasteboard = NSPasteboard.ghostty(location) else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
            var contents: [(String, Data)] = []
            var seen = Set<String>()
            if let mimes {
                for i in 0..<mimesLen {
                    guard let p = mimes[i] else { continue }
                    let mime = String(cString: p)
                    guard seen.insert(mime).inserted, let data = pasteboard.ghosttyData(forMime: mime) else { continue }
                    contents.append((mime, data))
                }
            }
            let available = list ? pasteboard.ghosttyAvailableMimes() : []
            if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            completeClipboard(surface, contents: contents, available: available, state: state)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }
    }

    nonisolated private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        let args = UncheckedSendable((userdata, confirm, state))
        mainSync {
            let (userdata, confirm, state) = args.value
            guard let view = view(from: userdata), let surface = view.surface else { return }
            guard let confirm else {
                ghostty_surface_deny_clipboard_request(surface, state)
                return
            }
            let c = confirm.pointee
            var reps: [(String, Data)] = []
            if let contents = c.contents {
                for i in 0..<c.contents_len {
                    let item = contents[i]
                    let data = item.len > 0 ? Data(bytes: item.data, count: item.len) : Data()
                    reps.append((String(cString: item.mime), data))
                }
            }
            var avail: [String] = []
            if let a = c.available {
                for i in 0..<c.available_len { if let p = a[i] { avail.append(String(cString: p)) } }
            }
            let text = reps.first(where: { $0.0 == "text/plain" }).flatMap { String(data: $0.1, encoding: .utf8) }
                ?? reps.map { "\($0.0) (\($0.1.count) bytes)" }.joined(separator: "\n")

            let (title, message): (String, String)
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                title = "Paste potentially unsafe text?"
                message = "The text you are pasting contains line breaks or control characters that could run commands immediately."
            default:
                title = "Allow a program to read your clipboard?"
                message = "A program running in this terminal wants to read the clipboard contents."
            }
            ClipboardConfirmation.present(for: view, title: title, message: message, contents: text) { allowed in
                guard let surface = view.surface else { return }
                if allowed {
                    completeClipboard(surface, contents: reps, available: avail, state: state, confirmed: true)
                } else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                }
            }
        }
    }

    nonisolated private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        let items: [(String, Data)] = (0..<len).compactMap { i in
            guard let content, let mime = content[i].mime else { return nil }
            let c = content[i]
            let data = c.len > 0 && c.data != nil ? Data(bytes: c.data, count: c.len) : Data()
            return (String(cString: mime), data)
        }
        // Resolve the view now, while libghostty guarantees it's alive, and hold
        // a strong reference across the hop: the pane may close before the
        // block runs, and turning a raw address back into a view then would
        // read freed memory.
        let viewBox = UncheckedSendable(view(from: userdata))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let pasteboard = NSPasteboard.ghostty(location), !items.isEmpty else { return }
                let write = {
                    let types = items.compactMap { NSPasteboard.PasteboardType(mimeType: $0.0) }
                    pasteboard.declareTypes(types, owner: nil)
                    for (mime, data) in items {
                        guard let type = NSPasteboard.PasteboardType(mimeType: mime) else { continue }
                        pasteboard.setData(data, forType: type)
                    }
                }
                guard confirm else { write(); return }
                let text = items.first(where: { $0.0 == "text/plain" }).flatMap { String(data: $0.1, encoding: .utf8) } ?? ""
                guard let view = viewBox.value, view.surface != nil else { return }
                ClipboardConfirmation.present(
                    for: view,
                    title: "Allow a program to write to your clipboard?",
                    message: "A program running in this terminal wants to replace your clipboard contents.",
                    contents: text
                ) { allowed in if allowed { write() } }
            }
        }
    }

    private static func completeClipboard(
        _ surface: ghostty_surface_t,
        contents: [(String, Data)],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        var cContents: [ghostty_clipboard_content_s] = []
        for (mime, data) in contents {
            guard let m = strdup(mime) else { continue }
            cStrings.append(m)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
            buffers.append(buf)
            data.withUnsafeBytes { src in
                if let base = src.baseAddress { buf.copyMemory(from: base, byteCount: src.count) }
            }
            cContents.append(ghostty_clipboard_content_s(mime: m, data: buf.assumingMemoryBound(to: CChar.self), len: data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let s = strdup(mime) else { continue }
            cStrings.append(s)
            cAvailable.append(UnsafePointer(s))
        }
        cContents.withUnsafeBufferPointer { cb in
            cAvailable.withUnsafeBufferPointer { ab in
                var complete = ghostty_clipboard_complete_s(
                    contents: cb.baseAddress, contents_len: cb.count,
                    available: ab.baseAddress, available_len: ab.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }
}

/// Tracks secure keyboard entry requested by terminal programs or the user.
@MainActor
final class SecureInput {
    static let shared = SecureInput()
    private(set) var enabled = false

    func apply(_ mode: ghostty_action_secure_input_e) {
        switch mode {
        case GHOSTTY_SECURE_INPUT_ON: set(true)
        case GHOSTTY_SECURE_INPUT_OFF: set(false)
        default: set(!enabled)
        }
    }

    func set(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }
}

import Carbon

/// Sheet-based confirmation for clipboard access and unsafe pastes.
@MainActor
enum ClipboardConfirmation {
    static func present(for view: NSView, title: String, message: String, contents: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 140)
        if let tv = scroll.documentView as? NSTextView {
            tv.string = contents.count > 10_000 ? String(contents.prefix(10_000)) + "\n…" : contents
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        alert.accessoryView = scroll

        if let window = view.window {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

/// Runs `body` on the main actor, synchronously. libghostty calls back on the
/// main thread in practice, but this keeps us safe if that ever changes.
func mainSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}

/// Carries values that aren't `Sendable` (C pointers from libghostty) into a
/// synchronous main-actor hop. Only for values used during that call.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
